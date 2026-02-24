# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-02-24

### Added

- Interactive TUI menu with Unicode box drawing, color coding, and emoji icons
- **Disk Space Overview** with visual usage bars and color-coded percentages
- **Quick Clean** — safe one-click cleanup targeting only guaranteed junk
- **System Logs Cleanup** — rotated logs, systemd journal trimming, application logs
- **Package Manager Cleanup** — cache clearing, orphan removal, old kernel purging
- **Cache Cleanup** — apt/yum/pip/npm/composer caches and tmp file cleanup
- **Docker Cleanup** — prune containers, images, volumes, build cache, and container logs
- **Snap/Flatpak Cleanup** — remove old snap revisions and unused Flatpak runtimes
- **Large File Finder** — scan for large files with interactive deletion prompts
- **Full Deep Clean** — run all cleanup routines with step-by-step progress reporting
- **Settings menu** — configurable thresholds, retention periods, and dry-run mode
- **Self-install and auto-update** via install script
- Cross-distribution support: Ubuntu, Debian, CentOS, RHEL, Rocky Linux, AlmaLinux, Fedora, Arch, Alpine, openSUSE
- Auto-detection of distribution and package manager via `/etc/os-release`
- Protected paths blocklist to prevent accidental deletion of critical system files
- Confirmation prompts before destructive operations
- Dry-run mode for previewing cleanup without deleting
- Configuration file support (`~/.vps-cleaner.conf`)
- One-liner install via `curl` or `wget`
- Progress bars, spinners, and space-freed summaries
