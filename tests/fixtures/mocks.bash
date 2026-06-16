#!/usr/bin/env bash
# Loaded by unit tests: load '../fixtures/mocks'
# Creates PATH-based stubs so sourced functions find mocked commands.

setup_mocks() {
    export MOCK_BIN
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # apt-get: succeed silently
    printf '#!/bin/bash\necho "mock: apt-get $*" >&2\nexit 0\n' \
        > "$MOCK_BIN/apt-get"

    # journalctl: return fake disk-usage line
    printf '#!/bin/bash\necho "Archived and active journals take up 45.0M in the file system."\nexit 0\n' \
        > "$MOCK_BIN/journalctl"

    # snap: list vs list --all
    cat > "$MOCK_BIN/snap" << 'EOF'
#!/bin/bash
if [[ "$*" == *"--all"* ]]; then
    echo "core 16-2.61 1233 disabled"
else
    echo "Name  Version  Rev"
    echo "core  16-2.61  1234"
fi
exit 0
EOF

    # docker: info succeeds; system df returns fake table
    cat > "$MOCK_BIN/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "info" ]]; then exit 0; fi
echo "TYPE     TOTAL   ACTIVE   SIZE    RECLAIMABLE"
echo "Images   5       2        1.2GB   800MB (66%)"
exit 0
EOF

    # dpkg-query: two fake kernel packages, format-aware
    cat > "$MOCK_BIN/dpkg-query" << 'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *'${Package} ${Installed-Size}'*)
            echo "linux-image-5.15.0-88-generic 245760"
            echo "linux-image-5.15.0-91-generic 245760"
            exit 0 ;;
        *'${Package}'*)
            echo "linux-image-5.15.0-88-generic"
            echo "linux-image-5.15.0-91-generic"
            exit 0 ;;
        *'${Installed-Size}'*)
            echo "245760"
            exit 0 ;;
    esac
done
exit 0
EOF

    # df: return fake filesystem line
    cat > "$MOCK_BIN/df" << 'EOF'
#!/bin/bash
echo "Filesystem  Size  Used  Avail  Use%  Mounted"
echo "/dev/sda1    50G   38G   9.5G   80%  /"
exit 0
EOF

    # du: return fake size for any path
    cat > "$MOCK_BIN/du" << 'EOF'
#!/bin/bash
echo "104857600	${@: -1}"
exit 0
EOF

    # hostname
    printf '#!/bin/bash\necho "test-host"\nexit 0\n' \
        > "$MOCK_BIN/hostname"

    chmod +x "$MOCK_BIN"/*
}

# Restrict PATH to the mock dir only, symlinking in the real core utilities
# the script and bats need. Makes "command not found" tests hermetic even on
# hosts where docker/pip/npm happen to be installed.
restrict_path_to_mocks() {
    local cmd real
    for cmd in bash sh env date find grep sed awk sort head tail wc cut tr \
               df du stat ln rm mkdir rmdir touch cat mktemp basename dirname uname; do
        [[ -e "$MOCK_BIN/$cmd" ]] && continue
        real=$(command -v "$cmd" 2>/dev/null) || continue
        ln -s "$real" "$MOCK_BIN/$cmd"
    done
    PATH="$MOCK_BIN"
}

teardown_mocks() {
    [[ -n "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
}
