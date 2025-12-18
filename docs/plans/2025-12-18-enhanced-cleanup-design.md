# Ubuntu Cleaner v3.0 - Enhanced Cleanup Design

## Overview

Enhance ubuntu-cleaner with additional cleanup targets, safety profiles for different server environments, and improved non-interactive operation for autonomous server maintenance.

## Problem Statement

Current script (v2.0.0) misses important cleanup targets:
- Snap cache (`/var/lib/snapd/cache/`) - only removes disabled revisions, not cached packages
- APT lists (`/var/lib/apt/lists/`) - not cleaned at all
- Monitoring tool caches (Netdata, Prometheus, Grafana) - can grow to gigabytes
- Crash reports, Python bytecode, and other server artifacts

Users need different cleanup behaviors for production vs development servers, controllable via simple command-line flags.

## New Cleanup Targets

| Target | Location | Typical Size | Risk Level |
|--------|----------|--------------|------------|
| Snap cache | `/var/lib/snapd/cache/` | 100MB - 2GB | Low |
| APT lists | `/var/lib/apt/lists/` | 50-200MB | Low (regenerated on `apt update`) |
| Crash reports | `/var/crash/` | 10MB - 1GB | Low |
| Old login records | `/var/log/wtmp.1`, `/var/log/btmp.1` | 1-50MB | Low |
| Netdata cache | `/opt/netdata/var/cache/netdata/` | 500MB - 5GB | Medium |
| Netdata DB engine | `/opt/netdata/var/lib/netdata/dbengine/` | 1-10GB | Medium (loses historical metrics) |
| Prometheus data | `/var/lib/prometheus/` (old WAL/chunks) | 1-50GB | Medium |
| Grafana cache | `/var/lib/grafana/png/`, sessions | 10-500MB | Low |
| Failed systemd units | Orphaned service remnants | Minimal | Low |
| Python bytecode | `/usr/local/**/*.pyc`, `__pycache__` | 10-100MB | Low |

## Safety Profiles

Three profiles via `--profile <level>`:

| Profile | Use Case | Behavior |
|---------|----------|----------|
| `safe` | Production servers | Only clean clearly disposable data (caches, temp files, old logs). Never touch monitoring history. Conservative age thresholds. |
| `moderate` | Staging/dev servers | Clean caches + monitoring data older than retention period. Balance between space and data preservation. |
| `aggressive` | Disk emergencies, CI runners | Maximum cleanup. Clears all caches, old monitoring data, build artifacts. Prioritizes disk space. |

### Profile Matrix

| Cleanup Target | `safe` | `moderate` | `aggressive` |
|----------------|--------|------------|--------------|
| Snap cache | Yes | Yes | Yes |
| APT lists | No | Yes | Yes |
| Crash reports | 30+ days | 7+ days | All |
| Netdata cache | No | Yes | Yes |
| Netdata DB engine | No | 14+ days | 3+ days |
| Prometheus old data | No | 30+ days | 7+ days |
| Grafana cache | No | Yes | Yes |
| Python bytecode | No | No | Yes |
| Journal retention | 14 days | 7 days | 3 days |
| Temp file age | 14 days | 7 days | 3 days |

**Default profile:** `safe` (preserves current behavior)

## Command-Line Interface

### New Flags

```bash
# Profile selection
--profile <safe|moderate|aggressive>   # Select cleanup profile (default: safe)

# New cleanup targets (can override profile)
--snap-cache          # Clean /var/lib/snapd/cache/
--apt-lists           # Clean /var/lib/apt/lists/
--crash-reports       # Clean /var/crash/
--netdata             # Clean Netdata cache and DB engine
--prometheus          # Clean old Prometheus WAL/chunks
--grafana             # Clean Grafana cache
--pycache             # Clean Python bytecode

# Skip specific operations (override profile)
--skip-snap-cache     # Don't clean snap cache
--skip-apt-lists      # Don't clean APT lists
--skip-netdata        # Don't touch Netdata even if profile enables it
--skip-prometheus     # Don't touch Prometheus even if profile enables it
--skip-grafana        # Don't touch Grafana
--skip-crash-reports  # Don't clean crash reports
--skip-pycache        # Don't clean Python bytecode

# Service handling
--stop-services       # Stop services before cleanup, restart after (default: false)
```

### Usage Examples

```bash
# Production server - safe cleanup
sudo ./logcleaner.sh --yes --profile safe

# Staging server - moderate cleanup
sudo ./logcleaner.sh --yes --profile moderate

# Emergency disk cleanup
sudo ./logcleaner.sh --yes --profile aggressive

# Safe profile but also clean Netdata (override)
sudo ./logcleaner.sh --yes --profile safe --netdata

# Aggressive but preserve Prometheus data
sudo ./logcleaner.sh --yes --profile aggressive --skip-prometheus

# Full cleanup with service restart
sudo ./logcleaner.sh --yes --profile aggressive --stop-services
```

### Precedence

Explicit flags (`--netdata`, `--skip-netdata`) always override profile defaults.

## New Cleanup Functions

### cleanup_snap_cache()
```
├── Check if /var/lib/snapd/cache/ exists
├── Calculate size before
├── Remove all files (safe - these are downloaded snap packages)
└── Report freed space
```

### cleanup_apt_lists()
```
├── Check if /var/lib/apt/lists/ exists
├── Remove all files except lock files
├── Note: User should run `apt update` after if needed
└── Report freed space
```

### cleanup_crash_reports()
```
├── Check if /var/crash/ exists
├── Remove .crash files older than threshold (profile-dependent)
└── Report freed space
```

### cleanup_netdata()
```
├── Check if Netdata is installed (detect path: /opt/netdata or /var/lib/netdata)
├── Optionally stop service before cleanup (--stop-services flag)
├── Clean cache directory
├── Clean dbengine (only files older than threshold)
├── Restart service if stopped
└── Report freed space
```

### cleanup_prometheus()
```
├── Detect Prometheus data dir (common: /var/lib/prometheus/)
├── Clean old WAL segments and chunks beyond retention
├── Never touch active/current data
└── Report freed space
```

### cleanup_grafana()
```
├── Clean /var/lib/grafana/png/ (rendered panel cache)
├── Clean old session files
└── Report freed space
```

### cleanup_pycache()
```
├── Find __pycache__ directories in /usr/local/, /opt/
├── Remove .pyc files older than threshold
└── Report freed space
```

## Service Handling

### Problem
Netdata, Prometheus, and Grafana may hold file handles to cache/data directories. Cleaning while running could cause issues.

### Solution
New flag: `--stop-services` (default: false for all profiles)

### Behavior by Profile

| Profile | Default `--stop-services` | Reasoning |
|---------|---------------------------|-----------|
| `safe` | false | Never interrupt monitoring on production |
| `moderate` | false | User must opt-in |
| `aggressive` | false | Still opt-in, but recommended in output |

### Service Handling Flow

```
1. Detect if service is running
2. If --stop-services and service running:
   ├── Stop service gracefully (systemctl stop)
   ├── Wait for clean shutdown (max 30s)
   ├── Perform cleanup
   ├── Restart service (systemctl start)
   └── Verify service is healthy
3. If NOT --stop-services and service running:
   ├── Print warning: "Netdata is running, some files may be locked"
   ├── Clean only unlocked files (skip on EBUSY)
   └── Suggest: "Run with --stop-services for complete cleanup"
```

**Safety:** Script will never force-kill services. If graceful stop fails, skip that cleanup with a warning.

## Error Handling & Logging

### Enhanced Logging

```
# Standard output (non-verbose)
✓ Snap cache cleaned, freed 1.2GB
✓ Netdata cache cleaned, freed 2.5GB
⚠ Prometheus cleanup skipped (service running, use --stop-services)

# Verbose output (-V)
ℹ Cleaning /var/lib/snapd/cache/...
ℹ Found 47 cached snap packages
ℹ Removing: core22_1564.snap (125MB)
ℹ Removing: lxd_28373.snap (89MB)
...
✓ Snap cache cleaned, freed 1.2GB
```

### Error Scenarios

| Scenario | Behavior |
|----------|----------|
| Service won't stop | Skip that cleanup, warn, continue with others |
| Permission denied on file | Skip file, log to manifest, continue |
| Directory doesn't exist | Skip silently (tool not installed) |
| Disk full during cleanup | Continue best-effort, prioritize by impact |
| Service won't restart | Error message with manual recovery steps |

### Manifest File Enhancement

```bash
# With --manifest /var/log/cleaned-files.txt
[2025-12-18 10:30:45] [snap-cache] Removed: /var/lib/snapd/cache/core22_1564.snap (125MB)
[2025-12-18 10:30:45] [netdata] Removed: /opt/netdata/var/cache/netdata/... (2.5GB)
[2025-12-18 10:30:46] [netdata] Skipped: /opt/netdata/var/lib/netdata/dbengine/datafile.db (locked)
```

## Backwards Compatibility

- Default behavior (no flags) equals current v2.0 behavior (equivalent to `--profile safe`)
- All existing flags continue to work
- Existing config file options remain valid
- New profile system is additive, not breaking

## Version

This design targets **v3.0.0** due to significant feature additions.

## Implementation Notes

1. Add profile configuration variables at top of script
2. Implement `apply_profile()` function to set defaults based on profile
3. Add new cleanup functions
4. Update `parse_arguments()` for new flags
5. Update help text
6. Update config file example
7. Update README with new features
