# Ubuntu Log Cleaner

**Version 3.1.0** - A comprehensive system maintenance script for Ubuntu servers that performs automated cleanup tasks to free disk space and maintain system health.

## Features

### Core Cleanup Operations (Always Available)

- **Remove Old Kernels** - Safely removes old kernel versions while keeping the current kernel + 1 previous version for rollback safety
- **Vacuum Systemd Journal** - Cleans systemd journal logs (configurable retention period, default: 7 days)
- **Remove Compressed Logs** - Deletes .gz compressed log files from `/var/log/`
- **Clean APT Cache** - Clears package manager cache and removes orphaned packages
- **Remove Old Snap Revisions** - Removes disabled snap package revisions
- **Clean Temporary Files** - Removes files older than configured age from `/tmp` and `/var/tmp`

### Advanced Cleanup Operations (Opt-In)

- **Docker Cleanup** - Removes unused containers, images, volumes, and build cache
- **Package Cache Cleanup** - Cleans pip, npm, and yarn caches
- **Systemd Coredump Cleanup** - Removes old system crash dumps
- **Thumbnail Cache Cleanup** - Clears thumbnail caches for all users
- **Mail Queue Cleanup** - Removes old mail files (30+ days)

### Safety Profiles (v3.0)

- **Profile-based cleanup** - Choose `safe`, `moderate`, or `aggressive` profiles
- **Snap cache cleanup** - Clean `/var/lib/snapd/cache/` downloaded packages
- **APT lists cleanup** - Clean `/var/lib/apt/lists/` package indexes
- **Crash reports cleanup** - Clean `/var/crash/` with configurable age
- **Netdata cleanup** - Clean cache and database with service handling
- **Prometheus cleanup** - Clean old WAL segments and chunks
- **Grafana cleanup** - Clean PNG cache, sessions, CSV exports
- **Python cache cleanup** - Clean `__pycache__` directories
- **Service handling** - Optional stop/start for monitoring services

### Analysis Mode

- **Read-Only System Audit** - `--analyze` scans the system and reports what can be cleaned without making any changes
- **AI-Ready Output** - Structured plain-text report designed to be pasted into AI tools for analysis
- **Report File Export** - `--report-file FILE` saves the report for later review or sharing

### Safety & Control Features

- **Dry-Run Mode** - Preview changes without making any modifications
- **Interactive Confirmation** - Prompts before executing cleanup operations
- **Comprehensive Logging** - Audit trail with detailed operation logs
- **Lock File Protection** - Prevents multiple simultaneous instances
- **Configuration File Support** - Customize behavior via `/etc/logcleaner.conf`
- **Selective Cleanup** - Run specific operations only or skip certain tasks
- **Deleted Files Manifest** - Track exactly what was removed

## Requirements

- **Operating System**: Ubuntu (tested on Ubuntu 18.04+)
- **Privileges**: Must be run as root or with sudo
- **Dependencies**: Standard Ubuntu utilities (apt-get, journalctl, snap)

## One-Liners

All commands run directly from GitHub — no installation, no cloning.

### Analyze (read-only)

Audit your system without making any changes:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --analyze
```

Save the report to a file:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --analyze --report-file /tmp/system-analysis.txt
```

### Clean (safe profile)

Conservative cleanup — logs, APT cache, old kernels, journal vacuum. Safe for production:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --yes --profile safe
```

### Clean (moderate profile)

Recommended for most servers — adds snap cache, APT lists, crash reports, temp files:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --yes --profile moderate
```

### Clean (aggressive profile)

Maximum cleanup — adds Netdata, Prometheus, Grafana data, Python cache, thumbnails. Review the [profile table](#safety-profiles) before running:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --yes --profile aggressive
```

### Dry-run before cleaning

Preview what would be removed without touching anything:

```bash
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --dry-run --profile moderate
```

## System Analysis (Read-Only)

Run a read-only system audit to identify what can be cleaned — no changes made, nothing deleted. The report is structured plain text, easy to copy-paste for manual review or AI-assisted analysis.

### One-Liner (No Installation Required)

```bash
# Print report to terminal
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --analyze

# Save report to file
curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --analyze --report-file /tmp/system-analysis.txt
```

### What the Report Covers

| Section | What it shows |
|---------|--------------|
| Disk usage | `df` overview + top 20 directories by size |
| Large files | All files >100MB across the filesystem |
| Log files | Total `/var/log` size, top 20 files, compressed log count |
| Journal | Current journal size, `journald.conf` settings, disk usage |
| APT cache | Cache size, package list size, autoremovable packages |
| Kernels | Installed kernel packages vs running kernel, estimated removable size |
| Snap | Installed snaps, disabled revisions, snap cache size |
| Temp files | `/tmp` and `/var/tmp` totals + files older than 7 days |
| Crash reports | `/var/crash` size and file listing |
| Docker | `docker system df` output with reclaimable space (if installed) |
| **Summary** | **Aggregate estimate of total reclaimable space** |

### Sample Output

```
=======================================================
  UBUNTU SYSTEM ANALYSIS REPORT
  Generated : 2026-04-22 10:30:00
  Hostname  : myserver.example.com
  Kernel    : 5.15.0-91-generic
  OS        : Ubuntu 22.04.3 LTS
=======================================================

=======================================================
  DISK USAGE
=======================================================

  Filesystem overview:
    Filesystem      Size  Used Avail Use%  Mounted on
    /dev/sda1        50G   38G  9.5G  80%  /

  Top 20 directories by size (/):
    ...

=======================================================
  KERNEL PACKAGES
=======================================================

  Running kernel: 5.15.0-91-generic
  Installed kernel packages:
    linux-image-5.15.0-88-generic (245MB) [removable]
    linux-image-5.15.0-91-generic (245MB) [CURRENT]
  Estimated removable:                    ~245MB (all non-current)

=======================================================
  SUMMARY - POTENTIAL SPACE TO RECOVER
=======================================================

  Old kernels:                            ~245MB
  Journal vacuum (7d):                    ~150MB
  APT cache:                              ~800MB
  Compressed .gz logs:                    ~45MB
  Temp files (/tmp):                      ~120MB
  Crash reports:                          ~300MB

-------------------------------------------------------
  ESTIMATED TOTAL:                        ~1.66GB
-------------------------------------------------------

  To reclaim space, run:
    sudo ./logcleaner.sh --yes --profile moderate
```

### AI-Assisted Workflow

1. Save the report to a file:
   ```bash
   curl -sL https://raw.githubusercontent.com/Volkers-BV/ubuntu-cleaner/main/logcleaner.sh | sudo bash -s -- --analyze --report-file /tmp/analysis.txt
   ```
2. Copy the contents of `/tmp/analysis.txt`
3. Paste into Claude, ChatGPT, or your preferred AI with a prompt like:
   > "Review this Ubuntu system analysis report and tell me what to clean up first, what looks unusual, and which logcleaner.sh flags to use."

### Options

| Option | Description |
|--------|-------------|
| `--analyze` | Run read-only analysis (no changes made) |
| `--report-file FILE` | Write report to FILE in addition to stdout |

## Installation

1. Clone or download the script:
```bash
git clone https://github.com/Volkers-BV/ubuntu-cleaner.git
cd ubuntu-cleaner
```

2. Make the script executable:
```bash
chmod +x logcleaner.sh
```

## Usage

### Basic Usage

Run with default settings (interactive mode with confirmation):

```bash
sudo ./logcleaner.sh
```

### Common Usage Patterns

**Preview changes without executing (dry-run):**
```bash
sudo ./logcleaner.sh --dry-run
```

**Run non-interactively (for automation/cron):**
```bash
sudo ./logcleaner.sh --yes --log-file /var/log/logcleaner.log
```

**Run with additional cleanup operations:**
```bash
sudo ./logcleaner.sh --docker --pkg-cache --coredump
```

**Run only specific operations:**
```bash
sudo ./logcleaner.sh --only-temp --only-journal
```

**Custom retention periods:**
```bash
sudo ./logcleaner.sh --temp-age 14 --journal-days 3 --kernel-keep 2
```

### Command-Line Options

**Analysis Options:**
- `--analyze` - Run read-only system analysis (no changes made)
- `--report-file FILE` - Write analysis report to FILE (in addition to stdout)

**General Options:**
- `-h, --help` - Show help message with all options
- `-v, --version` - Display version information
- `-d, --dry-run` - Preview what would be cleaned without making changes
- `-y, --yes` - Skip interactive confirmation (for automated runs)
- `-q, --quiet` - Suppress non-essential output
- `-V, --verbose` - Show detailed output

**Logging Options:**
- `--log-file FILE` - Write logs to specified file (default: `/var/log/logcleaner.log`)
- `--no-log` - Disable file logging
- `--manifest FILE` - Write list of deleted files to FILE

**Cleanup Control:**
- `--skip-kernels` - Skip old kernel cleanup
- `--skip-journal` - Skip systemd journal cleanup
- `--skip-gz-logs` - Skip compressed log cleanup
- `--skip-apt` - Skip APT cache cleanup
- `--skip-snap` - Skip snap revision cleanup
- `--skip-temp` - Skip temporary files cleanup

**Advanced Cleanup (Opt-In):**
- `--docker` - Enable Docker cleanup
- `--pkg-cache` - Enable package cache cleanup (pip, npm, yarn)
- `--coredump` - Enable systemd coredump cleanup
- `--thumbnails` - Enable thumbnail cache cleanup
- `--mail` - Enable mail queue cleanup

**Selective Cleanup (Run Only Specific Operations):**
- `--only-kernels` - Run only kernel cleanup
- `--only-journal` - Run only journal cleanup
- `--only-gz-logs` - Run only gz log cleanup
- `--only-apt` - Run only APT cleanup
- `--only-snap` - Run only snap cleanup
- `--only-temp` - Run only temp file cleanup

**Configuration:**
- `--config FILE` - Load configuration from FILE (default: `/etc/logcleaner.conf`)
- `--temp-age DAYS` - Age threshold for temporary files (default: 7)
- `--journal-days DAYS` - Days to keep journal logs (default: 7)
- `--kernel-keep N` - Number of old kernels to keep (default: 1)

### Safety Profiles

Use `--profile <level>` to select a cleanup profile:

| Profile | Best For | Behavior |
|---------|----------|----------|
| `safe` | Production | Conservative cleanup, preserves monitoring data |
| `moderate` | Staging/Dev | Balanced cleanup including monitoring caches |
| `aggressive` | Emergencies | Maximum cleanup, prioritizes disk space |

```bash
# Production server
sudo ./logcleaner.sh --yes --profile safe

# Development server
sudo ./logcleaner.sh --yes --profile moderate

# Disk emergency
sudo ./logcleaner.sh --yes --profile aggressive --stop-services
```

### Example Output

```
╔═══════════════════════════════════════════════════════╗
║         Ubuntu Log Cleaner - System Maintenance       ║
╚═══════════════════════════════════════════════════════╝

ℹ Starting cleanup process...
ℹ Start time: 2025-11-18 10:30:45

═══════════════════════════════════════════════════════
Removing Old Kernels
═══════════════════════════════════════════════════════
ℹ Current kernel: 5.15.0-91-generic
ℹ Found 3 old kernel(s) installed
ℹ Removing: linux-image-5.15.0-88-generic
✓ Removed 2 old kernel(s), freed 245.50MB

═══════════════════════════════════════════════════════
Vacuuming Systemd Journal
═══════════════════════════════════════════════════════
ℹ Journal size before: 512.00MB
✓ Journal vacuumed, freed 384.00MB

...

═══════════════════════════════════════════════════════
Cleanup Summary
═══════════════════════════════════════════════════════
ℹ End time: 2025-11-18 10:32:15
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total space freed: 1.85GB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Cleanup completed successfully!
```

## Configuration File

You can create a configuration file at `/etc/logcleaner.conf` to set default behavior. See `logcleaner.conf.example` for all available options.

### Example Configuration

```bash
# /etc/logcleaner.conf

# Cleanup configuration
TEMP_FILE_AGE=14
JOURNAL_KEEP_DAYS=7
KERNEL_KEEP_COUNT=2

# Enable advanced cleanup operations
CLEANUP_DOCKER=true
CLEANUP_PKG_CACHE=true

# Logging
LOG_TO_FILE=true
LOG_FILE="/var/log/logcleaner.log"
```

### Configuration Priority

Settings are applied in this order (later overrides earlier):
1. Configuration file (`/etc/logcleaner.conf`)
2. Environment variables
3. Command-line arguments (highest priority)

## Safety Features

- **Dry-Run Mode**: Preview all changes before executing with `--dry-run`
- **Interactive Confirmation**: Prompts user before cleanup (can be disabled with `--yes`)
- **Lock File Protection**: Prevents multiple instances from running simultaneously
- **Kernel Safety**: Always keeps the currently running kernel plus N previous versions
- **Error Handling**: Uses `set -euo pipefail` for strict error handling with automatic cleanup on error
- **Root Check**: Verifies the script is run with appropriate privileges
- **Comprehensive Logging**: Audit trail showing exactly what was cleaned and when
- **Deleted Files Manifest**: Optional tracking of all deleted files
- **Non-Destructive**: Only removes old/temporary files, never touches active system files

## Scheduling (Optional)

### Cron Setup

To run the script automatically via cron (recommended for production):

```bash
# Edit root's crontab
sudo crontab -e

# Run weekly on Sunday at 3 AM with logging (non-interactive)
0 3 * * 0 /path/to/logcleaner/logcleaner.sh --yes --log-file /var/log/logcleaner.log 2>&1

# Run daily at 2 AM with Docker cleanup
0 2 * * * /path/to/logcleaner/logcleaner.sh --yes --docker --pkg-cache --log-file /var/log/logcleaner.log 2>&1
```

### Systemd Timer (Alternative)

For more advanced scheduling, you can create a systemd timer:

```bash
# /etc/systemd/system/logcleaner.service
[Unit]
Description=Ubuntu Log Cleaner
After=network.target

[Service]
Type=oneshot
ExecStart=/path/to/logcleaner/logcleaner.sh --yes --log-file /var/log/logcleaner.log
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
# /etc/systemd/system/logcleaner.timer
[Unit]
Description=Run Ubuntu Log Cleaner weekly

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable the timer:
```bash
sudo systemctl daemon-reload
sudo systemctl enable logcleaner.timer
sudo systemctl start logcleaner.timer
```

## Troubleshooting

### Permission Denied
Make sure you're running with sudo:
```bash
sudo ./logcleaner.sh
```

### Script Not Executable
Make the script executable:
```bash
chmod +x logcleaner.sh
```

## What Gets Cleaned

### Core Operations (Always Available)

| Task | Location | Criteria | Configurable |
|------|----------|----------|--------------|
| Old Kernels | `/boot`, `/lib/modules` | All except current + N old | `--kernel-keep N` |
| Journal Logs | `/var/log/journal` | Older than N days | `--journal-days N` |
| Compressed Logs | `/var/log/**/*.gz` | All .gz files | No |
| APT Cache | `/var/cache/apt/archives` | All cached packages | No |
| Snap Revisions | `/snap/*` | Disabled revisions only | No |
| Temp Files | `/tmp`, `/var/tmp` | Older than N days | `--temp-age N` |

### Advanced Operations (Opt-In)

| Task | Location | Criteria | Enable With |
|------|----------|----------|-------------|
| Docker Cleanup | Docker daemon | Unused containers, images, volumes | `--docker` |
| Pip Cache | `~/.cache/pip` | All cached packages | `--pkg-cache` |
| NPM Cache | `~/.npm` | All cached packages | `--pkg-cache` |
| Yarn Cache | `~/.yarn/cache` | All cached packages | `--pkg-cache` |
| Coredumps | `/var/lib/systemd/coredump` | Files older than 7 days | `--coredump` |
| Thumbnails | `~/.cache/thumbnails`, `~/.thumbnails` | All thumbnails (all users) | `--thumbnails` |
| Mail | `/var/mail`, `/var/spool/mail` | Files older than 30 days | `--mail` |

## License

This script is provided as-is for system maintenance purposes.

## Contributing

Feel free to submit issues or pull requests for improvements.

## What's New in Version 3.0.0

### Major Features Added

- **Safety Profiles** - `--profile safe|moderate|aggressive` for different environments
- **Snap Cache Cleanup** - Clean downloaded snap packages
- **APT Lists Cleanup** - Clean package index files
- **Crash Reports Cleanup** - Clean `/var/crash/` with age threshold
- **Netdata Cleanup** - Clean cache and database engine
- **Prometheus Cleanup** - Clean old WAL segments and chunks
- **Grafana Cleanup** - Clean PNG, session, and CSV caches
- **Python Cache Cleanup** - Clean `__pycache__` directories
- **Service Handling** - `--stop-services` for clean monitoring cleanup
- **Override Flags** - Fine-tune profile behavior with `--skip-*` flags

### What's New in Version 2.0.0

- **Dry-Run Mode** - Preview changes before executing with `--dry-run`
- **Interactive Confirmation** - User prompts before cleanup operations
- **Configuration File Support** - Persistent configuration via `/etc/logcleaner.conf`
- **Command-Line Arguments** - Comprehensive CLI with 30+ options
- **Advanced Cleanup Operations** - Docker, package caches, coredumps, thumbnails, mail
- **Selective Cleanup** - Run only specific operations with `--only-*` flags
- **Comprehensive Logging** - Audit trail with optional deleted files manifest
- **Lock File Protection** - Prevents multiple simultaneous instances

## Warning

While this script includes comprehensive safety checks, always ensure you have:
- Recent backups of important data
- Tested the script in a non-production environment first (use `--dry-run`)
- Reviewed the configuration and understand what each cleanup operation does

**Production Recommendations:**
1. Always test with `--dry-run` first
2. Enable logging with `--log-file` for audit trails
3. Use configuration file for consistent behavior
4. Start with conservative retention periods
5. Monitor the first few runs closely

Use at your own risk.
