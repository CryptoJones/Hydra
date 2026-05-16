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
#   ./hydra.sh persistence </dev/sdX> Add a LUKS-encrypted Kali persistence file
#                                      sized to the free space on the Ventoy partition.
#                                      Prompts for the LUKS passphrase.
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
    for t in wget curl tar aria2c lsblk parted sgdisk dd cryptsetup qemu-system-x86_64; do
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
        sudo apt-get install -y aria2 qemu-system-x86 qemu-utils ovmf parted gdisk cryptsetup jq wget curl tar bats
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y aria2 qemu-system-x86 qemu-img edk2-ovmf parted gdisk cryptsetup jq wget curl tar bats
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm aria2 qemu-base edk2-ovmf parted gptfdisk cryptsetup jq wget curl tar bats
    else
        die "Unsupported package manager. Install: aria2 qemu-system-x86 ovmf parted gdisk cryptsetup jq manually."
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

cmd_persistence() {
    local dev="${1:-}"
    validate_usb_device "$dev"

    command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup missing — run: ./hydra.sh deps"
    command -v jq >/dev/null 2>&1         || die "jq missing — run: ./hydra.sh deps"
    command -v numfmt >/dev/null 2>&1     || die "numfmt missing (coreutils) — install coreutils."

    local part
    part=$(find_ventoy_partition "$dev")
    [[ -n "$part" ]] || die "No Ventoy-labelled partition on $dev. Run: ./hydra.sh usb $dev first."

    local dat_name="${HYDRA_PERSISTENCE_FILE:-persistence-kali.dat}"
    local mapper_name="hydra-persistence-$$"

    local mnt inner_mnt
    mnt=$(mktemp -d -t hydra-persist-XXXX)
    inner_mnt=$(mktemp -d -t hydra-persist-inner-XXXX)

    # Single cleanup trap covers every exit path. close before unmount so
    # the persistence file isn't held open by an orphaned mapper device.
    cleanup() {
        sudo umount "$inner_mnt" 2>/dev/null || true
        sudo cryptsetup close "$mapper_name" 2>/dev/null || true
        sudo umount "$mnt"       2>/dev/null || true
        rmdir "$inner_mnt"       2>/dev/null || true
        rmdir "$mnt"             2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    sudo mount "$part" "$mnt"

    local fs_type avail_bytes target_bytes
    fs_type=$(findmnt -no FSTYPE "$mnt")
    avail_bytes=$(df --output=avail -B1 "$mnt" | tail -n1 | tr -d ' ')

    # Size: user-set override or "fill the partition minus a 50 MiB buffer
    # so the FS metadata + sync slack has somewhere to live."
    if [[ -n "${HYDRA_PERSISTENCE_SIZE:-}" ]]; then
        target_bytes=$(numfmt --from=iec "$HYDRA_PERSISTENCE_SIZE" 2>/dev/null) \
            || die "HYDRA_PERSISTENCE_SIZE '$HYDRA_PERSISTENCE_SIZE' is not a valid size (try '2G' / '500M')."
    else
        target_bytes=$(( avail_bytes - 50 * 1024 * 1024 ))
    fi

    (( target_bytes >= 256 * 1024 * 1024 )) \
        || die "Less than 256 MiB available for persistence ($avail_bytes bytes free). Not creating a tiny persistence file."

    # FAT32 caps any single file at 4 GiB - 1 byte. Older Ventoy versions
    # default the data partition to FAT32; newer versions default to exFAT
    # (no cap). Detect and refuse-to-exceed rather than fail mid-allocate.
    if [[ "$fs_type" == "vfat" ]] && (( target_bytes > 4*1024*1024*1024 - 1 )); then
        c_yellow "  Ventoy partition is FAT32 — capping persistence at 4 GiB - 1 byte."
        target_bytes=$(( 4 * 1024 * 1024 * 1024 - 1 ))
    fi

    local target_path="$mnt/$dat_name"
    if [[ -f "$target_path" ]]; then
        die "$dat_name already exists on the Ventoy partition. Remove it first if you want to recreate."
    fi

    c_bold "=== Creating LUKS-encrypted Kali persistence ==="
    echo "  Ventoy partition: $part ($fs_type)"
    echo "  Persistence file: /$dat_name"
    echo "  Size:             $(numfmt --to=iec --suffix=B "$target_bytes")"
    echo ""

    echo "  Allocating $dat_name..."
    if ! sudo fallocate -l "$target_bytes" "$target_path" 2>/dev/null; then
        # fallocate isn't supported on every filesystem (notably some
        # FAT32 implementations). Fall back to dd; slower but universal.
        local mib=$(( target_bytes / (1024*1024) ))
        sudo dd if=/dev/zero of="$target_path" bs=1M count="$mib" status=progress conv=fsync
    fi

    c_bold "--- LUKS format ---"
    echo "  You'll be prompted for a passphrase. This is what unlocks the"
    echo "  encrypted persistence at Kali boot. There is NO recovery if you"
    echo "  forget it — Hydra doesn't store the passphrase anywhere."
    sudo cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$target_path"

    c_bold "--- Opening LUKS, formatting ext4, writing persistence.conf ---"
    sudo cryptsetup open "$target_path" "$mapper_name"
    sudo mkfs.ext4 -q -L persistence "/dev/mapper/$mapper_name"
    sudo mount "/dev/mapper/$mapper_name" "$inner_mnt"
    # Kali's live-boot looks for the persistence label + a /persistence.conf
    # whose first line is `/ union` (everything writable, overlay-style).
    echo "/ union" | sudo tee "$inner_mnt/persistence.conf" >/dev/null
    sudo umount "$inner_mnt"
    sudo cryptsetup close "$mapper_name"

    c_bold "--- Wiring up Ventoy persistence plugin (ventoy.json) ---"
    sudo mkdir -p "$mnt/ventoy"
    local cfg="$mnt/ventoy/ventoy.json"
    local entry
    entry=$(jq -nc \
        --arg image "/$KALI_ISO" \
        --arg backend "/$dat_name" \
        '{image: $image, backend: $backend}')

    if sudo test -f "$cfg"; then
        # Merge: replace any existing persistence entry for this Kali ISO,
        # leave other persistence entries (e.g. for Ubuntu) alone.
        local merged
        merged=$(sudo cat "$cfg" \
            | jq --argjson new "$entry" '
                .persistence = ((.persistence // []) | map(select(.image != $new.image)) + [$new])
            ')
        printf '%s\n' "$merged" | sudo tee "$cfg" >/dev/null
    else
        printf '{\n  "persistence": [%s]\n}\n' "$entry" | sudo tee "$cfg" >/dev/null
    fi

    write_hydra_url_file "$mnt"

    sync
    cleanup
    trap - EXIT INT TERM

    c_green "Encrypted Kali persistence ready on $dev."
    echo ""
    echo "At Kali's boot menu, pick the Live USB Encrypted Persistence entry"
    echo "and enter the passphrase you just set. The persistence layer mounts"
    echo "as / union — changes survive reboots."
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
