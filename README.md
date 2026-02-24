<p align="center">
  <h1 align="center">🧹 VPS Cleaner</h1>
  <p align="center">
    <strong>Comprehensive disk cleanup tool for Linux VPS</strong>
  </p>
  <p align="center">
    <a href="#features">Features</a> •
    <a href="#installation">Installation</a> •
    <a href="#usage">Usage</a> •
    <a href="#supported-distributions">Supported Distros</a> •
    <a href="#configuration">Configuration</a>
  </p>
</p>

---

## Quick Start

```bash
# Install with curl
curl -fsSL https://raw.githubusercontent.com/user/vps-cleaner/main/install.sh | bash

# Or with wget
wget -qO- https://raw.githubusercontent.com/user/vps-cleaner/main/install.sh | bash
```

Then simply run:

```bash
vps-cleaner
```

## Features

- 📊 **Disk space overview** with visual bars and color coding
- 🚀 **Quick Clean** — safe one-click cleanup for guaranteed junk
- 📋 **System logs cleanup** — rotated logs, journal, application logs
- 📦 **Package manager cleanup** — cache, orphaned packages, old kernels
- 🗂️ **Cache cleanup** — apt/yum/pip/npm/composer/tmp
- 🐳 **Docker cleanup** — containers, images, volumes, build cache, logs
- 📎 **Snap/Flatpak cleanup**
- 🔍 **Large file finder** with interactive deletion
- 🗑️ **Full deep clean** with step-by-step progress
- ⚙️ **Configurable settings** — thresholds, retention periods, dry-run mode
- 📥 **Self-install and auto-update**
- **Cross-distro** — Ubuntu, Debian, CentOS, RHEL, Rocky, Alma, Fedora, Arch, Alpine, openSUSE
- **Safe by design** — protected paths, confirmations, dry-run mode
- **Colorful UI** with progress bars, spinners, and Unicode box drawing

## Screenshot

```
╭─────────────────────────────────────────────╮
│  🧹 VPS Cleaner v1.0.0                     │
│  Distro: Ubuntu 22.04                      │
│  Disk: 15.2G / 50.0G (30%)                 │
╰─────────────────────────────────────────────╯

  1)  📊 Disk Space Overview
  2)  🚀 Quick Clean (Safe)
  3)  📋 System Logs Cleanup
  4)  📦 Package Manager Cleanup
  5)  🗂️  Cache Cleanup
  6)  🐳 Docker Cleanup
  7)  📎 Snap/Flatpak Cleanup
  8)  🔍 Find Large Files
  9)  🗑️  Full Deep Clean
 10)  ⚙️  Settings
 11)  📥 Install/Update vps-cleaner
  0)  🚪 Exit
```

## Installation

### One-liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/user/vps-cleaner/main/install.sh | bash
```

This downloads the script and installs it to `/usr/local/bin/vps-cleaner`.

### Manual Install

```bash
git clone https://github.com/user/vps-cleaner.git
cd vps-cleaner
chmod +x vps-cleaner.sh
sudo cp vps-cleaner.sh /usr/local/bin/vps-cleaner
```

### Run Without Installing

```bash
sudo bash vps-cleaner.sh
```

## Usage

Run `vps-cleaner` (or `sudo bash vps-cleaner.sh`) to launch the interactive menu. Select an option by number:

| Option | Description |
|--------|-------------|
| **1 — Disk Space Overview** | Shows partition usage with visual bars and color-coded percentages |
| **2 — Quick Clean** | One-click safe cleanup of guaranteed junk (see [Quick Clean](#quick-clean)) |
| **3 — System Logs Cleanup** | Removes rotated logs, trims journal, cleans application logs |
| **4 — Package Manager Cleanup** | Clears package cache, removes orphans, purges old kernels |
| **5 — Cache Cleanup** | Cleans apt/yum/pip/npm/composer caches and tmp files |
| **6 — Docker Cleanup** | Prunes containers, images, volumes, build cache, and container logs |
| **7 — Snap/Flatpak Cleanup** | Removes old snap revisions and unused Flatpak runtimes |
| **8 — Find Large Files** | Scans for large files with interactive deletion prompts |
| **9 — Full Deep Clean** | Runs all cleanup routines with step-by-step progress |
| **10 — Settings** | Configure thresholds, retention periods, and dry-run mode |
| **11 — Install/Update** | Install or update vps-cleaner to the latest version |
| **0 — Exit** | Quit the program |

## Quick Clean

Quick Clean targets only safe-to-remove junk:

- Package manager cache (`apt`, `yum`, `dnf`, `pacman`, `zypper`)
- Rotated/compressed log files (`*.gz`, `*.old`, `*.1` in `/var/log`)
- Systemd journal older than the configured retention period
- Tmp files older than the configured threshold
- Thumbnail and font caches

No user data, active containers, or current logs are touched.

## Configuration

Settings are stored in `~/.vps-cleaner.conf` and can be edited from the Settings menu or directly:

```bash
# ~/.vps-cleaner.conf

# Journal retention (default: 3d)
JOURNAL_RETAIN="3d"

# Tmp file age threshold in days (default: 7)
TMP_AGE_DAYS=7

# Large file size threshold (default: 100M)
LARGE_FILE_THRESHOLD="100M"

# Docker: prune all unused images, not just dangling (default: false)
DOCKER_PRUNE_ALL=false

# Log cleanup: max age in days for rotated logs (default: 7)
LOG_MAX_AGE_DAYS=7

# Dry-run mode: show what would be deleted without deleting (default: false)
DRY_RUN=false

# Old kernel retention count (default: 2)
KERNEL_KEEP_COUNT=2

# Snap: remove old revisions (default: true)
SNAP_CLEAN_OLD=true
```

## Supported Distributions

| Family | Distributions | Package Manager |
|--------|--------------|-----------------|
| **Debian** | Ubuntu, Debian | `apt` |
| **RHEL** | CentOS, RHEL, Rocky Linux, AlmaLinux | `yum` / `dnf` |
| **Fedora** | Fedora | `dnf` |
| **Arch** | Arch Linux, Manjaro | `pacman` |
| **Alpine** | Alpine Linux | `apk` |
| **SUSE** | openSUSE Leap, openSUSE Tumbleweed | `zypper` |

The script auto-detects your distribution via `/etc/os-release` and uses the appropriate package manager commands.

## Safety

VPS Cleaner is designed to be safe by default:

- **Protected paths** — Critical system directories and files are never touched. A built-in blocklist prevents accidental deletion of essential paths.
- **Confirmations** — Destructive operations require explicit confirmation before proceeding.
- **Dry-run mode** — Enable `DRY_RUN=true` in settings to preview what would be cleaned without actually deleting anything.
- **Logging** — All operations are logged for review. Check the output for a summary of what was removed and how much space was freed.

## Uninstall

```bash
sudo rm /usr/local/bin/vps-cleaner
rm -f ~/.vps-cleaner.conf
```

## Contributing

Contributions are welcome! Feel free to open issues and pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## License

[MIT](LICENSE) © 2026
