#!/bin/bash

################################################################################
# Ubuntu Log Cleaner - Automated System Maintenance Script
#
# Performs non-interactive cleanup tasks:
# - Remove old kernels (keeps current + 1 old)
# - Vacuum systemd journal
# - Remove compressed .gz logs
# - Clean APT cache
# - Remove old snap revisions
# - Clean temporary files (7+ days old)
#
# Usage: sudo ./logcleaner.sh
################################################################################

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

################################################################################
# Global Variables
################################################################################

TOTAL_FREED=0
TEMP_FILE_AGE=7  # Days

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

################################################################################
# Helper Functions
################################################################################

# Print colored messages
print_header() {
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
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
        echo "Usage: sudo $0"
        exit 1
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

    # Get list of installed kernels (sorted by version)
    local installed_kernels
    installed_kernels=$(dpkg --list | grep -E 'linux-image-[0-9]' | grep -v "$current_kernel" | awk '{print $2}' | sort -V || true)

    if [[ -z "$installed_kernels" ]]; then
        print_warning "No old kernels found to remove"
        return 0
    fi

    local kernel_count
    kernel_count=$(echo "$installed_kernels" | wc -l)
    print_info "Found $kernel_count old kernel(s) installed"

    # Keep 1 most recent old kernel (safety buffer)
    local kernels_to_keep=1
    local kernels_to_remove

    if (( kernel_count <= kernels_to_keep )); then
        print_warning "Keeping all $kernel_count old kernel(s) for safety (minimum $kernels_to_keep required)"
        return 0
    fi

    # Remove all but the most recent old kernel
    kernels_to_remove=$(echo "$installed_kernels" | head -n -${kernels_to_keep})

    if [[ -z "$kernels_to_remove" ]]; then
        print_warning "No kernels to remove after safety check"
        return 0
    fi

    local freed=0
    local count=0

    while IFS= read -r kernel; do
        if [[ -n "$kernel" ]]; then
            local size_before
            size_before=$(dpkg-query -W -f='${Installed-Size}' "$kernel" 2>/dev/null || echo "0")
            size_before=$((size_before * 1024))  # Convert KB to bytes

            print_info "Removing: $kernel"
            if apt-get purge -y "$kernel" >/dev/null 2>&1; then
                freed=$((freed + size_before))
                count=$((count + 1))
            else
                print_warning "Failed to remove $kernel"
            fi
        fi
    done <<< "$kernels_to_remove"

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count old kernel(s), freed $(bytes_to_human $freed)"
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

    # Vacuum journal - keep last 7 days
    if journalctl --vacuum-time=7d >/dev/null 2>&1; then
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

            if rm -f "$file" 2>/dev/null; then
                freed=$((freed + size))
                count=$((count + 1))
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

    # Set non-interactive mode to prevent prompts
    export DEBIAN_FRONTEND=noninteractive
    local dpkg_opts="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

    print_info "Running apt-get clean..."
    apt-get clean $dpkg_opts >/dev/null 2>&1 || true

    print_info "Running apt-get autoclean..."
    apt-get autoclean -y $dpkg_opts >/dev/null 2>&1 || true

    print_info "Running apt-get autoremove..."
    local autoremove_output
    autoremove_output=$(apt-get autoremove --purge -y $dpkg_opts 2>&1 || true)

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
        removed_count=$(echo "$autoremove_output" | grep -oP '\d+(?= to remove)' | head -1 || echo "0")
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

            print_info "Removing $snap_name revision $revision"

            if snap remove "$snap_name" --revision="$revision" >/dev/null 2>&1; then
                freed=$((freed + size))
                count=$((count + 1))
            else
                print_warning "Failed to remove $snap_name revision $revision"
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

    # Clean /tmp
    if [[ -d /tmp ]]; then
        print_info "Cleaning /tmp..."
        local tmp_files
        tmp_files=$(find /tmp -type f -mtime +${TEMP_FILE_AGE} 2>/dev/null || true)

        if [[ -n "$tmp_files" ]]; then
            while IFS= read -r file; do
                if [[ -n "$file" && -f "$file" ]]; then
                    local size
                    size=$(get_size "$file")

                    if rm -f "$file" 2>/dev/null; then
                        freed=$((freed + size))
                        count=$((count + 1))
                    fi
                fi
            done <<< "$tmp_files"
        fi
    fi

    # Clean /var/tmp
    if [[ -d /var/tmp ]]; then
        print_info "Cleaning /var/tmp..."
        local var_tmp_files
        var_tmp_files=$(find /var/tmp -type f -mtime +${TEMP_FILE_AGE} 2>/dev/null || true)

        if [[ -n "$var_tmp_files" ]]; then
            while IFS= read -r file; do
                if [[ -n "$file" && -f "$file" ]]; then
                    local size
                    size=$(get_size "$file")

                    if rm -f "$file" 2>/dev/null; then
                        freed=$((freed + size))
                        count=$((count + 1))
                    fi
                fi
            done <<< "$var_tmp_files"
        fi
    fi

    if (( count > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + freed))
        print_success "Removed $count temporary file(s), freed $(bytes_to_human $freed)"
    else
        print_info "No old temporary files found"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Check for root privileges
    check_root

    # Print banner
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         Ubuntu Log Cleaner - System Maintenance       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    print_info "Starting cleanup process..."
    print_info "Start time: $(date '+%Y-%m-%d %H:%M:%S')"

    # Execute cleanup functions
    cleanup_old_kernels
    cleanup_journal
    cleanup_gz_logs
    cleanup_apt_cache
    cleanup_snap_revisions
    cleanup_temp_files

    # Print summary
    print_header "Cleanup Summary"
    print_info "End time: $(date '+%Y-%m-%d %H:%M:%S')"

    if (( TOTAL_FREED > 0 )); then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}Total space freed: $(bytes_to_human $TOTAL_FREED)${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        print_success "Cleanup completed successfully!"
    else
        print_info "No space was freed - system is already clean"
        print_success "Cleanup completed!"
    fi

    echo ""
}

# Run main function
main "$@"
