#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Aaron K. Clark
#
# Hydra — Multi-OS Ventoy USB builder + VM-based boot tester.
#
# Builds a Ventoy USB stick that boots multiple ISOs (Ubuntu LTS desktop +
# Kali Linux Live by default), then optionally spins up a local QEMU VM that
# boots from the physical USB so you can verify it before staking a reboot on
# it.
#
# Usage:
#   ./hydra.sh check                  Show host readiness, USB candidates, ISO inventory.
#   ./hydra.sh deps                   Install required tools (aria2, ventoy, qemu). Needs sudo.
#   ./hydra.sh download               Download Ventoy + Ubuntu + Kali ISOs (idempotent).
#   ./hydra.sh usb </dev/sdX> [--force] [--allow-non-removable] [--gpt] [--vault SIZE]
#                                      Install Ventoy onto the named USB device. DESTRUCTIVE.
#                                      --force reinstalls over an existing Ventoy stick.
#                                      --allow-non-removable bypasses the kernel RM=1
#                                        check — needed for USB-attached SSDs/NVMe
#                                        enclosures, which present as non-removable
#                                        even though they're hot-pluggable.
#                                      --gpt installs with a GPT partition table
#                                        instead of Ventoy's MBR default. Pick GPT
#                                        for >2 TB drives or modern UEFI-only systems.
#                                      --vault SIZE reserves a tail of the drive (iec
#                                        size like '16G' or '512M') and carves a
#                                        standalone LUKS2-encrypted vault (ext4 inside)
#                                        into it AFTER the Ventoy install. Implies
#                                        --gpt. The vault is SEALED — you set the
#                                        passphrase interactively, it's stored nowhere,
#                                        and nothing auto-unlocks it on boot. This is a
#                                        general-purpose encrypted partition, distinct
#                                        from per-ISO `persistence` files. NOTE: the
#                                        boot ISOs stay plaintext (Ventoy must read them
#                                        to boot) — put sensitive data in the vault, not
#                                        on the Ventoy partition.
#   ./hydra.sh copy </dev/sdX> [--from <DIR|/dev/sdY>]
#                                      Copy downloaded ISOs to the Ventoy partition.
#                                      Also copies the file named in
#                                      HYDRA_WINDOWS_ISO (if set) — see env vars below.
#                                      --from <DIR>: copy every *.iso in that
#                                        directory instead of the fixed
#                                        Ubuntu+Kali set (use ISOs already on hand,
#                                        no re-download).
#                                      --from </dev/sdY>: clone the ISOs off an
#                                        existing Ventoy stick — mounted READ-ONLY,
#                                        never written. Pair with `usb` to rebuild a
#                                        bigger stick:
#                                          ./hydra.sh usb /dev/sdNEW
#                                          ./hydra.sh copy /dev/sdNEW --from /dev/sdOLD
#   ./hydra.sh persistence </dev/sdX> [--kali SIZE] [--ubuntu SIZE]
#                                      Add LUKS-encrypted persistence file(s) on the
#                                      Ventoy partition. SIZE accepts iec values like
#                                      '2G' or '500M', or 'max' to consume the rest of
#                                      the free space (one OS only). Default (no
#                                      flags): Kali takes everything available.
#                                      Each enabled OS prompts for its own passphrase.
#   ./hydra.sh test </dev/sdX> [--writable-scratch]
#                                      Boot a QEMU VM from the physical USB.
#                                      --writable-scratch: copy the stick to a temp
#                                        image first; QEMU mutates the copy, the real
#                                        stick is untouched. Required to verify
#                                        Ventoy persistence in QEMU.
#   ./hydra.sh all </dev/sdX> [--skip-downloads] [--skip-deps] [--allow-non-removable] [--gpt]
#                                      Run deps -> download -> usb -> copy -> test.
#                                      --skip-downloads: ISOs + Ventoy tarball are
#                                        already on disk; don't touch the network.
#                                      --skip-deps: deps already installed; don't
#                                        run apt/dnf/pacman.
#                                      --allow-non-removable: forwarded to `usb`
#                                        (see above).
#                                      --gpt: forwarded to `usb` (see above).
#
# Env overrides:
#   HYDRA_ISO_DIR              Where ISOs and Ventoy archive live (default ~/Downloads/iso)
#   HYDRA_VENTOY_VERSION       Default v1.1.12
#   HYDRA_UBUNTU_VERSION       Default 26.04   (LTS — change to 24.04 for prior LTS)
#   HYDRA_KALI_VERSION         Default 2026.1
#   HYDRA_VM_MEMORY            QEMU RAM in MB (default 4096)
#   HYDRA_VM_VCPUS             QEMU vCPU count (default 2)
#   HYDRA_SCRATCH_DIR          Where --writable-scratch writes its temp image
#                              (default /var/tmp — disk-backed, multi-GB safe)
#   HYDRA_WINDOWS_ISO          Absolute path to a Windows ISO (e.g. Win11_25H2_x64.iso).
#                              When set, `copy` also drops this ISO onto the Ventoy
#                              partition so Windows installers appear in the boot menu
#                              alongside Ubuntu + Kali. Unset by default — Microsoft
#                              doesn't offer a stable direct URL, so this is BYO.
#
# Safety:
#   The `usb` and `all` subcommands write to a block device. The script
#   refuses to run unless the device is non-empty, removable, and not the
#   host root. A second confirmation prompt is required before any write.
#
# License: Apache 2.0 — see LICENSE.

set -euo pipefail

# ---------- configuration ----------

HYDRA_ISO_DIR="${HYDRA_ISO_DIR:-$HOME/Downloads/iso}"
HYDRA_VENTOY_VERSION="${HYDRA_VENTOY_VERSION:-1.1.12}"
HYDRA_UBUNTU_VERSION="${HYDRA_UBUNTU_VERSION:-26.04}"
HYDRA_KALI_VERSION="${HYDRA_KALI_VERSION:-2026.1}"
HYDRA_VM_MEMORY="${HYDRA_VM_MEMORY:-4096}"
HYDRA_VM_VCPUS="${HYDRA_VM_VCPUS:-2}"

# Optional path to a Windows ISO. When set, cmd_copy drops it onto the
# Ventoy partition alongside Ubuntu + Kali. Unset = no Windows entry.
HYDRA_WINDOWS_ISO="${HYDRA_WINDOWS_ISO:-}"

VENTOY_TARBALL="ventoy-${HYDRA_VENTOY_VERSION}-linux.tar.gz"
VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v${HYDRA_VENTOY_VERSION}/${VENTOY_TARBALL}"
VENTOY_EXTRACTED_DIR="${HYDRA_ISO_DIR}/ventoy-${HYDRA_VENTOY_VERSION}"

UBUNTU_ISO="ubuntu-${HYDRA_UBUNTU_VERSION}-desktop-amd64.iso"
UBUNTU_URL="https://releases.ubuntu.com/${HYDRA_UBUNTU_VERSION}/${UBUNTU_ISO}"

KALI_ISO="kali-linux-${HYDRA_KALI_VERSION}-live-amd64.iso"
KALI_TORRENT="${KALI_ISO}.torrent"
KALI_TORRENT_URL="https://cdimage.kali.org/kali-${HYDRA_KALI_VERSION}/${KALI_TORRENT}"

# Project URL — written to the Ventoy partition as a .url shortcut so anyone
# who plugs the stick into a Windows host can double-click to land on the
# project page. Override with HYDRA_REPO_URL=... if you fork.
HYDRA_REPO_URL="${HYDRA_REPO_URL:-https://github.com/CryptoJones/Hydra}"

# ---------- tool inventory ----------
#
# Every external binary the script invokes, grouped by the subcommand that
# needs it. coreutils + grep / sed / awk / printf are assumed-present on any
# Linux box and not enumerated.
#
# `cmd_check` displays the union of these so an operator can see at a glance
# what's installed. Each `cmd_X` calls `preflight_tools` against its array
# so it fails fast with a clear message before doing real work.

HYDRA_TOOLS_DOWNLOAD=(wget curl tar aria2c)
HYDRA_TOOLS_USB=(lsblk partprobe findmnt parted sgdisk dd mkfs.exfat sudo)
HYDRA_TOOLS_COPY=(lsblk partprobe findmnt mount umount sudo)
HYDRA_TOOLS_PERSISTENCE=(lsblk partprobe findmnt mount umount mkfs.ext4 cryptsetup jq numfmt fallocate dd df sudo)
HYDRA_TOOLS_TEST=(qemu-system-x86_64 sudo)

# ---------- ui helpers ----------

c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { c_red "ERROR: $*" >&2; exit 1; }

# Verify every name in the array exists on $PATH. Dies with the missing
# names + a pointer at `./hydra.sh deps` if any are missing. Tools are
# tested via `command -v` so shell builtins (printf, etc.) wouldn't be
# valid inputs — only real binaries.
preflight_tools() {
    local context="$1"; shift
    local missing=()
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if (( ${#missing[@]} > 0 )); then
        die "$context needs these tools, but they aren't on PATH: ${missing[*]}. Run: ./hydra.sh deps"
    fi
}

# Sorted, de-duplicated union of all per-subcommand tool arrays. Used by
# cmd_check to show one global inventory.
_all_required_tools() {
    printf '%s\n' \
        "${HYDRA_TOOLS_DOWNLOAD[@]}" \
        "${HYDRA_TOOLS_USB[@]}" \
        "${HYDRA_TOOLS_COPY[@]}" \
        "${HYDRA_TOOLS_PERSISTENCE[@]}" \
        "${HYDRA_TOOLS_TEST[@]}" \
        | sort -u
}

# Ventoy 1.1.x's internal tooling calls `mkexfatfs` — the legacy binary
# name shipped by the now-deprecated `exfat-utils` package. Modern distros
# replaced that package with `exfatprogs`, which provides the same tool
# under the new name `mkfs.exfat` and does NOT install the old name.
#
# Result: Ventoy silently fails to format the data partition with a
# "mkexfatfs: command not found" warning, then exits 0 anyway. Our
# post-install probe catches the bad-install state, but the operator
# is left wondering what to do.
#
# This helper makes the workaround automatic: when `mkexfatfs` is missing
# but `mkfs.exfat` is present, symlink the modern binary under the legacy
# name in /usr/local/sbin (writable, on PATH, doesn't pollute distro dirs).
# Idempotent: if the symlink is already in place, nothing changes.
ensure_mkexfatfs_alias() {
    command -v mkexfatfs >/dev/null 2>&1 && return 0
    local mkfs_exfat
    mkfs_exfat=$(command -v mkfs.exfat 2>/dev/null) || return 0
    local link_path="/usr/local/sbin/mkexfatfs"
    c_yellow "  mkexfatfs missing; symlinking $link_path -> $mkfs_exfat for Ventoy compatibility"
    sudo ln -sf "$mkfs_exfat" "$link_path"
}

# ---------- subcommands ----------

cmd_check() {
    c_bold "=== Hydra: host readiness ==="
    echo "ISO dir:           $HYDRA_ISO_DIR"
    echo "Ventoy version:    $HYDRA_VENTOY_VERSION"
    echo "Ubuntu version:    $HYDRA_UBUNTU_VERSION"
    echo "Kali version:      $HYDRA_KALI_VERSION"
    echo ""
    c_bold "--- required tools ---"
    local t
    while IFS= read -r t; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  %-20s %s\n' "$t" "$(c_green ok)"
        else
            printf '  %-20s %s\n' "$t" "$(c_yellow missing)"
        fi
    done < <(_all_required_tools)
    echo ""
    c_bold "--- downloaded artifacts ---"
    mkdir -p "$HYDRA_ISO_DIR"
    for f in "$VENTOY_TARBALL" "$UBUNTU_ISO" "$KALI_ISO"; do
        if [[ -f "$HYDRA_ISO_DIR/$f" ]]; then
            printf '  %-50s %s\n' "$f" "$(c_green "$(du -h "$HYDRA_ISO_DIR/$f" | cut -f1)")"
        else
            printf '  %-50s %s\n' "$f" "$(c_yellow missing)"
        fi
    done
    if [[ -n "${HYDRA_WINDOWS_ISO:-}" ]]; then
        if [[ -f "$HYDRA_WINDOWS_ISO" ]]; then
            printf '  %-50s %s\n' "$(basename "$HYDRA_WINDOWS_ISO") (Windows)" \
                "$(c_green "$(du -h "$HYDRA_WINDOWS_ISO" | cut -f1)")"
        else
            printf '  %-50s %s\n' "HYDRA_WINDOWS_ISO=$HYDRA_WINDOWS_ISO" "$(c_yellow "not found")"
        fi
    else
        printf '  %-50s %s\n' "HYDRA_WINDOWS_ISO" "$(c_yellow "unset — no Windows entry")"
    fi
    echo ""
    c_bold "--- removable block devices (USB candidates) ---"
    lsblk -dn -o NAME,SIZE,TYPE,RM,RO,MODEL,TRAN 2>/dev/null \
      | awk '$3=="disk" && $4=="1" {print "  /dev/"$0}'
    if [[ -z "$(lsblk -dn -o NAME,RM 2>/dev/null | awk '$2==1{print $1}')" ]]; then
        c_yellow "  (no removable disks detected — plug in the USB and retry)"
    fi
}

cmd_deps() {
    c_bold "=== Installing required tools (needs sudo) ==="
    # Detect package manager
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y aria2 qemu-system-x86 qemu-utils ovmf parted gdisk cryptsetup jq exfatprogs pv wget curl tar bats
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y aria2 qemu-system-x86 qemu-img edk2-ovmf parted gdisk cryptsetup jq exfatprogs pv wget curl tar bats
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm aria2 qemu-base edk2-ovmf parted gptfdisk cryptsetup jq exfatprogs pv wget curl tar bats
    else
        die "Unsupported package manager. Install: aria2 qemu-system-x86 ovmf parted gdisk cryptsetup jq exfatprogs pv manually."
    fi
    # Ventoy 1.1.x still calls mkexfatfs; modern exfatprogs only ships
    # mkfs.exfat. Bridge the gap here so the next `hydra usb` doesn't fail.
    ensure_mkexfatfs_alias
    c_green "Dependencies installed."
}

cmd_download() {
    preflight_tools "download" "${HYDRA_TOOLS_DOWNLOAD[@]}"
    mkdir -p "$HYDRA_ISO_DIR"
    cd "$HYDRA_ISO_DIR"

    c_bold "=== Downloading Ventoy ${HYDRA_VENTOY_VERSION} ==="
    if [[ -f "$VENTOY_TARBALL" ]]; then
        c_green "  already present, skipping."
    else
        wget -c "$VENTOY_URL"
    fi

    if [[ ! -d "$VENTOY_EXTRACTED_DIR" ]]; then
        echo "  extracting..."
        tar -xzf "$VENTOY_TARBALL" -C "$HYDRA_ISO_DIR"
    fi

    c_bold "=== Downloading Ubuntu ${HYDRA_UBUNTU_VERSION} Desktop LTS ==="
    if [[ -f "$UBUNTU_ISO" ]]; then
        c_green "  already present, skipping."
    else
        wget -c "$UBUNTU_URL"
    fi

    c_bold "=== Downloading Kali ${HYDRA_KALI_VERSION} Live (via torrent) ==="
    if [[ -f "$KALI_ISO" ]]; then
        c_green "  already present, skipping."
    else
        command -v aria2c >/dev/null 2>&1 || die "aria2c missing — run: ./hydra.sh deps"
        wget -c "$KALI_TORRENT_URL"
        # aria2c will seed briefly after completion; --seed-time=0 stops immediately.
        aria2c --seed-time=0 --dir="$HYDRA_ISO_DIR" "$KALI_TORRENT"
    fi

    c_bold "--- final inventory ---"
    ls -lh "$HYDRA_ISO_DIR"/*.iso "$HYDRA_ISO_DIR"/*.tar.gz 2>/dev/null || true
}

# Invoke Ventoy2Disk.sh with cwd set to its install directory. Critical
# because Ventoy2Disk.sh captures `OLDDIR=$(pwd)` on its first line and
# then prepends `$OLDDIR/tool/$TOOLDIR` to PATH. Launching from anywhere
# else leaves Ventoy's bundled `mkexfatfs` / `vtoycli` binaries
# unreachable, its internal tool-check fails, and the install bails out
# with a generic "Some tools can not run" message — silently exiting 0
# anyway, which our post-install probe is now hardened against (see
# the previous PR) but is still ugly to hit.
#
# Wrapping the invocation in a subshell `( ... )` scopes the cwd change
# so the caller's directory is untouched on return.
#
# Args:
#   $1  installer_dir  — directory containing Ventoy2Disk.sh
#   $2  ventoy_flag    — -i (install) or -I (force reinstall)
#   $3  dev            — target block device, e.g. /dev/sda
#   $4  use_gpt        — optional, 1 to pass `-g` (GPT layout). Defaults to
#                        empty/0 (MBR), matching Ventoy's own default.
#   $5  reserve_mb     — optional MiB to leave UNALLOCATED at the end of the
#                        disk via Ventoy's `-r`. 0/absent = no reserve. Used
#                        by `usb --vault` to carve a LUKS tail afterward.
#
# Pipes `yes` to satisfy Ventoy's interactive y/n prompts (it has no
# non-interactive flag of its own).
run_ventoy_installer() {
    local installer_dir="$1" ventoy_flag="$2" dev="$3" use_gpt="${4:-0}" reserve_mb="${5:-0}"
    local -a args=("$ventoy_flag")
    (( use_gpt )) && args+=("-g")
    (( reserve_mb > 0 )) && args+=("-r" "$reserve_mb")
    args+=("$dev")
    # `yes` feeds Ventoy's endless y/n prompts; when Ventoy exits first, `yes`
    # gets SIGPIPE (exit 141). With `pipefail` on (set at the top of this
    # script) that 141 would mask Ventoy2Disk.sh's own exit status, so scope
    # pipefail OFF for just this pipeline — we care about the installer's
    # result, not yes's.
    ( cd "$installer_dir" && set +o pipefail && yes | sudo ./Ventoy2Disk.sh "${args[@]}" )
}

# Resolve the Ventoy installer path inside the extracted dir.
# Auto-extracts if the tarball is present but the dir hasn't been unpacked yet
# (common state when a prior session downloaded but the user jumped straight to
# `usb` in a new session). Only dies if BOTH the dir and the tarball are missing.
ventoy_installer_path() {
    local p="$VENTOY_EXTRACTED_DIR/Ventoy2Disk.sh"
    if [[ ! -x "$p" ]]; then
        local tarball="$HYDRA_ISO_DIR/$VENTOY_TARBALL"
        if [[ -f "$tarball" ]]; then
            echo "  Extracting $VENTOY_TARBALL..." >&2
            tar -xzf "$tarball" -C "$HYDRA_ISO_DIR"
        fi
    fi
    [[ -x "$p" ]] || die "Ventoy not extracted at $VENTOY_EXTRACTED_DIR. Run: ./hydra.sh download"
    printf '%s' "$p"
}

# Validate that the named device looks like a USB stick and is not the rootfs.
# Pass allow_non_removable=1 to bypass the kernel RM=1 check — USB-attached
# SSDs/NVMe enclosures report RM=0 even though the enclosure is hot-pluggable.
validate_usb_device() {
    local dev="${1:-}"
    local allow_non_removable="${2:-0}"
    [[ -n "$dev" ]] || die "no device specified. Usage: ./hydra.sh usb /dev/sdX"
    [[ -b "$dev" ]] || die "$dev is not a block device."

    local name="${dev#/dev/}"
    local rm size_bytes
    rm=$(lsblk -dn -o RM "$dev" 2>/dev/null | tr -d ' ')
    size_bytes=$(lsblk -dn -b -o SIZE "$dev" 2>/dev/null | tr -d ' ')

    if [[ "$rm" != "1" ]]; then
        if (( allow_non_removable )); then
            c_yellow "--allow-non-removable: $dev reports RM=0 but caller insists. Proceeding."
        else
            die "$dev is not a removable device. Refusing to write. (Pass --allow-non-removable if this is a USB-attached SSD/NVMe enclosure.)"
        fi
    fi

    # Sanity-check size: 4 GB minimum, 2 TB maximum (any larger is suspicious for USB).
    if (( size_bytes < 4*1024*1024*1024 )); then
        die "$dev is smaller than 4 GB ($size_bytes bytes). Ventoy + ISOs won't fit."
    fi
    if (( size_bytes > 2*1024*1024*1024*1024 )); then
        die "$dev is larger than 2 TB. Aborting — this is unusual for a Ventoy USB; verify the device."
    fi

    # Make sure it does NOT host the running rootfs.
    local root_dev
    root_dev=$(findmnt -no SOURCE / 2>/dev/null | sed -E 's|^/dev/mapper/||; s|[0-9]+$||')
    if [[ "$name" == "${root_dev}" || "$dev" == "/dev/${root_dev}"* ]]; then
        die "$dev appears to back the host root filesystem. Refusing to write."
    fi
}

# Resolve a vault SIZE spec (iec like '16G' / '512M') to whole MiB for
# Ventoy's `-r` reserve flag. Dies on garbage; enforces a 256 MiB floor so
# the LUKS2 header + a usable ext4 fit. Pure + unit-tested.
vault_reserve_mib() {
    local size_spec="$1"
    local bytes
    bytes=$(numfmt --from=iec "$size_spec" 2>/dev/null) \
        || die "vault size '$size_spec' is not valid. Try '16G', '512M', or '2G'."
    (( bytes >= 256 * 1024 * 1024 )) \
        || die "vault size resolved to $(numfmt --to=iec --suffix=B "$bytes"); under the 256 MiB floor."
    printf '%s' "$(( bytes / (1024 * 1024) ))"
}

# Build a partition device node from a disk + partition number, handling the
# NVMe/mmc `p` infix (/dev/sdb + 3 -> /dev/sdb3; /dev/nvme0n1 + 3 ->
# /dev/nvme0n1p3). Pure + unit-tested.
partition_node() {
    local dev="$1" num="$2"
    [[ "$dev" == *[0-9] ]] && printf '%s' "${dev}p${num}" || printf '%s' "${dev}${num}"
}

# Highest existing partition number on a disk, plus one. After a Ventoy GPT
# install the disk has p1 (data) + p2 (VTOYEFI), so this returns 3 — the slot
# for the vault. Pure (reads only lsblk); unit-tested with a stubbed lsblk.
next_partition_number() {
    local dev="$1" name max=0 n
    local base="${dev#/dev/}"
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != "$base" ]] || continue
        n="${name##*[!0-9]}"          # trailing digits = partition number
        [[ -n "$n" ]] || continue
        (( n > max )) && max="$n"
    done < <(lsblk -ln -o NAME "$dev" | tr -d ' ')
    printf '%s' "$(( max + 1 ))"
}

# Carve a LUKS2 encrypted vault into the unallocated tail Ventoy reserved
# (via -r). ext4 inside. The passphrase is entered interactively and stored
# NOWHERE; nothing auto-opens it on boot (no crypttab, no keyfile). Sealed
# until the operator runs `cryptsetup open` by hand.
create_vault_partition() {
    local dev="$1"
    local partnum part
    partnum=$(next_partition_number "$dev")
    part=$(partition_node "$dev" "$partnum")

    c_bold "=== Creating encrypted vault ($part) ==="
    echo "  Carving the reserved tail into a LUKS2 partition..."
    # 0:0 = whole largest free block (the reserved tail); 8309 = Linux LUKS.
    sudo sgdisk -n "${partnum}:0:0" -t "${partnum}:8309" -c "${partnum}:vault" "$dev" >/dev/null \
        || die "sgdisk failed to create the vault partition on $dev."
    sudo partprobe "$dev" 2>/dev/null || true
    sudo udevadm settle 2>/dev/null || true
    for _ in $(seq 1 15); do [[ -b "$part" ]] && break; sleep 1; done
    [[ -b "$part" ]] || die "vault partition $part never appeared after sgdisk."

    echo ""
    echo "  Set a passphrase for the vault. There is NO recovery if you forget"
    echo "  it — Hydra stores it nowhere, and nothing auto-unlocks it on boot."
    local mapper="hydra-vault-$$"
    sudo cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$part" \
        || die "LUKS format failed for the vault."
    sudo cryptsetup open "$part" "$mapper" \
        || die "luksOpen failed for the vault."
    sudo mkfs.ext4 -q -L vault "/dev/mapper/$mapper" \
        || { sudo cryptsetup close "$mapper" 2>/dev/null || true; die "mkfs.ext4 failed for the vault."; }
    sudo cryptsetup close "$mapper"

    c_green "Encrypted vault ready on $part (ext4 inside LUKS2, sealed)."
    echo "  Open:    sudo cryptsetup open $part vault && sudo mount /dev/mapper/vault /mnt"
    echo "  Re-seal: sudo umount /mnt && sudo cryptsetup close vault"
}

cmd_usb() {
    local dev="" force=0 allow_non_removable=0 use_gpt=0 vault_spec="" vault_mib=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=1; shift ;;
            --allow-non-removable)
                allow_non_removable=1; shift ;;
            --gpt)
                use_gpt=1; shift ;;
            --vault)
                [[ -n "${2:-}" ]] || die "--vault requires a SIZE value (e.g. '16G', '512M')."
                vault_spec="$2"; shift 2 ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$dev" ]] || die "usb takes a single device argument (got '$dev' and '$1')."
                dev="$1"; shift ;;
        esac
    done

    # A vault reserves a LUKS2 tail. Resolve its size now (fails fast on a bad
    # spec, before any destructive work) and force GPT — the vault is carved
    # as a 3rd GPT partition, so Ventoy must lay down a GPT table with a
    # reserved tail to hold it.
    if [[ -n "$vault_spec" ]]; then
        vault_mib=$(vault_reserve_mib "$vault_spec")
        if (( ! use_gpt )); then
            use_gpt=1
            c_yellow "--vault: forcing GPT layout (required to carve the encrypted vault partition)."
        fi
    fi

    preflight_tools "usb" "${HYDRA_TOOLS_USB[@]}"
    validate_usb_device "$dev" "$allow_non_removable"
    # The vault step needs cryptsetup + mkfs.ext4. Check AFTER validate so a
    # bad device still fails with the clear "not a block device" message
    # first (and so the no-vault path never requires these tools).
    if [[ -n "$vault_spec" ]]; then
        preflight_tools "usb --vault" cryptsetup mkfs.ext4
    fi
    # Runtime safety net: even if the operator skipped `./hydra.sh deps`,
    # make sure Ventoy can find the legacy exFAT format binary before we
    # commit to writing the stick.
    ensure_mkexfatfs_alias

    c_bold "=== Hydra: Ventoy install onto $dev ==="
    lsblk "$dev" || true
    echo ""
    if (( force )); then
        c_yellow "--force: reinstalling Ventoy (any existing Ventoy install AND its data will be wiped)."
    fi
    if (( use_gpt )); then
        c_yellow "--gpt: writing GPT partition table (Ventoy default is MBR)."
    fi
    if [[ -n "$vault_spec" ]]; then
        c_yellow "--vault: reserving ${vault_mib} MiB at the end of $dev for a LUKS2 encrypted vault (set up after the Ventoy install)."
    fi
    # "Now you know. And knowing is half the battle." — G.I. Joe (1985)
    # Hydra's job before the destructive write is to make sure you know what
    # you're about to wipe. lsblk above shows the contents; the line below
    # makes the consequence unambiguous; the retype-the-device prompt that
    # follows is the final gate.
    c_red "THIS WILL ERASE EVERYTHING ON $dev."
    echo -n "Type the device name to confirm (e.g. /dev/sdb): "
    read -r confirm
    [[ "$confirm" == "$dev" ]] || die "Confirmation mismatch ($confirm != $dev). Aborting."

    # -i = fresh install (refuses if Ventoy is already there).
    # -I = force reinstall over existing Ventoy.
    local ventoy_flag="-i"
    (( force )) && ventoy_flag="-I"
    # Confirm Ventoy is extracted before delegating (this helper also
    # auto-extracts the tarball if needed).
    ventoy_installer_path >/dev/null
    run_ventoy_installer "$VENTOY_EXTRACTED_DIR" "$ventoy_flag" "$dev" "$use_gpt" "$vault_mib"

    # POST-INSTALL VERIFICATION. Ventoy2Disk.sh can exit 0 even when
    # critical tools (mkfs.exfat / mkexfatfs) were missing and the data
    # partition wasn't created. Re-probe for the labelled partition; if
    # it isn't there, the install failed regardless of Ventoy's exit code.
    sudo partprobe "$dev" 2>/dev/null || true
    sleep 2
    local part
    part=$(find_ventoy_partition "$dev")
    if [[ -z "$part" ]]; then
        die "Ventoy2Disk.sh exited 0 but no 'Ventoy'-labelled partition appeared on $dev. The install did NOT take. Check the Ventoy output above for missing tools (e.g. mkfs.exfat / mkexfatfs) and re-run after installing them."
    fi
    c_green "Ventoy installed on $dev (data partition: $part)."

    # With a vault requested, carve + LUKS-format the reserved tail now.
    if [[ -n "$vault_spec" ]]; then
        create_vault_partition "$dev"
    fi

    echo ""
    echo "Next: ./hydra.sh copy $dev"
}

# Find the Ventoy data partition (label "Ventoy", FAT32 by default).
find_ventoy_partition() {
    local dev="$1"
    # Wait briefly in case udev hasn't re-scanned yet.
    sudo partprobe "$dev" 2>/dev/null || true
    sleep 1
    lsblk -ln -o NAME,LABEL "$dev" | awk '$2=="Ventoy"{print "/dev/"$1; exit}'
}

# Copy a (multi-GB) ISO to the Ventoy data partition with a live progress
# bar when `pv` is on PATH; falls back to a silent `sudo cp` otherwise.
#
# Multi-GB writes over USB take minutes and the previous silent `cp` left
# operators staring at a blinking cursor wondering if the script froze.
# `pv` reads from the source (no sudo needed for that — the ISO lives in
# the user's $HOME) and pipes to `sudo tee >/dev/null`, which writes to
# the mounted partition. pv's progress meter goes to stderr, so we see
# it even though stdout is piped.
#
# Args:
#   $1  src  — source path (an ISO under $HYDRA_ISO_DIR)
#   $2  dst  — destination path on the mounted Ventoy partition
copy_iso_with_progress() {
    local src="$1" dst="$2"
    local iso_name
    iso_name=$(basename "$src")
    if command -v pv >/dev/null 2>&1; then
        echo "  Copying $iso_name (with progress)..."
        # Stop a spurious "broken pipe" exit from pv | tee killing the loop
        # if tee errors out (set -o pipefail is on); the caller's trap
        # handles cleanup either way.
        pv --bytes --rate --eta --progress --timer "$src" \
            | sudo tee "$dst" >/dev/null
    else
        # Fallback: silent cp with reflink-when-possible. Same shape as
        # the original pre-pv path, kept for hosts that haven't installed
        # pv via `./hydra.sh deps`.
        echo "  Copying $iso_name (no pv on PATH — install via ./hydra.sh deps for progress)..."
        sudo cp --reflink=auto "$src" "$dst"
    fi
}

# Drop a Windows-style .url shortcut at the Ventoy partition root that
# points at the Hydra project page. Plugged into Windows, the stick shows
# a clickable "Hydra.url" — handy attribution + lets a recipient find the
# upstream when they wonder where the stick came from. Idempotent.
write_hydra_url_file() {
    local mnt="$1"
    local url_file="$mnt/Hydra.url"
    if [[ -f "$url_file" ]]; then
        c_green "  Hydra.url already present, skipping."
        return 0
    fi
    # CRLF line endings so the .url renders correctly on Windows hosts.
    printf '[InternetShortcut]\r\nURL=%s\r\n' "$HYDRA_REPO_URL" \
        | sudo tee "$url_file" >/dev/null
    c_green "  Wrote Hydra.url -> $HYDRA_REPO_URL"
}

# Echo the basenames of top-level *.iso files in a directory, one per line.
# Case-insensitive on the extension (.iso / .ISO), regular files only.
# Pure + side-effect free so it's unit-testable; the bash glob is sorted,
# so callers get deterministic order. Used by `copy --from <DIR|DEVICE>`.
list_source_isos() {
    local dir="$1" f base
    [[ -d "$dir" ]] || return 0
    # `shopt -p OPT` exits 1 when OPT is unset; `|| true` keeps that from
    # tripping `set -e` on the (normal) case where these are off.
    local had_nullglob had_nocaseglob
    had_nullglob=$(shopt -p nullglob || true)
    had_nocaseglob=$(shopt -p nocaseglob || true)
    shopt -s nullglob nocaseglob
    for f in "$dir"/*.iso; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        printf '%s\n' "$base"
    done
    # Restore the caller's original glob settings.
    eval "$had_nullglob"; eval "$had_nocaseglob"
}

cmd_copy() {
    local dev="" from=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                [[ -n "${2:-}" ]] || die "--from requires a value (a directory of ISOs, or a source /dev/sdX)."
                from="$2"; shift 2 ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$dev" ]] || die "copy takes a single device argument (got '$dev' and '$1')."
                dev="$1"; shift ;;
        esac
    done

    preflight_tools "copy" "${HYDRA_TOOLS_COPY[@]}"
    [[ -b "$dev" ]] || die "Usage: ./hydra.sh copy /dev/sdX [--from <DIR|/dev/sdY>]"

    local part
    part=$(find_ventoy_partition "$dev")
    [[ -n "$part" ]] || die "No Ventoy-labelled partition found on $dev. Run: ./hydra.sh usb $dev first."

    # Prime sudo's credential cache up front so the multi-minute copy +
    # url-write + unmount sequence doesn't get interrupted by a re-auth
    # prompt the operator misses. The first sudo call below would prompt
    # anyway; doing it explicitly here also makes the "operator needed"
    # moment unambiguous in the output.
    sudo -v || die "sudo authentication failed."

    # One EXIT trap owns BOTH the destination mount and, when --from names a
    # block device, the read-only source mount. src_mnt stays empty unless a
    # source device is mounted, so a default copy is unchanged. Trap body
    # tolerates the vars being out of scope under `set -u` (see the persistence
    # cmd for the same rationale).
    local mnt src_mnt=""
    mnt=$(mktemp -d -t hydra-ventoy-XXXX)
    # shellcheck disable=SC2154  # _m/_s are assigned inside the trap body string
    trap '_m="${mnt:-}"; _s="${src_mnt:-}";
          [[ -n "$_s" ]] && { sudo umount "$_s" 2>/dev/null; rmdir "$_s" 2>/dev/null; };
          [[ -n "$_m" ]] && { sudo umount "$_m" 2>/dev/null; rmdir "$_m" 2>/dev/null; }' EXIT
    sudo mount "$part" "$mnt"

    if [[ -n "$from" ]]; then
        copy_isos_from "$from" "$dev" "$mnt"
    else
        c_bold "=== Copying ISOs to Ventoy partition ($part -> $mnt) ==="
        for iso in "$UBUNTU_ISO" "$KALI_ISO"; do
            local src="$HYDRA_ISO_DIR/$iso"
            if [[ ! -f "$src" ]]; then
                c_yellow "  $iso not in $HYDRA_ISO_DIR — skipping. (Run: ./hydra.sh download)"
                continue
            fi
            if [[ -f "$mnt/$iso" ]]; then
                c_green "  $iso already on Ventoy, skipping."
                continue
            fi
            copy_iso_with_progress "$src" "$mnt/$iso"
        done

        # Optional BYO Windows ISO. Microsoft doesn't offer a stable direct URL,
        # so this is a path-to-local-file env var rather than a download step.
        if [[ -n "${HYDRA_WINDOWS_ISO:-}" ]]; then
            if [[ ! -f "$HYDRA_WINDOWS_ISO" ]]; then
                c_yellow "  HYDRA_WINDOWS_ISO=$HYDRA_WINDOWS_ISO not found — skipping."
            else
                local win_basename
                win_basename=$(basename "$HYDRA_WINDOWS_ISO")
                if [[ -f "$mnt/$win_basename" ]]; then
                    c_green "  $win_basename already on Ventoy, skipping."
                else
                    copy_iso_with_progress "$HYDRA_WINDOWS_ISO" "$mnt/$win_basename"
                fi
            fi
        fi
    fi

    write_hydra_url_file "$mnt"
    sync
    sudo umount "$mnt"
    rmdir "$mnt"
    [[ -n "$src_mnt" ]] && { sudo umount "$src_mnt" 2>/dev/null || true; rmdir "$src_mnt" 2>/dev/null || true; }
    trap - EXIT
    c_green "ISOs copied. Eject safely with: sudo eject $dev"
}

# Copy every *.iso from a --from source onto the already-mounted Ventoy
# partition. The source is either a directory or a block device (an existing
# Ventoy stick); devices are mounted READ-ONLY and never written. Sets the
# caller's `src_mnt` when it mounts a device so the caller's EXIT trap tears
# it down even on a mid-copy abort. Idempotent: skips ISOs already present.
copy_isos_from() {
    local from="$1" dest_dev="$2" mnt="$3"
    local src_dir
    if [[ -b "$from" ]]; then
        [[ "$from" != "$dest_dev" ]] || die "--from source and destination are the same device ($dest_dev)."
        local spart
        spart=$(find_ventoy_partition "$from")
        if [[ -z "$spart" ]]; then
            # Not a Ventoy-labelled stick — fall back to its first partition.
            local first
            first=$(lsblk -ln -o NAME "$from" | tail -n +2 | head -1)
            [[ -n "$first" ]] || die "No partition found on source device $from."
            spart="/dev/$first"
        fi
        src_mnt=$(mktemp -d -t hydra-src-XXXX)
        sudo mount -o ro "$spart" "$src_mnt" || die "Could not mount source partition $spart read-only."
        src_dir="$src_mnt"
        c_bold "=== Cloning ISOs from $from ($spart, read-only) -> $mnt ==="
    elif [[ -d "$from" ]]; then
        src_dir="$from"
        c_bold "=== Copying ISOs from directory $from -> $mnt ==="
    else
        die "--from '$from' is neither a directory nor a block device."
    fi

    local found=0 iso
    while IFS= read -r iso; do
        [[ -n "$iso" ]] || continue
        found=$((found + 1))
        if [[ -f "$mnt/$iso" ]]; then
            c_green "  $iso already on Ventoy, skipping."
            continue
        fi
        copy_iso_with_progress "$src_dir/$iso" "$mnt/$iso"
    done < <(list_source_isos "$src_dir")
    (( found > 0 )) || c_yellow "  No .iso files found in $from — nothing to copy."
}

# Allocate + LUKS-format + ext4 + persistence.conf for one ISO target.
#
# Args (positional):
#   $1  mount_point     — where the Ventoy partition is mounted
#   $2  fs_type         — vfat / exfat / ntfs — used for FAT32 size cap
#   $3  dat_name        — filename on the Ventoy partition (e.g. persistence-kali.dat)
#   $4  ext4_label      — ext4 label that live-boot scans for (e.g. "persistence", "writable")
#   $5  conf_name       — filename inside the persistence FS that live-boot reads (e.g. persistence.conf)
#   $6  size_bytes      — file size to allocate in bytes (pre-validated, FAT32-capped)
#   $7  display_name    — human label for the LUKS-prompt banner ("Kali" / "Ubuntu")
#
# Prompts for the LUKS passphrase interactively. No recovery if lost.
create_encrypted_persistence_image() {
    local mnt="$1" fs_type="$2" dat_name="$3" ext4_label="$4" conf_name="$5" size_bytes="$6" display="$7"
    local target_path="$mnt/$dat_name"
    local mapper_name="hydra-persist-$$-${ext4_label}"
    local inner_mnt
    inner_mnt=$(mktemp -d -t hydra-persist-inner-XXXX)

    # Local cleanup specific to this image — caller's broader trap still
    # owns the outer mount.
    image_cleanup() {
        sudo umount "$inner_mnt" 2>/dev/null || true
        sudo cryptsetup close "$mapper_name" 2>/dev/null || true
        rmdir "$inner_mnt" 2>/dev/null || true
    }

    if [[ -f "$target_path" ]]; then
        image_cleanup
        die "$dat_name already exists on the Ventoy partition. Remove it first to recreate."
    fi

    c_bold "=== Creating LUKS-encrypted $display persistence ==="
    echo "  Persistence file: /$dat_name"
    echo "  ext4 label:       $ext4_label"
    echo "  Size:             $(numfmt --to=iec --suffix=B "$size_bytes")"
    echo ""

    echo "  Allocating $dat_name..."
    if ! sudo fallocate -l "$size_bytes" "$target_path" 2>/dev/null; then
        # fallocate isn't supported on some FAT32 implementations.
        # Fall back to dd; slower but universal.
        local mib=$(( size_bytes / (1024*1024) ))
        sudo dd if=/dev/zero of="$target_path" bs=1M count="$mib" status=progress conv=fsync
    fi

    c_bold "--- LUKS format ($display) ---"
    echo "  Passphrase prompt below. There is NO recovery if you forget it —"
    echo "  Hydra doesn't store it anywhere."
    if ! sudo cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$target_path"; then
        image_cleanup
        die "LUKS format failed for $display persistence."
    fi

    sudo cryptsetup open "$target_path" "$mapper_name" || { image_cleanup; die "luksOpen failed for $display"; }
    sudo mkfs.ext4 -q -L "$ext4_label" "/dev/mapper/$mapper_name" || { image_cleanup; die "mkfs.ext4 failed for $display"; }
    sudo mount "/dev/mapper/$mapper_name" "$inner_mnt" || { image_cleanup; die "mount of $display persistence FS failed"; }

    # Both Kali (live-boot) and Ubuntu (casper newer than 22.04) read a
    # single-line config file with `/ union` to mean "make / a writable
    # union overlay." Same content, different filename.
    echo "/ union" | sudo tee "$inner_mnt/$conf_name" >/dev/null

    sudo umount "$inner_mnt"
    sudo cryptsetup close "$mapper_name"
    rmdir "$inner_mnt"
}

# Parse an explicit size spec or "max" against the remaining budget.
# Echoes the resolved size in bytes (or "0" if size_spec is empty).
# Errors out if max is requested but no budget remains.
resolve_persistence_size() {
    local size_spec="$1" remaining_bytes="$2" label="$3" fs_type="$4"
    local bytes=0

    if [[ -z "$size_spec" ]]; then
        printf '0'
        return 0
    fi
    if [[ "$size_spec" == "max" ]]; then
        bytes="$remaining_bytes"
    else
        bytes=$(numfmt --from=iec "$size_spec" 2>/dev/null) \
            || die "$label persistence size '$size_spec' is not valid. Try '2G', '500M', or 'max'."
    fi

    (( bytes >= 256 * 1024 * 1024 )) \
        || die "$label persistence resolved to $(numfmt --to=iec --suffix=B "$bytes"); under the 256 MiB floor."

    # FAT32 caps any single file at 4 GiB - 1 byte. Cap silently here so the
    # caller's budget math accounts for the lost bytes (they go back to free).
    if [[ "$fs_type" == "vfat" ]] && (( bytes > 4*1024*1024*1024 - 1 )); then
        c_yellow "  Ventoy partition is FAT32 — capping $label persistence at 4 GiB - 1 byte." >&2
        bytes=$(( 4 * 1024 * 1024 * 1024 - 1 ))
    fi

    printf '%s' "$bytes"
}

# Update ventoy/ventoy.json to attach a persistence file to an ISO.
# Idempotent: replaces any existing entry for the same image.
update_ventoy_persistence_config() {
    local mnt="$1" iso_name="$2" dat_name="$3"
    sudo mkdir -p "$mnt/ventoy"
    local cfg="$mnt/ventoy/ventoy.json"
    local entry
    entry=$(jq -nc \
        --arg image "/$iso_name" \
        --arg backend "/$dat_name" \
        '{image: $image, backend: $backend}')

    if sudo test -f "$cfg"; then
        local merged
        merged=$(sudo cat "$cfg" \
            | jq --argjson new "$entry" '
                .persistence = ((.persistence // []) | map(select(.image != $new.image)) + [$new])
            ')
        printf '%s\n' "$merged" | sudo tee "$cfg" >/dev/null
    else
        printf '{\n  "persistence": [%s]\n}\n' "$entry" | sudo tee "$cfg" >/dev/null
    fi
}

cmd_persistence() {
    local dev=""
    local kali_size_arg="" ubuntu_size_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kali)
                [[ -n "${2:-}" ]] || die "--kali requires a value (size like '2G', '500M', or 'max')."
                kali_size_arg="$2"; shift 2 ;;
            --ubuntu)
                [[ -n "${2:-}" ]] || die "--ubuntu requires a value (size like '2G', '500M', or 'max')."
                ubuntu_size_arg="$2"; shift 2 ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$dev" ]] || die "persistence takes a single device argument (got '$dev' and '$1')."
                dev="$1"; shift ;;
        esac
    done

    # Env-var fallback. HYDRA_PERSISTENCE_SIZE / _FILE were the original
    # single-image knobs; honour them as a back-compat default for Kali.
    local kali_size="${kali_size_arg:-${HYDRA_PERSISTENCE_KALI:-${HYDRA_PERSISTENCE_SIZE:-}}}"
    local ubuntu_size="${ubuntu_size_arg:-${HYDRA_PERSISTENCE_UBUNTU:-}}"
    # If neither is set, fall back to original behavior: Kali takes everything.
    if [[ -z "$kali_size" && -z "$ubuntu_size" ]]; then
        kali_size="max"
    fi
    if [[ "$kali_size" == "max" && "$ubuntu_size" == "max" ]]; then
        die "Both --kali and --ubuntu set to 'max' — only one can absorb the remaining space."
    fi

    validate_usb_device "$dev"
    preflight_tools "persistence" "${HYDRA_TOOLS_PERSISTENCE[@]}"

    local part
    part=$(find_ventoy_partition "$dev")
    [[ -n "$part" ]] || die "No Ventoy-labelled partition on $dev. Run: ./hydra.sh usb $dev first."

    # Prime sudo so the multi-minute LUKS-format + mkfs.ext4 + mount +
    # ventoy.json-merge sequence isn't interrupted by a fresh password
    # prompt the operator might miss.
    sudo -v || die "sudo authentication failed."

    local mnt
    mnt=$(mktemp -d -t hydra-persist-XXXX)
    # See cmd_copy for the rationale: trap body must tolerate `$mnt`
    # being out of scope when the EXIT trap fires under `set -u`.
    cleanup() {
        local m="${mnt:-}"
        [[ -n "$m" ]] || return 0
        sudo umount "$m" 2>/dev/null || true
        rmdir "$m"       2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    sudo mount "$part" "$mnt"

    local fs_type avail_bytes
    fs_type=$(findmnt -no FSTYPE "$mnt")
    avail_bytes=$(df --output=avail -B1 "$mnt" | tail -n1 | tr -d ' ')

    # Reserve a 50 MiB buffer for filesystem metadata / sync slack so a
    # "fill the partition" allocation doesn't push the FS into "no space
    # left on device" territory mid-write.
    local budget=$(( avail_bytes - 50 * 1024 * 1024 ))
    (( budget >= 256 * 1024 * 1024 )) \
        || die "Only $(numfmt --to=iec --suffix=B "$avail_bytes") free on Ventoy partition; need at least 256 MiB after a 50 MiB buffer."

    # Resolve explicit sizes first; "max" gets what's left after those.
    local kali_bytes=0 ubuntu_bytes=0
    if [[ -n "$kali_size" && "$kali_size" != "max" ]]; then
        kali_bytes=$(resolve_persistence_size "$kali_size" "$budget" "Kali" "$fs_type")
    fi
    if [[ -n "$ubuntu_size" && "$ubuntu_size" != "max" ]]; then
        ubuntu_bytes=$(resolve_persistence_size "$ubuntu_size" "$budget" "Ubuntu" "$fs_type")
    fi

    local fixed=$(( kali_bytes + ubuntu_bytes ))
    (( fixed <= budget )) \
        || die "Explicit sizes total $(numfmt --to=iec --suffix=B "$fixed"), more than the available $(numfmt --to=iec --suffix=B "$budget")."

    local remaining=$(( budget - fixed ))
    if [[ "$kali_size"   == "max" ]]; then kali_bytes=$(resolve_persistence_size   "max" "$remaining" "Kali"   "$fs_type"); fi
    if [[ "$ubuntu_size" == "max" ]]; then ubuntu_bytes=$(resolve_persistence_size "max" "$remaining" "Ubuntu" "$fs_type"); fi

    c_bold "=== Hydra persistence plan ==="
    echo "  Ventoy partition: $part ($fs_type)"
    echo "  Free space:       $(numfmt --to=iec --suffix=B "$avail_bytes") (budget $(numfmt --to=iec --suffix=B "$budget") after 50 MiB buffer)"
    [[ "$kali_bytes"   -gt 0 ]] && echo "  Kali:             $(numfmt --to=iec --suffix=B "$kali_bytes")  -> persistence-kali.dat"
    [[ "$ubuntu_bytes" -gt 0 ]] && echo "  Ubuntu:           $(numfmt --to=iec --suffix=B "$ubuntu_bytes")  -> persistence-ubuntu.dat"
    echo ""

    if (( kali_bytes > 0 )); then
        create_encrypted_persistence_image "$mnt" "$fs_type" \
            "persistence-kali.dat" "persistence" "persistence.conf" "$kali_bytes" "Kali"
        update_ventoy_persistence_config "$mnt" "$KALI_ISO" "persistence-kali.dat"
    fi

    if (( ubuntu_bytes > 0 )); then
        # Ubuntu Live (casper) since 22.04 reads a file labelled "writable"
        # containing a /writable.conf with `/ union`. Older Ubuntu used
        # "casper-rw" with no config file; "writable" is the modern shape.
        create_encrypted_persistence_image "$mnt" "$fs_type" \
            "persistence-ubuntu.dat" "writable" "writable.conf" "$ubuntu_bytes" "Ubuntu"
        update_ventoy_persistence_config "$mnt" "$UBUNTU_ISO" "persistence-ubuntu.dat"
    fi

    write_hydra_url_file "$mnt"

    sync
    cleanup
    trap - EXIT INT TERM

    c_green "Encrypted persistence ready on $dev."
    echo ""
    if (( kali_bytes > 0 )); then
        echo "Kali: at the boot menu, pick 'Live USB Encrypted Persistence' and"
        echo "      enter your Kali passphrase. Mounts as / union."
    fi
    if (( ubuntu_bytes > 0 )); then
        echo "Ubuntu: at the boot menu, pick the persistent live entry and enter"
        echo "        your Ubuntu passphrase. Subiquity-installer ISOs may not"
        echo "        honor persistence — test before relying on it."
    fi
}

cmd_test() {
    local target="" writable_scratch=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --writable-scratch)
                # Boot QEMU against a writable copy of the stick instead of
                # the stick itself. Required to verify Ventoy persistence in
                # QEMU — the default readonly mount path blocks Ventoy's
                # initramfs persistence hook from running (see GitHub #19).
                writable_scratch=1; shift ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$target" ]] || die "test takes a single device argument (got '$target' and '$1')."
                target="$1"; shift ;;
        esac
    done

    preflight_tools "test" "${HYDRA_TOOLS_TEST[@]}"

    if [[ -z "$target" ]]; then
        die "Usage: ./hydra.sh test /dev/sdX [--writable-scratch]   (boots the VM from your physical USB stick)"
    fi
    [[ -b "$target" ]] || die "$target is not a block device."

    local ovmf_code
    for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/x64/OVMF_CODE.fd /usr/share/qemu/ovmf-x86_64.bin; do
        if [[ -f "$p" ]]; then ovmf_code="$p"; break; fi
    done

    # shellcheck disable=SC2054  # commas in `type=q35,accel=kvm` are QEMU syntax, not array separators
    local -a qemu_args=(
        -enable-kvm
        -machine type=q35,accel=kvm
        -cpu host
        -smp "$HYDRA_VM_VCPUS"
        -m "$HYDRA_VM_MEMORY"
        -vga virtio
        -boot menu=on
        -display gtk
    )
    [[ -n "${ovmf_code:-}" ]] && qemu_args+=(-bios "$ovmf_code")

    if (( writable_scratch )); then
        run_qemu_with_scratch "$target" "${qemu_args[@]}"
    else
        c_bold "=== Launching QEMU VM booting from $target (read-only) ==="
        echo "RAM: ${HYDRA_VM_MEMORY}MB  vCPUs: ${HYDRA_VM_VCPUS}  GPU: virtio"
        echo "Close the QEMU window to stop. Reading the USB requires sudo."
        echo ""
        # qemu needs read access to the raw device; running via sudo is the simplest path.
        sudo qemu-system-x86_64 "${qemu_args[@]}" \
            -drive "file=${target},format=raw,if=virtio,readonly=on"
    fi
}

# Boot QEMU against a writable scratch copy of the stick. The real device
# is read once into a temp image; QEMU mutates the image freely; the image
# is deleted on exit. This is the only way to actually verify Ventoy's
# persistence layer in QEMU (the default readonly path blocks the
# initramfs hook that mounts persistence backends).
#
# Note: this requires ~15 GB of free space on the scratch dir for a typical
# Ventoy USB. We default to /var/tmp (usually disk-backed) over /tmp
# (often tmpfs) so we don't try to RAM-back a multi-GB image.
run_qemu_with_scratch() {
    local target="$1"; shift
    local -a qemu_args=("$@")

    local size_bytes
    size_bytes=$(lsblk -dn -b -o SIZE "$target" 2>/dev/null | tr -d ' ')
    local size_gb=$(( size_bytes / (1024*1024*1024) ))

    local scratch_dir="${HYDRA_SCRATCH_DIR:-/var/tmp}"
    [[ -d "$scratch_dir" && -w "$scratch_dir" ]] || \
        die "scratch dir $scratch_dir not writable. Override with HYDRA_SCRATCH_DIR=/path."

    # Verify free space on the scratch dir. We need at least 1.1× the stick
    # size (1× for the copy + 10% headroom for any image growth + temp
    # files). Using `df -B1 --output=avail` for byte-precision.
    local avail_bytes
    avail_bytes=$(df -B1 --output=avail "$scratch_dir" | tail -n1 | tr -d ' ')
    local needed_bytes=$(( size_bytes * 11 / 10 ))
    if (( avail_bytes < needed_bytes )); then
        die "scratch dir $scratch_dir has $(numfmt --to=iec --suffix=B "$avail_bytes") free; need >= $(numfmt --to=iec --suffix=B "$needed_bytes") for a writable copy of $target ($(numfmt --to=iec --suffix=B "$size_bytes"))."
    fi

    local scratch
    scratch=$(mktemp -p "$scratch_dir" --suffix=.img hydra-scratch-XXXX)
    trap 'rm -f "$scratch" 2>/dev/null' EXIT INT TERM

    c_bold "=== Launching QEMU VM booting from a WRITABLE SCRATCH copy of $target ==="
    echo "Scratch dir:  $scratch_dir"
    echo "Scratch file: $scratch"
    echo "Stick size:   ${size_gb} GB — copy will take a couple minutes on USB 3.0."
    echo "RAM:          ${HYDRA_VM_MEMORY}MB  vCPUs: ${HYDRA_VM_VCPUS}"
    echo ""
    echo "The real stick at $target is NOT modified — all writes go to the scratch image"
    echo "and are deleted when QEMU exits."
    echo ""
    echo "--- copying $target to scratch (sudo required to read raw device) ---"
    sudo dd if="$target" of="$scratch" bs=64M status=progress conv=fsync
    sudo chown "$(id -u):$(id -g)" "$scratch"  # so QEMU runs as your user can mutate it
    echo ""
    echo "--- launching QEMU ---"
    qemu-system-x86_64 "${qemu_args[@]}" \
        -drive "file=${scratch},format=raw,if=virtio"
    echo "(QEMU window closed; deleting scratch image.)"
    rm -f "$scratch"
    trap - EXIT INT TERM
}

cmd_all() {
    local dev="" skip_downloads=0 skip_deps=0 allow_non_removable=0 use_gpt=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-downloads)
                # ISOs + Ventoy tarball already present on disk; don't even
                # check the network. Useful for offline builds and for
                # re-running `all` after a previous `download` step succeeded.
                skip_downloads=1; shift ;;
            --skip-deps)
                # Counterpart for hosts where deps are already installed and
                # the operator doesn't want sudo + apt update running.
                skip_deps=1; shift ;;
            --allow-non-removable)
                # Forwarded to cmd_usb. USB-attached SSD/NVMe enclosures
                # report RM=0 even though the enclosure is hot-pluggable.
                allow_non_removable=1; shift ;;
            --gpt)
                # Forwarded to cmd_usb. Switches Ventoy from MBR to GPT.
                use_gpt=1; shift ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$dev" ]] || die "all takes a single device argument (got '$dev' and '$1')."
                dev="$1"; shift ;;
        esac
    done
    [[ -n "$dev" ]] || die "Usage: ./hydra.sh all /dev/sdX [--skip-downloads] [--skip-deps] [--allow-non-removable] [--gpt]"

    if (( skip_deps )); then
        c_yellow "--skip-deps: not running 'hydra deps'. (Assuming everything is installed.)"
    else
        cmd_deps
    fi

    if (( skip_downloads )); then
        c_yellow "--skip-downloads: not downloading Ventoy / Ubuntu / Kali. (Assuming present in $HYDRA_ISO_DIR.)"
        # Sanity check: refuse to continue if the artifacts the next steps
        # rely on aren't actually there. Otherwise cmd_usb would hit a
        # confusing "Ventoy not extracted" error from the tarball-not-found
        # path, and cmd_copy would silently skip both ISOs.
        local missing=()
        [[ -f "$HYDRA_ISO_DIR/$VENTOY_TARBALL" ]] || missing+=("$VENTOY_TARBALL")
        [[ -f "$HYDRA_ISO_DIR/$UBUNTU_ISO" ]] || missing+=("$UBUNTU_ISO")
        [[ -f "$HYDRA_ISO_DIR/$KALI_ISO" ]] || missing+=("$KALI_ISO")
        if (( ${#missing[@]} > 0 )); then
            die "--skip-downloads but missing from $HYDRA_ISO_DIR: ${missing[*]}. Drop those files in place or run without --skip-downloads."
        fi
    else
        cmd_download
    fi

    local -a usb_args=("$dev")
    (( allow_non_removable )) && usb_args+=("--allow-non-removable")
    (( use_gpt ))             && usb_args+=("--gpt")
    cmd_usb "${usb_args[@]}"
    cmd_copy "$dev"
    cmd_test "$dev"
}

# ---------- dispatch ----------

main() {
    local sub="${1:-check}"
    shift || true
    case "$sub" in
        check)        cmd_check        "$@" ;;
        deps)         cmd_deps         "$@" ;;
        download)     cmd_download     "$@" ;;
        usb)          cmd_usb          "$@" ;;
        copy)         cmd_copy         "$@" ;;
        persistence)  cmd_persistence  "$@" ;;
        test)         cmd_test         "$@" ;;
        all)          cmd_all          "$@" ;;
        -h|--help|help)
            # Print the full header banner — usage, env overrides, safety —
            # up to (but not including) the `set -euo pipefail` line.
            sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d'
            ;;
        *)
            die "Unknown subcommand: $sub. Try './hydra.sh help'."
            ;;
    esac
}

# Only execute main() when run directly. Allows tests to `source hydra.sh`
# and call internal functions without triggering CLI dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
