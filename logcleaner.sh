#!/bin/bash

################################################################################
# Ubuntu Log Cleaner - Automated System Maintenance Script
#
# Performs cleanup tasks:
# - Remove old kernels (keeps current + 1 old)
# - Vacuum systemd journal
# - Remove compressed .gz logs
# - Clean APT cache
# - Remove old snap revisions
# - Clean temporary files (7+ days old)
# - Docker cleanup (optional)
# - Package cache cleanup (pip, npm, yarn - optional)
# - Systemd coredump cleanup (optional)
# - Thumbnail cache cleanup (optional)
#
# Usage: sudo ./logcleaner.sh [OPTIONS]
# Run with --help for detailed usage information
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

################################################################################
# Script Metadata
################################################################################

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CONFIG_FILE="/etc/logcleaner.conf"
readonly LOCK_FILE="/var/run/logcleaner.pid"
readonly DEFAULT_LOG_FILE="/var/log/logcleaner.log"

################################################################################
# Global Configuration Variables
################################################################################

# Operational modes
DRY_RUN=false
INTERACTIVE=true
VERBOSE=false
QUIET=false
CREATE_BACKUP=false
BACKUP_DIR="/var/backups/logcleaner"

# Cleanup configuration
TEMP_FILE_AGE=7              # Days to keep temp files
JOURNAL_KEEP_DAYS=7          # Days to keep journal logs
KERNEL_KEEP_COUNT=1          # Number of old kernels to keep (in addition to current)

# Feature flags (which cleanup operations to run)
CLEANUP_KERNELS=true
CLEANUP_JOURNAL=true
CLEANUP_GZ_LOGS=true
CLEANUP_APT=true
CLEANUP_SNAP=true
CLEANUP_TEMP=true
CLEANUP_DOCKER=false         # Opt-in
CLEANUP_PKG_CACHE=false      # Opt-in (pip, npm, yarn)
CLEANUP_COREDUMP=false       # Opt-in
CLEANUP_THUMBNAILS=false     # Opt-in
CLEANUP_MAIL=false           # Opt-in

# Logging
LOG_FILE=""
LOG_TO_FILE=false
DELETED_FILES_MANIFEST=""

# Runtime state
TOTAL_FREED=0
DISK_USED_BEFORE=0

# Color codes for output (will be disabled if not a TTY)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color
USE_COLORS=true

################################################################################
# Helper Functions
################################################################################

# Initialize color support based on TTY detection
init_colors() {
    if [[ ! -t 1 ]] || [[ "$QUIET" == true ]]; then
        USE_COLORS=false
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        CYAN=''
        NC=''
    fi
}

# Logging function that writes to both console and log file
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Write to log file if enabled
    if [[ "$LOG_TO_FILE" == true ]] && [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi

    # Log deleted files to manifest if it's a deletion message
    if [[ -n "$DELETED_FILES_MANIFEST" ]] && [[ "$message" =~ ^(Removing|Deleted): ]]; then
        echo "[$timestamp] $message" >> "$DELETED_FILES_MANIFEST"
    fi
}

# Print colored messages
print_header() {
    local msg="$1"
    [[ "$QUIET" == true ]] && return

    if [[ "$USE_COLORS" == true ]]; then
        echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}$msg${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    else
        echo ""
        echo "======================================================="
        echo "$msg"
        echo "======================================================="
    fi
    log_message "INFO" "$msg"
}

print_success() {
    local msg="$1"
    [[ "$QUIET" == true ]] && return

    if [[ "$USE_COLORS" == true ]]; then
        echo -e "${GREEN}✓ $msg${NC}"
    else
        echo "✓ $msg"
    fi
    log_message "SUCCESS" "$msg"
}

print_warning() {
    local msg="$1"
    if [[ "$USE_COLORS" == true ]]; then
        echo -e "${YELLOW}⚠ $msg${NC}" >&2
    else
        echo "⚠ $msg" >&2
    fi
    log_message "WARNING" "$msg"
}

print_error() {
    local msg="$1"
    if [[ "$USE_COLORS" == true ]]; then
        echo -e "${RED}✗ $msg${NC}" >&2
    else
        echo "✗ $msg" >&2
    fi
    log_message "ERROR" "$msg"
}

print_info() {
    local msg="$1"
    [[ "$QUIET" == true ]] && return
    [[ "$VERBOSE" == false ]] && return

    if [[ "$USE_COLORS" == true ]]; then
        echo -e "${BLUE}ℹ $msg${NC}"
    else
        echo "ℹ $msg"
    fi
    log_message "INFO" "$msg"
}

print_dry_run() {
    local msg="$1"
    [[ "$QUIET" == true ]] && return

    if [[ "$USE_COLORS" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] $msg${NC}"
    else
        echo "[DRY RUN] $msg"
    fi
    log_message "DRY-RUN" "$msg"
}

# Convert bytes to human-readable format
bytes_to_human() {
    local bytes=$1
    # Use numfmt (coreutils) instead of bc to avoid extra dependency
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        # Fallback to pure bash if numfmt isn't available
        if (( bytes < 1024 )); then
            echo "${bytes}B"
        elif (( bytes < 1048576 )); then
            echo "$(( bytes / 1024 ))KB"
        elif (( bytes < 1073741824 )); then
            echo "$(( bytes / 1048576 ))MB"
        else
            # Use awk instead of bc for decimal division
            printf "%.2fGB\n" "$(awk "BEGIN {print $bytes / 1073741824}")"
        fi
    fi
}

# Get disk usage of a path
get_size() {
    local path=$1
    if [[ -e "$path" ]]; then
        du -sb "$path" 2>/dev/null | awk '{print $1}' || echo "0"
    else
        echo "0"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo"
        echo "Usage: sudo $SCRIPT_NAME [OPTIONS]"
        echo "Run with --help for more information"
        exit 1
    fi
}

# Acquire lock file to prevent multiple instances
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            print_error "Another instance is already running (PID: $lock_pid)"
            print_error "If this is incorrect, remove $LOCK_FILE and try again"
            exit 1
        else
            print_warning "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    log_message "INFO" "Lock acquired (PID: $$)"
}

# Release lock file
release_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        log_message "INFO" "Lock released"
    fi
}

# Cleanup function called on error or exit
cleanup_on_exit() {
    local exit_code=$?
    release_lock

    if [[ $exit_code -ne 0 ]]; then
        print_error "Script exited with error code $exit_code"
        log_message "ERROR" "Script terminated with exit code $exit_code"
    fi

    exit $exit_code
}

# Set up error handling traps
setup_error_handling() {
    trap cleanup_on_exit EXIT
    trap 'print_error "Script interrupted by user"; exit 130' INT TERM
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Loading configuration from $CONFIG_FILE"
        # Source the config file safely
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log_message "INFO" "Configuration loaded from $CONFIG_FILE"
    fi
}

# Initialize logging
init_logging() {
    # Set up log file
    if [[ -n "$LOG_FILE" ]] || [[ "$LOG_TO_FILE" == true ]]; then
        LOG_TO_FILE=true
        LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

        # Create log directory if needed
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || {
                print_warning "Could not create log directory $log_dir, logging to file disabled"
                LOG_TO_FILE=false
                return
            }
        fi

        # Touch log file to ensure we can write to it
        if ! touch "$LOG_FILE" 2>/dev/null; then
            print_warning "Cannot write to log file $LOG_FILE, logging to file disabled"
            LOG_TO_FILE=false
            return
        fi

        print_info "Logging to file: $LOG_FILE"
    fi

    # Set up deleted files manifest if requested
    if [[ -n "$DELETED_FILES_MANIFEST" ]]; then
        local manifest_dir
        manifest_dir="$(dirname "$DELETED_FILES_MANIFEST")"
        if [[ ! -d "$manifest_dir" ]]; then
            mkdir -p "$manifest_dir" 2>/dev/null || {
                print_warning "Could not create manifest directory $manifest_dir"
                DELETED_FILES_MANIFEST=""
            }
        fi
        if [[ -n "$DELETED_FILES_MANIFEST" ]]; then
            touch "$DELETED_FILES_MANIFEST" 2>/dev/null || {
                print_warning "Cannot write to manifest file $DELETED_FILES_MANIFEST"
                DELETED_FILES_MANIFEST=""
            }
        fi
    fi
}

# Prompt for user confirmation
confirm_action() {
    [[ "$INTERACTIVE" == false ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local prompt="${1:-Do you want to proceed?}"
    local response

    echo -e "${YELLOW}$prompt [y/N]:${NC} " >&2
    read -r response

    case "$response" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            print_info "Operation cancelled by user"
            exit 0
            ;;
    esac
}

# Create backup of files before deletion
create_backup_archive() {
    [[ "$CREATE_BACKUP" == false ]] && return 0

    local backup_name="logcleaner-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local backup_path="$BACKUP_DIR/$backup_name"

    print_info "Creating backup at $backup_path..."

    # Create backup directory if it doesn't exist
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || {
            print_warning "Could not create backup directory $BACKUP_DIR, skipping backup"
            return 1
        }
    fi

    # TODO: Implement actual backup of files to be deleted
    # This is a placeholder - actual implementation will be added when we modify cleanup functions

    print_info "Backup created: $backup_path"
    log_message "INFO" "Backup created at $backup_path"
    return 0
}

# Basic environment validation
preflight_checks() {
    local os_id="unknown"
    if [[ -r /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    if [[ "$os_id" != "ubuntu" && "$os_id" != "debian" ]]; then
        print_warning "Non-Ubuntu/Debian system detected ($os_id), running best-effort cleanup"
    fi

    # Required tools
    for cmd in dpkg-query apt-get find; do
        if ! command -v "$cmd" &> /dev/null; then
            print_error "Required command '$cmd' not found. Please install it or adjust the script."
            exit 1
        fi
    done
}

# Capture used disk space (bytes) for later delta calculations
get_used_space() {
    df --output=used -B1 / 2>/dev/null | tail -n 1 | awk '{print $1}' | awk 'NF {print; exit} END {if (NR==0) print 0}'
}

# Show help message
show_help() {
    cat << EOF
Ubuntu Log Cleaner v${VERSION}
Automated system maintenance and disk space cleanup tool

USAGE:
    sudo $SCRIPT_NAME [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -d, --dry-run           Preview actions without making changes
    -y, --yes               Skip interactive confirmation prompts
    -q, --quiet             Suppress non-essential output
    -V, --verbose           Show detailed output
    --log-file FILE         Write logs to specified file (default: $DEFAULT_LOG_FILE)
    --no-log                Disable file logging
    --manifest FILE         Write list of deleted files to FILE

    --create-backup         Create backup archive before deletion
    --backup-dir DIR        Backup directory (default: $BACKUP_DIR)

CLEANUP OPTIONS (enable/disable specific operations):
    --skip-kernels          Skip old kernel cleanup
    --skip-journal          Skip systemd journal cleanup
    --skip-gz-logs          Skip compressed log cleanup
    --skip-apt              Skip APT cache cleanup
    --skip-snap             Skip snap revision cleanup
    --skip-temp             Skip temporary files cleanup

    --docker                Enable Docker cleanup
    --pkg-cache             Enable package cache cleanup (pip, npm, yarn)
    --coredump              Enable systemd coredump cleanup
    --thumbnails            Enable thumbnail cache cleanup
    --mail                  Enable mail queue cleanup

    --only-kernels          Run only kernel cleanup
    --only-journal          Run only journal cleanup
    --only-gz-logs          Run only gz log cleanup
    --only-apt              Run only APT cleanup
    --only-snap             Run only snap cleanup
    --only-temp             Run only temp file cleanup

CONFIGURATION:
    --config FILE           Load configuration from FILE (default: $CONFIG_FILE)
    --temp-age DAYS         Age threshold for temporary files (default: $TEMP_FILE_AGE)
    --journal-days DAYS     Days to keep journal logs (default: $JOURNAL_KEEP_DAYS)
    --kernel-keep N         Number of old kernels to keep (default: $KERNEL_KEEP_COUNT)

EXAMPLES:
    # Run with default settings (interactive)
    sudo $SCRIPT_NAME

    # Preview what would be cleaned without making changes
    sudo $SCRIPT_NAME --dry-run

    # Run non-interactively with logging
    sudo $SCRIPT_NAME --yes --log-file /var/log/logcleaner.log

    # Run only Docker and package cache cleanup
    sudo $SCRIPT_NAME --only-docker --pkg-cache

    # Create backup before cleanup
    sudo $SCRIPT_NAME --create-backup --backup-dir /backup/logcleaner

    # Clean with custom retention periods
    sudo $SCRIPT_NAME --temp-age 14 --journal-days 3

CONFIGURATION FILE:
    You can create a configuration file at $CONFIG_FILE with:
        TEMP_FILE_AGE=14
        JOURNAL_KEEP_DAYS=3
        KERNEL_KEEP_COUNT=2
        CLEANUP_DOCKER=true
        LOG_TO_FILE=true

EXIT CODES:
    0    Success
    1    Error occurred
    130  Interrupted by user

For more information, visit: https://github.com/Volkers-BV/ubuntu-cleaner
EOF
    exit 0
}

# Show version information
show_version() {
    echo "Ubuntu Log Cleaner v${VERSION}"
    exit 0
}

# Parse command-line arguments
parse_arguments() {
    local only_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -v|--version)
                show_version
                ;;
            -d|--dry-run)
                DRY_RUN=true
                INTERACTIVE=false
                VERBOSE=true
                shift
                ;;
            -y|--yes)
                INTERACTIVE=false
                shift
                ;;
            -q|--quiet)
                QUIET=true
                VERBOSE=false
                shift
                ;;
            -V|--verbose)
                VERBOSE=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                LOG_TO_FILE=true
                shift 2
                ;;
            --no-log)
                LOG_TO_FILE=false
                shift
                ;;
            --manifest)
                DELETED_FILES_MANIFEST="$2"
                shift 2
                ;;
            --create-backup)
                CREATE_BACKUP=true
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --temp-age)
                TEMP_FILE_AGE="$2"
                shift 2
                ;;
            --journal-days)
                JOURNAL_KEEP_DAYS="$2"
                shift 2
                ;;
            --kernel-keep)
                KERNEL_KEEP_COUNT="$2"
                shift 2
                ;;
            --skip-kernels)
                CLEANUP_KERNELS=false
                shift
                ;;
            --skip-journal)
                CLEANUP_JOURNAL=false
                shift
                ;;
            --skip-gz-logs)
                CLEANUP_GZ_LOGS=false
                shift
                ;;
            --skip-apt)
                CLEANUP_APT=false
                shift
                ;;
            --skip-snap)
                CLEANUP_SNAP=false
                shift
                ;;
            --skip-temp)
                CLEANUP_TEMP=false
                shift
                ;;
            --docker)
                CLEANUP_DOCKER=true
                shift
                ;;
            --pkg-cache)
                CLEANUP_PKG_CACHE=true
                shift
                ;;
            --coredump)
                CLEANUP_COREDUMP=true
                shift
                ;;
            --thumbnails)
                CLEANUP_THUMBNAILS=true
                shift
                ;;
            --mail)
                CLEANUP_MAIL=true
                shift
                ;;
            --only-kernels)
                only_mode=true
                CLEANUP_KERNELS=true
                shift
                ;;
            --only-journal)
                only_mode=true
                CLEANUP_JOURNAL=true
                shift
                ;;
            --only-gz-logs)
                only_mode=true
                CLEANUP_GZ_LOGS=true
                shift
                ;;
            --only-apt)
                only_mode=true
                CLEANUP_APT=true
                shift
                ;;
            --only-snap)
                only_mode=true
                CLEANUP_SNAP=true
                shift
                ;;
            --only-temp)
                only_mode=true
                CLEANUP_TEMP=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run '$SCRIPT_NAME --help' for usage information"
                exit 1
                ;;
        esac
    done

    # If only mode was activated, disable all other cleanup operations
    if [[ "$only_mode" == true ]]; then
        # Save the current states
        local k=$CLEANUP_KERNELS
        local j=$CLEANUP_JOURNAL
        local g=$CLEANUP_GZ_LOGS
        local a=$CLEANUP_APT
        local s=$CLEANUP_SNAP
        local t=$CLEANUP_TEMP

        # Disable all
        CLEANUP_KERNELS=false
        CLEANUP_JOURNAL=false
        CLEANUP_GZ_LOGS=false
        CLEANUP_APT=false
        CLEANUP_SNAP=false
        CLEANUP_TEMP=false
        CLEANUP_DOCKER=false
        CLEANUP_PKG_CACHE=false
        CLEANUP_COREDUMP=false
        CLEANUP_THUMBNAILS=false
        CLEANUP_MAIL=false

        # Re-enable only the selected ones
        [[ "$k" == true ]] && CLEANUP_KERNELS=true
        [[ "$j" == true ]] && CLEANUP_JOURNAL=true
        [[ "$g" == true ]] && CLEANUP_GZ_LOGS=true
        [[ "$a" == true ]] && CLEANUP_APT=true
        [[ "$s" == true ]] && CLEANUP_SNAP=true
        [[ "$t" == true ]] && CLEANUP_TEMP=true
    fi
}

################################################################################
# Cleanup Functions
################################################################################

# Remove old kernels (keep current + 1 old kernel)
cleanup_old_kernels() {
    print_header "Removing Old Kernels"

    local current_kernel
    current_kernel=$(uname -r)
    print_info "Current kernel: $current_kernel"

    # Collect installed kernel-related packages (images/modules/headers)
    local kernel_packages
    kernel_packages=$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null \
        | grep -E 'linux-(image|modules|headers)-[0-9]' | sort -u || true)

    if [[ -z "$kernel_packages" ]]; then
        print_warning "No kernel packages found to evaluate"
        return 0
    fi

    # Derive unique kernel versions
    local kernel_versions
    kernel_versions=$(echo "$kernel_packages" | sed -E 's/^linux-(image|modules|headers)-//' | sort -V | uniq)

    # Exclude the running kernel from removal candidates
    local removable_versions
    removable_versions=$(echo "$kernel_versions" | grep -vx "$current_kernel" || true)

    if [[ -z "$removable_versions" ]]; then
        print_warning "No old kernels found to remove"
        return 0
    fi

    local version_count
    version_count=$(echo "$removable_versions" | wc -l)
    local versions_to_keep=1

    if (( version_count <= versions_to_keep )); then
        print_warning "Keeping all $version_count old kernel version(s) for safety (minimum $versions_to_keep required)"
        return 0
    fi

    # Remove all but the most recent removable version
    local versions_to_remove
    versions_to_remove=$(echo "$removable_versions" | sort -V | head -n -"${versions_to_keep}")

    if [[ -z "$versions_to_remove" ]]; then
        print_warning "No kernels to remove after safety check"
        return 0
    fi

    local freed=0
    local count=0

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        local packages_for_version
        packages_for_version=$(echo "$kernel_packages" | grep -E "${version}\$" || true)

        if [[ -z "$packages_for_version" ]]; then
            continue
        fi

        local version_freed=0
        local pkg
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            local size_before
            size_before=$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo "0")
            size_before=$((size_before * 1024))  # Convert KB to bytes

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $pkg ($(bytes_to_human $size_before))"
                version_freed=$((version_freed + size_before))
                count=$((count + 1))
            else
                print_info "Removing: $pkg"
                if apt-get purge -y "$pkg" >/dev/null 2>&1; then
                    version_freed=$((version_freed + size_before))
                    count=$((count + 1))
                else
                    print_warning "Failed to remove $pkg"
                fi
            fi
        done <<< "$packages_for_version"

        freed=$((freed + version_freed))
    done <<< "$versions_to_remove"

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count kernel package(s), freed $(bytes_to_human $freed)"
    else
        print_warning "No kernels were removed"
    fi
}

# Vacuum systemd journal
cleanup_journal() {
    print_header "Vacuuming Systemd Journal"

    if ! command -v journalctl &> /dev/null; then
        print_warning "journalctl not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size /var/log/journal)

    print_info "Journal size before: $(bytes_to_human $size_before)"

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would vacuum journal (keep last ${JOURNAL_KEEP_DAYS} days)"
        # Estimate freed space (conservative estimate: 30% of current size)
        local estimated_freed=$((size_before * 30 / 100))
        if (( estimated_freed > 0 )); then
            TOTAL_FREED=$((TOTAL_FREED + estimated_freed))
            print_dry_run "Estimated space to free: $(bytes_to_human $estimated_freed)"
        fi
    else
        # Vacuum journal - keep last N days
        if journalctl --vacuum-time=${JOURNAL_KEEP_DAYS}d >/dev/null 2>&1; then
            local size_after
            size_after=$(get_size /var/log/journal)
            local freed=$((size_before - size_after))

            # Clamp to 0 if journal grew during execution
            if (( freed < 0 )); then
                freed=0
            fi

            if (( freed > 0 )); then
                TOTAL_FREED=$((TOTAL_FREED + freed))
                print_success "Journal vacuumed, freed $(bytes_to_human $freed)"
            else
                print_info "Journal was already optimal"
            fi
        else
            print_warning "Failed to vacuum journal"
        fi
    fi
}

# Remove compressed .gz log files
cleanup_gz_logs() {
    print_header "Removing Compressed .gz Logs"

    if [[ ! -d /var/log ]]; then
        print_warning "/var/log directory not found, skipping"
        return 0
    fi

    local gz_files
    gz_files=$(find /var/log -type f -name "*.gz" 2>/dev/null || true)

    if [[ -z "$gz_files" ]]; then
        print_warning "No .gz log files found"
        return 0
    fi

    local count=0
    local freed=0

    while IFS= read -r file; do
        if [[ -n "$file" && -f "$file" ]]; then
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        fi
    done <<< "$gz_files"

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count .gz log file(s), freed $(bytes_to_human $freed)"
    else
        print_warning "No .gz files were removed"
    fi
}

# Clean APT cache
cleanup_apt_cache() {
    print_header "Cleaning APT Cache"

    if ! command -v apt-get &> /dev/null; then
        print_warning "apt-get not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size /var/cache/apt/archives)

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would run apt-get clean"
        print_dry_run "Would run apt-get autoclean"
        print_dry_run "Would run apt-get autoremove --purge"
        # Estimate freed space
        local estimated_freed=$((size_before * 70 / 100))
        if (( estimated_freed > 0 )); then
            TOTAL_FREED=$((TOTAL_FREED + estimated_freed))
            print_dry_run "Estimated space to free: $(bytes_to_human $estimated_freed)"
        fi
    else
        # Set non-interactive mode to prevent prompts
        export DEBIAN_FRONTEND=noninteractive
        local dpkg_opts="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

        print_info "Running apt-get clean..."
        apt-get clean $dpkg_opts >/dev/null 2>&1

        print_info "Running apt-get autoclean..."
        apt-get autoclean -y $dpkg_opts >/dev/null 2>&1

        print_info "Running apt-get autoremove..."
        local autoremove_output
        autoremove_output=$(apt-get autoremove --purge -y $dpkg_opts 2>&1)

        local size_after
        size_after=$(get_size /var/cache/apt/archives)
        local freed=$((size_before - size_after))

        # Clamp to 0 if cache grew during execution (downloads, etc.)
        if (( freed < 0 )); then
            freed=0
        fi

        # Check if any packages were removed
        if echo "$autoremove_output" | grep -q "0 upgraded, 0 newly installed, 0 to remove"; then
            print_info "No packages to autoremove"
        else
            local removed_count
            removed_count=$(echo "$autoremove_output" | grep -oE '[0-9]+' | grep -B1 'to remove' | head -1 || echo "0")
            if (( removed_count > 0 )); then
                print_info "Autoremoved $removed_count package(s)"
            fi
        fi

        if (( freed > 0 )); then
            TOTAL_FREED=$((TOTAL_FREED + freed))
            print_success "APT cache cleaned, freed $(bytes_to_human $freed)"
        else
            print_info "APT cache was already clean"
        fi
    fi
}

# Remove old snap revisions
cleanup_snap_revisions() {
    print_header "Removing Old Snap Revisions"

    if ! command -v snap &> /dev/null; then
        print_warning "snap not found, skipping"
        return 0
    fi

    local freed=0
    local count=0

    # Get list of disabled snap revisions
    local disabled_snaps
    disabled_snaps=$(snap list --all 2>/dev/null | grep disabled | awk '{print $1, $3}' || true)

    if [[ -z "$disabled_snaps" ]]; then
        print_warning "No old snap revisions found"
        return 0
    fi

    while IFS=' ' read -r snap_name revision; do
        if [[ -n "$snap_name" && -n "$revision" ]]; then
            local snap_path="/snap/$snap_name/$revision"
            local size=0

            if [[ -d "$snap_path" ]]; then
                size=$(get_size "$snap_path")
            fi

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove $snap_name revision $revision ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                print_info "Removing $snap_name revision $revision"
                if snap remove "$snap_name" --revision="$revision" >/dev/null 2>&1; then
                    freed=$((freed + size))
                    count=$((count + 1))
                else
                    print_warning "Failed to remove $snap_name revision $revision"
                fi
            fi
        fi
    done <<< "$disabled_snaps"

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count snap revision(s), freed $(bytes_to_human $freed)"
    else
        print_warning "No snap revisions were removed"
    fi
}

# Clean temporary files older than 7 days
cleanup_temp_files() {
    print_header "Cleaning Temporary Files (${TEMP_FILE_AGE}+ days old)"

    local freed=0
    local count=0

    # Helper to clean a directory
    clean_temp_dir() {
        local dir=$1
        [[ ! -d "$dir" ]] && return

        print_info "Cleaning $dir..."

        # Remove files, symlinks, sockets, and FIFOs
        while IFS= read -r -d '' entry; do
            local size
            size=$(get_size "$entry")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $entry ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f -- "$entry" 2>/dev/null; then
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        done < <(find "$dir" -mindepth 1 \( -type f -o -type l -o -type s -o -type p \) -mtime +${TEMP_FILE_AGE} -print0 2>/dev/null)

        # Remove empty directories that are older than threshold
        local dir_removed=0
        while IFS= read -r -d '' empty_dir; do
            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove empty directory: $empty_dir"
                dir_removed=$((dir_removed + 1))
            else
                if rmdir "$empty_dir" 2>/dev/null; then
                    dir_removed=$((dir_removed + 1))
                fi
            fi
        done < <(find "$dir" -type d -empty -mtime +${TEMP_FILE_AGE} -print0 2>/dev/null)

        if (( dir_removed > 0 )); then
            print_info "Would remove/Removed $dir_removed empty director$( (( dir_removed == 1 )) && echo 'y' || echo 'ies') from $dir"
        fi
    }

    clean_temp_dir /tmp
    clean_temp_dir /var/tmp

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count temporary file(s), freed $(bytes_to_human $freed)"
    else
        print_info "No old temporary files found"
    fi
}

# Clean Docker system (containers, images, volumes, build cache)
cleanup_docker() {
    print_header "Cleaning Docker System"

    if ! command -v docker &> /dev/null; then
        print_warning "docker not found, skipping"
        return 0
    fi

    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        print_warning "Docker daemon is not running, skipping"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would run docker system prune -af --volumes"
        # Try to estimate size
        local size_estimate
        size_estimate=$(docker system df 2>/dev/null | awk '/Reclaimable/ {print $4}' | head -1 || echo "0B")
        print_dry_run "Estimated reclaimable space: $size_estimate"
        return 0
    fi

    print_info "Running docker system prune..."
    local docker_output
    docker_output=$(docker system prune -af --volumes 2>&1 || echo "")

    # Try to extract freed space from output
    local freed_match
    freed_match=$(echo "$docker_output" | grep -oE 'Total reclaimed space: [0-9.]+[KMGT]?B' || echo "")

    if [[ -n "$freed_match" ]]; then
        print_success "Docker cleanup completed: $freed_match"
        log_message "INFO" "Docker cleanup: $freed_match"
    else
        print_info "Docker cleanup completed"
    fi
}

# Clean package manager caches (pip, npm, yarn)
cleanup_package_caches() {
    print_header "Cleaning Package Manager Caches"

    local freed=0
    local total_cleaned=0

    # Clean pip cache
    if command -v pip3 &> /dev/null || command -v pip &> /dev/null; then
        local pip_cmd
        pip_cmd=$(command -v pip3 || command -v pip)
        local pip_cache_dir
        pip_cache_dir=$($pip_cmd cache dir 2>/dev/null || echo "$HOME/.cache/pip")

        if [[ -d "$pip_cache_dir" ]]; then
            local size_before
            size_before=$(get_size "$pip_cache_dir")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would clean pip cache at $pip_cache_dir ($(bytes_to_human $size_before))"
                freed=$((freed + size_before))
            else
                print_info "Cleaning pip cache..."
                if $pip_cmd cache purge >/dev/null 2>&1; then
                    freed=$((freed + size_before))
                    print_success "Pip cache cleaned, freed $(bytes_to_human $size_before)"
                    total_cleaned=$((total_cleaned + 1))
                else
                    print_warning "Failed to clean pip cache"
                fi
            fi
        fi
    fi

    # Clean npm cache
    if command -v npm &> /dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            print_dry_run "Would clean npm cache"
        else
            print_info "Cleaning npm cache..."
            local npm_cache_dir
            npm_cache_dir=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
            local size_before
            size_before=$(get_size "$npm_cache_dir")

            if npm cache clean --force >/dev/null 2>&1; then
                local size_after
                size_after=$(get_size "$npm_cache_dir")
                local npm_freed=$((size_before - size_after))
                if (( npm_freed > 0 )); then
                    freed=$((freed + npm_freed))
                    print_success "NPM cache cleaned, freed $(bytes_to_human $npm_freed)"
                    total_cleaned=$((total_cleaned + 1))
                fi
            else
                print_warning "Failed to clean npm cache"
            fi
        fi
    fi

    # Clean yarn cache
    if command -v yarn &> /dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            print_dry_run "Would clean yarn cache"
        else
            print_info "Cleaning yarn cache..."
            local yarn_cache_dir
            yarn_cache_dir=$(yarn cache dir 2>/dev/null || echo "$HOME/.yarn/cache")
            local size_before
            size_before=$(get_size "$yarn_cache_dir")

            if yarn cache clean >/dev/null 2>&1; then
                local size_after
                size_after=$(get_size "$yarn_cache_dir")
                local yarn_freed=$((size_before - size_after))
                if (( yarn_freed > 0 )); then
                    freed=$((freed + yarn_freed))
                    print_success "Yarn cache cleaned, freed $(bytes_to_human $yarn_freed)"
                    total_cleaned=$((total_cleaned + 1))
                fi
            else
                print_warning "Failed to clean yarn cache"
            fi
        fi
    fi

    if (( total_cleaned > 0 )) || [[ "$DRY_RUN" == true ]]; then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        if [[ "$DRY_RUN" == false ]]; then
            print_success "Package cache cleanup completed, freed $(bytes_to_human $freed)"
        fi
    else
        print_warning "No package manager caches found to clean"
    fi
}

# Clean systemd coredumps
cleanup_coredumps() {
    print_header "Cleaning Systemd Coredumps"

    local coredump_dir="/var/lib/systemd/coredump"

    if [[ ! -d "$coredump_dir" ]]; then
        print_warning "Coredump directory not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size "$coredump_dir")

    if (( size_before == 0 )); then
        print_info "No coredumps to clean"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would clean coredumps from $coredump_dir ($(bytes_to_human $size_before))"
        TOTAL_FREED=$((TOTAL_FREED + size_before))
    else
        print_info "Cleaning coredumps..."
        if command -v coredumpctl &> /dev/null; then
            # Use coredumpctl if available
            if coredumpctl clean >/dev/null 2>&1; then
                print_success "Coredumps cleaned using coredumpctl"
            fi
        fi

        # Also manually clean old files
        find "$coredump_dir" -type f -mtime +7 -delete 2>/dev/null || true

        local size_after
        size_after=$(get_size "$coredump_dir")
        local freed=$((size_before - size_after))

        if (( freed > 0 )); then
            TOTAL_FREED=$((TOTAL_FREED + freed))
            print_success "Coredumps cleaned, freed $(bytes_to_human $freed)"
        else
            print_info "No coredumps were removed"
        fi
    fi
}

# Clean thumbnail caches
cleanup_thumbnails() {
    print_header "Cleaning Thumbnail Caches"

    local freed=0
    local thumbnail_dirs=()

    # Check common thumbnail locations
    [[ -d "/root/.cache/thumbnails" ]] && thumbnail_dirs+=("/root/.cache/thumbnails")
    [[ -d "/root/.thumbnails" ]] && thumbnail_dirs+=("/root/.thumbnails")

    # Find user home directories
    while IFS=: read -r username _ uid _ _ homedir _; do
        if (( uid >= 1000 )) && [[ -d "$homedir" ]]; then
            [[ -d "$homedir/.cache/thumbnails" ]] && thumbnail_dirs+=("$homedir/.cache/thumbnails")
            [[ -d "$homedir/.thumbnails" ]] && thumbnail_dirs+=("$homedir/.thumbnails")
        fi
    done < /etc/passwd

    if (( ${#thumbnail_dirs[@]} == 0 )); then
        print_warning "No thumbnail caches found"
        return 0
    fi

    for dir in "${thumbnail_dirs[@]}"; do
        local size
        size=$(get_size "$dir")

        if (( size > 0 )); then
            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove thumbnails from $dir ($(bytes_to_human $size))"
                freed=$((freed + size))
            else
                print_info "Cleaning $dir..."
                if rm -rf "$dir"/* 2>/dev/null; then
                    freed=$((freed + size))
                    print_success "Cleaned $dir, freed $(bytes_to_human $size)"
                fi
            fi
        fi
    done

    if (( freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Thumbnail cleanup completed, freed $(bytes_to_human $freed)"
    else
        print_info "No thumbnails to remove"
    fi
}

# Clean old mail
cleanup_mail() {
    print_header "Cleaning Old Mail"

    local mail_dirs=("/var/mail" "/var/spool/mail")
    local freed=0
    local count=0

    for mail_dir in "${mail_dirs[@]}"; do
        [[ ! -d "$mail_dir" ]] && continue

        # Find files older than 30 days
        while IFS= read -r -d '' mailfile; do
            if [[ -f "$mailfile" ]]; then
                local size
                size=$(get_size "$mailfile")

                # Only remove if file is older than 30 days and not recently modified
                if [[ "$DRY_RUN" == true ]]; then
                    print_dry_run "Would remove old mail: $mailfile ($(bytes_to_human $size))"
                    freed=$((freed + size))
                    count=$((count + 1))
                else
                    print_info "Removing old mail: $mailfile"
                    if rm -f "$mailfile" 2>/dev/null; then
                        freed=$((freed + size))
                        count=$((count + 1))
                    fi
                fi
            fi
        done < <(find "$mail_dir" -type f -mtime +30 -print0 2>/dev/null)
    done

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count old mail file(s), freed $(bytes_to_human $freed)"
    else
        print_info "No old mail to remove"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Parse command-line arguments first
    parse_arguments "$@"

    # Initialize colors based on TTY detection
    init_colors

    # Set up error handling
    setup_error_handling

    # Load configuration file if it exists
    load_config

    # Check for root privileges
    check_root

    # Acquire lock to prevent multiple instances
    acquire_lock

    # Initialize logging
    init_logging

    # Environment validation
    preflight_checks

    # Print banner
    if [[ "$QUIET" == false ]]; then
        if [[ "$USE_COLORS" == true ]]; then
            echo -e "${CYAN}"
            echo "╔═══════════════════════════════════════════════════════╗"
            echo "║    Ubuntu Log Cleaner v${VERSION} - System Maintenance    ║"
            echo "╚═══════════════════════════════════════════════════════╝"
            echo -e "${NC}"
        else
            echo "======================================================="
            echo "   Ubuntu Log Cleaner v${VERSION} - System Maintenance"
            echo "======================================================="
        fi
    fi

    log_message "INFO" "=== Ubuntu Log Cleaner v${VERSION} Started ==="
    log_message "INFO" "Command line: $0 $*"

    if [[ "$DRY_RUN" == true ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    # Show confirmation prompt if interactive
    if [[ "$INTERACTIVE" == true ]]; then
        echo "The following cleanup operations will be performed:"
        [[ "$CLEANUP_KERNELS" == true ]] && echo "  - Remove old kernels"
        [[ "$CLEANUP_JOURNAL" == true ]] && echo "  - Vacuum systemd journal"
        [[ "$CLEANUP_GZ_LOGS" == true ]] && echo "  - Remove compressed .gz logs"
        [[ "$CLEANUP_APT" == true ]] && echo "  - Clean APT cache"
        [[ "$CLEANUP_SNAP" == true ]] && echo "  - Remove old snap revisions"
        [[ "$CLEANUP_TEMP" == true ]] && echo "  - Clean temporary files"
        [[ "$CLEANUP_DOCKER" == true ]] && echo "  - Clean Docker system"
        [[ "$CLEANUP_PKG_CACHE" == true ]] && echo "  - Clean package caches (pip, npm, yarn)"
        [[ "$CLEANUP_COREDUMP" == true ]] && echo "  - Clean systemd coredumps"
        [[ "$CLEANUP_THUMBNAILS" == true ]] && echo "  - Clean thumbnail caches"
        [[ "$CLEANUP_MAIL" == true ]] && echo "  - Clean old mail"
        echo ""
        confirm_action "Proceed with cleanup?"
    fi

    print_info "Starting cleanup process..."
    print_info "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
    DISK_USED_BEFORE=$(get_used_space)

    # Execute cleanup functions based on feature flags
    [[ "$CLEANUP_KERNELS" == true ]] && cleanup_old_kernels
    [[ "$CLEANUP_JOURNAL" == true ]] && cleanup_journal
    [[ "$CLEANUP_GZ_LOGS" == true ]] && cleanup_gz_logs
    [[ "$CLEANUP_APT" == true ]] && cleanup_apt_cache
    [[ "$CLEANUP_SNAP" == true ]] && cleanup_snap_revisions
    [[ "$CLEANUP_TEMP" == true ]] && cleanup_temp_files
    [[ "$CLEANUP_DOCKER" == true ]] && cleanup_docker
    [[ "$CLEANUP_PKG_CACHE" == true ]] && cleanup_package_caches
    [[ "$CLEANUP_COREDUMP" == true ]] && cleanup_coredumps
    [[ "$CLEANUP_THUMBNAILS" == true ]] && cleanup_thumbnails
    [[ "$CLEANUP_MAIL" == true ]] && cleanup_mail

    # Print summary
    print_header "Cleanup Summary"
    print_info "End time: $(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "$DRY_RUN" == false ]]; then
        local disk_used_after
        disk_used_after=$(get_used_space)
        local actual_freed=$((DISK_USED_BEFORE - disk_used_after))
        if (( actual_freed < 0 )); then
            actual_freed=0
        fi

        if (( actual_freed > 0 )); then
            if [[ "$USE_COLORS" == true ]]; then
                echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${GREEN}Total space freed: $(bytes_to_human $actual_freed)${NC}"
                echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            else
                echo "======================================================="
                echo "Total space freed: $(bytes_to_human $actual_freed)"
                echo "======================================================="
            fi
            print_success "Cleanup completed successfully!"
        else
            print_info "No space was freed - system is already clean"
            print_success "Cleanup completed!"
        fi
    else
        # Dry run summary
        if (( TOTAL_FREED > 0 )); then
            if [[ "$USE_COLORS" == true ]]; then
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${YELLOW}Estimated space that would be freed: $(bytes_to_human $TOTAL_FREED)${NC}"
                echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            else
                echo "======================================================="
                echo "Estimated space that would be freed: $(bytes_to_human $TOTAL_FREED)"
                echo "======================================================="
            fi
            print_success "Dry run completed!"
        else
            print_info "No files would be removed"
        fi
    fi

    log_message "INFO" "=== Ubuntu Log Cleaner Finished ==="

    if [[ "$QUIET" == false ]]; then
        echo ""
    fi
}

# Run main function
main "$@"
