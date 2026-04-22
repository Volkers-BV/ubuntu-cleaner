# Testing Infrastructure Design

**Date:** 2026-04-22
**Status:** Approved

## Goal

Make `logcleaner.sh` fully testable across Ubuntu 18.04, 20.04, 22.04, and 24.04 using BATS as the test framework, Docker containers for isolation, and GitHub Actions for CI.

## Architecture

Two test layers:

- **Unit tests** — mock all system commands, test function logic in isolation, fast (no containers needed for local dev)
- **Integration tests** — run real script inside Ubuntu containers against pre-seeded fixtures, verify actual filesystem changes

Both layers run for all four Ubuntu versions in CI. Locally, `make test-unit` runs unit tests without Docker for a fast dev loop.

## Directory Structure

```
ubuntu-cleaner/
├── logcleaner.sh
├── Makefile
├── docker/
│   └── Dockerfile.base          # Parameterized via UBUNTU_VERSION build arg
├── tests/
│   ├── fixtures/
│   │   ├── mocks.bash           # Stub functions for apt-get, journalctl, snap, df, etc.
│   │   └── setup_fixtures.sh    # Seeds fake logs, tmp files, crash reports into container
│   ├── unit/
│   │   ├── test_args.bats       # Argument parsing, profiles, flag combinations
│   │   ├── test_analyze.bats    # All analyze_* functions, output format, estimates
│   │   └── test_cleanup.bats    # Cleanup function logic with mocked system commands
│   └── integration/
│       ├── test_smoke.bats      # --analyze and --dry-run on clean container
│       └── test_cleanup.bats    # Real deletion against seeded fixtures
└── .github/
    └── workflows/
        └── test.yml             # Matrix: [18.04, 20.04, 22.04, 24.04]
```

## Docker Setup

Single parameterized `Dockerfile.base` — no per-version Dockerfiles:

```dockerfile
ARG UBUNTU_VERSION
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    bats \
    curl \
    sudo \
    systemd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/logcleaner
COPY logcleaner.sh .
COPY tests/ tests/
RUN chmod +x logcleaner.sh

CMD ["bats", "--recursive", "tests/"]
```

Build and run per version:

```bash
docker build --build-arg UBUNTU_VERSION=22.04 -t logcleaner-test:22.04 -f docker/Dockerfile.base .
docker run --rm --privileged logcleaner-test:22.04 bats --recursive tests/integration/
```

`docker-compose.yml` runs all four versions in parallel:

```yaml
services:
  test-1804:
    build:
      context: .
      dockerfile: docker/Dockerfile.base
      args:
        UBUNTU_VERSION: "18.04"
  test-2004:
    build:
      args:
        UBUNTU_VERSION: "20.04"
  test-2204:
    build:
      args:
        UBUNTU_VERSION: "22.04"
  test-2404:
    build:
      args:
        UBUNTU_VERSION: "24.04"
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make test` | All tests, all Ubuntu versions |
| `make test-unit` | Unit tests only, no Docker (fast dev loop) |
| `make test-integration` | Integration tests, all versions |
| `make test-2204` | Both layers, Ubuntu 22.04 only |
| `make shell-2204` | Interactive shell in 22.04 container for debugging |

## Unit Test Design

Tests source `logcleaner.sh` functions directly without running `main()`. All system commands are stubbed via `mocks.bash`.

```bash
# tests/unit/test_analyze.bats
setup() {
    load '../fixtures/mocks'
    source logcleaner.sh --source-only
}

@test "analyze_apt reports cache size" {
    mock_get_size "/var/cache/apt/archives" "104857600"
    run analyze_apt
    assert_success
    assert_output --partial "APT cache size:"
    assert_output --partial "100MB"
}
```

Mocked commands: `apt-get`, `journalctl`, `snap`, `docker`, `dpkg-query`, `df`, `du`, `find`, `uname`.

## Integration Test Design

`setup_fixtures.sh` seeds realistic junk into the container before each test run:

- `create_gz_logs` — 5 fake `.gz` files in `/var/log`
- `create_tmp_files` — files with mtime older than 7 days in `/tmp`
- `create_crash_reports` — fake `.crash` files in `/var/crash`

Integration tests assert files exist before and are gone after cleanup:

```bash
# tests/integration/test_cleanup.bats
setup() { bash tests/fixtures/setup_fixtures.sh; }

@test "cleanup removes .gz logs" {
    assert [ -f /var/log/test.log.gz ]
    run sudo bash logcleaner.sh --yes --only-gz-logs
    assert_success
    assert [ ! -f /var/log/test.log.gz ]
}

@test "--analyze runs without changes" {
    run sudo bash logcleaner.sh --analyze
    assert_success
    assert_output --partial "ESTIMATED TOTAL"
    assert [ -f /var/log/test.log.gz ]
}
```

## Test Coverage Plan

| Area | Unit | Integration |
|------|------|-------------|
| Argument parsing (`--analyze`, `--profile`, `--yes`, `--dry-run`) | ✅ | — |
| Safety profiles (safe / moderate / aggressive) | ✅ | — |
| `analyze_*` output format and estimates | ✅ | ✅ smoke |
| `.gz` log cleanup | ✅ mocked | ✅ real |
| Temp file cleanup | ✅ mocked | ✅ real |
| Crash report cleanup | ✅ mocked | ✅ real |
| Journal vacuum | ✅ mocked | ✅ smoke only |
| APT cache cleanup | ✅ mocked | ✅ smoke only |
| `--dry-run` makes no changes | ✅ | ✅ real |
| Kernel removal | ✅ mocked | ❌ too destructive |
| Live APT operations | ✅ mocked | ❌ too destructive |

Kernel removal and live APT operations are mocked-only — running them in a shared container layer risks breaking the test environment.

## GitHub Actions Workflow

`.github/workflows/test.yml` — triggers on push and PR to `main`:

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
          docker run --rm logcleaner-test:${{ matrix.ubuntu }} \
            bats --recursive tests/unit/

      - name: Run integration tests
        run: |
          docker run --rm --privileged logcleaner-test:${{ matrix.ubuntu }} \
            bats --recursive tests/integration/
```

`fail-fast: false` ensures all four versions run even if one fails — important for spotting version-specific breakage.

## Out of Scope

- ShellCheck linting (can be added as a separate fast pre-check job later)
- Performance/timing benchmarks
- Testing on non-Ubuntu distros (script already warns on non-Ubuntu systems)
