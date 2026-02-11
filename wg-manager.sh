#!/usr/bin/env bash
#
# wg-manager.sh
# -----------------------------------------------------------------------------
# WireGuard convenience wrapper around wg-quick (+ systemd integration).
#
# Purpose:
#   This tool DOES NOT replace wg-quick. It wraps it to simplify common tasks:
#     • import configs
#     • list configs
#     • show configs (with --redact / --qr / --strip)
#     • remove configs
#     • enable/disable connections (systemd wg-quick@.service)
#     • start/stop/toggle connections
#     • install itself + bash completion
#
# Default interface resolution (when iface is omitted):
#   - If /etc/wireguard has NO *.conf files: uses fallback (wg0)
#   - If exactly ONE config exists: uses that interface automatically
#   - If multiple configs exist: prompts you to choose (1.) 2.) 3.) ...
#       • Uses /dev/tty when available (works with sudo/sudo-rs)
#       • If non-interactive, errors and requires you to specify an interface
#
# Notes:
#   - Imported configs are installed as /etc/wireguard/<iface>.conf with root:root 600
#   - wg-manager sanitizes PATH when running wg-quick/systemctl:
#       PATH=/usr/sbin:/usr/bin:/sbin:/bin
#   - Warns once if /usr/bin/stat is not GNU coreutils (wg-quick assumptions).
# -----------------------------------------------------------------------------

set -euo pipefail

########################################
# Configuration
########################################
VERSION="1.4.0"

WG_CONFIG_DIR="/etc/wireguard"
HANDSHAKE_MAX_AGE=180   # seconds, used by --check-handshake

# If no configs exist, default to this interface name:
DEFAULT_INTERFACE_FALLBACK="wg0"

INSTALL_PATH="/usr/local/sbin/wg-manager"
BASH_COMPLETION_NAME="wg-manager"
########################################

SCRIPT_NAME="$(basename "$0")"

# Global flags
QUIET=0
FORCE=0

CHECK_ONLY=0
CHECK_HANDSHAKE=0

NO_COMPLETION=0
COMPLETION_ONLY=0
UNINSTALL_COMPLETION=0

# Import flags (parsed after "import")
IMPORT_ENABLE=0
IMPORT_START=0

# Show flags (parsed after "show")
SHOW_REDACT=0
SHOW_QR=0
SHOW_STRIP=0

# Warn-once latch
STAT_WARNED=0

# Resolved default iface cache (avoid multiple prompts)
RESOLVED_DEFAULT_INTERFACE=""

########################################
# Color Setup (script messages only)
########################################
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_INFO=$'\e[36m'     # cyan
  C_OK=$'\e[32m'       # green
  C_WARN=$'\e[33m'     # yellow
  C_ERR=$'\e[31m'      # red
else
  C_RESET="" C_INFO="" C_OK="" C_WARN="" C_ERR=""
fi

log()  { [[ "$QUIET" -eq 0 ]] && printf '%s%s%s\n' "$C_INFO" "$*" "$C_RESET"; }
ok()   { [[ "$QUIET" -eq 0 ]] && printf '%s%s%s\n' "$C_OK"   "$*" "$C_RESET"; }
warn() { [[ "$QUIET" -eq 0 ]] && printf '%s%s%s\n' "$C_WARN" "$*" "$C_RESET" >&2; }
die()  { printf '%sError: %s%s\n' "$C_ERR" "$*" "$C_RESET" >&2; exit 1; }

show_version() {
  printf '%s%s v%s%s\n' "$C_INFO" "wg-manager" "$VERSION" "$C_RESET"
  exit 0
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [global-options] [command] [args...]

Default interface resolution (when iface is omitted):
  - 0 configs in ${WG_CONFIG_DIR}: uses ${DEFAULT_INTERFACE_FALLBACK}
  - 1 config: uses that config name automatically
  - multiple configs: prompts to choose (interactive via /dev/tty), otherwise errors

Default behavior:
  - No args                              => toggle the default-resolved interface
  - If first arg is an interface name    => toggle that interface

Core commands:
  toggle [iface]          Toggle interface UP/DOWN (wg-quick)
  up [iface]              Bring interface up (wg-quick)
  down [iface]            Bring interface down (wg-quick)
  status [iface]          Show interface status (wg + ip link)
  list                    List active WireGuard interfaces (wg show interfaces)

Config commands:
  import <file.conf> [iface] [--enable] [--start]
                          Install config into ${WG_CONFIG_DIR}/<iface>.conf (600)
  configs                 List available configs in ${WG_CONFIG_DIR}
  show [iface] [--redact] [--qr] [--strip]
                          Display config (optionally redacted, as QR, or stripped via wg-quick)
  remove <iface>          Remove config (disables systemd unit first). Refuses if active unless --force

Systemd commands (wg-quick@.service):
  enable [iface]          systemctl enable wg-quick@<iface>
  disable [iface]         systemctl disable wg-quick@<iface>
  start [iface]           systemctl start wg-quick@<iface>  (falls back to wg-quick if no systemd)
  stop [iface]            systemctl stop wg-quick@<iface>   (falls back to wg-quick if no systemd)
  restart [iface]         systemctl restart wg-quick@<iface> (fallback supported)
  is-enabled [iface]      Show whether unit is enabled
  is-active [iface]       Show whether unit is active
  journal [iface]         Tail logs: journalctl -u wg-quick@<iface> -f

Install commands:
  install                 Install script to: ${INSTALL_PATH}
  uninstall               Remove installed script at: ${INSTALL_PATH}

Global options:
  -q, --quiet             Suppress script messages (wg-quick/systemctl errors still show)
  -f, --force             Allow overwrite (import/install) or force remove while active
  -V, --version           Show version information
  -h, --help              Show this help

Health checks:
  --check [iface]         Exit 0 if UP else 4 (no changes)
  --check-handshake [iface]
                          Like --check, but fails with 5 if handshake stale/missing

Install options:
  --no-completion         Install binary only (skip bash completion)
  --completion-only       Install bash completion only
  --uninstall-completion  Remove installed bash completion

Import options (must appear after "import"):
  --enable                Enable wg-quick@<iface> after import (systemd)
  --start                 Start wg-quick@<iface> after import (systemd; fallback to wg-quick)

Exit codes:
  0  Success / interface UP (and handshake OK if requested)
  2  Must be run as root
  3  Config missing/unreadable/invalid, or ambiguous default selection
  4  Interface DOWN / refused due to active state (remove)
  5  Handshake stale/missing (with --check-handshake)
EOF
  exit 0
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf '%sError: must be run as root. Try: sudo %s %s%s\n' \
      "$C_ERR" "$SCRIPT_NAME" "${*:-}" "$C_RESET" >&2
    exit 2
  fi
}

########################################
# Helpers
########################################
cfg_path() { echo "${WG_CONFIG_DIR}/$1.conf"; }
unit_name() { echo "wg-quick@$1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1
}

is_up() { ip link show "$1" &>/dev/null; }

list_config_ifaces() {
  if [[ -d "$WG_CONFIG_DIR" ]]; then
    command ls -1 "$WG_CONFIG_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' || true
  fi
}

resolve_default_interface() {
  if [[ -n "$RESOLVED_DEFAULT_INTERFACE" ]]; then
    echo "$RESOLVED_DEFAULT_INTERFACE"
    return 0
  fi

  local -a ifaces=()
  mapfile -t ifaces < <(list_config_ifaces)

  if [[ "${#ifaces[@]}" -eq 0 ]]; then
    RESOLVED_DEFAULT_INTERFACE="$DEFAULT_INTERFACE_FALLBACK"
    echo "$RESOLVED_DEFAULT_INTERFACE"
    return 0
  fi

  if [[ "${#ifaces[@]}" -eq 1 ]]; then
    RESOLVED_DEFAULT_INTERFACE="${ifaces[0]}"
    echo "$RESOLVED_DEFAULT_INTERFACE"
    return 0
  fi

  # Multiple configs: prompt via /dev/tty if possible (works under sudo/sudo-rs)
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    # fd 3: read from tty, fd 4: write to tty
    exec 3</dev/tty 4>/dev/tty

    {
      echo "Multiple WireGuard configs found in $WG_CONFIG_DIR:"
      local i
      for i in "${!ifaces[@]}"; do
        printf "  %d.) %s\n" "$((i+1))" "${ifaces[$i]}"
      done

      while true; do
        printf "Select interface [1-%d] (or 'q' to quit): " "${#ifaces[@]}"
        local choice
        IFS= read -r choice
        [[ "$choice" == "q" || "$choice" == "Q" ]] && exit 1

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
          RESOLVED_DEFAULT_INTERFACE="${ifaces[$((choice-1))]}"
          break
        fi
        echo "Invalid selection."
      done
    } >&4 <&3

    exec 3<&- 4>&-

    # IMPORTANT: print selection to stdout for callers (do NOT send to tty)
    echo "$RESOLVED_DEFAULT_INTERFACE"
    return 0
  fi

  printf '%sError: multiple WireGuard configs found; specify an interface explicitly.%s\n' "$C_ERR" "$C_RESET" >&2
  printf '%sAvailable configs:%s\n' "$C_WARN" "$C_RESET" >&2
  printf '  %s\n' "${ifaces[@]}" >&2
  exit 3
}

get_interface() {
  local requested="${1:-}"
  local iface

  if [[ -n "$requested" ]]; then
    iface="$requested"
  else
    iface="$(resolve_default_interface)"
  fi

  [[ -n "${iface:-}" ]] || die "No interface selected."
  echo "$iface"
}

check_config_readable() {
  local iface="$1" cfg
  cfg="$(cfg_path "$iface")"

  if [[ ! -e "$cfg" ]]; then
    printf '%sError: %s not found.%s\n' "$C_ERR" "$cfg" "$C_RESET" >&2
    exit 3
  fi
  if [[ ! -r "$cfg" ]]; then
    printf '%sError: cannot read %s (permission denied).%s\n' "$C_ERR" "$cfg" "$C_RESET" >&2
    printf '%sHint: run with sudo. Details:%s\n' "$C_WARN" "$C_RESET" >&2
    ls -l "$cfg" >&2 || true
    exit 3
  fi
}

validate_conf_file() {
  local src="$1"
  [[ -f "$src" ]] || { printf '%sError: %s is not a file.%s\n' "$C_ERR" "$src" "$C_RESET" >&2; exit 3; }
  [[ -r "$src" ]] || { printf '%sError: cannot read %s.%s\n' "$C_ERR" "$src" "$C_RESET" >&2; exit 3; }
  grep -Eq '^[[:space:]]*\[Interface\][[:space:]]*$' "$src" \
    || { printf '%sError: %s missing [Interface].%s\n' "$C_ERR" "$src" "$C_RESET" >&2; exit 3; }
}

derive_iface_from_filename() {
  local src="$1" base
  base="$(basename "$src")"
  echo "${base%.conf}"
}

check_handshake_health() {
  local iface="$1" latest now age
  latest="$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -n1 || true)"
  [[ -z "${latest:-}" ]] && return 5
  [[ "$latest" -eq 0 ]] && return 5
  now="$(date +%s)"
  age=$(( now - latest ))
  (( age <= HANDSHAKE_MAX_AGE )) || return 5
  return 0
}

warn_if_non_gnu_stat() {
  [[ "$STAT_WARNED" -eq 1 ]] && return 0
  STAT_WARNED=1

  local statbin="/usr/bin/stat"
  if [[ ! -x "$statbin" ]]; then
    statbin="$(which stat 2>/dev/null || true)"
  fi
  [[ -n "${statbin:-}" ]] || return 0

  local ver
  ver="$("$statbin" --version 2>/dev/null | head -n1 || true)"

  if [[ "$ver" != *"GNU coreutils"* ]]; then
    warn "Non-GNU stat detected: $ver"
    warn "wg-quick expects GNU coreutils behavior; you may see permission-check errors."
    warn "Tip (Ubuntu/Debian): sudo apt-get install --reinstall coreutils"
  fi
}

redact_privatekey_stream() {
  sed -E 's/^([[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*).*/\1(REDACTED)/I'
}

print_config_as_qr() {
  if ! have_cmd qrencode; then
    die "qrencode not found. Install it (Debian/Ubuntu): sudo apt-get install qrencode"
  fi
  if qrencode -t ANSIUTF8 -o - >/dev/null 2>&1 <<<"test"; then
    qrencode -t ANSIUTF8 -o -
  else
    qrencode -t ANSI -o -
  fi
}

########################################
# Exec wrappers (PATH-sanitized)
########################################
run_wgquick() {
  local action="$1" iface="$2"
  local SAFE_PATH="/usr/sbin:/usr/bin:/sbin:/bin"

  warn_if_non_gnu_stat

  if [[ "$QUIET" -eq 1 ]]; then
    env PATH="$SAFE_PATH" wg-quick "$action" "$iface" 1>/dev/null
  else
    env PATH="$SAFE_PATH" wg-quick "$action" "$iface"
  fi
}

run_systemctl() {
  local SAFE_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
  local args=("$@")

  if [[ "$QUIET" -eq 1 ]]; then
    env PATH="$SAFE_PATH" systemctl "${args[@]}" 1>/dev/null
  else
    env PATH="$SAFE_PATH" systemctl "${args[@]}"
  fi
}

########################################
# Bash completion generation + install
########################################
generate_bash_completion() {
  cat <<'EOF'
# bash completion for wg-manager

_wg_manager()
{
  local cur prev words cword
  _init_completion -n : || return

  local commands="toggle up down status list import configs show remove enable disable start stop restart is-enabled is-active journal install uninstall"
  local opts="--check --check-handshake --quiet --force --help --version --no-completion --completion-only --uninstall-completion -q -f -h -V"
  local show_opts="--redact --qr --strip"

  local ifaces=""
  if [[ -d /etc/wireguard ]]; then
    ifaces="$(command ls -1 /etc/wireguard/*.conf 2>/dev/null \
      | sed 's#.*/##; s#\.conf$##' | tr '\n' ' ')"
  fi

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$opts $commands $ifaces" -- "$cur") )
    return 0
  fi

  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$opts --enable --start $show_opts" -- "$cur") )
    return 0
  fi

  case "${words[1]}" in
    toggle|up|down|status|enable|disable|start|stop|restart|is-enabled|is-active|journal|remove|show)
      COMPREPLY=( $(compgen -W "$ifaces" -- "$cur") )
      ;;
    import)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null || true
      elif [[ $cword -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "$ifaces" -- "$cur") )
      fi
      ;;
  esac
}

complete -F _wg_manager wg-manager
EOF
}

detect_completion_dir() {
  if [[ -d /usr/share/bash-completion ]]; then
    mkdir -p /usr/share/bash-completion/completions 2>/dev/null || true
    if [[ -d /usr/share/bash-completion/completions ]]; then
      echo "/usr/share/bash-completion/completions"
      return 0
    fi
  fi
  if [[ -d /etc/bash_completion.d ]]; then
    echo "/etc/bash_completion.d"
    return 0
  fi
  return 1
}

install_completion() {
  local dir file
  dir="$(detect_completion_dir)" || { warn "No bash-completion directory found. Skipping completion install."; return 0; }

  mkdir -p "$dir" 2>/dev/null || true
  file="$dir/$BASH_COMPLETION_NAME"

  if [[ -e "$file" && "$FORCE" -ne 1 ]]; then
    die "Completion already exists at $file (use --force to overwrite)."
  fi

  log "Installing bash completion → $file"
  if ! generate_bash_completion | install -m 0644 /dev/stdin "$file"; then
    if [[ "$dir" != "/etc/bash_completion.d" ]]; then
      warn "Install failed at $file; retrying in /etc/bash_completion.d"
      mkdir -p /etc/bash_completion.d 2>/dev/null || true
      file="/etc/bash_completion.d/$BASH_COMPLETION_NAME"
      generate_bash_completion | install -m 0644 /dev/stdin "$file"
    else
      die "Failed to install bash completion."
    fi
  fi

  ok "Bash completion installed."
}

uninstall_completion() {
  local dir file
  dir="$(detect_completion_dir)" || { warn "No bash-completion directory found."; return 0; }
  file="$dir/$BASH_COMPLETION_NAME"

  if [[ ! -e "$file" ]]; then
    warn "No completion installed at $file"
    return 0
  fi

  log "Removing bash completion → $file"
  rm -f "$file"
  ok "Bash completion removed."
}

########################################
# Install routines
########################################
self_path() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$0" 2>/dev/null || echo "$0"
  else
    echo "$0"
  fi
}

cmd_install() {
  local src dest
  src="$(self_path)"
  dest="$INSTALL_PATH"

  if [[ "$UNINSTALL_COMPLETION" -eq 1 ]]; then
    uninstall_completion
    exit 0
  fi
  if [[ "$COMPLETION_ONLY" -eq 1 ]]; then
    install_completion
    exit 0
  fi

  [[ -f "$src" ]] || die "Cannot locate script file to install (source: $src)."

  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    die "$dest already exists. Re-run with --force to overwrite."
  fi

  log "Installing $src → $dest"
  install -m 0755 -o root -g root "$src" "$dest"
  ok "Installed binary: $dest"

  if [[ "$NO_COMPLETION" -eq 0 ]]; then
    install_completion
  else
    log "Skipping completion installation (--no-completion)."
  fi

  log "Installation complete. Try: sudo wg-manager --version"
}

cmd_uninstall() {
  local dest="$INSTALL_PATH"
  if [[ ! -e "$dest" ]]; then
    warn "Not installed: $dest does not exist."
    exit 0
  fi
  log "Removing $dest"
  rm -f "$dest"
  ok "Removed: $dest"
}

########################################
# Core wg-quick wrappers
########################################
cmd_up() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"
  log "Bringing up $iface..."
  run_wgquick up "$iface"
  ok "$iface is now UP"
}

cmd_down() {
  local iface
  iface="$(get_interface "${1:-}")"
  [[ -n "$iface" ]] || die "No interface selected."
  log "Bringing down $iface..."
  run_wgquick down "$iface"
  ok "$iface is now DOWN"
}

cmd_toggle() {
  local iface
  iface="$(get_interface "${1:-}")"
  [[ -n "$iface" ]] || die "No interface selected."

  check_config_readable "$iface"

  if is_up "$iface"; then
    log "$iface is UP → bringing DOWN"
    run_wgquick down "$iface"
    ok "$iface is now DOWN"
  else
    log "$iface is DOWN → bringing UP"
    run_wgquick up "$iface"
    ok "$iface is now UP"
  fi
}

cmd_status() {
  local iface
  iface="$(get_interface "${1:-}")"
  if is_up "$iface"; then
    log "Interface $iface is UP"
    if [[ "$QUIET" -eq 0 ]]; then
      echo "--------------------------"
      wg show "$iface"
    fi
    exit 0
  else
    log "Interface $iface is DOWN"
    exit 4
  fi
}

cmd_list() {
  if [[ "$QUIET" -eq 0 ]]; then
    wg show interfaces || echo "No active WireGuard interfaces."
  else
    wg show interfaces 1>/dev/null || true
  fi
}

########################################
# Health checks
########################################
cmd_check() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"

  if ! is_up "$iface"; then
    log "$iface is DOWN"
    exit 4
  fi

  log "$iface is UP"

  if [[ "$CHECK_HANDSHAKE" -eq 1 ]]; then
    if check_handshake_health "$iface"; then
      ok "Handshake OK"
      exit 0
    else
      log "Handshake stale/missing (>${HANDSHAKE_MAX_AGE}s or never)"
      exit 5
    fi
  fi

  exit 0
}

########################################
# Config management
########################################
cmd_configs() {
  log "Configs in $WG_CONFIG_DIR:"
  local any=0
  local iface cfg enabled active

  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    any=1
    cfg="$(cfg_path "$iface")"

    enabled="n/a"
    active="n/a"

    if has_systemd; then
      if systemctl is-enabled "$(unit_name "$iface")" >/dev/null 2>&1; then enabled="enabled"; else enabled="disabled"; fi
      if systemctl is-active  "$(unit_name "$iface")" >/dev/null 2>&1; then active="active";  else active="inactive";  fi
    else
      enabled="(no systemd)"
      active="$(is_up "$iface" && echo active || echo inactive)"
    fi

    if [[ "$QUIET" -eq 0 ]]; then
      printf "  %-16s  %-10s  %-10s  %s\n" "$iface" "$enabled" "$active" "$cfg"
    fi
  done < <(list_config_ifaces)

  if [[ "$any" -eq 0 ]]; then
    [[ "$QUIET" -eq 0 ]] && echo "  (none)"
  fi
}

cmd_import() {
  local src="${1:-}" iface="${2:-}"
  [[ -n "$src" ]] || die "import requires a source .conf file (e.g. import my.conf)."

  validate_conf_file "$src"
  if [[ -z "$iface" ]]; then
    iface="$(derive_iface_from_filename "$src")"
  fi
  [[ -n "$iface" ]] || die "Could not determine interface name."

  local dest
  dest="$(cfg_path "$iface")"

  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    die "$dest already exists. Use --force to overwrite."
  fi

  log "Importing $src → $dest"
  install -m 600 -o root -g root "$src" "$dest"
  ok "Installed config: $dest (root:root, 600)"

  if have_cmd wg-quick; then
    if ! wg-quick strip "$iface" >/dev/null 2>&1; then
      warn "Note: wg-quick could not parse the imported config cleanly. Please review:"
      warn "  $dest"
    fi
  fi

  if [[ "$IMPORT_ENABLE" -eq 1 ]]; then
    cmd_enable "$iface"
  fi
  if [[ "$IMPORT_START" -eq 1 ]]; then
    cmd_start "$iface"
  fi
}

cmd_show() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"
  local cfg
  cfg="$(cfg_path "$iface")"

  if [[ "$SHOW_STRIP" -eq 1 ]]; then
    have_cmd wg-quick || die "wg-quick not found."

    if [[ "$QUIET" -eq 0 ]]; then
      printf '%s=== stripped: %s ===%s\n' "$C_INFO" "$cfg" "$C_RESET"
    fi

    local out
    out="$(wg-quick strip "$iface" 2>&1)" || {
      printf '%sError: wg-quick strip failed for %s%s\n' "$C_ERR" "$iface" "$C_RESET" >&2
      printf '%s%s%s\n' "$C_ERR" "$out" "$C_RESET" >&2
      exit 3
    }

    if [[ "$SHOW_REDACT" -eq 1 ]]; then
      out="$(printf '%s\n' "$out" | redact_privatekey_stream)"
    fi

    if [[ "$SHOW_QR" -eq 1 ]]; then
      printf '%s' "$out" | print_config_as_qr
    else
      printf '%s\n' "$out"
    fi
    return 0
  fi

  if [[ "$QUIET" -eq 0 ]]; then
    printf '%s=== %s ===%s\n' "$C_INFO" "$cfg" "$C_RESET"
  fi

  if [[ "$SHOW_REDACT" -eq 1 ]]; then
    if [[ "$SHOW_QR" -eq 1 ]]; then
      cat "$cfg" | redact_privatekey_stream | print_config_as_qr
    else
      cat "$cfg" | redact_privatekey_stream
    fi
  else
    if [[ "$SHOW_QR" -eq 1 ]]; then
      cat "$cfg" | print_config_as_qr
    else
      cat "$cfg"
    fi
  fi
}

cmd_remove() {
  local iface
  iface="$(get_interface "${1:-}")"
  [[ -n "$iface" ]] || die "remove requires an interface name."

  local cfg
  cfg="$(cfg_path "$iface")"
  [[ -e "$cfg" ]] || { printf '%sError: %s not found.%s\n' "$C_ERR" "$cfg" "$C_RESET" >&2; exit 3; }

  if is_up "$iface"; then
    if [[ "$FORCE" -ne 1 ]]; then
      log "$iface is active. Refusing to remove. Use --force to stop/remove."
      exit 4
    fi
    warn "$iface is active; forcing stop before removal."
    cmd_stop "$iface" || true
  fi

  if has_systemd; then
    if systemctl is-enabled "$(unit_name "$iface")" >/dev/null 2>&1; then
      warn "Disabling $(unit_name "$iface") before removal."
      run_systemctl disable "$(unit_name "$iface")" || true
    fi
  fi

  log "Removing config $cfg"
  rm -f "$cfg"
  ok "Removed config for $iface"
}

########################################
# Systemd wrappers
########################################
cmd_enable() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"
  has_systemd || die "systemd not detected; enable/disable not available."
  log "Enabling $(unit_name "$iface")..."
  run_systemctl enable "$(unit_name "$iface")"
  ok "Enabled $(unit_name "$iface")"
}

cmd_disable() {
  local iface
  iface="$(get_interface "${1:-}")"
  has_systemd || die "systemd not detected; enable/disable not available."
  log "Disabling $(unit_name "$iface")..."
  run_systemctl disable "$(unit_name "$iface")"
  ok "Disabled $(unit_name "$iface")"
}

cmd_start() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"
  if has_systemd; then
    log "Starting $(unit_name "$iface")..."
    run_systemctl start "$(unit_name "$iface")"
    ok "Started $(unit_name "$iface")"
  else
    warn "systemd not detected; falling back to wg-quick up $iface"
    cmd_up "$iface"
  fi
}

cmd_stop() {
  local iface
  iface="$(get_interface "${1:-}")"
  if has_systemd; then
    log "Stopping $(unit_name "$iface")..."
    run_systemctl stop "$(unit_name "$iface")"
    ok "Stopped $(unit_name "$iface")"
  else
    warn "systemd not detected; falling back to wg-quick down $iface"
    cmd_down "$iface"
  fi
}

cmd_restart() {
  local iface
  iface="$(get_interface "${1:-}")"
  check_config_readable "$iface"
  if has_systemd; then
    log "Restarting $(unit_name "$iface")..."
    run_systemctl restart "$(unit_name "$iface")"
    ok "Restarted $(unit_name "$iface")"
  else
    warn "systemd not detected; falling back to wg-quick down/up $iface"
    cmd_down "$iface" || true
    cmd_up "$iface"
  fi
}

cmd_is_enabled() {
  local iface
  iface="$(get_interface "${1:-}")"
  has_systemd || die "systemd not detected; is-enabled not available."
  if systemctl is-enabled "$(unit_name "$iface")" >/dev/null 2>&1; then
    [[ "$QUIET" -eq 0 ]] && echo "enabled"
    exit 0
  fi
  [[ "$QUIET" -eq 0 ]] && echo "disabled"
  exit 1
}

cmd_is_active() {
  local iface
  iface="$(get_interface "${1:-}")"
  if has_systemd; then
    if systemctl is-active "$(unit_name "$iface")" >/dev/null 2>&1; then
      [[ "$QUIET" -eq 0 ]] && echo "active"
      exit 0
    fi
    [[ "$QUIET" -eq 0 ]] && echo "inactive"
    exit 1
  else
    if is_up "$iface"; then
      [[ "$QUIET" -eq 0 ]] && echo "active"
      exit 0
    fi
    [[ "$QUIET" -eq 0 ]] && echo "inactive"
    exit 1
  fi
}

cmd_journal() {
  local iface
  iface="$(get_interface "${1:-}")"
  has_systemd || die "systemd not detected; journal not available."
  exec journalctl -u "$(unit_name "$iface")" -f
}

########################################
# Main
########################################
main() {
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--quiet) QUIET=1; shift ;;
      -f|--force) FORCE=1; shift ;;

      --check) CHECK_ONLY=1; shift ;;
      --check-handshake) CHECK_ONLY=1; CHECK_HANDSHAKE=1; shift ;;

      --no-completion) NO_COMPLETION=1; shift ;;
      --completion-only) COMPLETION_ONLY=1; shift ;;
      --uninstall-completion) UNINSTALL_COMPLETION=1; shift ;;

      -V|--version) show_version ;;
      -h|--help) usage ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
  set -- "${POSITIONAL[@]}"

  require_root "$@"

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    cmd_check "${1:-}"
  fi

  if [[ $# -eq 0 ]]; then
    cmd_toggle ""
    exit 0
  fi

  case "$1" in
    toggle|up|down|status|list|import|configs|show|remove|enable|disable|start|stop|restart|is-enabled|is-active|journal|install|uninstall) ;;
    *) cmd_toggle "$1"; exit 0 ;;
  esac

  case "$1" in
    toggle)   cmd_toggle "${2:-}" ;;
    up)       cmd_up     "${2:-}" ;;
    down)     cmd_down   "${2:-}" ;;
    status)   cmd_status "${2:-}" ;;
    list)     cmd_list ;;
    configs)  cmd_configs ;;
    remove)   cmd_remove "${2:-}" ;;

    enable)     cmd_enable     "${2:-}" ;;
    disable)    cmd_disable    "${2:-}" ;;
    start)      cmd_start      "${2:-}" ;;
    stop)       cmd_stop       "${2:-}" ;;
    restart)    cmd_restart    "${2:-}" ;;
    is-enabled) cmd_is_enabled "${2:-}" ;;
    is-active)  cmd_is_active  "${2:-}" ;;
    journal)    cmd_journal    "${2:-}" ;;

    install)    cmd_install ;;
    uninstall)  cmd_uninstall ;;

    import)
      IMPORT_ENABLE=0
      IMPORT_START=0

      [[ $# -ge 2 ]] || die "import requires <file.conf> [iface] [--enable] [--start]"

      src="${2:-}"
      maybe_iface="${3:-}"
      i=4
      if [[ "${maybe_iface:-}" == -* ]]; then
        maybe_iface=""
        i=3
      fi

      while [[ $i -le $# ]]; do
        eval "arg=\${$i}"
        case "$arg" in
          --enable) IMPORT_ENABLE=1 ;;
          --start)  IMPORT_START=1 ;;
          *) die "Unknown import option: $arg" ;;
        esac
        i=$((i+1))
      done

      cmd_import "$src" "$maybe_iface"
      ;;

    show)
      SHOW_REDACT=0
      SHOW_QR=0
      SHOW_STRIP=0

      maybe_iface="${2:-}"
      i=3
      if [[ "${maybe_iface:-}" == -* ]]; then
        maybe_iface=""
        i=2
      fi

      while [[ $i -le $# ]]; do
        eval "arg=\${$i}"
        case "$arg" in
          --redact) SHOW_REDACT=1 ;;
          --qr)     SHOW_QR=1 ;;
          --strip)  SHOW_STRIP=1 ;;
          *) die "Unknown show option: $arg" ;;
        esac
        i=$((i+1))
      done

      cmd_show "$maybe_iface"
      ;;

    *) usage ;;
  esac
}

main "$@"
