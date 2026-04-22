#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'
load '../fixtures/mocks'

setup() {
    cd /opt/logcleaner
    setup_mocks
    # Source functions without running main()
    # shellcheck disable=SC1091
    source logcleaner.sh
    REPORT_FILE=""
    declare -gA _ANALYSIS_ESTIMATES || true
}

teardown() {
    teardown_mocks
}

# --- report helpers ---

@test "report_line prints to stdout" {
    run report_line "hello world"
    assert_success
    assert_output "hello world"
}

@test "report_section prints title with separators" {
    run report_section "MY SECTION"
    assert_success
    assert_output --partial "MY SECTION"
    assert_output --partial "======="
}

@test "report_kv formats key and value aligned" {
    run report_kv "Cache size" "100MB"
    assert_success
    assert_output --partial "Cache size:"
    assert_output --partial "100MB"
}

@test "record_estimate stores bytes in _ANALYSIS_ESTIMATES" {
    record_estimate "APT cache" "104857600"
    assert_equal "${_ANALYSIS_ESTIMATES[APT cache]}" "104857600"
}

# --- analyze_logs ---

@test "analyze_logs prints LOG FILES section header" {
    run analyze_logs
    assert_output --partial "LOG FILES"
}

@test "analyze_logs reports compressed file count" {
    mkdir -p /var/log
    touch /var/log/bats-unit-test.log.gz
    run analyze_logs
    assert_output --partial ".gz"
    rm -f /var/log/bats-unit-test.log.gz
}

# --- analyze_journal ---

@test "analyze_journal prints SYSTEMD JOURNAL header" {
    run analyze_journal
    assert_output --partial "SYSTEMD JOURNAL"
}

@test "analyze_journal shows Journal size" {
    run analyze_journal
    assert_output --partial "Journal size"
}

# --- analyze_apt ---

@test "analyze_apt prints APT CACHE header" {
    run analyze_apt
    assert_output --partial "APT CACHE"
}

@test "analyze_apt shows APT cache size key" {
    run analyze_apt
    assert_output --partial "APT cache size"
}

@test "analyze_apt records APT cache estimate" {
    analyze_apt
    assert [ "${_ANALYSIS_ESTIMATES[APT cache]+set}" = "set" ]
}

# --- analyze_kernels ---

@test "analyze_kernels prints KERNEL PACKAGES header" {
    run analyze_kernels
    assert_output --partial "KERNEL PACKAGES"
}

@test "analyze_kernels shows running kernel" {
    run analyze_kernels
    assert_output --partial "Running kernel"
}

# --- analyze_temp ---

@test "analyze_temp prints TEMPORARY FILES header" {
    run analyze_temp
    assert_output --partial "TEMPORARY FILES"
}

@test "analyze_temp reports /tmp" {
    run analyze_temp
    assert_output --partial "/tmp"
}

# --- analyze_crash ---

@test "analyze_crash prints CRASH REPORTS header" {
    run analyze_crash
    assert_output --partial "CRASH REPORTS"
}

# --- analyze_docker ---

@test "analyze_docker prints DOCKER header" {
    run analyze_docker
    assert_output --partial "DOCKER"
}

# --- analyze_summary ---

@test "analyze_summary prints SUMMARY header" {
    run analyze_summary
    assert_output --partial "SUMMARY"
}

@test "analyze_summary shows ESTIMATED TOTAL line" {
    run analyze_summary
    assert_output --partial "ESTIMATED TOTAL"
}

@test "analyze_summary shows cleanup hint" {
    run analyze_summary
    assert_output --partial "logcleaner.sh"
}
