# wg-manager

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`wg-manager` is a convenience wrapper around **wg-quick** designed to
simplify common WireGuard workflows **without replacing native
tooling**.

It keeps `wg-quick` as the engine and adds a user-friendly CLI for:

-   Importing WireGuard configs into `/etc/wireguard`
-   Listing, showing, and removing configs safely
-   Enabling/disabling connections via systemd (`wg-quick@.service`)
-   Starting/stopping/toggling connections
-   Health checks (optionally with handshake freshness)
-   Easy install/uninstall with bash completion

> **Not a replacement for wg-quick.** `wg-manager` is intentionally a
> small wrapper for hobbyists and power users.

------------------------------------------------------------------------

## Key Features

### Smart default interface selection

When you omit an interface name, `wg-manager` resolves it like this:

-   **0 configs** in `/etc/wireguard/*.conf` → fallback to **wg0**
-   **1 config** → automatically selects that config
-   **Multiple configs** → prompts you to choose (**1.) 2.) 3.) ...**)
    using `/dev/tty`
    -   Works under `sudo` / `sudo-rs`
    -   If non-interactive (no TTY), it exits with a clear error and
        asks you to specify an interface

This makes `sudo wg-manager` and `sudo wg-manager toggle` feel natural
even when you manage multiple tunnels.

------------------------------------------------------------------------

## Installation

### Prerequisites

-   WireGuard tools: `wg`, `wg-quick`
-   Bash
-   systemd (optional, recommended)
-   bash completion (optional): `bash-completion`
-   QR support (optional): `qrencode`

Install packages on Debian/Ubuntu:

``` bash
sudo apt update
sudo apt install wireguard bash-completion
# optional for "show --qr"
sudo apt install qrencode
```

### Install

From your repo directory:

``` bash
sudo ./wg-manager.sh install
```

Default install path:

    /usr/local/sbin/wg-manager

Completion install locations:

-   `/usr/share/bash-completion/completions/` (preferred)
-   `/etc/bash_completion.d/` (fallback)

Install options:

-   `--force` --- overwrite existing install
-   `--no-completion` --- install binary only
-   `--completion-only` --- install completion only
-   `--uninstall-completion` --- remove completion

Examples:

``` bash
sudo ./wg-manager.sh install --force
sudo ./wg-manager.sh install --no-completion
sudo ./wg-manager.sh install --completion-only
sudo ./wg-manager.sh install --uninstall-completion
```

------------------------------------------------------------------------

## Usage

### Toggle (default command)

``` bash
sudo wg-manager
```

-   If only one config exists, it toggles that interface.
-   If multiple exist, it prompts you to pick one.

Explicit interface:

``` bash
sudo wg-manager wg1
sudo wg-manager toggle wg1
```

### Bring up / down

``` bash
sudo wg-manager up
sudo wg-manager down wg1
```

### Status

``` bash
sudo wg-manager status
```

### List active interfaces

``` bash
sudo wg-manager list
```

### List installed configs

``` bash
sudo wg-manager configs
```

------------------------------------------------------------------------

## Importing Configs

Import a config file into `/etc/wireguard/<iface>.conf` with safe
permissions:

``` bash
sudo wg-manager import myvpn.conf
```

-   If you don't pass an interface name, it uses the file name
    (e.g. `myvpn.conf → myvpn`).

Options (must come after `import`):

-   `--enable` → enable `wg-quick@<iface>` (systemd)
-   `--start` → start immediately (systemd; falls back to `wg-quick` if
    no systemd)

Example:

``` bash
sudo wg-manager import myvpn.conf --enable --start
```

Permissions enforced:

-   owner/group: `root:root`
-   mode: `600`

------------------------------------------------------------------------

## Showing Configs

Show the contents of a config:

``` bash
sudo wg-manager show
sudo wg-manager show wg1
```

### Redact private keys

``` bash
sudo wg-manager show --redact
sudo wg-manager show wg1 --redact
```

This replaces `PrivateKey = ...` with `PrivateKey = (REDACTED)` so you
can safely paste/share output.

### Show as a QR code (mobile)

``` bash
sudo wg-manager show --qr
sudo wg-manager show wg1 --qr
```

Requires `qrencode`.

### Show stripped config (wg-quick cleaned output)

``` bash
sudo wg-manager show --strip
sudo wg-manager show wg1 --strip --redact
sudo wg-manager show --strip --qr
```

`--strip` uses `wg-quick strip <iface>` to output the normalized/cleaned
config.

------------------------------------------------------------------------

## Removing Configs

``` bash
sudo wg-manager remove wg0
```

If the interface is active, it refuses unless you use:

``` bash
sudo wg-manager remove wg0 --force
```

When systemd is present, it also disables `wg-quick@<iface>` before
removal.

------------------------------------------------------------------------

## systemd Integration

If systemd is present, `wg-manager` wraps `wg-quick@<iface>.service`:

``` bash
sudo wg-manager enable wg0
sudo wg-manager disable wg0
sudo wg-manager start wg0
sudo wg-manager stop wg0
sudo wg-manager restart wg0
sudo wg-manager is-enabled wg0
sudo wg-manager is-active wg0
sudo wg-manager journal wg0
```

If systemd isn't available, `start/stop/restart` fall back to
`wg-quick up/down` behavior.

------------------------------------------------------------------------

## Health Checks

Check whether the interface is UP:

``` bash
sudo wg-manager --check
```

Check if the interface is UP and has a recent handshake:

``` bash
sudo wg-manager --check-handshake
```

Exit codes:

  -----------------------------------------------------------------------
  Code                         Meaning
  ---------------------------- ------------------------------------------
  0                            OK / interface up (and handshake OK if
                               requested)

  2                            Must be run as root

  3                            Config missing/invalid, or ambiguous
                               default selection without a TTY

  4                            Interface down

  5                            Handshake stale or missing (with
                               `--check-handshake`)
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## PATH Sanitization & Tooling Warnings

When calling `wg-quick` or `systemctl`, `wg-manager` runs them with:

    PATH=/usr/sbin:/usr/bin:/sbin:/bin

This avoids surprises from:

-   Snap-installed tools
-   shadowed binaries in `/usr/local/bin`
-   other nonstandard environments

It also warns once per run if `/usr/bin/stat` is not GNU coreutils,
since `wg-quick` assumes GNU behavior on many distros.

------------------------------------------------------------------------

## Version

``` bash
wg-manager --version
```

------------------------------------------------------------------------

## License

This project is licensed under the MIT License.

See the [LICENSE](LICENSE) file for details.

------------------------------------------------------------------------

## Disclaimer

This is a lightweight wrapper for manual WireGuard management.

It is **not** intended for:

-   Enterprise orchestration
-   Infrastructure-as-code
-   Large-scale configuration management

For those, use Ansible/Terraform/etc.