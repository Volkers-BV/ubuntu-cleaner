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

@test "--temp-age rejects non-numeric value" {
    run bash logcleaner.sh --temp-age abc 2>&1
    assert_failure
    assert_output --partial "Invalid value for --temp-age"
}

@test "--journal-days rejects missing value" {
    run bash logcleaner.sh --journal-days 2>&1
    assert_failure
    assert_output --partial "Invalid value for --journal-days"
}

@test "--only-if-usage flag is recognized" {
    run bash logcleaner.sh --only-if-usage 85 --version
    assert_success
    refute_output --partial "Unknown option"
}

@test "--only-if-usage rejects non-numeric value" {
    run bash logcleaner.sh --only-if-usage high 2>&1
    assert_failure
    assert_output --partial "Invalid value for --only-if-usage"
}

@test "--only-if-usage 100 skips cleanup on a non-full disk" {
    run bash logcleaner.sh --yes --only-if-usage 100 \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert_output --partial "below threshold"
}

@test "CLI flags override config file settings" {
    local cfg="/tmp/bats-config-$$.conf"
    echo 'TEMP_FILE_AGE=99' > "$cfg"
    run bash logcleaner.sh --yes --dry-run --config "$cfg" --only-temp --temp-age 3 2>&1
    assert_success
    assert_output --partial "(3+ days old)"
    rm -f "$cfg"
}

@test "config file ages survive profile defaults" {
    local cfg="/tmp/bats-config-$$.conf"
    echo 'TEMP_FILE_AGE=99' > "$cfg"
    run bash logcleaner.sh --yes --dry-run --config "$cfg" --only-temp 2>&1
    assert_success
    assert_output --partial "(99+ days old)"
    rm -f "$cfg"
}
