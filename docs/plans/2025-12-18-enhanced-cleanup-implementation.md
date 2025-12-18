# Ubuntu Cleaner v3.0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add safety profiles, new cleanup targets (snap cache, APT lists, Netdata, Prometheus, Grafana, crash reports, pycache), and service handling for autonomous server operation.

**Architecture:** Extend existing bash script with profile system that sets default feature flags, add 7 new cleanup functions following existing patterns, add service stop/start wrapper for monitoring tools.

**Tech Stack:** Bash, systemctl, standard Linux utilities (find, rm, du)

---

## Task 1: Add Profile Configuration Variables

**Files:**
- Modify: `logcleaner.sh:36-64` (Global Configuration Variables section)

**Step 1: Add new configuration variables after existing feature flags**

Add these variables after line 64 (after `CLEANUP_MAIL=false`):

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: add v3.0 configuration variables for profiles and new cleanup targets"
```

---

## Task 2: Implement apply_profile() Function

**Files:**
- Modify: `logcleaner.sh` (add after `load_config()` function, around line 292)

**Step 1: Add the apply_profile function**

Add after `load_config()` function:

```bash
# Apply safety profile settings
apply_profile() {
    case "$CLEANUP_PROFILE" in
        safe)
            # Conservative - production servers
            TEMP_FILE_AGE=14
            JOURNAL_KEEP_DAYS=14
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=false
            CLEANUP_CRASH_REPORTS=true
            CRASH_REPORT_AGE=30
            CLEANUP_NETDATA=false
            CLEANUP_PROMETHEUS=false
            CLEANUP_GRAFANA=false
            CLEANUP_PYCACHE=false
            ;;
        moderate)
            # Balanced - staging/dev servers
            TEMP_FILE_AGE=7
            JOURNAL_KEEP_DAYS=7
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=true
            CLEANUP_CRASH_REPORTS=true
            CRASH_REPORT_AGE=7
            CLEANUP_NETDATA=true
            NETDATA_DB_AGE=14
            CLEANUP_PROMETHEUS=true
            PROMETHEUS_DATA_AGE=30
            CLEANUP_GRAFANA=true
            CLEANUP_PYCACHE=false
            ;;
        aggressive)
            # Maximum cleanup - emergencies, CI runners
            TEMP_FILE_AGE=3
            JOURNAL_KEEP_DAYS=3
            CLEANUP_SNAP_CACHE=true
            CLEANUP_APT_LISTS=true
            CLEANUP_CRASH_REPORTS=true
            CRASH_REPORT_AGE=0  # All crash reports
            CLEANUP_NETDATA=true
            NETDATA_DB_AGE=3
            CLEANUP_PROMETHEUS=true
            PROMETHEUS_DATA_AGE=7
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement apply_profile() function for safety profiles"
```

---

## Task 3: Add Profile and New Target CLI Arguments

**Files:**
- Modify: `logcleaner.sh` (parse_arguments function, around line 506-686)

**Step 1: Add new argument cases in parse_arguments()**

Add these cases inside the `while` loop, before the `*)` catch-all case:

```bash
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
                shift 2
                ;;
            --netdata-age)
                NETDATA_DB_AGE="$2"
                shift 2
                ;;
            --prometheus-age)
                PROMETHEUS_DATA_AGE="$2"
                shift 2
                ;;
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: add CLI arguments for profiles and new cleanup targets"
```

---

## Task 4: Update Help Text

**Files:**
- Modify: `logcleaner.sh` (show_help function, around line 413-497)

**Step 1: Update the help text**

Replace the show_help() function content with expanded help including new options. Add these sections after existing cleanup options:

```bash
# Add after line ~441 (after --mail line in help text)
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

PROFILES:
    safe        Production servers - conservative cleanup, preserves monitoring data
    moderate    Staging/dev - balanced cleanup including monitoring caches
    aggressive  Maximum cleanup - for disk emergencies or CI runners
```

**Step 2: Test help output**

Run: `bash logcleaner.sh --help | head -80`
Expected: Help text displays with new options

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "docs: update help text with v3.0 options"
```

---

## Task 5: Implement cleanup_snap_cache()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_snap_revisions function, around line 997)

**Step 1: Add cleanup_snap_cache function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_snap_cache() function"
```

---

## Task 6: Implement cleanup_apt_lists()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_snap_cache function)

**Step 1: Add cleanup_apt_lists function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_apt_lists() function"
```

---

## Task 7: Implement cleanup_crash_reports()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_apt_lists function)

**Step 1: Add cleanup_crash_reports function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_crash_reports() function"
```

---

## Task 8: Implement Service Helper Functions

**Files:**
- Modify: `logcleaner.sh` (add after helper functions section, around line 275)

**Step 1: Add service management helper functions**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: add service management helper functions"
```

---

## Task 9: Implement cleanup_netdata()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_crash_reports function)

**Step 1: Add cleanup_netdata function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_netdata() function"
```

---

## Task 10: Implement cleanup_prometheus()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_netdata function)

**Step 1: Add cleanup_prometheus function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_prometheus() function"
```

---

## Task 11: Implement cleanup_grafana()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_prometheus function)

**Step 1: Add cleanup_grafana function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_grafana() function"
```

---

## Task 12: Implement cleanup_pycache()

**Files:**
- Modify: `logcleaner.sh` (add after cleanup_grafana function)

**Step 1: Add cleanup_pycache function**

```bash
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
```

**Step 2: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: implement cleanup_pycache() function"
```

---

## Task 13: Update main() to Call New Functions

**Files:**
- Modify: `logcleaner.sh` (main function, around line 1337-1466)

**Step 1: Add apply_profile() call after load_config()**

After line `load_config` (around line 1348), add:

```bash
    # Apply safety profile
    apply_profile
```

**Step 2: Add new cleanup calls in main()**

After the existing cleanup calls (around line 1418), add:

```bash
    [[ "$CLEANUP_SNAP_CACHE" == true ]] && cleanup_snap_cache
    [[ "$CLEANUP_APT_LISTS" == true ]] && cleanup_apt_lists
    [[ "$CLEANUP_CRASH_REPORTS" == true ]] && cleanup_crash_reports
    [[ "$CLEANUP_NETDATA" == true ]] && cleanup_netdata_with_service
    [[ "$CLEANUP_PROMETHEUS" == true ]] && cleanup_prometheus_with_service
    [[ "$CLEANUP_GRAFANA" == true ]] && cleanup_grafana_with_service
    [[ "$CLEANUP_PYCACHE" == true ]] && cleanup_pycache
```

**Step 3: Update the interactive confirmation list**

In the interactive confirmation section (around line 1386-1399), add:

```bash
        [[ "$CLEANUP_SNAP_CACHE" == true ]] && echo "  - Clean snap package cache"
        [[ "$CLEANUP_APT_LISTS" == true ]] && echo "  - Clean APT package lists"
        [[ "$CLEANUP_CRASH_REPORTS" == true ]] && echo "  - Clean crash reports"
        [[ "$CLEANUP_NETDATA" == true ]] && echo "  - Clean Netdata cache/database"
        [[ "$CLEANUP_PROMETHEUS" == true ]] && echo "  - Clean old Prometheus data"
        [[ "$CLEANUP_GRAFANA" == true ]] && echo "  - Clean Grafana cache"
        [[ "$CLEANUP_PYCACHE" == true ]] && echo "  - Clean Python bytecode"
```

**Step 4: Verify syntax**

Run: `bash -n logcleaner.sh`
Expected: No output (no syntax errors)

**Step 5: Commit**

```bash
git add logcleaner.sh
git commit -m "feat: wire up new cleanup functions in main()"
```

---

## Task 14: Update Version Number

**Files:**
- Modify: `logcleaner.sh:28`

**Step 1: Update VERSION constant**

Change:
```bash
readonly VERSION="2.0.0"
```

To:
```bash
readonly VERSION="3.0.0"
```

**Step 2: Commit**

```bash
git add logcleaner.sh
git commit -m "chore: bump version to 3.0.0"
```

---

## Task 15: Update Config File Example

**Files:**
- Modify: `logcleaner.conf.example`

**Step 1: Add new configuration options**

Add after line 69 (after `CLEANUP_MAIL=false`):

```bash
################################################################################
# Safety Profiles (v3.0)
################################################################################

# Cleanup profile: safe, moderate, aggressive
# - safe: Production servers, conservative cleanup
# - moderate: Staging/dev, balanced cleanup
# - aggressive: Maximum cleanup, disk emergencies
CLEANUP_PROFILE="safe"

################################################################################
# New Cleanup Targets (v3.0)
################################################################################

# Clean snap package cache (/var/lib/snapd/cache/)
CLEANUP_SNAP_CACHE=false

# Clean APT package lists (/var/lib/apt/lists/)
# Note: Run 'apt update' to refresh after cleanup
CLEANUP_APT_LISTS=false

# Clean crash reports (/var/crash/)
CLEANUP_CRASH_REPORTS=false

# Clean Netdata cache and database
CLEANUP_NETDATA=false

# Clean old Prometheus data
CLEANUP_PROMETHEUS=false

# Clean Grafana cache
CLEANUP_GRAFANA=false

# Clean Python bytecode (__pycache__)
CLEANUP_PYCACHE=false

################################################################################
# Service Handling (v3.0)
################################################################################

# Stop monitoring services before cleanup, restart after
STOP_SERVICES=false

################################################################################
# Age Thresholds (v3.0)
################################################################################

# Days to keep crash reports (0 = remove all)
CRASH_REPORT_AGE=30

# Days to keep Netdata database files
NETDATA_DB_AGE=14

# Days to keep Prometheus data
PROMETHEUS_DATA_AGE=30
```

**Step 2: Update example profiles section at bottom**

Add new profile examples:

```bash
# PROFILE-BASED CONFIGURATION (v3.0)
# Just set the profile and let it configure everything:
# CLEANUP_PROFILE="moderate"

# Or customize a profile with overrides:
# CLEANUP_PROFILE="moderate"
# CLEANUP_NETDATA=false  # Override: don't touch Netdata
```

**Step 3: Commit**

```bash
git add logcleaner.conf.example
git commit -m "docs: update config example with v3.0 options"
```

---

## Task 16: Update README

**Files:**
- Modify: `README.md`

**Step 1: Update version and add new features to Features section**

Update the version number in the header and add to features list:

```markdown
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
```

**Step 2: Add profiles documentation section**

Add new section after "Command-Line Options":

```markdown
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
```

**Step 3: Update "What's New" section**

Add v3.0.0 changes:

```markdown
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
```

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README with v3.0 features"
```

---

## Task 17: Test Dry Run

**Step 1: Test syntax one final time**

Run: `bash -n logcleaner.sh`
Expected: No output

**Step 2: Test help output**

Run: `bash logcleaner.sh --help`
Expected: Help text with all new options

**Step 3: Test dry run with each profile**

Run (on an Ubuntu system):
```bash
sudo ./logcleaner.sh --dry-run --profile safe
sudo ./logcleaner.sh --dry-run --profile moderate
sudo ./logcleaner.sh --dry-run --profile aggressive
```

**Step 4: Tag release**

```bash
git tag -a v3.0.0 -m "Release v3.0.0 - Safety profiles and enhanced cleanup"
```

---

## Summary

17 tasks covering:
- Configuration variables (Task 1)
- Profile system (Tasks 2-4)
- 7 new cleanup functions (Tasks 5-12)
- Integration (Task 13)
- Documentation (Tasks 14-16)
- Testing (Task 17)

Each task is a focused 2-5 minute unit with verification steps.
