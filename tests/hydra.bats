#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Aaron K. Clark
#
# Unit tests for hydra.sh.
#
# Run with:    bats tests/
#
# Tests are split into two groups:
#   1. CLI-level tests that exercise hydra.sh as a subprocess
#   2. Function-level tests that `source hydra.sh` and call internals
#
# We use a per-test stub PATH for the function-level tests so that lsblk,
# findmnt, sudo, etc. can be mocked without touching the host.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HYDRA="$REPO_ROOT/hydra.sh"
    STUB_DIR="$(mktemp -d -t hydra-stubs-XXXX)"
    export PATH="$STUB_DIR:$PATH"

    # Tests that don't override HYDRA_ISO_DIR get a temp one.
    export HYDRA_ISO_DIR="$(mktemp -d -t hydra-iso-XXXX)"
}

teardown() {
    [[ -n "$STUB_DIR" ]] && rm -rf "$STUB_DIR"
    [[ -n "$HYDRA_ISO_DIR" && "$HYDRA_ISO_DIR" == /tmp/* ]] && rm -rf "$HYDRA_ISO_DIR"
}

# ---------- CLI subcommand tests ----------

@test "help subcommand prints usage" {
    run bash "$HYDRA" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"download"* ]]
    [[ "$output" == *"usb"* ]]
}

@test "unknown subcommand exits non-zero with helpful message" {
    run bash "$HYDRA" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown subcommand"* ]]
    [[ "$output" == *"frobnicate"* ]]
}

@test "no subcommand defaults to check (does not crash)" {
    # cmd_check only reads, never writes — safe to run.
    run bash "$HYDRA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hydra: host readiness"* ]]
}

@test "usb subcommand with no device exits with clear error" {
    run bash "$HYDRA" usb
    [ "$status" -ne 0 ]
    [[ "$output" == *"no device specified"* ]] || [[ "$output" == *"Usage:"* ]]
}

@test "usb refuses a non-existent device path" {
    run bash "$HYDRA" usb /dev/this-does-not-exist-XXX
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
}

@test "usb refuses a regular file (not a block device)" {
    local f="$BATS_TEST_TMPDIR/not-a-device"
    touch "$f"
    run bash "$HYDRA" usb "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
}

@test "copy with no device argument exits with usage" {
    run bash "$HYDRA" copy
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"copy"* ]]
}

@test "test with no device argument exits with usage" {
    run bash "$HYDRA" test
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"test"* ]]
}

@test "persistence with no device argument exits with clear error" {
    run bash "$HYDRA" persistence
    [ "$status" -ne 0 ]
    [[ "$output" == *"no device specified"* ]] || [[ "$output" == *"Usage:"* ]]
}

@test "persistence refuses a non-existent device path" {
    run bash "$HYDRA" persistence /dev/this-does-not-exist-XXX
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
}

@test "persistence refuses a regular file (not a block device)" {
    local f="$BATS_TEST_TMPDIR/not-a-device"
    touch "$f"
    run bash "$HYDRA" persistence "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
}

@test "help output mentions the persistence subcommand" {
    run bash "$HYDRA" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"persistence"* ]]
}

# ---------- Function-level tests (source hydra.sh) ----------

@test "URL constants pick up HYDRA_VENTOY_VERSION env override" {
    HYDRA_VENTOY_VERSION=9.9.9 source "$HYDRA"
    [[ "$VENTOY_URL" == *"v9.9.9/ventoy-9.9.9-linux.tar.gz" ]]
    [[ "$VENTOY_TARBALL" == "ventoy-9.9.9-linux.tar.gz" ]]
}

@test "URL constants pick up HYDRA_UBUNTU_VERSION env override" {
    HYDRA_UBUNTU_VERSION=99.04 source "$HYDRA"
    [[ "$UBUNTU_ISO" == "ubuntu-99.04-desktop-amd64.iso" ]]
    [[ "$UBUNTU_URL" == "https://releases.ubuntu.com/99.04/ubuntu-99.04-desktop-amd64.iso" ]]
}

@test "URL constants pick up HYDRA_KALI_VERSION env override" {
    HYDRA_KALI_VERSION=9999.9 source "$HYDRA"
    [[ "$KALI_ISO" == "kali-linux-9999.9-live-amd64.iso" ]]
    [[ "$KALI_TORRENT_URL" == *"kali-9999.9/kali-linux-9999.9-live-amd64.iso.torrent" ]]
}

@test "ventoy_installer_path dies when extracted dir is missing" {
    source "$HYDRA"
    run ventoy_installer_path
    [ "$status" -ne 0 ]
    [[ "$output" == *"Ventoy not extracted"* ]]
}

@test "ventoy_installer_path returns the script path when present" {
    source "$HYDRA"
    mkdir -p "$VENTOY_EXTRACTED_DIR"
    echo '#!/bin/sh' > "$VENTOY_EXTRACTED_DIR/Ventoy2Disk.sh"
    chmod +x "$VENTOY_EXTRACTED_DIR/Ventoy2Disk.sh"
    run ventoy_installer_path
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ventoy2Disk.sh" ]]
}

@test "validate_usb_device errors with no argument" {
    source "$HYDRA"
    run validate_usb_device ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"no device specified"* ]]
}

@test "validate_usb_device errors on non-block file" {
    source "$HYDRA"
    local f="$BATS_TEST_TMPDIR/regular-file"
    touch "$f"
    run validate_usb_device "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
}

@test "HYDRA_REPO_URL defaults to the CryptoJones Hydra URL" {
    source "$HYDRA"
    [[ "$HYDRA_REPO_URL" == "https://github.com/CryptoJones/Hydra" ]]
}

@test "HYDRA_REPO_URL env var overrides the default" {
    HYDRA_REPO_URL="https://example.test/forked-hydra" source "$HYDRA"
    [[ "$HYDRA_REPO_URL" == "https://example.test/forked-hydra" ]]
}

@test "write_hydra_url_file emits CRLF-terminated InternetShortcut format" {
    source "$HYDRA"
    # Stub sudo so the helper writes as the test user instead of escalating.
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local mnt
    mnt=$(mktemp -d -t hydra-urltest-XXXX)
    HYDRA_REPO_URL="https://example.test/hydra" write_hydra_url_file "$mnt"

    [ -f "$mnt/Hydra.url" ]
    # Format check: section header, URL line, CRLF line endings.
    grep -q '^\[InternetShortcut\]' "$mnt/Hydra.url"
    grep -q '^URL=https://example.test/hydra' "$mnt/Hydra.url"
    # Each line must end with CR LF (\r\n) so Windows honours the .url format.
    [ "$(awk '/\r$/{c++} END{print c}' "$mnt/Hydra.url")" = "2" ]

    rm -rf "$mnt"
}

@test "write_hydra_url_file is idempotent when the file already exists" {
    source "$HYDRA"
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local mnt
    mnt=$(mktemp -d -t hydra-urltest-XXXX)
    printf 'original content\r\n' > "$mnt/Hydra.url"
    local mtime_before
    mtime_before=$(stat -c %Y "$mnt/Hydra.url")
    sleep 1
    write_hydra_url_file "$mnt"
    local mtime_after
    mtime_after=$(stat -c %Y "$mnt/Hydra.url")
    [ "$mtime_before" = "$mtime_after" ]
    # And content must NOT have been overwritten.
    grep -q '^original content' "$mnt/Hydra.url"

    rm -rf "$mnt"
}

# ---------- Sanity: shellcheck-style invariants ----------

@test "hydra.sh has valid bash syntax" {
    run bash -n "$HYDRA"
    [ "$status" -eq 0 ]
}

@test "hydra.sh starts with shebang + SPDX header" {
    run head -3 "$HYDRA"
    [[ "$output" == *"#!/bin/bash"* ]]
    [[ "$output" == *"SPDX-License-Identifier: Apache-2.0"* ]]
}

@test "hydra.sh has a sourcing guard around main" {
    grep -q 'BASH_SOURCE\[0\].*==.*\${0}' "$HYDRA"
}
