#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

# Smoke tests: script runs correctly in read-only modes.
# Run as root inside real Ubuntu containers — no mocks.

@test "--version exits 0 and prints version" {
    run bash /opt/logcleaner/logcleaner.sh --version
    assert_success
    assert_output --partial "Ubuntu Log Cleaner v"
}

@test "--help exits 0 and shows USAGE" {
    run bash /opt/logcleaner/logcleaner.sh --help
    assert_success
    assert_output --partial "USAGE"
}

@test "--help shows ANALYSIS MODE section" {
    run bash /opt/logcleaner/logcleaner.sh --help
    assert_success
    assert_output --partial "ANALYSIS MODE"
}

@test "--dry-run completes without error" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run 2>&1
    assert_success
    assert_output --partial "DRY RUN MODE"
}

@test "--analyze completes without error" {
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert_output --partial "UBUNTU SYSTEM ANALYSIS REPORT"
}

@test "--analyze output contains ESTIMATED TOTAL" {
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert_output --partial "ESTIMATED TOTAL"
}

@test "--analyze --report-file writes report to file" {
    local f="/tmp/bats-smoke-report-$$.txt"
    run bash /opt/logcleaner/logcleaner.sh --analyze --report-file "$f" 2>&1
    assert_success
    assert [ -f "$f" ]
    run grep "ESTIMATED TOTAL" "$f"
    assert_success
    rm -f "$f"
}

@test "--analyze does not delete files" {
    local sentinel="/tmp/bats-sentinel-$$"
    touch "$sentinel"
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert [ -f "$sentinel" ]
    rm -f "$sentinel"
}
