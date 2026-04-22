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

readonly VERSION="3.1.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="/etc/logcleaner.conf"
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

# Safety profile (safe, moderate, aggressive)
CLEANUP_PROFILE="safe"

# New cleanup targets (v3.0)
CLEANUP_SNAP_CACHE=false      # /var/lib/snapd/cache/
CLEANUP_APT_LISTS=false       # /var/lib/apt/lists/
CLEANUP_CRASH_REPORTS=false   # /var/crash/
CLEANUP_NETDATA=false         # Netdata cache and dbengine
CLEANUP_PROMETHEUS=false      # Prometheus old WAL/chunks
CLEANUP_GRAFANA=false         # Grafana cache
CLEANUP_PYCACHE=false         # Python bytecode

# Service handling
STOP_SERVICES=false           # Stop services before cleanup

# Profile-specific thresholds
CRASH_REPORT_AGE=30           # Days to keep crash reports
NETDATA_DB_AGE=14             # Days to keep Netdata dbengine data
PROMETHEUS_DATA_AGE=30        # Days to keep Prometheus data

# Logging
LOG_FILE=""
LOG_TO_FILE=false
DELETED_FILES_MANIFEST=""

# Track which settings were explicitly set by CLI args (to avoid profile overwrite)
_USER_SET_TEMP_FILE_AGE=false
_USER_SET_JOURNAL_KEEP_DAYS=false
_USER_SET_CRASH_REPORT_AGE=false
_USER_SET_NETDATA_DB_AGE=false
_USER_SET_PROMETHEUS_DATA_AGE=false

# Analysis mode
ANALYZE_MODE=false
REPORT_FILE=""
declare -A _ANALYSIS_ESTIMATES

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

print_status() {
    local msg="$1"
    [[ "$QUIET" == true ]] && return

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

# Convert bytes to human-readable format (pure bash, no subprocesses)
bytes_to_human() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "${bytes}B"
    elif (( bytes < 1048576 )); then
        echo "$(( bytes / 1024 ))KB"
    elif (( bytes < 1073741824 )); then
        echo "$(( bytes / 1048576 ))MB"
    else
        # Use awk for decimal division only for GB+ sizes
        printf "%.2fGB\n" "$(awk "BEGIN {print $bytes / 1073741824}")"
    fi
}

# Get disk usage of a path
get_size() {
    local path=$1
    if [[ -e "$path" ]]; then
        if [[ -f "$path" ]]; then
            # For files, use stat (single syscall, no subprocess for awk)
            stat --format='%s' "$path" 2>/dev/null || echo "0"
        else
            # For directories, du is needed to recurse
            du -sb "$path" 2>/dev/null | awk '{print $1}' || echo "0"
        fi
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

################################################################################
# Service Management Helper Functions
################################################################################

# Check if a systemd service is running
is_service_running() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

# Stop a service gracefully
stop_service() {
    local service="$1"
    local timeout="${2:-30}"

    if ! is_service_running "$service"; then
        return 0
    fi

    print_info "Stopping $service..."
    if systemctl stop "$service" --timeout="${timeout}s" 2>/dev/null; then
        # Wait for service to fully stop
        local count=0
        while is_service_running "$service" && (( count < timeout )); do
            sleep 1
            count=$((count + 1))
        done

        if ! is_service_running "$service"; then
            log_message "INFO" "Service $service stopped"
            return 0
        fi
    fi

    print_warning "Failed to stop $service gracefully"
    return 1
}

# Start a service
start_service() {
    local service="$1"

    if is_service_running "$service"; then
        return 0
    fi

    print_info "Starting $service..."
    if systemctl start "$service" 2>/dev/null; then
        sleep 2  # Give service time to initialize
        if is_service_running "$service"; then
            log_message "INFO" "Service $service started"
            return 0
        fi
    fi

    print_warning "Failed to start $service"
    return 1
}

# Wrapper to run cleanup with optional service stop/start
run_with_service_control() {
    local service="$1"
    local cleanup_func="$2"
    local was_running=false

    if is_service_running "$service"; then
        was_running=true
        if [[ "$STOP_SERVICES" == true ]]; then
            if ! stop_service "$service"; then
                print_warning "$service cleanup may be incomplete (service still running)"
            fi
        else
            print_warning "$service is running, some files may be locked"
            print_info "Tip: Use --stop-services for complete cleanup"
        fi
    fi

    # Run the cleanup function
    "$cleanup_func"

    # Restart service if we stopped it
    if [[ "$was_running" == true ]] && [[ "$STOP_SERVICES" == true ]]; then
        if ! is_service_running "$service"; then
            start_service "$service"
        fi
    fi
}

################################################################################
# Configuration Management
################################################################################

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

# Apply safety profile settings
apply_profile() {
    case "$CLEANUP_PROFILE" in
        safe)
            # Conservative - production servers
            [[ "$_USER_SET_TEMP_FILE_AGE" == false ]] && TEMP_FILE_AGE=14
            [[ "$_USER_SET_JOURNAL_KEEP_DAYS" == false ]] && JOURNAL_KEEP_DAYS=14
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=false
            CLEANUP_CRASH_REPORTS=true
            [[ "$_USER_SET_CRASH_REPORT_AGE" == false ]] && CRASH_REPORT_AGE=30
            CLEANUP_NETDATA=false
            CLEANUP_PROMETHEUS=false
            CLEANUP_GRAFANA=false
            CLEANUP_PYCACHE=false
            ;;
        moderate)
            # Balanced - staging/dev servers
            [[ "$_USER_SET_TEMP_FILE_AGE" == false ]] && TEMP_FILE_AGE=7
            [[ "$_USER_SET_JOURNAL_KEEP_DAYS" == false ]] && JOURNAL_KEEP_DAYS=7
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=true
            CLEANUP_CRASH_REPORTS=true
            [[ "$_USER_SET_CRASH_REPORT_AGE" == false ]] && CRASH_REPORT_AGE=7
            CLEANUP_NETDATA=true
            [[ "$_USER_SET_NETDATA_DB_AGE" == false ]] && NETDATA_DB_AGE=14
            CLEANUP_PROMETHEUS=true
            [[ "$_USER_SET_PROMETHEUS_DATA_AGE" == false ]] && PROMETHEUS_DATA_AGE=30
            CLEANUP_GRAFANA=true
            CLEANUP_PYCACHE=false
            ;;
        aggressive)
            # Maximum cleanup - emergencies, CI runners
            [[ "$_USER_SET_TEMP_FILE_AGE" == false ]] && TEMP_FILE_AGE=3
            [[ "$_USER_SET_JOURNAL_KEEP_DAYS" == false ]] && JOURNAL_KEEP_DAYS=3
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=true
            CLEANUP_CRASH_REPORTS=true
            [[ "$_USER_SET_CRASH_REPORT_AGE" == false ]] && CRASH_REPORT_AGE=0  # All crash reports
            CLEANUP_NETDATA=true
            [[ "$_USER_SET_NETDATA_DB_AGE" == false ]] && NETDATA_DB_AGE=3
            CLEANUP_PROMETHEUS=true
            [[ "$_USER_SET_PROMETHEUS_DATA_AGE" == false ]] && PROMETHEUS_DATA_AGE=7
            CLEANUP_GRAFANA=true
            CLEANUP_PYCACHE=true
            ;;
        *)
            print_error "Unknown profile: $CLEANUP_PROFILE"
            print_error "Valid profiles: safe, moderate, aggressive"
            exit 1
            ;;
    esac

    print_info "Applied profile: $CLEANUP_PROFILE"
    log_message "INFO" "Applied cleanup profile: $CLEANUP_PROFILE"
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

PROFILE OPTIONS:
    --profile LEVEL         Set cleanup profile: safe, moderate, aggressive
                           (default: safe)

NEW CLEANUP TARGETS (v3.0):
    --snap-cache            Clean snap package cache (/var/lib/snapd/cache/)
    --apt-lists             Clean APT package lists (/var/lib/apt/lists/)
    --crash-reports         Clean crash reports (/var/crash/)
    --netdata               Clean Netdata cache and database
    --prometheus            Clean old Prometheus data
    --grafana               Clean Grafana cache
    --pycache               Clean Python bytecode (__pycache__)

    --skip-snap-cache       Skip snap cache cleanup
    --skip-apt-lists        Skip APT lists cleanup
    --skip-crash-reports    Skip crash reports cleanup
    --skip-netdata          Skip Netdata cleanup
    --skip-prometheus       Skip Prometheus cleanup
    --skip-grafana          Skip Grafana cleanup
    --skip-pycache          Skip Python bytecode cleanup

SERVICE HANDLING:
    --stop-services         Stop monitoring services before cleanup, restart after

AGE THRESHOLDS:
    --crash-age DAYS        Age threshold for crash reports (default: 30)
    --netdata-age DAYS      Age threshold for Netdata DB (default: 14)
    --prometheus-age DAYS   Age threshold for Prometheus data (default: 30)

CONFIGURATION:
    --config FILE           Load configuration from FILE (default: $CONFIG_FILE)
    --temp-age DAYS         Age threshold for temporary files (default: $TEMP_FILE_AGE)
    --journal-days DAYS     Days to keep journal logs (default: $JOURNAL_KEEP_DAYS)
    --kernel-keep N         Number of old kernels to keep (default: $KERNEL_KEEP_COUNT)

ANALYSIS MODE:
    --analyze               Run read-only system analysis (no changes made)
    --report-file FILE      Write analysis report to FILE (default: stdout only)

EXAMPLES:
    # Run with default settings (interactive)
    sudo $SCRIPT_NAME

    # Preview what would be cleaned without making changes
    sudo $SCRIPT_NAME --dry-run

    # Run non-interactively with logging
    sudo $SCRIPT_NAME --yes --log-file /var/log/logcleaner.log

    # Run only Docker and package cache cleanup
    sudo $SCRIPT_NAME --only-docker --pkg-cache

    # Clean with custom retention periods
    sudo $SCRIPT_NAME --temp-age 14 --journal-days 3

    # Run read-only system analysis
    sudo $SCRIPT_NAME --analyze

    # Save analysis report to file
    sudo $SCRIPT_NAME --analyze --report-file /tmp/analysis.txt

CONFIGURATION FILE:
    You can create a configuration file at $CONFIG_FILE with:
        TEMP_FILE_AGE=14
        JOURNAL_KEEP_DAYS=3
        KERNEL_KEEP_COUNT=2
        CLEANUP_DOCKER=true
        LOG_TO_FILE=true

PROFILES:
    safe        Production servers - conservative cleanup, preserves monitoring data
    moderate    Staging/dev - balanced cleanup including monitoring caches
    aggressive  Maximum cleanup - for disk emergencies or CI runners

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
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --temp-age)
                TEMP_FILE_AGE="$2"
                _USER_SET_TEMP_FILE_AGE=true
                shift 2
                ;;
            --journal-days)
                JOURNAL_KEEP_DAYS="$2"
                _USER_SET_JOURNAL_KEEP_DAYS=true
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
            --profile)
                CLEANUP_PROFILE="$2"
                shift 2
                ;;
            --snap-cache)
                CLEANUP_SNAP_CACHE=true
                shift
                ;;
            --apt-lists)
                CLEANUP_APT_LISTS=true
                shift
                ;;
            --crash-reports)
                CLEANUP_CRASH_REPORTS=true
                shift
                ;;
            --netdata)
                CLEANUP_NETDATA=true
                shift
                ;;
            --prometheus)
                CLEANUP_PROMETHEUS=true
                shift
                ;;
            --grafana)
                CLEANUP_GRAFANA=true
                shift
                ;;
            --pycache)
                CLEANUP_PYCACHE=true
                shift
                ;;
            --skip-snap-cache)
                CLEANUP_SNAP_CACHE=false
                shift
                ;;
            --skip-apt-lists)
                CLEANUP_APT_LISTS=false
                shift
                ;;
            --skip-crash-reports)
                CLEANUP_CRASH_REPORTS=false
                shift
                ;;
            --skip-netdata)
                CLEANUP_NETDATA=false
                shift
                ;;
            --skip-prometheus)
                CLEANUP_PROMETHEUS=false
                shift
                ;;
            --skip-grafana)
                CLEANUP_GRAFANA=false
                shift
                ;;
            --skip-pycache)
                CLEANUP_PYCACHE=false
                shift
                ;;
            --stop-services)
                STOP_SERVICES=true
                shift
                ;;
            --crash-age)
                CRASH_REPORT_AGE="$2"
                _USER_SET_CRASH_REPORT_AGE=true
                shift 2
                ;;
            --netdata-age)
                NETDATA_DB_AGE="$2"
                _USER_SET_NETDATA_DB_AGE=true
                shift 2
                ;;
            --prometheus-age)
                PROMETHEUS_DATA_AGE="$2"
                _USER_SET_PROMETHEUS_DATA_AGE=true
                shift 2
                ;;
            --analyze)
                ANALYZE_MODE=true
                shift
                ;;
            --report-file)
                REPORT_FILE="$2"
                shift 2
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
    print_status "Current kernel: $current_kernel"

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
                print_status "Removing: $pkg"
                if DEBIAN_FRONTEND=noninteractive apt-get purge -y \
                    -o Dpkg::Options::=--force-confdef \
                    -o Dpkg::Options::=--force-confold \
                    "$pkg" >/dev/null 2>&1; then
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

    print_status "Journal size before: $(bytes_to_human $size_before)"

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
        local dpkg_opts="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

        print_status "Running apt-get clean..."
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

# Clean snap package cache
cleanup_snap_cache() {
    print_header "Cleaning Snap Package Cache"

    local snap_cache_dir="/var/lib/snapd/cache"

    if [[ ! -d "$snap_cache_dir" ]]; then
        print_warning "Snap cache directory not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size "$snap_cache_dir")

    if (( size_before == 0 )); then
        print_info "Snap cache is empty"
        return 0
    fi

    local count=0
    local freed=0

    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[snap-cache] Removed: $file ($(bytes_to_human $size))"
                    freed=$((freed + size))
                    count=$((count + 1))
                else
                    print_warning "Failed to remove: $file"
                fi
            fi
        fi
    done < <(find "$snap_cache_dir" -type f -print0 2>/dev/null)

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Snap cache cleaned, freed $(bytes_to_human $freed) ($count files)"
    else
        print_info "No snap cache files to remove"
    fi
}

# Clean APT package lists
cleanup_apt_lists() {
    print_header "Cleaning APT Package Lists"

    local apt_lists_dir="/var/lib/apt/lists"

    if [[ ! -d "$apt_lists_dir" ]]; then
        print_warning "APT lists directory not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size "$apt_lists_dir")

    if (( size_before == 0 )); then
        print_info "APT lists directory is empty"
        return 0
    fi

    local count=0
    local freed=0

    # Remove all files except lock and partial directory
    while IFS= read -r -d '' file; do
        local basename
        basename=$(basename "$file")

        # Skip lock files and partial directory
        if [[ "$basename" == "lock" ]] || [[ "$file" == *"/partial/"* ]]; then
            continue
        fi

        if [[ -f "$file" ]]; then
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[apt-lists] Removed: $file"
                    freed=$((freed + size))
                    count=$((count + 1))
                else
                    print_warning "Failed to remove: $file"
                fi
            fi
        fi
    done < <(find "$apt_lists_dir" -type f -print0 2>/dev/null)

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "APT lists cleaned, freed $(bytes_to_human $freed) ($count files)"
        if [[ "$DRY_RUN" == false ]]; then
            print_info "Note: Run 'apt update' to refresh package lists when needed"
        fi
    else
        print_info "No APT list files to remove"
    fi
}

# Clean crash reports
cleanup_crash_reports() {
    print_header "Cleaning Crash Reports"

    local crash_dir="/var/crash"

    if [[ ! -d "$crash_dir" ]]; then
        print_warning "Crash directory not found, skipping"
        return 0
    fi

    local size_before
    size_before=$(get_size "$crash_dir")

    if (( size_before == 0 )); then
        print_info "No crash reports found"
        return 0
    fi

    local count=0
    local freed=0

    # Find crash files based on age threshold
    local find_args=("$crash_dir" -type f -name "*.crash")
    if (( CRASH_REPORT_AGE > 0 )); then
        find_args+=(-mtime +"$CRASH_REPORT_AGE")
        print_info "Removing crash reports older than $CRASH_REPORT_AGE days"
    else
        print_info "Removing all crash reports"
    fi

    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[crash-reports] Removed: $file"
                    freed=$((freed + size))
                    count=$((count + 1))
                else
                    print_warning "Failed to remove: $file"
                fi
            fi
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)

    # Also clean .uploaded files
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        fi
    done < <(find "$crash_dir" -type f -name "*.uploaded" -print0 2>/dev/null)

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Crash reports cleaned, freed $(bytes_to_human $freed) ($count files)"
    else
        print_info "No crash reports to remove"
    fi
}

# Clean Netdata cache and database
cleanup_netdata() {
    print_header "Cleaning Netdata"

    # Detect Netdata installation path
    local netdata_base=""
    local netdata_service="netdata"

    if [[ -d "/opt/netdata" ]]; then
        netdata_base="/opt/netdata"
    elif [[ -d "/var/lib/netdata" ]]; then
        netdata_base="/var/lib/netdata"
    else
        print_warning "Netdata not found, skipping"
        return 0
    fi

    local cache_dir=""
    local db_dir=""

    if [[ "$netdata_base" == "/opt/netdata" ]]; then
        cache_dir="$netdata_base/var/cache/netdata"
        db_dir="$netdata_base/var/lib/netdata/dbengine"
    else
        cache_dir="/var/cache/netdata"
        db_dir="$netdata_base/dbengine"
    fi

    local freed=0

    # Clean cache directory
    if [[ -d "$cache_dir" ]]; then
        local cache_size
        cache_size=$(get_size "$cache_dir")

        if (( cache_size > 0 )); then
            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would clean Netdata cache: $cache_dir ($(bytes_to_human $cache_size))"
                freed=$((freed + cache_size))
            else
                print_info "Cleaning Netdata cache: $cache_dir"
                if rm -rf "$cache_dir"/* 2>/dev/null; then
                    log_message "INFO" "[netdata] Cleaned cache: $(bytes_to_human $cache_size)"
                    freed=$((freed + cache_size))
                else
                    print_warning "Failed to clean some Netdata cache files (may be locked)"
                fi
            fi
        fi
    fi

    # Clean old dbengine files
    if [[ -d "$db_dir" ]]; then
        local db_count=0
        local db_freed=0

        if (( NETDATA_DB_AGE > 0 )); then
            print_info "Removing Netdata DB files older than $NETDATA_DB_AGE days"

            while IFS= read -r -d '' file; do
                local size
                size=$(get_size "$file")

                if [[ "$DRY_RUN" == true ]]; then
                    print_dry_run "Would remove: $file ($(bytes_to_human $size))"
                    db_freed=$((db_freed + size))
                    db_count=$((db_count + 1))
                else
                    if rm -f "$file" 2>/dev/null; then
                        log_message "INFO" "[netdata] Removed DB file: $file"
                        db_freed=$((db_freed + size))
                        db_count=$((db_count + 1))
                    fi
                fi
            done < <(find "$db_dir" -type f -mtime +"$NETDATA_DB_AGE" -print0 2>/dev/null)

            freed=$((freed + db_freed))

            if (( db_count > 0 )); then
                print_info "Removed $db_count old DB files ($(bytes_to_human $db_freed))"
            fi
        else
            # Aggressive mode - clean all
            local db_size
            db_size=$(get_size "$db_dir")

            if (( db_size > 0 )); then
                if [[ "$DRY_RUN" == true ]]; then
                    print_dry_run "Would clean Netdata DB: $db_dir ($(bytes_to_human $db_size))"
                    freed=$((freed + db_size))
                else
                    if rm -rf "$db_dir"/* 2>/dev/null; then
                        log_message "INFO" "[netdata] Cleaned dbengine: $(bytes_to_human $db_size)"
                        freed=$((freed + db_size))
                    fi
                fi
            fi
        fi
    fi

    if (( freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Netdata cleaned, freed $(bytes_to_human $freed)"
    else
        print_info "No Netdata data to clean"
    fi
}

# Wrapper for Netdata cleanup with service control
cleanup_netdata_with_service() {
    run_with_service_control "netdata" cleanup_netdata
}

# Clean old Prometheus data
cleanup_prometheus() {
    print_header "Cleaning Prometheus Data"

    # Common Prometheus data directories
    local prometheus_dir=""
    for dir in "/var/lib/prometheus" "/var/lib/prometheus/metrics2" "/opt/prometheus/data"; do
        if [[ -d "$dir" ]]; then
            prometheus_dir="$dir"
            break
        fi
    done

    if [[ -z "$prometheus_dir" ]]; then
        print_warning "Prometheus data directory not found, skipping"
        return 0
    fi

    print_info "Prometheus data directory: $prometheus_dir"

    local freed=0
    local count=0

    # Clean old WAL segments
    local wal_dir="$prometheus_dir/wal"
    if [[ -d "$wal_dir" ]]; then
        while IFS= read -r -d '' file; do
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove old WAL: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[prometheus] Removed WAL: $file"
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        done < <(find "$wal_dir" -type f -mtime +"$PROMETHEUS_DATA_AGE" -print0 2>/dev/null)
    fi

    # Clean old chunks
    local chunks_head="$prometheus_dir/chunks_head"
    if [[ -d "$chunks_head" ]]; then
        while IFS= read -r -d '' file; do
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove old chunk: $file ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[prometheus] Removed chunk: $file"
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        done < <(find "$chunks_head" -type f -mtime +"$PROMETHEUS_DATA_AGE" -print0 2>/dev/null)
    fi

    if (( freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Prometheus cleaned, freed $(bytes_to_human $freed) ($count files)"
    else
        print_info "No old Prometheus data to clean"
    fi
}

# Wrapper for Prometheus cleanup with service control
cleanup_prometheus_with_service() {
    run_with_service_control "prometheus" cleanup_prometheus
}

# Clean Grafana cache
cleanup_grafana() {
    print_header "Cleaning Grafana Cache"

    local grafana_dir="/var/lib/grafana"

    if [[ ! -d "$grafana_dir" ]]; then
        print_warning "Grafana directory not found, skipping"
        return 0
    fi

    local freed=0

    # Clean PNG renderer cache
    local png_dir="$grafana_dir/png"
    if [[ -d "$png_dir" ]]; then
        local png_size
        png_size=$(get_size "$png_dir")

        if (( png_size > 0 )); then
            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would clean Grafana PNG cache: $(bytes_to_human $png_size)"
                freed=$((freed + png_size))
            else
                if rm -rf "$png_dir"/* 2>/dev/null; then
                    log_message "INFO" "[grafana] Cleaned PNG cache: $(bytes_to_human $png_size)"
                    freed=$((freed + png_size))
                fi
            fi
        fi
    fi

    # Clean old sessions (files older than 7 days)
    local sessions_dir="$grafana_dir/sessions"
    if [[ -d "$sessions_dir" ]]; then
        local session_freed=0
        local session_count=0

        while IFS= read -r -d '' file; do
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                session_freed=$((session_freed + size))
                session_count=$((session_count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    session_freed=$((session_freed + size))
                    session_count=$((session_count + 1))
                fi
            fi
        done < <(find "$sessions_dir" -type f -mtime +7 -print0 2>/dev/null)

        if (( session_count > 0 )); then
            freed=$((freed + session_freed))
            print_info "Cleaned $session_count old session files"
        fi
    fi

    # Clean CSV export cache
    local csv_dir="$grafana_dir/csv"
    if [[ -d "$csv_dir" ]]; then
        local csv_size
        csv_size=$(get_size "$csv_dir")

        if (( csv_size > 0 )); then
            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would clean Grafana CSV cache: $(bytes_to_human $csv_size)"
                freed=$((freed + csv_size))
            else
                if rm -rf "$csv_dir"/* 2>/dev/null; then
                    log_message "INFO" "[grafana] Cleaned CSV cache: $(bytes_to_human $csv_size)"
                    freed=$((freed + csv_size))
                fi
            fi
        fi
    fi

    if (( freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Grafana cache cleaned, freed $(bytes_to_human $freed)"
    else
        print_info "No Grafana cache to clean"
    fi
}

# Wrapper for Grafana cleanup with service control
cleanup_grafana_with_service() {
    run_with_service_control "grafana-server" cleanup_grafana
}

# Clean Python bytecode cache
cleanup_pycache() {
    print_header "Cleaning Python Bytecode Cache"

    local freed=0
    local count=0

    # Directories to search for Python cache
    local search_dirs=("/usr/local" "/opt")

    for search_dir in "${search_dirs[@]}"; do
        if [[ ! -d "$search_dir" ]]; then
            continue
        fi

        # Find and remove __pycache__ directories
        while IFS= read -r -d '' dir; do
            local size
            size=$(get_size "$dir")

            if [[ "$DRY_RUN" == true ]]; then
                print_dry_run "Would remove: $dir ($(bytes_to_human $size))"
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -rf "$dir" 2>/dev/null; then
                    log_message "INFO" "[pycache] Removed: $dir"
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        done < <(find "$search_dir" -type d -name "__pycache__" -print0 2>/dev/null)

        # Find and remove .pyc files not in __pycache__
        while IFS= read -r -d '' file; do
            local size
            size=$(get_size "$file")

            if [[ "$DRY_RUN" == true ]]; then
                freed=$((freed + size))
                count=$((count + 1))
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "INFO" "[pycache] Removed: $file"
                    freed=$((freed + size))
                    count=$((count + 1))
                fi
            fi
        done < <(find "$search_dir" -type f -name "*.pyc" -print0 2>/dev/null)
    done

    if (( freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Python cache cleaned, freed $(bytes_to_human $freed) ($count items)"
    else
        print_info "No Python cache to clean"
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

        print_status "Cleaning $dir..."

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

    print_status "Running docker system prune..."
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
                print_status "Cleaning $dir..."
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
# Analysis Mode
################################################################################

# Write a line to stdout and optionally to REPORT_FILE
report_line() {
    local line="$1"
    echo "$line"
    if [[ -n "$REPORT_FILE" ]]; then
        echo "$line" >> "$REPORT_FILE"
    fi
}

report_section() {
    local title="$1"
    report_line ""
    report_line "======================================================="
    report_line "  $title"
    report_line "======================================================="
}

report_kv() {
    local key="$1"
    local value="$2"
    report_line "$(printf '  %-35s %s' "$key:" "$value")"
}

# Record an estimate for the summary (label, bytes)
record_estimate() {
    local label="$1"
    local bytes="$2"
    _ANALYSIS_ESTIMATES["$label"]="$bytes"
}

analyze_disk() {
    report_section "DISK USAGE"

    report_line ""
    report_line "  Filesystem overview:"
    df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
        | grep -v tmpfs \
        | grep -v udev \
        | while IFS= read -r line; do report_line "    $line"; done || true

    report_line ""
    report_line "  Top 20 directories by size (/):"
    du -xh --max-depth=3 / 2>/dev/null \
        | sort -rh \
        | head -20 \
        | while IFS= read -r line; do report_line "    $line"; done || true
}

analyze_large_files() {
    report_section "LARGE FILES (>100MB)"

    report_line ""
    report_line "  Files larger than 100MB across filesystem:"

    local count=0
    while IFS= read -r line; do
        report_line "    $line"
        count=$((count + 1))
    done < <(find / -xdev -type f -size +100M -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -30 \
        | awk '{printf "%s\t%s\n", ($1 >= 1073741824 ? sprintf("%.1fGB", $1/1073741824) : sprintf("%.0fMB", $1/1048576)), $2}')

    if (( count == 0 )); then
        report_line "    (none found)"
    fi
}

analyze_logs() {
    report_section "LOG FILES (/var/log)"

    if [[ ! -d /var/log ]]; then
        report_line "  /var/log not found"
        return
    fi

    local total_size
    total_size=$(du -sb /var/log 2>/dev/null | awk '{print $1}')
    report_kv "Total /var/log size" "$(bytes_to_human "${total_size:-0}")"

    local gz_count gz_size
    gz_count=$(find /var/log -name "*.gz" -type f 2>/dev/null | wc -l)
    gz_size=$(find /var/log -name "*.gz" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
    report_kv "Compressed (.gz) files" "$gz_count files ($(bytes_to_human "$gz_size"))"

    report_line ""
    report_line "  Top 20 log files by size:"
    find /var/log -type f -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -20 \
        | awk '{printf "    %s\t%s\n", ($1 >= 1073741824 ? sprintf("%.1fGB", $1/1073741824) : $1 >= 1048576 ? sprintf("%.0fMB", $1/1048576) : sprintf("%.0fKB", $1/1024)), $2}' \
        | while IFS= read -r line; do report_line "$line"; done

    record_estimate "Compressed .gz logs" "$gz_size"
}

analyze_journal() {
    report_section "SYSTEMD JOURNAL"

    if ! command -v journalctl &>/dev/null; then
        report_line "  journalctl not found"
        return
    fi

    local journal_size
    journal_size=$(get_size /var/log/journal)
    report_kv "Journal size" "$(bytes_to_human "$journal_size")"

    local conf_file="/etc/systemd/journald.conf"
    if [[ -f "$conf_file" ]]; then
        report_line ""
        report_line "  journald.conf active settings:"
        grep -v '^\s*#' "$conf_file" | grep -v '^\s*$' | while IFS= read -r line; do
            report_line "    $line"
        done
    fi

    report_line ""
    report_line "  Current disk usage:"
    journalctl --disk-usage 2>/dev/null | while IFS= read -r line; do report_line "    $line"; done

    local estimated_freed=$(( journal_size * 30 / 100 ))
    record_estimate "Journal vacuum (7d)" "$estimated_freed"
}

analyze_apt() {
    report_section "APT CACHE"

    if ! command -v apt-get &>/dev/null; then
        report_line "  apt-get not found"
        return
    fi

    local cache_size
    cache_size=$(get_size /var/cache/apt/archives)
    report_kv "APT cache size" "$(bytes_to_human "$cache_size")"

    local lists_size
    lists_size=$(get_size /var/lib/apt/lists)
    report_kv "APT lists size" "$(bytes_to_human "$lists_size")"

    local pkg_count
    pkg_count=$(find /var/cache/apt/archives -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    report_kv "Cached .deb packages" "$pkg_count"

    report_line ""
    report_line "  Autoremovable packages:"
    local autoremove_list
    autoremove_list=$(apt-get --dry-run autoremove 2>/dev/null | grep "^Remv" | awk '{print $2}' || true)
    if [[ -n "$autoremove_list" ]]; then
        echo "$autoremove_list" | while IFS= read -r pkg; do
            report_line "    $pkg"
        done
        local autoremove_count
        autoremove_count=$(echo "$autoremove_list" | wc -l)
        report_kv "Total autoremovable" "$autoremove_count packages"
    else
        report_line "    (none)"
    fi

    record_estimate "APT cache" "$cache_size"
}

analyze_kernels() {
    report_section "KERNEL PACKAGES"

    local current_kernel
    current_kernel=$(uname -r)
    report_kv "Running kernel" "$current_kernel"

    local kernel_packages
    kernel_packages=$(dpkg-query -W -f='${Package} ${Installed-Size}\n' \
        'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-headers-[0-9]*' 2>/dev/null \
        | grep -E 'linux-(image|modules|headers)-[0-9]' | sort || true)

    report_line ""
    report_line "  Installed kernel packages:"

    local removable_size=0
    while IFS=' ' read -r pkg size_kb; do
        [[ -z "$pkg" ]] && continue
        local marker=""
        if echo "$pkg" | grep -q "$current_kernel"; then
            marker=" [CURRENT]"
        else
            marker=" [removable]"
            removable_size=$((removable_size + size_kb * 1024))
        fi
        report_line "    $pkg ($(bytes_to_human $((size_kb * 1024))))$marker"
    done <<< "$kernel_packages"

    report_line ""
    report_kv "Estimated removable" "$(bytes_to_human "$removable_size") (all non-current)"

    record_estimate "Old kernels" "$removable_size"
}

analyze_snap() {
    report_section "SNAP"

    if ! command -v snap &>/dev/null; then
        report_line "  snap not found"
        return
    fi

    report_line ""
    report_line "  Installed snaps:"
    snap list 2>/dev/null | while IFS= read -r line; do report_line "    $line"; done

    report_line ""
    report_line "  Disabled (removable) revisions:"
    local disabled
    disabled=$(snap list --all 2>/dev/null | grep disabled || true)

    local removable_size=0
    if [[ -n "$disabled" ]]; then
        echo "$disabled" | while IFS= read -r line; do report_line "    $line"; done

        while IFS=' ' read -r snap_name _ revision _; do
            local snap_path="/snap/$snap_name/$revision"
            if [[ -d "$snap_path" ]]; then
                local sz
                sz=$(get_size "$snap_path")
                removable_size=$((removable_size + sz))
            fi
        done < <(snap list --all 2>/dev/null | grep disabled | awk '{print $1, $2, $3}')
    else
        report_line "    (none)"
    fi

    local snap_cache_size
    snap_cache_size=$(get_size /var/lib/snapd/cache)
    report_line ""
    report_kv "Snap cache size" "$(bytes_to_human "$snap_cache_size")"

    record_estimate "Old snap revisions" "$removable_size"
    record_estimate "Snap cache" "$snap_cache_size"
}

analyze_temp() {
    report_section "TEMPORARY FILES"

    for dir in /tmp /var/tmp; do
        [[ ! -d "$dir" ]] && continue
        local total_size old_size old_count
        total_size=$(get_size "$dir")
        old_size=$(find "$dir" -mindepth 1 -type f -mtime +7 -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
        old_count=$(find "$dir" -mindepth 1 -type f -mtime +7 2>/dev/null | wc -l)
        report_kv "$dir total size" "$(bytes_to_human "$total_size")"
        report_kv "$dir files >7 days old" "$old_count files ($(bytes_to_human "$old_size"))"
        record_estimate "Temp files ($dir)" "$old_size"
    done
}

analyze_crash() {
    report_section "CRASH REPORTS (/var/crash)"

    if [[ ! -d /var/crash ]]; then
        report_line "  /var/crash not found"
        return
    fi

    local crash_size crash_count
    crash_size=$(get_size /var/crash)
    crash_count=$(find /var/crash -type f 2>/dev/null | wc -l)

    report_kv "/var/crash size" "$(bytes_to_human "$crash_size")"
    report_kv "Crash report files" "$crash_count"

    if (( crash_count > 0 )); then
        report_line ""
        report_line "  Crash report files:"
        find /var/crash -type f -printf '%TY-%Tm-%Td\t%s\t%p\n' 2>/dev/null \
            | sort -rn \
            | while IFS=$'\t' read -r date size path; do
                report_line "    $date  $(bytes_to_human "$size")  $path"
            done
    fi

    record_estimate "Crash reports" "$crash_size"
}

analyze_docker() {
    report_section "DOCKER"

    if ! command -v docker &>/dev/null; then
        report_line "  docker not found"
        return
    fi

    if ! docker info &>/dev/null 2>&1; then
        report_line "  Docker daemon not running"
        return
    fi

    report_line ""
    report_line "  Docker disk usage:"
    docker system df 2>/dev/null | while IFS= read -r line; do report_line "    $line"; done

    local reclaimable_line
    reclaimable_line=$(docker system df 2>/dev/null | grep -oE '[0-9.]+ [KMGT]?B \(reclaimable\)' | tail -1 || true)
    if [[ -n "$reclaimable_line" ]]; then
        report_line ""
        report_kv "Total reclaimable" "$reclaimable_line"
    fi
}

analyze_summary() {
    report_section "SUMMARY - POTENTIAL SPACE TO RECOVER"

    report_line ""
    local grand_total=0

    local labels=("Old kernels" "Journal vacuum (7d)" "APT cache" "Compressed .gz logs" \
                  "Old snap revisions" "Snap cache" "Temp files (/tmp)" "Temp files (/var/tmp)" \
                  "Crash reports")

    for label in "${labels[@]}"; do
        local bytes="${_ANALYSIS_ESTIMATES[$label]:-0}"
        if (( bytes > 0 )); then
            report_kv "$label" "~$(bytes_to_human "$bytes")"
            grand_total=$((grand_total + bytes))
        fi
    done

    report_line ""
    report_line "-------------------------------------------------------"
    report_kv "ESTIMATED TOTAL" "~$(bytes_to_human "$grand_total")"
    report_line "-------------------------------------------------------"
    report_line ""
    report_line "  To reclaim space, run:"
    report_line "    sudo ./logcleaner.sh --yes --profile moderate"
    report_line ""
    report_line "  Estimates are conservative. Actual results may vary."
}

run_analysis() {
    # Truncate/create report file if specified
    if [[ -n "$REPORT_FILE" ]]; then
        : > "$REPORT_FILE" || {
            echo "ERROR: Cannot write to $REPORT_FILE" >&2
            exit 1
        }
    fi

    report_line "======================================================="
    report_line "  UBUNTU SYSTEM ANALYSIS REPORT"
    report_line "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
    report_line "  Hostname  : $(hostname -f 2>/dev/null || hostname)"
    report_line "  Kernel    : $(uname -r)"
    report_line "  OS        : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')"
    report_line "======================================================="

    analyze_disk
    analyze_large_files
    analyze_logs
    analyze_journal
    analyze_apt
    analyze_kernels
    analyze_snap
    analyze_temp
    analyze_crash
    analyze_docker
    analyze_summary

    report_line ""
    if [[ -n "$REPORT_FILE" ]]; then
        echo "Report saved to: $REPORT_FILE"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Parse command-line arguments first
    parse_arguments "$@"

    # Auto-disable interactive mode when stdin is not a terminal (e.g., piped one-liner)
    if [[ "$INTERACTIVE" == true ]] && [[ ! -t 0 ]]; then
        INTERACTIVE=false
    fi

    # Analysis mode bypasses all cleanup logic
    if [[ "$ANALYZE_MODE" == true ]]; then
        check_root
        set +e  # analysis is read-only; don't abort on non-zero (e.g. du permission errors)
        run_analysis
        exit 0
    fi

    # Prevent apt/dpkg interactive prompts (e.g., debconf, config file questions)
    export DEBIAN_FRONTEND=noninteractive

    # Initialize colors based on TTY detection
    init_colors

    # Set up error handling
    setup_error_handling

    # Load configuration file if it exists
    load_config

    # Apply safety profile
    apply_profile

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
        [[ "$CLEANUP_SNAP_CACHE" == true ]] && echo "  - Clean snap package cache"
        [[ "$CLEANUP_APT_LISTS" == true ]] && echo "  - Clean APT package lists"
        [[ "$CLEANUP_CRASH_REPORTS" == true ]] && echo "  - Clean crash reports"
        [[ "$CLEANUP_NETDATA" == true ]] && echo "  - Clean Netdata cache/database"
        [[ "$CLEANUP_PROMETHEUS" == true ]] && echo "  - Clean old Prometheus data"
        [[ "$CLEANUP_GRAFANA" == true ]] && echo "  - Clean Grafana cache"
        [[ "$CLEANUP_PYCACHE" == true ]] && echo "  - Clean Python bytecode"
        echo ""
        confirm_action "Proceed with cleanup?"
    fi

    print_status "Starting cleanup process..."
    print_status "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
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
    [[ "$CLEANUP_SNAP_CACHE" == true ]] && cleanup_snap_cache
    [[ "$CLEANUP_APT_LISTS" == true ]] && cleanup_apt_lists
    [[ "$CLEANUP_CRASH_REPORTS" == true ]] && cleanup_crash_reports
    [[ "$CLEANUP_NETDATA" == true ]] && cleanup_netdata_with_service
    [[ "$CLEANUP_PROMETHEUS" == true ]] && cleanup_prometheus_with_service
    [[ "$CLEANUP_GRAFANA" == true ]] && cleanup_grafana_with_service
    [[ "$CLEANUP_PYCACHE" == true ]] && cleanup_pycache

    # Print summary
    print_header "Cleanup Summary"
    print_status "End time: $(date '+%Y-%m-%d %H:%M:%S')"

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
            print_status "No space was freed - system is already clean"
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
            print_status "No files would be removed"
        fi
    fi

    log_message "INFO" "=== Ubuntu Log Cleaner Finished ==="

    if [[ "$QUIET" == false ]]; then
        echo ""
    fi
}

# Run main function (skip when sourced for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
