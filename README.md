# wg-manager

`wg-manager` is a bash-first convenience wrapper around `wg-quick`.

It is meant to keep common WireGuard tasks simple on Debian, Ubuntu, Arch Linux,
and Omarchy without replacing the native tools underneath.

The installed launcher path is:

- `/usr/local/bin/wg-manager`

## Overview

`wg-manager` is designed as one small command with:

- smart default interface resolution
- direct config editing in `/etc/wireguard`
- safe config import and removal
- config viewing, redaction, strip output, and QR export
- optional systemd integration through `wg-quick@.service`
- simple health checks
- install, update, and bash completion helpers

## Target Platform

This project currently targets:

- Debian
- Ubuntu
- Arch Linux
- Omarchy

Setup detects the distribution from `/etc/os-release`. It uses `apt-get` on
Debian/Ubuntu, `omarchy pkg add` on Omarchy, and `pacman` on Arch Linux (or when
the Omarchy command is unavailable).

## Quick Install

Download and install from the public repository:

```bash
curl -fsSL https://raw.githubusercontent.com/peternickol/wg-manager.sh/master/wg-manager.sh -o wg-manager.sh
sudo bash wg-manager.sh install
rm wg-manager.sh
```

Quick update:

```bash
sudo wg-manager update
```

## Command Summary

```text
wg-manager [iface]
wg-manager toggle [iface]
wg-manager up [iface]
wg-manager down [iface]
wg-manager status [iface]
wg-manager list
wg-manager configs
wg-manager edit [iface]
wg-manager add [iface]
wg-manager import <file.conf> [iface] [--enable] [--start]
wg-manager show [iface] [--redact] [--qr] [--strip]
wg-manager remove <iface> [--force]
wg-manager enable [iface]
wg-manager disable [iface]
wg-manager start [iface]
wg-manager stop [iface]
wg-manager restart [iface]
wg-manager is-enabled [iface]
wg-manager is-active [iface]
wg-manager journal [iface]
wg-manager setup
wg-manager install [--force] [--no-completion]
wg-manager update [--no-completion]
wg-manager uninstall
wg-manager --check [iface]
wg-manager --check-handshake [iface]
wg-manager --help
wg-manager --version
```

## Default Interface Resolution

When no interface is provided:

- **0 configs**: fall back to `wg0`
- **1 config**: select it automatically
- **Multiple configs**: prompt on `/dev/tty` when interactive

If multiple configs exist and the session is non-interactive, the command exits
with an error and asks you to specify an interface explicitly.

This same default resolution is used by commands like `toggle`, `up`, `show`,
`status`, and `edit`.

## Install And Update

### `wg-manager install`

Install the current script to:

- `/usr/local/bin/wg-manager`

Examples:

```bash
./wg-manager.sh install
./wg-manager.sh install --force
./wg-manager.sh install --no-completion
```

`install` copies the script you are currently running. If you want the latest
published version from GitHub, use `wg-manager update` instead.

### `wg-manager update`

`update` downloads the latest public script from:

```text
https://raw.githubusercontent.com/peternickol/wg-manager.sh/master/wg-manager.sh
```

What it does:

- downloads the latest script with `curl` or `wget`
- syntax-checks the downloaded file with `bash -n`
- installs it to `/usr/local/bin/wg-manager`
- refreshes bash completion unless `--no-completion` is used

Examples:

```bash
sudo wg-manager update
sudo wg-manager update --no-completion
```

## Setup

`wg-manager setup` prepares a supported machine for WireGuard use and skips
packages that are already installed.

On Debian/Ubuntu, it installs:

- `wireguard`
- `wireguard-tools`
- a `resolvconf` provider (`openresolv` when available, otherwise `resolvconf`)
- `nano`

On Arch Linux/Omarchy, it installs:

- `wireguard-tools` (provides both `wg` and `wg-quick`)
- `nano`
- a `resolvconf` provider if the command is missing: `systemd-resolvconf` when
  `systemd-resolved` is active (the standard Omarchy setup), otherwise `openresolv`

Existing DNS providers are preserved. Setup does not change `/etc/resolv.conf`
or enable/restart network services. Arch package installation uses the existing
package databases; it does not refresh them or run a system upgrade.

It also prepares:

- `/etc/wireguard`

Example:

```bash
sudo wg-manager setup
```

On Omarchy, optional QR export and Bash completion dependencies can be installed
with:

```bash
omarchy pkg add qrencode bash-completion
```

## Command Reference

### `wg-manager`

With no arguments, `wg-manager` toggles the default-resolved interface.

Examples:

```bash
sudo wg-manager
sudo wg-manager wg1
```

### `wg-manager edit`

Open a config directly in `nano`:

```bash
sudo wg-manager edit
sudo wg-manager edit wg1
sudo wg-manager edit branch-office
```

This opens:

```text
/etc/wireguard/<name>.conf
```

If the config file does not exist yet, it is created first with:

- `root:root`
- mode `600`

`add` is accepted as a compatibility alias for `edit`.

### `wg-manager import`

Import a config into `/etc/wireguard`:

```bash
sudo wg-manager import myvpn.conf
sudo wg-manager import myvpn.conf wg1
sudo wg-manager import myvpn.conf --enable --start
```

Installed configs are written as:

```text
/etc/wireguard/<iface>.conf
```

Permissions are enforced as `root:root 600`.

### `wg-manager show`

Show a config:

```bash
sudo wg-manager show
sudo wg-manager show wg1
```

Common options:

- `--redact`
- `--qr`
- `--strip`

Examples:

```bash
sudo wg-manager show --redact
sudo wg-manager show --qr
sudo wg-manager show wg1 --strip --redact
```

`--qr` requires `qrencode`.

### `wg-manager remove`

Remove a config:

```bash
sudo wg-manager remove wg0
sudo wg-manager remove wg0 --force
```

Behavior:

- refuses removal while active unless `--force` is used
- disables the matching systemd unit first when systemd is present

### systemd commands

When systemd is available, `wg-manager` wraps:

```text
wg-quick@<iface>.service
```

Examples:

```bash
sudo wg-manager enable wg0
sudo wg-manager disable wg0
sudo wg-manager start wg0
sudo wg-manager stop wg0
sudo wg-manager restart wg0
sudo wg-manager journal wg0
```

If systemd is not present, `start`, `stop`, and `restart` fall back to
`wg-quick` behavior where supported.

### Health checks

Examples:

```bash
sudo wg-manager --check
sudo wg-manager --check-handshake
sudo wg-manager --check wg1
```

Exit codes:

- `0`: success, or interface is up and handshake is healthy when requested
- `2`: must be run as root
- `3`: config missing, unreadable, invalid, or default selection is ambiguous
- `4`: interface down, or removal refused due to active state
- `5`: handshake stale or missing

## Requirements

- root privileges
- systemd for systemd-specific commands
- bash-completion for completion install support
- qrencode for `show --qr`

## Development

Run the setup regression tests with Python 3 and Bash:

```bash
python3 -m unittest discover -s tests -v
```

The tests mock package installation, service queries, and privileged directory
creation; they do not require root or change the host's network configuration.

## License

This project is released under the MIT License. See `LICENSE`.
