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
#   ./hydra.sh usb </dev/sdX> [--force]
#                                      Install Ventoy onto the named USB device. DESTRUCTIVE.
#                                      --force reinstalls over an existing Ventoy stick.
#   ./hydra.sh copy </dev/sdX>        Copy downloaded ISOs to the Ventoy partition.
#   ./hydra.sh persistence </dev/sdX> [--kali SIZE] [--ubuntu SIZE]
#                                      Add LUKS-encrypted persistence file(s) on the
#                                      Ventoy partition. SIZE accepts iec values like
#                                      '2G' or '500M', or 'max' to consume the rest of
#                                      the free space (one OS only). Default (no
#                                      flags): Kali takes everything available.
#                                      Each enabled OS prompts for its own passphrase.
#   ./hydra.sh test [/dev/sdX]        Boot a QEMU VM from the physical USB (or ISO dir).
#   ./hydra.sh all </dev/sdX>         Run deps -> download -> usb -> copy -> test.
#
# Env overrides:
#   HYDRA_ISO_DIR              Where ISOs and Ventoy archive live (default ~/Downloads/iso)
#   HYDRA_VENTOY_VERSION       Default v1.1.12
#   HYDRA_UBUNTU_VERSION       Default 26.04   (LTS — change to 24.04 for prior LTS)
#   HYDRA_KALI_VERSION         Default 2026.1
#   HYDRA_VM_MEMORY            QEMU RAM in MB (default 4096)
#   HYDRA_VM_VCPUS             QEMU vCPU count (default 2)
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
        sudo apt-get install -y aria2 qemu-system-x86 qemu-utils ovmf parted gdisk cryptsetup jq exfatprogs wget curl tar bats
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y aria2 qemu-system-x86 qemu-img edk2-ovmf parted gdisk cryptsetup jq exfatprogs wget curl tar bats
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm aria2 qemu-base edk2-ovmf parted gptfdisk cryptsetup jq exfatprogs wget curl tar bats
    else
        die "Unsupported package manager. Install: aria2 qemu-system-x86 ovmf parted gdisk cryptsetup jq exfatprogs manually."
    fi
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
    ls -lh "$HYDRA_ISO_DIR" | grep -E '\.(iso|tar\.gz)$' || true
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
validate_usb_device() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || die "no device specified. Usage: ./hydra.sh usb /dev/sdX"
    [[ -b "$dev" ]] || die "$dev is not a block device."

    local name="${dev#/dev/}"
    local rm size_bytes
    rm=$(lsblk -dn -o RM "$dev" 2>/dev/null | tr -d ' ')
    size_bytes=$(lsblk -dn -b -o SIZE "$dev" 2>/dev/null | tr -d ' ')

    [[ "$rm" == "1" ]] || die "$dev is not a removable device. Refusing to write."

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

cmd_usb() {
    local dev="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=1; shift ;;
            -*)
                die "Unknown flag: $1. Try './hydra.sh help'." ;;
            *)
                [[ -z "$dev" ]] || die "usb takes a single device argument (got '$dev' and '$1')."
                dev="$1"; shift ;;
        esac
    done

    preflight_tools "usb" "${HYDRA_TOOLS_USB[@]}"
    validate_usb_device "$dev"

    c_bold "=== Hydra: Ventoy install onto $dev ==="
    lsblk "$dev" || true
    echo ""
    if (( force )); then
        c_yellow "--force: reinstalling Ventoy (any existing Ventoy install AND its data will be wiped)."
    fi
    c_red "THIS WILL ERASE EVERYTHING ON $dev."
    echo -n "Type the device name to confirm (e.g. /dev/sdb): "
    read -r confirm
    [[ "$confirm" == "$dev" ]] || die "Confirmation mismatch ($confirm != $dev). Aborting."

    local installer
    installer=$(ventoy_installer_path)
    # Ventoy2Disk.sh has no "skip prompt" flag (an earlier version of this
    # function used -y, which Ventoy treats as an invalid argument — it
    # prints usage and exits 0, which our exit-code check silently rubber-
    # stamped). The supported pattern is to pipe `y` answers in via stdin.
    # `yes` repeats "y\n" indefinitely; Ventoy reads as many as it needs
    # and then closes the pipe (yes exits cleanly on SIGPIPE).
    # -i = fresh install (refuses if Ventoy is already there).
    # -I = force reinstall over existing Ventoy.
    local ventoy_flag="-i"
    (( force )) && ventoy_flag="-I"
    yes | sudo "$installer" "$ventoy_flag" "$dev"

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

cmd_copy() {
    local dev="${1:-}"
    preflight_tools "copy" "${HYDRA_TOOLS_COPY[@]}"
    [[ -b "$dev" ]] || die "Usage: ./hydra.sh copy /dev/sdX"

    local part
    part=$(find_ventoy_partition "$dev")
    [[ -n "$part" ]] || die "No Ventoy-labelled partition found on $dev. Run: ./hydra.sh usb $dev first."

    local mnt
    mnt=$(mktemp -d -t hydra-ventoy-XXXX)
    trap 'sudo umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null' EXIT
    sudo mount "$part" "$mnt"

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
        echo "  Copying $iso..."
        sudo cp --reflink=auto "$src" "$mnt/$iso"
    done
    write_hydra_url_file "$mnt"
    sync
    sudo umount "$mnt"
    rmdir "$mnt"
    trap - EXIT
    c_green "ISOs copied. Eject safely with: sudo eject $dev"
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

    local mnt
    mnt=$(mktemp -d -t hydra-persist-XXXX)
    cleanup() {
        sudo umount "$mnt" 2>/dev/null || true
        rmdir "$mnt"       2>/dev/null || true
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
    local target="${1:-}"
    preflight_tools "test" "${HYDRA_TOOLS_TEST[@]}"
    local ovmf_code
    for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/x64/OVMF_CODE.fd /usr/share/qemu/ovmf-x86_64.bin; do
        if [[ -f "$p" ]]; then ovmf_code="$p"; break; fi
    done

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

    if [[ -z "$target" ]]; then
        die "Usage: ./hydra.sh test /dev/sdX   (boots the VM from your physical USB stick)"
    fi
    [[ -b "$target" ]] || die "$target is not a block device."

    c_bold "=== Launching QEMU VM booting from $target ==="
    echo "RAM: ${HYDRA_VM_MEMORY}MB  vCPUs: ${HYDRA_VM_VCPUS}  GPU: virtio"
    echo "Close the QEMU window to stop. Reading the USB requires sudo."
    echo ""

    # qemu needs read access to the raw device; running via sudo is the simplest path.
    sudo qemu-system-x86_64 "${qemu_args[@]}" \
        -drive "file=${target},format=raw,if=virtio,readonly=on"
}

cmd_all() {
    local dev="${1:-}"
    [[ -n "$dev" ]] || die "Usage: ./hydra.sh all /dev/sdX"
    cmd_deps
    cmd_download
    cmd_usb "$dev"
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
            sed -n '2,30p' "$0"
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
