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

    # dpkg-query: return two fake kernel packages
    printf '#!/bin/bash\necho "linux-image-5.15.0-88-generic 245760"\necho "linux-image-5.15.0-91-generic 245760"\nexit 0\n' \
        > "$MOCK_BIN/dpkg-query"

    # df: return fake filesystem line
    cat > "$MOCK_BIN/df" << 'EOF'
#!/bin/bash
echo "Filesystem  Size  Used  Avail  Use%  Mounted"
echo "/dev/sda1    50G   38G   9.5G   80%  /"
exit 0
EOF

    # du: return fake size for any path
    printf '#!/bin/bash\necho "104857600\t${@: -1}"\nexit 0\n' \
        > "$MOCK_BIN/du"

    # hostname
    printf '#!/bin/bash\necho "test-host"\nexit 0\n' \
        > "$MOCK_BIN/hostname"

    chmod +x "$MOCK_BIN"/*
}

teardown_mocks() {
    [[ -n "${MOCK_BIN:-}" ]] && rm -rf "$MOCK_BIN"
}
