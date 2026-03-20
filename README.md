# wg-manager

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`wg-manager` is a lightweight convenience wrapper around **wg-quick**
that simplifies everyday WireGuard management without replacing native
tooling.

It keeps `wg-quick` as the engine and provides a cleaner CLI workflow
for power users and hobbyists.

The installer places the launcher at:

- `/usr/local/bin/wg-manager`

------------------------------------------------------------------------

## ✨ Features

-   Smart default interface resolution
-   Debian/Ubuntu setup helper for WireGuard prerequisites
-   Edit configs directly in `/etc/wireguard` with `nano`
-   Import configs safely into `/etc/wireguard`
-   List, show, redact, strip, and QR-export configs
-   Remove configs safely (with active protection)
-   systemd integration (`wg-quick@.service`)
-   Health checks (optional handshake validation)
-   Self-install routine with bash completion
-   PATH sanitization to avoid tool conflicts

## Requirements

- root privileges
- systemd (optional)
- bash-completion (optional)
- qrencode (optional, for --qr)

------------------------------------------------------------------------

## 🚀 Quick Install

### Install

``` bash
curl -fsSL https://raw.githubusercontent.com/peternickol/wg-manager.sh/master/wg-manager.sh   -o wg-manager.sh && sudo bash wg-manager.sh install && rm wg-manager.sh
```

------------------------------------------------------------------------

### Force Reinstall

``` bash
curl -fsSL https://raw.githubusercontent.com/peternickol/wg-manager.sh/master/wg-manager.sh   -o wg-manager.sh && sudo bash wg-manager.sh install --force && rm wg-manager.sh
```

### Debian / Ubuntu Setup

To prepare a normal Debian or Ubuntu machine for WireGuard management:

``` bash
sudo wg-manager setup
```

This installs the common local prerequisites:

- `wireguard`
- `wireguard-tools`
- `openresolv`
- `nano`

and prepares:

- `/etc/wireguard`

------------------------------------------------------------------------

## 🧠 Smart Default Interface Resolution

When no interface is specified:

-   **0 configs** → fallback to `wg0`
-   **1 config** → automatically selects it
-   **Multiple configs** → prompts you to choose (`1.) 2.) 3.) …`)
    -   Works under `sudo` / `sudo-rs` via `/dev/tty`
    -   Non-interactive mode exits safely with an error

------------------------------------------------------------------------

## 📦 Usage

### Toggle (default)

``` bash
sudo wg-manager
sudo wg-manager wg1
```

### Setup a machine for WireGuard

``` bash
sudo wg-manager setup
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

### Edit or create a config in `nano`

``` bash
sudo wg-manager edit
sudo wg-manager edit wg1
sudo wg-manager edit branch-office
```

`edit` opens:

    /etc/wireguard/<name>.conf

If the file does not exist yet, it is created first with `root:root 600`.

### Compatibility alias

`add` is still accepted as an alias for `edit`:

``` bash
sudo wg-manager add wg1
sudo wg-manager add branch-office.conf
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

### Show stripped config

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

## Exit Codes

- **0** — OK  
- **2** — Must be run as root  
- **3** — Config missing / ambiguous selection  
- **4** — Interface down  
- **5** — Handshake stale or missing  

------------------------------------------------------------------------

## 🔒 PATH Sanitization

When invoking `wg-quick` or `systemctl`, wg-manager runs them with:

    PATH=/usr/sbin:/usr/bin:/sbin:/bin

This prevents conflicts with:

-   Snap-installed tools
-   Shadowed `/usr/local/bin` utilities
-   Non-GNU coreutils replacements

------------------------------------------------------------------------

## 📄 License

This project is licensed under the MIT License.

See the [LICENSE](LICENSE) file for details.

------------------------------------------------------------------------

## ⚠ Disclaimer

This is a small wrapper for manual WireGuard management.

It is **not intended for enterprise orchestration or
infrastructure-as-code**.
