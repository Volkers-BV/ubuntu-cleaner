# Ubuntu Log Cleaner

A non-interactive system maintenance script for Ubuntu servers that performs automated cleanup tasks to free disk space and maintain system health.

## Features

The script performs the following cleanup operations:

- **Remove Old Kernels** - Safely removes old kernel versions while keeping the current kernel + 1 previous version for rollback safety
- **Vacuum Systemd Journal** - Cleans systemd journal logs older than 7 days
- **Remove Compressed Logs** - Deletes .gz compressed log files from `/var/log/`
- **Clean APT Cache** - Clears package manager cache and removes orphaned packages
- **Remove Old Snap Revisions** - Removes disabled snap package revisions
- **Clean Temporary Files** - Removes files older than 7 days from `/tmp` and `/var/tmp`

## Requirements

- **Operating System**: Ubuntu (tested on Ubuntu 18.04+)
- **Privileges**: Must be run as root or with sudo
- **Dependencies**: Standard Ubuntu utilities (apt-get, journalctl, snap)

## Installation

1. Clone or download the script:
```bash
git clone <repository-url>
cd logcleaner
```

2. Make the script executable:
```bash
chmod +x logcleaner.sh
```

## Usage

Run the script with sudo privileges:

```bash
sudo ./logcleaner.sh
```

The script will:
- Display a banner and start time
- Execute each cleanup task sequentially
- Show verbose output for each operation
- Display space freed for each task
- Show a summary with total space freed

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

## Safety Features

- **Kernel Safety**: Always keeps the currently running kernel plus 1 previous version to allow rollback
- **Error Handling**: Uses `set -euo pipefail` for strict error handling
- **Root Check**: Verifies the script is run with appropriate privileges
- **Verbose Logging**: Shows exactly what's being cleaned and how much space is freed
- **Non-Destructive**: Only removes old/temporary files, never touches active system files

## Customization

You can modify these variables in the script to adjust behavior:

- `TEMP_FILE_AGE=7` - Age in days for temporary file cleanup (line 24)
- Kernel retention: Modify `kernels_to_keep=1` in `cleanup_old_kernels()` function (line 112)
- Journal retention: Change `--vacuum-time=7d` in `cleanup_journal()` function (line 154)

## Scheduling (Optional)

To run the script automatically, you can add it to cron:

```bash
# Edit root's crontab
sudo crontab -e

# Run weekly on Sunday at 3 AM
0 3 * * 0 /path/to/logcleaner/logcleaner.sh >> /var/log/logcleaner.log 2>&1
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

### bc Command Not Found
The script uses `bc` for calculations. Install it if missing:
```bash
sudo apt-get install bc
```

## What Gets Cleaned

| Task | Location | Criteria |
|------|----------|----------|
| Old Kernels | `/boot`, `/lib/modules` | All except current + 1 old |
| Journal Logs | `/var/log/journal` | Older than 7 days |
| Compressed Logs | `/var/log/**/*.gz` | All .gz files |
| APT Cache | `/var/cache/apt/archives` | All cached packages |
| Snap Revisions | `/snap/*` | Disabled revisions only |
| Temp Files | `/tmp`, `/var/tmp` | Older than 7 days |

## License

This script is provided as-is for system maintenance purposes.

## Contributing

Feel free to submit issues or pull requests for improvements.

## Warning

While this script includes safety checks, always ensure you have:
- Recent backups of important data
- Tested the script in a non-production environment first
- Understand what each cleanup operation does

Use at your own risk.
