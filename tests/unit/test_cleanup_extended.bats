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

@test "cleanup_snap_cache skips when snap cache dir not found" {
    rm -rf /var/lib/snapd/cache
    run cleanup_snap_cache
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_snap_cache dry-run reports would remove" {
    mkdir -p /var/lib/snapd/cache
    touch /var/lib/snapd/cache/test-snap-$$.snap
    run cleanup_snap_cache
    assert_success
    assert_output --partial "Would remove"
    rm -rf /var/lib/snapd/cache
}

@test "cleanup_apt_lists skips when dir not found" {
    local orig=""
    [[ -d /var/lib/apt/lists ]] && { mv /var/lib/apt/lists /var/lib/apt/lists.bak; orig=1; }
    run cleanup_apt_lists
    assert_success
    assert_output --partial "not found, skipping"
    [[ -n "$orig" ]] && mv /var/lib/apt/lists.bak /var/lib/apt/lists || true
}

@test "cleanup_apt_lists dry-run reports would remove" {
    mkdir -p /var/lib/apt/lists
    touch /var/lib/apt/lists/test-list-$$
    run cleanup_apt_lists
    assert_success
    assert_output --partial "Would remove"
    rm -f /var/lib/apt/lists/test-list-$$
}

@test "cleanup_netdata skips when not installed" {
    rm -rf /opt/netdata /var/lib/netdata
    run cleanup_netdata
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_prometheus skips when not installed" {
    rm -rf /var/lib/prometheus /opt/prometheus
    run cleanup_prometheus
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_grafana skips when not installed" {
    rm -rf /var/lib/grafana
    run cleanup_grafana
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_grafana dry-run reports would clean png cache" {
    mkdir -p /var/lib/grafana/png
    touch /var/lib/grafana/png/test-$$.png
    run cleanup_grafana
    assert_success
    assert_output --partial "Would clean Grafana PNG cache"
    rm -rf /var/lib/grafana
}

@test "cleanup_pycache reports no cache when none found" {
    find /usr/local /opt -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    run cleanup_pycache
    assert_success
    assert_output --partial "No Python cache"
}

@test "cleanup_pycache dry-run reports would remove __pycache__" {
    mkdir -p /opt/testapp/__pycache__
    touch /opt/testapp/__pycache__/module.cpython-310.pyc
    run cleanup_pycache
    assert_success
    assert_output --partial "Would remove"
    rm -rf /opt/testapp
}

@test "cleanup_coredumps skips when dir not found" {
    rm -rf /var/lib/systemd/coredump
    run cleanup_coredumps
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_coredumps dry-run reports would clean" {
    mkdir -p /var/lib/systemd/coredump
    touch /var/lib/systemd/coredump/core-bash-99-$$.lz4
    run cleanup_coredumps
    assert_success
    assert_output --partial "Would clean coredumps"
    rm -rf /var/lib/systemd/coredump
}

@test "cleanup_thumbnails reports no caches when none found" {
    rm -rf /root/.cache/thumbnails /root/.thumbnails
    run cleanup_thumbnails
    assert_success
    assert_output --partial "No thumbnail caches found"
}

@test "cleanup_thumbnails dry-run reports would remove" {
    mkdir -p /root/.cache/thumbnails/normal
    touch /root/.cache/thumbnails/normal/test-$$.png
    run cleanup_thumbnails
    assert_success
    assert_output --partial "Would remove thumbnails"
    rm -rf /root/.cache/thumbnails
}

@test "cleanup_mail reports no mail when dirs empty" {
    mkdir -p /var/mail /var/spool/mail
    run cleanup_mail
    assert_success
    assert_output --partial "No old mail"
}

@test "cleanup_package_caches warns when no package managers found" {
    rm -f "$MOCK_BIN/pip" "$MOCK_BIN/pip3" "$MOCK_BIN/npm" "$MOCK_BIN/yarn"
    run cleanup_package_caches
    assert_success
    assert_output --partial "No package manager caches found"
}

@test "cleanup_docker dry-run prints would prune" {
    run cleanup_docker
    assert_success
    assert_output --partial "Would run docker system prune"
}

@test "cleanup_docker skips when docker not in PATH" {
    rm -f "$MOCK_BIN/docker"
    run cleanup_docker
    assert_success
    assert_output --partial "docker not found, skipping"
}

@test "cleanup_netdata_with_service runs cleanup_netdata" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/systemctl"
    chmod +x "$MOCK_BIN/systemctl"
    rm -rf /opt/netdata /var/lib/netdata
    run cleanup_netdata_with_service
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_prometheus_with_service runs cleanup_prometheus" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/systemctl"
    chmod +x "$MOCK_BIN/systemctl"
    rm -rf /var/lib/prometheus /opt/prometheus
    run cleanup_prometheus_with_service
    assert_success
    assert_output --partial "not found, skipping"
}

@test "cleanup_grafana_with_service runs cleanup_grafana" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/systemctl"
    chmod +x "$MOCK_BIN/systemctl"
    rm -rf /var/lib/grafana
    run cleanup_grafana_with_service
    assert_success
    assert_output --partial "not found, skipping"
}
