#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

setup() {
    cd /opt/logcleaner
}

@test "--version prints version string" {
    run bash logcleaner.sh --version
    assert_success
    assert_output --partial "Ubuntu Log Cleaner v"
}

@test "--help exits successfully and shows USAGE" {
    run bash logcleaner.sh --help
    assert_success
    assert_output --partial "USAGE"
}

@test "--help shows --analyze option" {
    run bash logcleaner.sh --help
    assert_success
    assert_output --partial "--analyze"
}

@test "--analyze flag is recognized (no unknown option error)" {
    run bash logcleaner.sh --analyze 2>&1 || true
    refute_output --partial "Unknown option"
}

@test "--dry-run enters dry run mode" {
    run bash logcleaner.sh --yes --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert_output --partial "DRY RUN MODE"
}

@test "--yes skips interactive confirmation prompt" {
    run bash logcleaner.sh --yes --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    refute_output --partial "Proceed with cleanup?"
}

@test "--profile safe is accepted" {
    run bash logcleaner.sh --profile safe --yes --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile moderate is accepted" {
    run bash logcleaner.sh --profile moderate --yes --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile aggressive is accepted" {
    run bash logcleaner.sh --profile aggressive --yes --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile unknown exits with error" {
    run bash logcleaner.sh --profile badprofile --dry-run 2>&1 || true
    assert_output --partial "Unknown profile"
}

@test "unknown flag prints error message" {
    run bash logcleaner.sh --not-a-real-flag 2>&1 || true
    assert_output --partial "Unknown option"
}

@test "--analyze --report-file creates the report file" {
    local tmpfile="/tmp/bats-report-test-$$.txt"
    bash logcleaner.sh --analyze --report-file "$tmpfile" 2>&1 || true
    run test -f "$tmpfile"
    assert_success
    rm -f "$tmpfile"
}
