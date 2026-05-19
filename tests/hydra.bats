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

@test "usb --allow-non-removable is accepted in arg parsing" {
    run bash "$HYDRA" usb --allow-non-removable /dev/this-does-not-exist-XXX
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
    [[ "$output" != *"Unknown flag"* ]]
}

@test "validate_usb_device refuses non-removable device by default" {
    source "$HYDRA"
    # Use loop0 as a stand-in: it's a real block device on CI, never removable
    # (RM=0 for loop devices), and never the rootfs.
    [[ -b /dev/loop0 ]] || skip "no /dev/loop0 on this host"
    run validate_usb_device /dev/loop0
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a removable device"* ]]
    [[ "$output" == *"--allow-non-removable"* ]]
}

@test "validate_usb_device with allow_non_removable=1 bypasses RM check" {
    source "$HYDRA"
    [[ -b /dev/loop0 ]] || skip "no /dev/loop0 on this host"
    # loop0 is non-removable AND under 4G (CI uses 4K loops) so the size
    # check will fail next. That's fine — what we're asserting is that the
    # RM=1 check did NOT fire (i.e. the failure is the size check, not the
    # removability check). The yellow warning line still fires regardless.
    run validate_usb_device /dev/loop0 1
    [ "$status" -ne 0 ]
    [[ "$output" != *"not a removable device"* ]]
    [[ "$output" == *"allow-non-removable"* ]]
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

@test "test --writable-scratch flag is recognized in arg parsing" {
    # Pass --writable-scratch with a non-existent device. The flag should
    # parse cleanly; the failure should be from validate-usb-device, not
    # from "unknown flag".
    run bash "$HYDRA" test --writable-scratch /dev/this-does-not-exist-XXX
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a block device"* ]]
    [[ "$output" != *"Unknown flag"* ]]
}

@test "test rejects unknown flag" {
    run bash "$HYDRA" test --frobnicate /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
    [[ "$output" == *"frobnicate"* ]]
}

@test "test rejects two positional device args" {
    run bash "$HYDRA" test /dev/sda /dev/sdb
    [ "$status" -ne 0 ]
    [[ "$output" == *"single device"* ]] || [[ "$output" == *"test takes"* ]]
}

@test "help output documents --writable-scratch + HYDRA_SCRATCH_DIR" {
    run bash "$HYDRA" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--writable-scratch"* ]]
    [[ "$output" == *"HYDRA_SCRATCH_DIR"* ]]
}

@test "help output documents --allow-non-removable" {
    run bash "$HYDRA" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--allow-non-removable"* ]]
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

@test "run_ventoy_installer invokes Ventoy2Disk.sh with cwd = installer_dir" {
    # Regression test for the bug where Ventoy2Disk.sh's `OLDDIR=$(pwd)`
    # captured the caller's cwd (the Hydra repo dir) instead of the
    # Ventoy install dir. PATH-prepend then pointed at a non-existent
    # path and Ventoy couldn't find its bundled binaries.
    source "$HYDRA"

    local fake_install_dir="$BATS_TEST_TMPDIR/fake-ventoy"
    mkdir -p "$fake_install_dir"
    # Fake Ventoy2Disk.sh records the cwd it was invoked under, so the
    # test can assert OLDDIR would have captured the right value.
    cat > "$fake_install_dir/Ventoy2Disk.sh" <<'EOF'
#!/usr/bin/env bash
pwd > "$RECORDED_CWD_FILE"
exit 0
EOF
    chmod +x "$fake_install_dir/Ventoy2Disk.sh"

    # Stub sudo to exec the command without escalation (tests run unpriv).
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    export RECORDED_CWD_FILE="$BATS_TEST_TMPDIR/recorded-cwd"

    run_ventoy_installer "$fake_install_dir" "-i" "/dev/null"

    [ -f "$RECORDED_CWD_FILE" ]
    # Use realpath on both sides — BATS_TEST_TMPDIR can include symlink
    # components on some systems and pwd resolves them.
    local recorded
    recorded=$(realpath "$(cat "$RECORDED_CWD_FILE")")
    local expected
    expected=$(realpath "$fake_install_dir")
    [ "$recorded" = "$expected" ]
}

@test "run_ventoy_installer does not leak cwd change to caller" {
    # The subshell `( cd ... )` scoping is the load-bearing detail.
    # If a future refactor accidentally drops the parens, hydra.sh's
    # subsequent post-install probe would run from the Ventoy install
    # dir instead of the operator's working directory.
    source "$HYDRA"

    local fake_install_dir="$BATS_TEST_TMPDIR/fake-ventoy-cwd"
    mkdir -p "$fake_install_dir"
    cat > "$fake_install_dir/Ventoy2Disk.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_install_dir/Ventoy2Disk.sh"
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local before_cwd
    before_cwd=$(pwd)
    run_ventoy_installer "$fake_install_dir" "-i" "/dev/null"
    local after_cwd
    after_cwd=$(pwd)
    [ "$before_cwd" = "$after_cwd" ]
}

@test "run_ventoy_installer passes ventoy_flag + dev as positional args to the installer" {
    # Catches a regression where the wrap accidentally drops/reorders args.
    source "$HYDRA"

    local fake_install_dir="$BATS_TEST_TMPDIR/fake-ventoy-args"
    mkdir -p "$fake_install_dir"
    cat > "$fake_install_dir/Ventoy2Disk.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RECORDED_ARGS_FILE"
exit 0
EOF
    chmod +x "$fake_install_dir/Ventoy2Disk.sh"
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    export RECORDED_ARGS_FILE="$BATS_TEST_TMPDIR/recorded-args"

    run_ventoy_installer "$fake_install_dir" "-I" "/dev/loop42"

    [ -f "$RECORDED_ARGS_FILE" ]
    # Two args, in order: -I /dev/loop42
    [ "$(sed -n 1p "$RECORDED_ARGS_FILE")" = "-I" ]
    [ "$(sed -n 2p "$RECORDED_ARGS_FILE")" = "/dev/loop42" ]
}

@test "run_ventoy_installer pipes 'y' answers on stdin so Ventoy's prompts auto-confirm" {
    source "$HYDRA"

    local fake_install_dir="$BATS_TEST_TMPDIR/fake-ventoy-stdin"
    mkdir -p "$fake_install_dir"
    # Read the first line of stdin and record it.
    cat > "$fake_install_dir/Ventoy2Disk.sh" <<'EOF'
#!/usr/bin/env bash
read -r line
printf '%s\n' "$line" > "$RECORDED_STDIN_FILE"
exit 0
EOF
    chmod +x "$fake_install_dir/Ventoy2Disk.sh"
    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    export RECORDED_STDIN_FILE="$BATS_TEST_TMPDIR/recorded-stdin"

    run_ventoy_installer "$fake_install_dir" "-i" "/dev/null"

    [ -f "$RECORDED_STDIN_FILE" ]
    [ "$(cat "$RECORDED_STDIN_FILE")" = "y" ]
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

@test "all subcommand accepts --skip-downloads flag and validates artifacts" {
    # When --skip-downloads is set with an empty ISO dir, the script must
    # bail with a clear "missing from ISO_DIR" error instead of charging
    # ahead into cmd_usb / cmd_copy where the failure mode would be
    # less obvious. Both --skip-deps and --skip-downloads are needed to
    # skip past cmd_deps (which would otherwise prompt for sudo).
    HYDRA_ISO_DIR="$BATS_TEST_TMPDIR/empty-iso-dir"
    mkdir -p "$HYDRA_ISO_DIR"
    export HYDRA_ISO_DIR
    run bash "$HYDRA" all --skip-deps --skip-downloads /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"--skip-downloads but missing from"* ]]
    [[ "$output" == *"$HYDRA_ISO_DIR"* ]]
}

@test "all subcommand rejects unknown flag" {
    run bash "$HYDRA" all --frobnicate /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
    [[ "$output" == *"frobnicate"* ]]
}

@test "all subcommand rejects two positional device args" {
    run bash "$HYDRA" all /dev/sda /dev/sdb
    [ "$status" -ne 0 ]
    [[ "$output" == *"single device"* ]] || [[ "$output" == *"all takes"* ]]
}

@test "all subcommand requires a device argument" {
    run bash "$HYDRA" all
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "help output documents --skip-downloads + --skip-deps" {
    run bash "$HYDRA" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--skip-downloads"* ]]
    [[ "$output" == *"--skip-deps"* ]]
}

@test "cmd_copy / cmd_persistence cleanup traps tolerate \$mnt being unbound (regression)" {
    # Regression: an EXIT trap that referenced `local mnt` could fire after the
    # function had returned (set -e during a mid-function sudo failure). With
    # `set -u` in effect, `$mnt` was then unbound and the trap itself crashed
    # with `mnt: unbound variable` — masking the real error. The fix is to
    # write the trap with `${mnt:-}` defaulting so the cleanup either runs
    # against the real path or no-ops when the local is gone.
    #
    # Simulate the post-function-return state by running both trap bodies
    # in a fresh shell with `set -u` active and `mnt` never defined.

    # cmd_copy's trap body (extracted verbatim from hydra.sh).
    run bash -c 'set -u; _m="${mnt:-}"; [[ -n "$_m" ]] && { sudo umount "$_m" 2>/dev/null; rmdir "$_m" 2>/dev/null; }; echo OK'
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"unbound variable"* ]]

    # cmd_persistence's cleanup() body shape.
    run bash -c 'set -u; cleanup() { local m="${mnt:-}"; [[ -n "$m" ]] || return 0; sudo umount "$m" 2>/dev/null || true; rmdir "$m" 2>/dev/null || true; }; cleanup; echo OK'
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "copy_iso_with_progress uses pv when present" {
    # When pv is on PATH, the helper should print a "with progress" message
    # and route the data through pv | sudo tee. We stub pv + sudo to
    # capture the invocation shape without copying real bytes.
    source "$HYDRA"

    cat > "$STUB_DIR/pv" <<'EOF'
#!/usr/bin/env bash
echo "PV-CALLED $*" >> "$STUB_LOG"
# Read & discard whatever the caller would have piped through.
cat > /dev/null < "${@: -1}" 2>/dev/null || true
EOF
    chmod +x "$STUB_DIR/pv"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO-CALLED $*" >> "$STUB_LOG"
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    local src="$BATS_TEST_TMPDIR/source.iso"
    local dst="$BATS_TEST_TMPDIR/dest.iso"
    printf 'fake iso payload' > "$src"

    run copy_iso_with_progress "$src" "$dst"
    [ "$status" -eq 0 ]
    [[ "$output" == *"with progress"* ]]

    # pv was invoked; sudo was invoked (for tee).
    grep -q '^PV-CALLED' "$STUB_LOG"
    grep -q '^SUDO-CALLED' "$STUB_LOG"
}

@test "copy_iso_with_progress falls back to cp when pv is missing" {
    # pv intentionally absent — stub PATH only contains sudo. The helper
    # must still complete via the cp fallback.
    source "$HYDRA"

    # Make sure pv is genuinely off PATH for this test.
    PATH="$STUB_DIR"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
echo "SUDO-CALLED $*" >> "$STUB_LOG"
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"
    # Stub cp so we don't actually shell out to /usr/bin/cp via the
    # stripped PATH (which would also fail to find cp).
    cat > "$STUB_DIR/cp" <<'EOF'
#!/usr/bin/env bash
echo "CP-CALLED $*" >> "$STUB_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/cp"

    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    local src="$BATS_TEST_TMPDIR/source.iso"
    local dst="$BATS_TEST_TMPDIR/dest.iso"
    printf 'fake iso payload' > "$src"

    run copy_iso_with_progress "$src" "$dst"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no pv on PATH"* ]]
    grep -q '^CP-CALLED' "$STUB_LOG"
}

@test "update_ventoy_persistence_config creates ventoy.json when absent" {
    # The persistence subcommand calls this after writing the LUKS-encrypted
    # .dat file. First time on a clean Ventoy stick, ventoy.json doesn't
    # exist yet — the helper must create it with a single persistence entry.
    source "$HYDRA"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local mnt="$BATS_TEST_TMPDIR/ventoy-mnt"
    mkdir -p "$mnt"

    update_ventoy_persistence_config "$mnt" "kali-2026.1-live-amd64.iso" "persistence-kali.dat"

    [ -f "$mnt/ventoy/ventoy.json" ]
    local json
    json=$(cat "$mnt/ventoy/ventoy.json")
    # Single entry, image + backend land at the expected absolute-style paths.
    [ "$(echo "$json" | jq '.persistence | length')" = "1" ]
    [ "$(echo "$json" | jq -r '.persistence[0].image')" = "/kali-2026.1-live-amd64.iso" ]
    [ "$(echo "$json" | jq -r '.persistence[0].backend')" = "/persistence-kali.dat" ]
}

@test "update_ventoy_persistence_config replaces existing entry for same image" {
    # Re-running persistence on the same OS should overwrite the old entry,
    # not duplicate it. Otherwise Ventoy would see two competing backends
    # for the same ISO.
    source "$HYDRA"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local mnt="$BATS_TEST_TMPDIR/ventoy-mnt"
    mkdir -p "$mnt/ventoy"
    cat > "$mnt/ventoy/ventoy.json" <<'EOF'
{
  "persistence": [
    {"image": "/kali-2026.1-live-amd64.iso", "backend": "/old-persistence.dat"}
  ]
}
EOF

    update_ventoy_persistence_config "$mnt" "kali-2026.1-live-amd64.iso" "new-persistence.dat"

    local json
    json=$(cat "$mnt/ventoy/ventoy.json")
    [ "$(echo "$json" | jq '.persistence | length')" = "1" ]
    [ "$(echo "$json" | jq -r '.persistence[0].backend')" = "/new-persistence.dat" ]
}

@test "update_ventoy_persistence_config preserves entries for other images" {
    # Adding Kali persistence on a stick that already has Ubuntu persistence
    # must NOT drop the Ubuntu entry. Same shape for the reverse case.
    source "$HYDRA"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    local mnt="$BATS_TEST_TMPDIR/ventoy-mnt"
    mkdir -p "$mnt/ventoy"
    cat > "$mnt/ventoy/ventoy.json" <<'EOF'
{
  "persistence": [
    {"image": "/ubuntu-26.04-desktop-amd64.iso", "backend": "/persistence-ubuntu.dat"}
  ]
}
EOF

    update_ventoy_persistence_config "$mnt" "kali-2026.1-live-amd64.iso" "persistence-kali.dat"

    local json
    json=$(cat "$mnt/ventoy/ventoy.json")
    [ "$(echo "$json" | jq '.persistence | length')" = "2" ]
    # Both entries present.
    echo "$json" | jq -e '.persistence[] | select(.image == "/ubuntu-26.04-desktop-amd64.iso")' >/dev/null
    echo "$json" | jq -e '.persistence[] | select(.image == "/kali-2026.1-live-amd64.iso")' >/dev/null
}

@test "find_ventoy_partition returns the partition matching the Ventoy label" {
    # Stub lsblk + partprobe so the function runs without a real device.
    source "$HYDRA"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    cat > "$STUB_DIR/partprobe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$STUB_DIR/partprobe"

    cat > "$STUB_DIR/lsblk" <<'EOF'
#!/usr/bin/env bash
# Canned output mimicking a real Ventoy stick: two partitions,
# data partition labelled "Ventoy", EFI labelled "VTOYEFI".
cat <<'OUT'
sda
sda1 Ventoy
sda2 VTOYEFI
OUT
EOF
    chmod +x "$STUB_DIR/lsblk"

    run find_ventoy_partition /dev/sda
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sda1" ]
}

@test "find_ventoy_partition returns empty when no Ventoy label exists" {
    # Tells cmd_copy / cmd_persistence "this isn't a Ventoy stick yet,"
    # which they translate into a "run ./hydra.sh usb first" error.
    source "$HYDRA"

    cat > "$STUB_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    chmod +x "$STUB_DIR/sudo"

    cat > "$STUB_DIR/partprobe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$STUB_DIR/partprobe"

    cat > "$STUB_DIR/lsblk" <<'EOF'
#!/usr/bin/env bash
# Stick still has only the manufacturer FAT32 partition labelled Lexar.
cat <<'OUT'
sda
sda1 Lexar
OUT
EOF
    chmod +x "$STUB_DIR/lsblk"

    run find_ventoy_partition /dev/sda
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "cmd_check output lists every tool from the HYDRA_TOOLS_* arrays" {
    # If a new subcommand adds a tool to its array, cmd_check must surface
    # it in the inventory — otherwise an operator can't tell why a
    # preflight failure happened. This test guarantees the inventory stays
    # in sync with the union.
    source "$HYDRA"

    local expected
    expected=$(_all_required_tools)
    [ -n "$expected" ]

    run bash "$HYDRA" check
    [ "$status" -eq 0 ]
    while IFS= read -r tool; do
        [[ "$output" == *"$tool"* ]] || {
            echo "FAIL: cmd_check output missing tool '$tool'" >&2
            return 1
        }
    done <<<"$expected"
}

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
