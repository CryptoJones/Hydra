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

@test "usb rejects an unknown flag" {
    run bash "$HYDRA" usb --frobnicate /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
    [[ "$output" == *"frobnicate"* ]]
}

@test "usb rejects two positional device args" {
    run bash "$HYDRA" usb /dev/sda /dev/sdb
    [ "$status" -ne 0 ]
    [[ "$output" == *"single device"* ]] || [[ "$output" == *"usb takes"* ]]
}

@test "usb --force is accepted in arg parsing" {
    # --force followed by a non-existent device should fail at validate_usb_device,
    # NOT at flag parsing. This proves --force is recognized.
    run bash "$HYDRA" usb --force /dev/this-does-not-exist-XXX
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
    [[ "$output" != *"Unknown flag"* ]]
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

@test "persistence --kali with no value exits with clear error" {
    run bash "$HYDRA" persistence --kali
    [ "$status" -ne 0 ]
    [[ "$output" == *"--kali requires a value"* ]]
}

@test "persistence --ubuntu with no value exits with clear error" {
    run bash "$HYDRA" persistence --ubuntu
    [ "$status" -ne 0 ]
    [[ "$output" == *"--ubuntu requires a value"* ]]
}

@test "persistence rejects an unknown flag" {
    run bash "$HYDRA" persistence --frobnicate /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
    [[ "$output" == *"frobnicate"* ]]
}

@test "persistence rejects --kali max + --ubuntu max (can't both absorb remaining)" {
    run bash "$HYDRA" persistence --kali max --ubuntu max /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"only one can absorb the remaining space"* ]]
}

@test "persistence rejects two positional device args" {
    run bash "$HYDRA" persistence /dev/sda /dev/sdb
    [ "$status" -ne 0 ]
    [[ "$output" == *"single device"* ]] || [[ "$output" == *"persistence takes"* ]]
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

@test "ventoy_installer_path auto-extracts when tarball is present but dir is missing" {
    source "$HYDRA"
    # Stage a minimal Ventoy tarball: ventoy-${VERSION}/Ventoy2Disk.sh
    local stage="$BATS_TEST_TMPDIR/stage"
    mkdir -p "$stage/ventoy-${HYDRA_VENTOY_VERSION}"
    echo '#!/bin/sh' > "$stage/ventoy-${HYDRA_VENTOY_VERSION}/Ventoy2Disk.sh"
    chmod +x "$stage/ventoy-${HYDRA_VENTOY_VERSION}/Ventoy2Disk.sh"
    tar -czf "$HYDRA_ISO_DIR/$VENTOY_TARBALL" -C "$stage" "ventoy-${HYDRA_VENTOY_VERSION}"
    [ ! -d "$VENTOY_EXTRACTED_DIR" ]

    run ventoy_installer_path
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ventoy2Disk.sh" ]]
    # Side-effect: the dir is now extracted.
    [ -d "$VENTOY_EXTRACTED_DIR" ]
    [ -x "$VENTOY_EXTRACTED_DIR/Ventoy2Disk.sh" ]
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

@test "preflight_tools passes when every tool is present" {
    source "$HYDRA"
    # cat is universally on PATH; use it as the trivially-present stand-in.
    run preflight_tools "fake-context" cat ls
    [ "$status" -eq 0 ]
}

@test "preflight_tools dies with the missing tools listed in context" {
    source "$HYDRA"
    run preflight_tools "usb" hydra-fake-tool-A hydra-fake-tool-B
    [ "$status" -ne 0 ]
    [[ "$output" == *"usb needs these tools"* ]]
    [[ "$output" == *"hydra-fake-tool-A"* ]]
    [[ "$output" == *"hydra-fake-tool-B"* ]]
    [[ "$output" == *"./hydra.sh deps"* ]]
}

@test "preflight_tools reports only the missing ones, not the present ones" {
    source "$HYDRA"
    run preflight_tools "test-ctx" cat hydra-fake-tool ls
    [ "$status" -ne 0 ]
    [[ "$output" == *"hydra-fake-tool"* ]]
    # 'cat' and 'ls' both exist; should not be in the missing list.
    [[ "$output" != *"PATH: cat"* ]]
}

@test "ensure_mkexfatfs_alias is a no-op when mkexfatfs already exists" {
    source "$HYDRA"
    # Stub mkexfatfs into PATH (already on STUB_DIR, which is at the front).
    cat > "$STUB_DIR/mkexfatfs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$STUB_DIR/mkexfatfs"

    # sudo would prove we tried to symlink; stub it to record any call.
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO-CALLED $*" >&2
EOF
    chmod +x "$STUB_DIR/sudo"

    run ensure_mkexfatfs_alias
    [ "$status" -eq 0 ]
    # No sudo invocation should have happened.
    [[ "$output" != *"SUDO-CALLED"* ]]
    [[ "$stderr" != *"SUDO-CALLED"* ]] || true  # bats merges streams by default
}

@test "ensure_mkexfatfs_alias does nothing when neither binary is present" {
    source "$HYDRA"
    # Wipe both names out of the test PATH by setting PATH to only the stub dir,
    # which currently contains neither binary.
    PATH="$STUB_DIR"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO-CALLED $*" >&2
exit 0
EOF
    chmod +x "$STUB_DIR/sudo"

    run ensure_mkexfatfs_alias
    [ "$status" -eq 0 ]
    [[ "$output" != *"SUDO-CALLED"* ]]
}

@test "ensure_mkexfatfs_alias symlinks when mkexfatfs missing but mkfs.exfat present" {
    source "$HYDRA"
    # mkfs.exfat is present; mkexfatfs is not.
    cat > "$STUB_DIR/mkfs.exfat" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$STUB_DIR/mkfs.exfat"

    # sudo stub: capture the ln invocation it would have run.
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO: $*"
exit 0
EOF
    chmod +x "$STUB_DIR/sudo"

    run ensure_mkexfatfs_alias
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUDO:"* ]]
    [[ "$output" == *"ln -sf"* ]]
    [[ "$output" == *"mkfs.exfat"* ]]
    [[ "$output" == *"mkexfatfs"* ]]
}

@test "_all_required_tools is sorted, de-duplicated, and includes critical names" {
    source "$HYDRA"
    local out
    out=$(_all_required_tools)
    # Sample tools we know each subcommand needs.
    grep -qx 'wget' <<<"$out"
    grep -qx 'cryptsetup' <<<"$out"
    grep -qx 'mkfs.ext4' <<<"$out"
    grep -qx 'mkfs.exfat' <<<"$out"
    grep -qx 'qemu-system-x86_64' <<<"$out"
    # De-duplication: 'sudo' appears in multiple arrays, must appear once.
    [ "$(grep -c '^sudo$' <<<"$out")" = "1" ]
    # Sorted: 'aria2c' < 'wget'.
    local first last
    first=$(head -n1 <<<"$out")
    last=$(tail -n1 <<<"$out")
    [[ "$first" < "$last" ]] || [[ "$first" == "$last" ]]
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

@test "resolve_persistence_size: explicit '2G' resolves to 2 GiB in bytes" {
    source "$HYDRA"
    run resolve_persistence_size "2G" $((10*1024*1024*1024)) "Kali" "exfat"
    [ "$status" -eq 0 ]
    [ "$output" = "$((2 * 1024 * 1024 * 1024))" ]
}

@test "resolve_persistence_size: 'max' returns the remaining budget" {
    source "$HYDRA"
    run resolve_persistence_size "max" $((3*1024*1024*1024)) "Kali" "exfat"
    [ "$status" -eq 0 ]
    [ "$output" = "$((3 * 1024 * 1024 * 1024))" ]
}

@test "resolve_persistence_size: empty spec returns 0" {
    source "$HYDRA"
    run resolve_persistence_size "" $((10*1024*1024*1024)) "Kali" "exfat"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "resolve_persistence_size: rejects garbage spec" {
    source "$HYDRA"
    run resolve_persistence_size "not-a-size" $((10*1024*1024*1024)) "Kali" "exfat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid"* ]] || [[ "$output" == *"not-a-size"* ]]
}

@test "resolve_persistence_size: under 256 MiB floor dies" {
    source "$HYDRA"
    run resolve_persistence_size "100M" $((10*1024*1024*1024)) "Kali" "exfat"
    [ "$status" -ne 0 ]
    [[ "$output" == *"256 MiB floor"* ]] || [[ "$output" == *"256 MiB"* ]]
}

@test "resolve_persistence_size: FAT32 caps single file at 4 GiB - 1" {
    source "$HYDRA"
    # 10G requested on vfat: should silently cap at 4 GiB - 1 = 4294967295.
    # The cap warning lands on stderr; capture only stdout for the value.
    local out
    out=$(resolve_persistence_size "10G" $((20*1024*1024*1024)) "Kali" "vfat" 2>/dev/null)
    [ "$out" = "4294967295" ]
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
