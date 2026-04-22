#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'
load '../fixtures/mocks'

setup() {
    cd /opt/logcleaner
    setup_mocks
    source logcleaner.sh
    DRY_RUN=true
    VERBOSE=true
    QUIET=false
    USE_COLORS=false
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
    TOTAL_FREED=0
}

teardown() {
    teardown_mocks
}

# --- bytes_to_human ---

@test "bytes_to_human: bytes" {
    run bytes_to_human 512
    assert_output "512B"
}

@test "bytes_to_human: kilobytes" {
    run bytes_to_human 2048
    assert_output "2KB"
}

@test "bytes_to_human: megabytes" {
    run bytes_to_human 5242880
    assert_output "5MB"
}

@test "bytes_to_human: gigabytes" {
    run bytes_to_human 2147483648
    assert_output --partial "GB"
}

# --- cleanup_gz_logs (dry-run) ---

@test "cleanup_gz_logs dry-run reports files it would remove" {
    mkdir -p /var/log
    touch /var/log/bats-cleanup-test-$$.log.gz
    run cleanup_gz_logs
    assert_success
    assert_output --partial "Would remove"
    find /var/log -name "bats-cleanup-test-*.log.gz" -delete 2>/dev/null || true
}

@test "cleanup_gz_logs succeeds with no .gz files" {
    find /var/log -name "*.gz" -delete 2>/dev/null || true
    run cleanup_gz_logs
    assert_success
}

# --- cleanup_temp_files (dry-run) ---

@test "cleanup_temp_files dry-run shows old files" {
    local f="/tmp/bats-cleanup-unit-test-$$.tmp"
    touch "$f"
    touch -d "10 days ago" "$f"
    TEMP_FILE_AGE=7
    run cleanup_temp_files
    assert_success
    assert_output --partial "Would remove"
    rm -f "$f"
}

# --- cleanup_journal (dry-run) ---

@test "cleanup_journal dry-run prints Would vacuum" {
    JOURNAL_KEEP_DAYS=7
    run cleanup_journal
    assert_success
    assert_output --partial "Would vacuum"
}

# --- cleanup_apt_cache (dry-run) ---

@test "cleanup_apt_cache dry-run prints Would run apt-get" {
    run cleanup_apt_cache
    assert_success
    assert_output --partial "Would run apt-get"
}

# --- cleanup_snap_revisions ---

@test "cleanup_snap_revisions skips when snap not in PATH" {
    rm -f "$MOCK_BIN/snap"
    run cleanup_snap_revisions
    assert_success
    assert_output --partial "snap not found"
}
