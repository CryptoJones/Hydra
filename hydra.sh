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
#   ./hydra.sh usb </dev/sdX>         Install Ventoy onto the named USB device. DESTRUCTIVE.
#   ./hydra.sh copy </dev/sdX>        Copy downloaded ISOs to the Ventoy partition.
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

# ---------- ui helpers ----------

c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { c_red "ERROR: $*" >&2; exit 1; }

# ---------- subcommands ----------

cmd_check() {
    c_bold "=== Hydra: host readiness ==="
    echo "ISO dir:           $HYDRA_ISO_DIR"
    echo "Ventoy version:    $HYDRA_VENTOY_VERSION"
    echo "Ubuntu version:    $HYDRA_UBUNTU_VERSION"
    echo "Kali version:      $HYDRA_KALI_VERSION"
    echo ""
    c_bold "--- required tools ---"
    for t in wget curl tar aria2c lsblk parted sgdisk dd qemu-system-x86_64; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  %-20s %s\n' "$t" "$(c_green ok)"
        else
            printf '  %-20s %s\n' "$t" "$(c_yellow missing)"
        fi
    done
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
        sudo apt-get install -y aria2 qemu-system-x86 qemu-utils ovmf parted gdisk wget curl tar bats
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y aria2 qemu-system-x86 qemu-img edk2-ovmf parted gdisk wget curl tar bats
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm aria2 qemu-base edk2-ovmf parted gptfdisk wget curl tar bats
    else
        die "Unsupported package manager. Install: aria2 qemu-system-x86 ovmf parted gdisk manually."
    fi
    c_green "Dependencies installed."
}

cmd_download() {
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
ventoy_installer_path() {
    local p="$VENTOY_EXTRACTED_DIR/Ventoy2Disk.sh"
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
    local dev="${1:-}"
    validate_usb_device "$dev"

    c_bold "=== Hydra: Ventoy install onto $dev ==="
    lsblk "$dev" || true
    echo ""
    c_red "THIS WILL ERASE EVERYTHING ON $dev."
    echo -n "Type the device name to confirm (e.g. /dev/sdb): "
    read -r confirm
    [[ "$confirm" == "$dev" ]] || die "Confirmation mismatch ($confirm != $dev). Aborting."

    local installer
    installer=$(ventoy_installer_path)
    sudo "$installer" -i "$dev"
    c_green "Ventoy installed on $dev."
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

cmd_copy() {
    local dev="${1:-}"
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
    sync
    sudo umount "$mnt"
    rmdir "$mnt"
    trap - EXIT
    c_green "ISOs copied. Eject safely with: sudo eject $dev"
}

cmd_test() {
    local target="${1:-}"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 missing — run: ./hydra.sh deps"
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
        check)    cmd_check    "$@" ;;
        deps)     cmd_deps     "$@" ;;
        download) cmd_download "$@" ;;
        usb)      cmd_usb      "$@" ;;
        copy)     cmd_copy     "$@" ;;
        test)     cmd_test     "$@" ;;
        all)      cmd_all      "$@" ;;
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
