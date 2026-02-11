# wg-manager

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`wg-manager` is a lightweight convenience wrapper around **wg-quick**
that simplifies everyday WireGuard management --- without replacing
native tooling.

It keeps `wg-quick` as the engine and provides a cleaner CLI workflow
for power users and hobbyists.

------------------------------------------------------------------------

## ✨ Features

-   Smart default interface resolution
-   Import configs safely into `/etc/wireguard`
-   List, show, redact, strip, and QR-export configs
-   Remove configs safely (with active protection)
-   systemd integration (`wg-quick@.service`)
-   Health checks (optional handshake validation)
-   Self-install routine with bash completion
-   PATH sanitization to avoid tool conflicts

------------------------------------------------------------------------

## 🧠 Smart Default Interface Resolution

When no interface is specified:

-   **0 configs** → fallback to `wg0`
-   **1 config** → automatically selects it
-   **Multiple configs** → prompts you to choose (`1.) 2.) 3.) …`)
    -   Works under `sudo` / `sudo-rs` via `/dev/tty`
    -   Non-interactive mode exits safely with an error

This makes:

``` bash
sudo wg-manager
```

feel natural even when managing multiple tunnels.

------------------------------------------------------------------------

## 🚀 Installation

### Requirements

-   `wg` and `wg-quick`
-   Bash
-   systemd (optional, recommended)
-   `bash-completion` (optional)
-   `qrencode` (optional, for QR support)

Debian / Ubuntu:

``` bash
sudo apt install wireguard bash-completion
# optional:
sudo apt install qrencode
```

### Install

``` bash
sudo ./wg-manager.sh install
```

Default location:

    /usr/local/sbin/wg-manager

Install options:

-   `--force`
-   `--no-completion`
-   `--completion-only`
-   `--uninstall-completion`

------------------------------------------------------------------------

## 📦 Usage

### Toggle (default)

``` bash
sudo wg-manager
sudo wg-manager wg1
```

### Up / Down

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

## 📥 Importing Configs

``` bash
sudo wg-manager import myvpn.conf
```

Options (after `import`):

-   `--enable`
-   `--start`

Example:

``` bash
sudo wg-manager import myvpn.conf --enable --start
```

Configs are installed as:

    /etc/wireguard/<iface>.conf

Permissions enforced: `root:root 600`

------------------------------------------------------------------------

## 👁 Showing Configs

``` bash
sudo wg-manager show
sudo wg-manager show wg1
```

### Redact private keys

``` bash
sudo wg-manager show --redact
```

### Generate QR code

``` bash
sudo wg-manager show --qr
```

Requires `qrencode`.

### Show stripped config (wg-quick normalized)

``` bash
sudo wg-manager show --strip
sudo wg-manager show wg1 --strip --redact
```

------------------------------------------------------------------------

## 🗑 Removing Configs

``` bash
sudo wg-manager remove wg0
```

If active, requires:

``` bash
sudo wg-manager remove wg0 --force
```

systemd units are disabled automatically when present.

------------------------------------------------------------------------

## ⚙ systemd Integration

When available, wraps:

    wg-quick@<iface>.service

Commands:

``` bash
sudo wg-manager enable wg0
sudo wg-manager disable wg0
sudo wg-manager start wg0
sudo wg-manager stop wg0
sudo wg-manager restart wg0
sudo wg-manager journal wg0
```

If systemd is not present, start/stop/restart fall back to `wg-quick`.

------------------------------------------------------------------------

## 🩺 Health Checks

``` bash
sudo wg-manager --check
sudo wg-manager --check-handshake
```

Exit codes:

  Code   Meaning
  ------ --------------------------------------
  0      OK
  2      Must be run as root
  3      Config missing / ambiguous selection
  4      Interface down
  5      Handshake stale or missing

------------------------------------------------------------------------

## 🔒 PATH Sanitization

When invoking `wg-quick` or `systemctl`, wg-manager runs them with:

    PATH=/usr/sbin:/usr/bin:/sbin:/bin

This prevents conflicts with:

-   Snap-installed tools
-   Shadowed `/usr/local/bin` utilities
-   Non-GNU coreutils replacements

It also warns if `/usr/bin/stat` is not GNU coreutils.

------------------------------------------------------------------------

## 📄 License

This project is licensed under the MIT License.

See the [LICENSE](LICENSE) file for details.

------------------------------------------------------------------------

## ⚠ Disclaimer

This is a small wrapper for manual WireGuard management.

It is **not intended for enterprise orchestration or
infrastructure-as-code**. For those use cases, use Ansible, Terraform,
or similar tools.