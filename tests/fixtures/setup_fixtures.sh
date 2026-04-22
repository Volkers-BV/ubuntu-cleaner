#!/usr/bin/env bash
# Seeds fake files into the container for integration tests.
# Must run as root inside the container.
set -euo pipefail

create_gz_logs() {
    for i in 1 2 3 4 5; do
        dd if=/dev/zero bs=1K count=100 2>/dev/null \
            | gzip > "/var/log/test-fixture-${i}.log.gz"
    done
    echo "Created 5 fake .gz log files in /var/log"
}

create_tmp_files() {
    for i in 1 2 3; do
        local f="/tmp/logcleaner-fixture-${i}.tmp"
        touch "$f"
        touch -d "10 days ago" "$f"
    done
    echo "Created 3 old temp files in /tmp (backdated 10 days)"
}

create_crash_reports() {
    mkdir -p /var/crash
    for i in 1 2; do
        local f="/var/crash/test-fixture-${i}.crash"
        dd if=/dev/zero bs=1K count=50 2>/dev/null > "$f"
        touch -d "35 days ago" "$f"
    done
    echo "Created 2 fake crash reports in /var/crash (backdated 35 days)"
}

create_gz_logs
create_tmp_files
create_crash_reports
echo "All fixtures ready."
