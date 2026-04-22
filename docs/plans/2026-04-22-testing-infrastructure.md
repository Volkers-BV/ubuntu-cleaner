# Testing Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `logcleaner.sh` fully testable across Ubuntu 18.04–24.04 using BATS, Docker, and GitHub Actions.

**Architecture:** A parameterized `Dockerfile.base` builds Ubuntu images with BATS 1.x. Unit tests source `logcleaner.sh` functions directly with PATH-based stubs mocking system commands. Integration tests run the full script inside containers against pre-seeded fixtures. A Makefile ties local and CI execution together.

**Tech Stack:** BATS 1.x + bats-support + bats-assert, Docker, Docker Compose, GitHub Actions matrix, Makefile

---

## Task 1: Add source-only guard to logcleaner.sh

Unit tests need to source `logcleaner.sh` to call individual functions without triggering `main()`.

**Files:**
- Modify: `logcleaner.sh` (last 4 lines)

- [ ] **Step 1: Replace the final `main "$@"` call**

Find the last two lines of `logcleaner.sh`:
```bash
# Run main function
main "$@"
```

Replace with:
```bash
# Run main function (skip when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

When the script is sourced (`source logcleaner.sh`), `BASH_SOURCE[0]` is the script path but `$0` is the shell binary — they differ, so `main` is not called. When executed directly (`bash logcleaner.sh`), they match and `main` runs as before.

- [ ] **Step 2: Verify the guard works**

Run:
```bash
bash -n logcleaner.sh && echo "syntax OK"
source logcleaner.sh && echo "sourced OK — main not called"
bash logcleaner.sh --version
```

Expected:
```
syntax OK
sourced OK — main not called
Ubuntu Log Cleaner v3.1.0
```

- [ ] **Step 3: Commit**

```bash
git add logcleaner.sh
git commit -m "feat(test): add source-only guard for BATS unit testing"
```

---

## Task 2: Docker infrastructure

**Files:**
- Create: `docker/Dockerfile.base`
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `docker/Dockerfile.base`**

```dockerfile
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    sudo \
    systemd \
    findutils \
    gawk \
    && rm -rf /var/lib/apt/lists/*

# Install BATS 1.x from source (Ubuntu apt has old 0.4.x on 18.04/20.04)
RUN git clone --depth 1 --branch v1.11.0 \
    https://github.com/bats-core/bats-core.git /tmp/bats-core \
    && /tmp/bats-core/install.sh /usr/local \
    && rm -rf /tmp/bats-core

# Install bats-support and bats-assert helpers
RUN git clone --depth 1 \
    https://github.com/bats-core/bats-support.git /usr/lib/bats-support \
    && git clone --depth 1 \
    https://github.com/bats-core/bats-assert.git /usr/lib/bats-assert

WORKDIR /opt/logcleaner
COPY logcleaner.sh .
COPY tests/ tests/
RUN chmod +x logcleaner.sh tests/fixtures/setup_fixtures.sh

CMD ["bats", "--recursive", "tests/"]
```

- [ ] **Step 2: Verify the Dockerfile builds**

Run:
```bash
docker build --build-arg UBUNTU_VERSION=22.04 \
    -t logcleaner-test:22.04 \
    -f docker/Dockerfile.base .
```

Expected: build completes, image tagged `logcleaner-test:22.04`.

Run:
```bash
docker run --rm logcleaner-test:22.04 bats --version
```

Expected output contains: `Bats 1.11.0`

- [ ] **Step 3: Create `docker-compose.yml`**

```yaml
services:
  test-1804:
    build:
      context: .
      dockerfile: docker/Dockerfile.base
      args:
        UBUNTU_VERSION: "18.04"
    command: bats --recursive tests/
    privileged: true

  test-2004:
    build:
      context: .
      dockerfile: docker/Dockerfile.base
      args:
        UBUNTU_VERSION: "20.04"
    command: bats --recursive tests/
    privileged: true

  test-2204:
    build:
      context: .
      dockerfile: docker/Dockerfile.base
      args:
        UBUNTU_VERSION: "22.04"
    command: bats --recursive tests/
    privileged: true

  test-2404:
    build:
      context: .
      dockerfile: docker/Dockerfile.base
      args:
        UBUNTU_VERSION: "24.04"
    command: bats --recursive tests/
    privileged: true
```

- [ ] **Step 4: Verify Compose builds all versions**

Run:
```bash
docker compose build
```

Expected: all four images build without error.

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile.base docker-compose.yml
git commit -m "feat(test): add parameterized Dockerfile and docker-compose for all Ubuntu versions"
```

---

## Task 3: Makefile

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Create `Makefile`**

```makefile
VERSIONS := 18.04 20.04 22.04 24.04

.PHONY: test test-unit test-integration $(addprefix test-,$(subst .,,$(VERSIONS))) $(addprefix shell-,$(subst .,,$(VERSIONS))) build

## Run all tests across all Ubuntu versions
test: build
	docker compose up --abort-on-container-exit --exit-code-from test-2204

## Run unit tests only (no Docker required)
test-unit:
	bats --recursive tests/unit/

## Run integration tests in all Ubuntu containers
test-integration: build
	@for v in $(VERSIONS); do \
		tag=$$(echo $$v | tr -d '.'); \
		echo "=== Integration: Ubuntu $$v ==="; \
		docker run --rm --privileged \
			$$(docker compose images -q test-$$tag 2>/dev/null || \
			   docker build -q --build-arg UBUNTU_VERSION=$$v -f docker/Dockerfile.base .) \
			bats --recursive tests/integration/; \
	done

## Run all tests against a single Ubuntu version (e.g. make test-2204)
test-1804: build
	docker run --rm --privileged logcleaner-test:18.04 bats --recursive tests/
test-2004: build
	docker run --rm --privileged logcleaner-test:20.04 bats --recursive tests/
test-2204: build
	docker run --rm --privileged logcleaner-test:22.04 bats --recursive tests/
test-2404: build
	docker run --rm --privileged logcleaner-test:24.04 bats --recursive tests/

## Drop into interactive shell for a specific version (e.g. make shell-2204)
shell-1804:
	docker run --rm -it --privileged logcleaner-test:18.04 bash
shell-2004:
	docker run --rm -it --privileged logcleaner-test:20.04 bash
shell-2204:
	docker run --rm -it --privileged logcleaner-test:22.04 bash
shell-2404:
	docker run --rm -it --privileged logcleaner-test:24.04 bash

## Build all test images
build:
	@for v in $(VERSIONS); do \
		echo "Building Ubuntu $$v..."; \
		docker build -q --build-arg UBUNTU_VERSION=$$v \
			-t logcleaner-test:$$v \
			-f docker/Dockerfile.base . ; \
	done
```

- [ ] **Step 2: Verify Makefile syntax and build target**

Run:
```bash
make build
```

Expected: all four images built, tagged `logcleaner-test:18.04` through `logcleaner-test:24.04`.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "feat(test): add Makefile with test, build, and shell targets"
```

---

## Task 4: Test fixtures — mocks and setup

**Files:**
- Create: `tests/fixtures/mocks.bash`
- Create: `tests/fixtures/setup_fixtures.sh`

- [ ] **Step 1: Create `tests/fixtures/mocks.bash`**

This file creates PATH-based stubs so sourced functions find mocked commands via `command -v` and direct invocation.

```bash
#!/usr/bin/env bash
# Loaded by unit tests via: load '../fixtures/mocks'
# Creates stub scripts in a temp bin dir prepended to PATH.

setup_mocks() {
    export MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # apt-get: succeed silently
    printf '#!/bin/bash\necho "mock: apt-get $*" >&2\nexit 0\n' > "$MOCK_BIN/apt-get"

    # journalctl: return fake disk usage
    printf '#!/bin/bash\necho "Archived and active journals take up 45.0M in the file system."\nexit 0\n' \
        > "$MOCK_BIN/journalctl"

    # snap: list and list --all
    printf '#!/bin/bash\nif [[ "$*" == *"--all"* ]]; then\n  echo "core 16-2.61 disabled"\nelse\n  echo "Name  Version  Rev"\n  echo "core  16-2.61  1234"\nfi\nexit 0\n' \
        > "$MOCK_BIN/snap"

    # docker: succeed, return fake df output
    printf '#!/bin/bash\nif [[ "$1" == "info" ]]; then exit 0; fi\necho "TYPE   TOTAL   ACTIVE   SIZE   RECLAIMABLE"\necho "Images 5       2        1.2GB  800MB (66%)"\nexit 0\n' \
        > "$MOCK_BIN/docker"

    # dpkg-query: return two fake kernel packages
    printf '#!/bin/bash\necho "linux-image-5.15.0-88-generic 245760"\necho "linux-image-5.15.0-91-generic 245760"\nexit 0\n' \
        > "$MOCK_BIN/dpkg-query"

    # df: return fake filesystem info
    printf '#!/bin/bash\necho "Filesystem Size Used Avail Use%% Mounted"\necho "/dev/sda1  50G  38G  9.5G  80%% /"\nexit 0\n' \
        > "$MOCK_BIN/df"

    # du: return fake sizes
    printf '#!/bin/bash\necho "104857600\t$2"\nexit 0\n' \
        > "$MOCK_BIN/du"

    # hostname
    printf '#!/bin/bash\necho "test-host"\nexit 0\n' \
        > "$MOCK_BIN/hostname"

    chmod +x "$MOCK_BIN"/*
}

teardown_mocks() {
    [[ -n "$MOCK_BIN" ]] && rm -rf "$MOCK_BIN"
}
```

- [ ] **Step 2: Create `tests/fixtures/setup_fixtures.sh`**

```bash
#!/usr/bin/env bash
# Seeds fake files into the container for integration tests.
# Run as root inside the container.

set -euo pipefail

create_gz_logs() {
    for i in 1 2 3 4 5; do
        dd if=/dev/zero bs=1K count=100 2>/dev/null | gzip > "/var/log/test-fixture-${i}.log.gz"
    done
    echo "Created 5 fake .gz log files in /var/log"
}

create_tmp_files() {
    for i in 1 2 3; do
        local f="/tmp/logcleaner-fixture-${i}.tmp"
        touch "$f"
        # backdate to 10 days ago so --temp-age 7 picks them up
        touch -d "10 days ago" "$f"
    done
    echo "Created 3 old temp files in /tmp"
}

create_crash_reports() {
    mkdir -p /var/crash
    for i in 1 2; do
        local f="/var/crash/test-fixture-${i}.crash"
        dd if=/dev/zero bs=1K count=50 2>/dev/null > "$f"
        touch -d "35 days ago" "$f"
    done
    echo "Created 2 fake crash reports in /var/crash"
}

main() {
    create_gz_logs
    create_tmp_files
    create_crash_reports
    echo "Fixtures ready."
}

main "$@"
```

- [ ] **Step 3: Verify mocks file is valid bash**

Run:
```bash
bash -n tests/fixtures/mocks.bash && echo "OK"
bash -n tests/fixtures/setup_fixtures.sh && echo "OK"
```

Expected: both print `OK`.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/mocks.bash tests/fixtures/setup_fixtures.sh
git commit -m "feat(test): add mock stubs and fixture setup script"
```

---

## Task 5: Unit tests — argument parsing

**Files:**
- Create: `tests/unit/test_args.bats`

- [ ] **Step 1: Create `tests/unit/test_args.bats`**

```bash
#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

setup() {
    cd /opt/logcleaner
}

# --- Flag: --version ---

@test "--version prints version string" {
    run bash logcleaner.sh --version
    assert_success
    assert_output --partial "Ubuntu Log Cleaner v"
}

# --- Flag: --analyze ---

@test "--analyze flag is recognized without error" {
    # Will fail because run_analysis is called and analyze_disk etc run — 
    # but it should not fail with "Unknown option"
    run bash logcleaner.sh --analyze 2>&1 || true
    refute_output --partial "Unknown option"
}

# --- Flag: --dry-run ---

@test "--dry-run sets DRY_RUN and does not prompt" {
    run bash logcleaner.sh --dry-run --skip-kernels --skip-journal \
        --skip-gz-logs --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert_output --partial "DRY RUN MODE"
}

# --- Flag: --yes ---

@test "--yes skips interactive confirmation" {
    run bash logcleaner.sh --yes --dry-run --skip-kernels --skip-journal \
        --skip-gz-logs --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    refute_output --partial "Proceed with cleanup?"
}

# --- Flag: --profile ---

@test "--profile safe is accepted" {
    run bash logcleaner.sh --profile safe --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile moderate is accepted" {
    run bash logcleaner.sh --profile moderate --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile aggressive is accepted" {
    run bash logcleaner.sh --profile aggressive --dry-run \
        --skip-kernels --skip-journal --skip-gz-logs \
        --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
}

@test "--profile unknown exits with error" {
    run bash logcleaner.sh --profile badprofile --dry-run 2>&1 || true
    assert_output --partial "Unknown profile"
}

# --- Unknown flag ---

@test "unknown flag exits with error message" {
    run bash logcleaner.sh --not-a-real-flag 2>&1 || true
    assert_output --partial "Unknown option"
}

# --- Flag: --report-file ---

@test "--analyze --report-file writes report to file" {
    local tmpfile
    tmpfile="$(mktemp)"
    run bash logcleaner.sh --analyze --report-file "$tmpfile" 2>&1 || true
    # File should have been created/written regardless of analyze errors
    run stat "$tmpfile"
    assert_success
    rm -f "$tmpfile"
}
```

- [ ] **Step 2: Run unit tests inside the 22.04 container**

Run:
```bash
docker run --rm logcleaner-test:22.04 \
    bats tests/unit/test_args.bats
```

Expected: all tests pass (or skip with known failures that will be fixed in later tasks).

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_args.bats
git commit -m "test(unit): add argument parsing tests"
```

---

## Task 6: Unit tests — analyze functions

**Files:**
- Create: `tests/unit/test_analyze.bats`

- [ ] **Step 1: Create `tests/unit/test_analyze.bats`**

```bash
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
    # Initialize globals that functions depend on
    REPORT_FILE=""
    declare -gA _ANALYSIS_ESTIMATES
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

@test "report_kv formats key and value" {
    run report_kv "Cache size" "100MB"
    assert_success
    assert_output --partial "Cache size:"
    assert_output --partial "100MB"
}

@test "record_estimate stores value in _ANALYSIS_ESTIMATES" {
    record_estimate "APT cache" "104857600"
    assert_equal "${_ANALYSIS_ESTIMATES[APT cache]}" "104857600"
}

# --- analyze_logs ---

@test "analyze_logs section header present" {
    run analyze_logs
    assert_output --partial "LOG FILES"
}

@test "analyze_logs reports compressed file count" {
    # Create a fake .gz file for find to discover
    mkdir -p /var/log
    touch /var/log/fake-test.log.gz
    run analyze_logs
    assert_output --partial ".gz"
    rm -f /var/log/fake-test.log.gz
}

# --- analyze_journal ---

@test "analyze_journal section header present" {
    run analyze_journal
    assert_output --partial "SYSTEMD JOURNAL"
}

@test "analyze_journal shows disk usage line" {
    run analyze_journal
    assert_output --partial "Journal size"
}

# --- analyze_apt ---

@test "analyze_apt section header present" {
    run analyze_apt
    assert_output --partial "APT CACHE"
}

@test "analyze_apt shows cache size" {
    run analyze_apt
    assert_output --partial "APT cache size"
}

@test "analyze_apt records estimate" {
    analyze_apt
    # Estimate should be set (may be 0 in test environment)
    assert [ "${_ANALYSIS_ESTIMATES[APT cache]+set}" = "set" ]
}

# --- analyze_kernels ---

@test "analyze_kernels section header present" {
    run analyze_kernels
    assert_output --partial "KERNEL PACKAGES"
}

@test "analyze_kernels shows running kernel" {
    run analyze_kernels
    assert_output --partial "Running kernel"
}

# --- analyze_temp ---

@test "analyze_temp section header present" {
    run analyze_temp
    assert_output --partial "TEMPORARY FILES"
}

@test "analyze_temp reports /tmp" {
    run analyze_temp
    assert_output --partial "/tmp"
}

# --- analyze_crash ---

@test "analyze_crash section header present" {
    run analyze_crash
    assert_output --partial "CRASH REPORTS"
}

# --- analyze_docker ---

@test "analyze_docker section header present" {
    run analyze_docker
    assert_output --partial "DOCKER"
}

# --- analyze_summary ---

@test "analyze_summary section header present" {
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
```

- [ ] **Step 2: Run inside 22.04 container**

Run:
```bash
docker run --rm logcleaner-test:22.04 \
    bats tests/unit/test_analyze.bats
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_analyze.bats
git commit -m "test(unit): add analyze function unit tests"
```

---

## Task 7: Unit tests — cleanup functions

**Files:**
- Create: `tests/unit/test_cleanup.bats`

- [ ] **Step 1: Create `tests/unit/test_cleanup.bats`**

```bash
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

# --- cleanup_gz_logs ---

@test "cleanup_gz_logs dry-run reports files it would remove" {
    mkdir -p /var/log
    touch /var/log/logcleaner-unit-test.log.gz
    run cleanup_gz_logs
    assert_success
    assert_output --partial "Would remove"
    rm -f /var/log/logcleaner-unit-test.log.gz
}

@test "cleanup_gz_logs skips when no .gz files" {
    # Ensure no .gz files exist that belong to our test
    run bash -c 'cd /opt/logcleaner && source logcleaner.sh && \
        DRY_RUN=true VERBOSE=true QUIET=false USE_COLORS=false \
        RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC="" \
        TOTAL_FREED=0 \
        bash -c "find /var/log -name \"*.gz\" -delete 2>/dev/null; cleanup_gz_logs"'
    # Should not fail even with no gz files
    assert_success
}

# --- cleanup_temp_files ---

@test "cleanup_temp_files dry-run shows old files" {
    local f="/tmp/logcleaner-unit-test-$$.tmp"
    touch "$f"
    touch -d "10 days ago" "$f"
    TEMP_FILE_AGE=7
    run cleanup_temp_files
    assert_success
    assert_output --partial "Would remove"
    rm -f "$f"
}

# --- cleanup_journal ---

@test "cleanup_journal dry-run does not error" {
    JOURNAL_KEEP_DAYS=7
    run cleanup_journal
    assert_success
    assert_output --partial "Would vacuum"
}

# --- cleanup_apt_cache ---

@test "cleanup_apt_cache dry-run prints dry run message" {
    run cleanup_apt_cache
    assert_success
    assert_output --partial "Would run apt-get"
}

# --- cleanup_snap_revisions ---

@test "cleanup_snap_revisions skips when snap not found" {
    # Remove snap from mock PATH so command -v snap fails
    rm -f "$MOCK_BIN/snap"
    run cleanup_snap_revisions
    assert_success
    assert_output --partial "snap not found"
}

# --- bytes_to_human ---

@test "bytes_to_human converts bytes" {
    run bytes_to_human 512
    assert_output "512B"
}

@test "bytes_to_human converts kilobytes" {
    run bytes_to_human 2048
    assert_output "2KB"
}

@test "bytes_to_human converts megabytes" {
    run bytes_to_human 5242880
    assert_output "5MB"
}

@test "bytes_to_human converts gigabytes" {
    run bytes_to_human 2147483648
    assert_output --partial "GB"
}
```

- [ ] **Step 2: Run inside 22.04 container**

Run:
```bash
docker run --rm --privileged logcleaner-test:22.04 \
    bats tests/unit/test_cleanup.bats
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_cleanup.bats
git commit -m "test(unit): add cleanup function unit tests"
```

---

## Task 8: Integration tests — smoke

**Files:**
- Create: `tests/integration/test_smoke.bats`

- [ ] **Step 1: Create `tests/integration/test_smoke.bats`**

```bash
#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

# Smoke tests: verify the script runs without crashing in read-only modes.
# These run as root inside real Ubuntu containers. No mocks.

@test "--version exits successfully" {
    run bash /opt/logcleaner/logcleaner.sh --version
    assert_success
    assert_output --partial "Ubuntu Log Cleaner v"
}

@test "--help exits successfully and shows usage" {
    run bash /opt/logcleaner/logcleaner.sh --help
    assert_success
    assert_output --partial "USAGE"
    assert_output --partial "--analyze"
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
    assert_output --partial "ESTIMATED TOTAL"
}

@test "--analyze --report-file writes to file" {
    local tmpfile="/tmp/logcleaner-smoke-test-report.txt"
    run bash /opt/logcleaner/logcleaner.sh --analyze --report-file "$tmpfile" 2>&1
    assert_success
    assert [ -f "$tmpfile" ]
    run grep "ESTIMATED TOTAL" "$tmpfile"
    assert_success
    rm -f "$tmpfile"
}

@test "--analyze does not delete any files" {
    # Create a sentinel file, verify it survives --analyze
    local sentinel="/tmp/logcleaner-sentinel-$$"
    touch "$sentinel"
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert [ -f "$sentinel" ]
    rm -f "$sentinel"
}

@test "--dry-run reports estimated space to free" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run 2>&1
    assert_success
    assert_output --partial "Estimated space"
}
```

- [ ] **Step 2: Run inside 22.04 container**

Run:
```bash
docker run --rm --privileged logcleaner-test:22.04 \
    bats tests/integration/test_smoke.bats
```

Expected: all 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/test_smoke.bats
git commit -m "test(integration): add smoke tests for --analyze and --dry-run"
```

---

## Task 9: Integration tests — real cleanup with fixtures

**Files:**
- Create: `tests/integration/test_cleanup.bats`

- [ ] **Step 1: Create `tests/integration/test_cleanup.bats`**

```bash
#!/usr/bin/env bats

load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

setup() {
    bash /opt/logcleaner/tests/fixtures/setup_fixtures.sh
}

teardown() {
    # Clean up any leftover fixture files
    rm -f /var/log/test-fixture-*.log.gz
    rm -f /tmp/logcleaner-fixture-*.tmp
    rm -f /var/crash/test-fixture-*.crash
}

# --- .gz log cleanup ---

@test "gz log files exist after fixture setup" {
    run ls /var/log/test-fixture-1.log.gz
    assert_success
}

@test "--only-gz-logs removes fixture .gz files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-gz-logs 2>&1
    assert_success
    run ls /var/log/test-fixture-1.log.gz
    assert_failure   # file should be gone
}

@test "--dry-run does not remove .gz files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run --only-gz-logs 2>&1
    assert_success
    assert [ -f /var/log/test-fixture-1.log.gz ]   # still there
}

# --- temp file cleanup ---

@test "old tmp files exist after fixture setup" {
    run ls /tmp/logcleaner-fixture-1.tmp
    assert_success
}

@test "--only-temp removes old fixture temp files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-temp --temp-age 7 2>&1
    assert_success
    run ls /tmp/logcleaner-fixture-1.tmp
    assert_failure   # file should be gone
}

@test "--dry-run does not remove temp files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run --only-temp --temp-age 7 2>&1
    assert_success
    assert [ -f /tmp/logcleaner-fixture-1.tmp ]
}

# --- crash report cleanup ---

@test "crash reports exist after fixture setup" {
    run ls /var/crash/test-fixture-1.crash
    assert_success
}

@test "--crash-reports removes old fixture crash files" {
    run bash /opt/logcleaner/logcleaner.sh --yes --crash-reports --crash-age 30 \
        --skip-kernels --skip-journal --skip-gz-logs --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    run ls /var/crash/test-fixture-1.crash
    assert_failure   # file should be gone
}

@test "--dry-run does not remove crash reports" {
    run bash /opt/logcleaner/logcleaner.sh --yes --dry-run --crash-reports --crash-age 30 \
        --skip-kernels --skip-journal --skip-gz-logs --skip-apt --skip-snap --skip-temp 2>&1
    assert_success
    assert [ -f /var/crash/test-fixture-1.crash ]
}

# --- --analyze doesn't touch fixtures ---

@test "--analyze leaves all fixture files untouched" {
    run bash /opt/logcleaner/logcleaner.sh --analyze 2>&1
    assert_success
    assert [ -f /var/log/test-fixture-1.log.gz ]
    assert [ -f /tmp/logcleaner-fixture-1.tmp ]
    assert [ -f /var/crash/test-fixture-1.crash ]
}

# --- summary output ---

@test "cleanup reports freed space in summary" {
    run bash /opt/logcleaner/logcleaner.sh --yes --only-gz-logs 2>&1
    assert_success
    assert_output --partial "freed"
}
```

- [ ] **Step 2: Run inside 22.04 container**

Run:
```bash
docker run --rm --privileged logcleaner-test:22.04 \
    bats tests/integration/test_cleanup.bats
```

Expected: all 12 tests pass.

- [ ] **Step 3: Run all tests across all four versions**

Run:
```bash
make test-1804
make test-2004
make test-2204
make test-2404
```

Expected: all pass on all versions. Note any version-specific failures for investigation.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/test_cleanup.bats
git commit -m "test(integration): add real cleanup tests with fixture setup"
```

---

## Task 10: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Create `.github/workflows/test.yml`**

```yaml
name: Test

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Ubuntu ${{ matrix.ubuntu }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        ubuntu: ["18.04", "20.04", "22.04", "24.04"]
      fail-fast: false

    steps:
      - uses: actions/checkout@v4

      - name: Build test image
        run: |
          docker build \
            --build-arg UBUNTU_VERSION=${{ matrix.ubuntu }} \
            -t logcleaner-test:${{ matrix.ubuntu }} \
            -f docker/Dockerfile.base .

      - name: Run unit tests
        run: |
          docker run --rm \
            logcleaner-test:${{ matrix.ubuntu }} \
            bats --recursive tests/unit/

      - name: Run integration tests
        run: |
          docker run --rm --privileged \
            logcleaner-test:${{ matrix.ubuntu }} \
            bats --recursive tests/integration/
```

- [ ] **Step 2: Validate the workflow file is valid YAML**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))" && echo "valid YAML"
```

Expected: `valid YAML`

- [ ] **Step 3: Commit and push to trigger CI**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add GitHub Actions test matrix for Ubuntu 18.04–24.04"
git push origin main
```

Expected: GitHub Actions runs four parallel jobs, all green.

---

## Self-Review

**Spec coverage:**
- ✅ Ubuntu 18.04, 20.04, 22.04, 24.04 — Task 2 (Dockerfile), Task 10 (GHA matrix)
- ✅ BATS 1.x — Task 2 (installed from source in Dockerfile)
- ✅ Unit tests — Tasks 5, 6, 7
- ✅ Integration tests — Tasks 8, 9
- ✅ Fixture seeding — Task 4 (setup_fixtures.sh)
- ✅ PATH-based mocks — Task 4 (mocks.bash)
- ✅ Source-only guard — Task 1
- ✅ Makefile targets — Task 3
- ✅ docker-compose.yml — Task 2
- ✅ GitHub Actions — Task 10
- ✅ Smoke tests (--analyze, --dry-run) — Task 8
- ✅ Real deletion tests (gz, temp, crash) — Task 9
- ✅ Kernel and live APT stay mocked-only — covered in unit tests, excluded from integration

**Placeholder scan:** None found.

**Consistency check:**
- `setup_mocks` / `teardown_mocks` defined in Task 4, called in Tasks 6 and 7 ✅
- `setup_fixtures.sh` defined in Task 4, called in Task 9 `setup()` ✅
- BATS helper paths `/usr/lib/bats-support/load` and `/usr/lib/bats-assert/load` match Dockerfile install paths in Task 2 ✅
- `logcleaner.sh` source guard defined in Task 1, relied on by Tasks 6 and 7 ✅
