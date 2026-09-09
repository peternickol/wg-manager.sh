"""Exercise platform setup with fake package managers; no root/network required."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "wg-manager.sh"
HARNESS = r'''
source "$TEST_SCRIPT"
WG_CONFIG_DIR="$TEST_DIR/wireguard"

# Override discovery so fixtures cannot accidentally use the host's packages.
have_cmd() {
  [[ "$1" != "$MISSING_COMMAND" ]] || return 1
  case "$1" in
    omarchy) [[ "$HAS_OMARCHY" == 1 ]] ;;
    resolvconf) [[ "$HAS_RESOLVCONF" == 1 ]] ;;
    pacman|apt-get|apt-cache|dpkg-query|systemctl) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
record() { printf '%s\n' "$*" >> "$TEST_DIR/calls"; }
pacman() {
  if [[ "$1" == -Q ]]; then
    [[ " $INSTALLED " == *" $2 "* ]]
  else
    record pacman "$@"
    return "$PACKAGE_EXIT"
  fi
}
omarchy() { record omarchy "$@"; return "$PACKAGE_EXIT"; }
apt-get() {
  record apt-get "$@"
  if [[ "$1" == update ]]; then return "$UPDATE_EXIT"; fi
  return "$PACKAGE_EXIT"
}
dpkg-query() {
  if [[ " $INSTALLED " == *" ${@: -1} "* ]]; then
    printf 'install ok installed'
  else
    return 1
  fi
}
apt-cache() {
  if [[ " $AVAILABLE_RESOLVERS " == *" $2 "* ]]; then
    printf '  Candidate: 1.0\n'
  else
    printf '  Candidate: (none)\n'
  fi
}
systemctl() {
  [[ "$*" == 'is-active --quiet systemd-resolved' ]] || exit 99
  [[ "$RESOLVED_ACTIVE" == 1 ]]
}
install() { record install "$@"; }
require_root() { :; }

# Exercise real detection, then reuse the result when setup/hints detect again.
test_platform="$(detect_platform "$TEST_DIR/os-release")"
detect_platform() { printf '%s\n' "$test_platform"; }
'''


class SetupTests(unittest.TestCase):
    def run_script(self, action='main setup', os_release='ID=omarchy\n', **settings):
        with tempfile.TemporaryDirectory(prefix='wg-manager-test-') as directory:
            root = Path(directory)
            (root / 'os-release').write_text(os_release)
            env = dict(os.environ, TEST_SCRIPT=str(SCRIPT), TEST_DIR=directory,
                       HAS_OMARCHY='1', HAS_RESOLVCONF='0', INSTALLED='',
                       RESOLVED_ACTIVE='1', MISSING_COMMAND='', PACKAGE_EXIT='0', UPDATE_EXIT='0',
                       AVAILABLE_RESOLVERS='openresolv resolvconf')
            env.update(settings)
            result = subprocess.run(['bash', '-c', HARNESS + '\n' + action],
                                    env=env, text=True, capture_output=True)
            calls_file = root / 'calls'
            calls = calls_file.read_text().replace(directory, '<tmp>').splitlines() \
                if calls_file.exists() else []
            return result, calls

    def assert_setup(self, expected, **settings):
        result, calls = self.run_script(**settings)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, expected + [
            'install -d -m 700 -o root -g root <tmp>/wireguard'])
        return result

    def test_distribution_detection(self):
        cases = [
            ('ID=omarchy\nID_LIKE=arch\n', '0', 'omarchy'),
            ('ID=arch\n', '1', 'omarchy'),
            ('ID=arch\n', '0', 'arch'),
            ('ID=endeavouros\nID_LIKE=arch\n', '0', 'arch'),
            ('ID=debian\n', '0', 'debian'),
            ('ID=ubuntu\nID_LIKE=debian\n', '0', 'debian'),
            ('ID=linuxmint\nID_LIKE="ubuntu debian"\n', '0', 'debian'),
            ('ID=fedora\n', '1', 'unsupported'),
            ('ID=unknown\nID_LIKE=archlinux\n', '0', 'unsupported'),
            ('', '0', 'unsupported'),
        ]
        for fixture, omarchy, expected in cases:
            with self.subTest(fixture=fixture, omarchy=omarchy):
                result, calls = self.run_script('detect_platform', fixture,
                                                HAS_OMARCHY=omarchy)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(calls, [])

    def test_omarchy_with_resolved(self):
        self.assert_setup(['omarchy pkg add wireguard-tools nano systemd-resolvconf'])

    def test_only_missing_packages_are_installed(self):
        self.assert_setup(['omarchy pkg add wireguard-tools systemd-resolvconf'],
                          INSTALLED='nano')

    def test_existing_resolver_is_preserved(self):
        self.assert_setup(['omarchy pkg add wireguard-tools nano'],
                          HAS_RESOLVCONF='1')

    def test_inactive_resolved_uses_openresolv(self):
        self.assert_setup(['omarchy pkg add wireguard-tools nano openresolv'],
                          RESOLVED_ACTIVE='0')

    def test_no_systemctl_uses_openresolv(self):
        self.assert_setup(['omarchy pkg add wireguard-tools nano openresolv'],
                          MISSING_COMMAND='systemctl')

    def test_arch_uses_pacman_without_database_refresh(self):
        self.assert_setup(['pacman -S --needed --noconfirm wireguard-tools nano systemd-resolvconf'],
                          os_release='ID=arch\n', HAS_OMARCHY='0')

    def test_omarchy_without_cli_uses_pacman(self):
        self.assert_setup(['pacman -S --needed --noconfirm wireguard-tools nano systemd-resolvconf'],
                          HAS_OMARCHY='0')

    def test_fully_installed_omarchy_skips_package_manager(self):
        self.assert_setup([], INSTALLED='wireguard-tools nano systemd-resolvconf',
                          HAS_RESOLVCONF='1')

    def test_debian_prefers_openresolv(self):
        self.assert_setup(['apt-get update',
                           'apt-get install -y wireguard wireguard-tools nano openresolv'],
                          os_release='ID=debian\n')

    def test_ubuntu_falls_back_to_resolvconf(self):
        self.assert_setup(['apt-get update',
                           'apt-get install -y wireguard wireguard-tools nano resolvconf'],
                          os_release='ID=ubuntu\n', AVAILABLE_RESOLVERS='resolvconf')

    def test_debian_preserves_existing_resolver(self):
        self.assert_setup(['apt-get update', 'apt-get install -y wireguard-tools'],
                          os_release='ID=debian\n', INSTALLED='wireguard nano',
                          HAS_RESOLVCONF='1')

    def test_debian_without_available_resolver_warns(self):
        result = self.assert_setup(['apt-get update',
                                    'apt-get install -y wireguard wireguard-tools nano'],
                                   os_release='ID=debian\n', AVAILABLE_RESOLVERS='')
        self.assertIn('No resolvconf provider package is available', result.stderr)

    def test_fully_installed_debian_skips_package_manager(self):
        self.assert_setup([], os_release='ID=debian\n',
                          INSTALLED='wireguard wireguard-tools nano', HAS_RESOLVCONF='1')

    def test_quiet_setup_completes(self):
        for platform in ('omarchy', 'debian'):
            with self.subTest(platform=platform):
                result, calls = self.run_script('main --quiet setup', f'ID={platform}\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, '')
                self.assertTrue(calls[-1].startswith('install -d -m 700'))

    def test_package_failure_stops_before_directory_creation(self):
        for platform, omarchy in [('omarchy', '1'), ('arch', '0'), ('debian', '0')]:
            with self.subTest(platform=platform):
                result, calls = self.run_script(os_release=f'ID={platform}\n',
                                                HAS_OMARCHY=omarchy, PACKAGE_EXIT='23')
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertTrue(calls)
                self.assertFalse(any(call.startswith('install ') for call in calls))

    def test_missing_package_manager_is_reported(self):
        for platform, missing in [('omarchy', 'pacman'), ('debian', 'apt-get')]:
            with self.subTest(platform=platform):
                result, calls = self.run_script(os_release=f'ID={platform}\n',
                                                MISSING_COMMAND=missing)
                self.assertEqual(result.returncode, 1)
                self.assertIn(missing, result.stderr)
                self.assertEqual(calls, [])

    def test_debian_update_failure_stops_setup(self):
        result, calls = self.run_script(os_release='ID=debian\n', UPDATE_EXIT='23')
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(calls, ['apt-get update'])

    def test_unsupported_distribution_has_no_side_effects(self):
        result, calls = self.run_script(os_release='ID=fedora\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('setup supports', result.stderr)
        self.assertEqual(calls, [])

    def test_dependency_hints_match_platform(self):
        for platform, omarchy, expected in [
            ('omarchy', '1', 'omarchy pkg add qrencode'),
            ('omarchy', '0', 'sudo pacman -S --needed qrencode'),
            ('arch', '0', 'sudo pacman -S --needed qrencode'),
            ('debian', '0', 'sudo apt-get install qrencode'),
        ]:
            with self.subTest(platform=platform, omarchy=omarchy):
                result, calls = self.run_script('package_install_hint qrencode',
                                                f'ID={platform}\n', HAS_OMARCHY=omarchy)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
