#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

setup() {
    bash /opt/logcleaner/tests/fixtures/setup_fixtures.sh
}

teardown() {
    rm -f /var/log/test-fixture-*.log.gz
    rm -f /tmp/logcleaner-fixture-*.tmp
    rm -f /var/crash/test-fixture-*.crash 2>/dev/null || true
}

# --- fixture existence ---

@test "gz log fixtures exist after setup" {
    assert [ -f /var/log/test-fixture-1.log.gz ]
}

@test "tmp file fixtures exist after setup" {
    assert [ -f /tmp/logcleaner-fixture-1.tmp ]
}

@test "crash report fixtures exist after setup" {
    assert [ -f /var/crash/test-fixture-1.crash ]
}

# --- .gz log cleanup ---

@test "--only-gz-logs removes fixture .gz files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-gz-logs 2>&1
    assert_success
    assert [ ! -f /var/log/test-fixture-1.log.gz ]
}

@test "--dry-run does not remove .gz files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run --only-gz-logs 2>&1
    assert_success
    assert [ -f /var/log/test-fixture-1.log.gz ]
}

@test "--only-gz-logs reports freed space" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-gz-logs 2>&1
    assert_success
    assert_output --partial "freed"
}

# --- temp file cleanup ---

@test "--only-temp removes old fixture tmp files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-temp --temp-age 7 2>&1
    assert_success
    assert [ ! -f /tmp/logcleaner-fixture-1.tmp ]
}

@test "--dry-run does not remove tmp files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run --only-temp --temp-age 7 2>&1
    assert_success
    assert [ -f /tmp/logcleaner-fixture-1.tmp ]
}

# --- crash report cleanup ---

@test "--crash-reports removes old fixture crash files" {
    run bash /opt/logcleaner/logcleaner.sh --yes \
        --crash-reports --crash-age 30 \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert [ ! -f /var/crash/test-fixture-1.crash ]
}

@test "--dry-run does not remove crash reports" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run \
        --crash-reports --crash-age 30 \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert [ -f /var/crash/test-fixture-1.crash ]
}

# --- --analyze leaves everything untouched ---

@test "--analyze leaves all fixture files untouched" {
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert [ -f /var/log/test-fixture-1.log.gz ]
    assert [ -f /tmp/logcleaner-fixture-1.tmp ]
    assert [ -f /var/crash/test-fixture-1.crash ]
}
