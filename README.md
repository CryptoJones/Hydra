# Hydra — Multi-OS Bootable USB Builder + VM Tester

[![Tests](https://github.com/CryptoJones/Hydra/actions/workflows/test.yml/badge.svg)](https://github.com/CryptoJones/Hydra/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Build a [Ventoy](https://github.com/ventoy/Ventoy)-based multi-boot USB stick
that carries Ubuntu LTS + Kali Linux Live (and any other ISOs you drop on
it), then sanity-check the stick by booting a local QEMU VM directly from
the physical USB — no actual reboot required to verify it works.

Named for the mythological creature: one stick, many heads.

---

## What it does

1. **Downloads** Ventoy, the latest Ubuntu LTS desktop ISO, and Kali Linux
   Live (via torrent — Kali's Live image is torrent-only on cdimage.kali.org).
2. **Installs Ventoy** to your USB stick (with safety checks so it refuses to
   touch internal disks or non-removable devices).
3. **Copies the ISOs** to the Ventoy data partition.
4. **Spins up a QEMU VM** that boots from the physical USB so you can verify
   the stick actually boots before staking a real reboot on it.

---

## Quick start

```bash
chmod +x hydra.sh

# See what's installed, what's missing, and which USB candidates are visible
./hydra.sh check

# One-time tool install (apt / dnf / pacman; needs sudo)
# Installs: aria2, qemu-system-x86, qemu-utils, ovmf, parted, gdisk, wget, curl, tar
./hydra.sh deps

# Download Ventoy + Ubuntu + Kali (idempotent — re-runs skip already-fetched files)
./hydra.sh download

# Install Ventoy onto your USB (DESTRUCTIVE — pass the exact device path).
# The script refuses to write to non-removable or rootfs-backing devices.
./hydra.sh usb /dev/sdX

# Copy the ISOs to the Ventoy data partition
./hydra.sh copy /dev/sdX

# Verify the stick boots — opens a QEMU window with your USB as the boot drive
./hydra.sh test /dev/sdX
```

Or, all in one shot:

```bash
./hydra.sh all /dev/sdX
```

---

## Dependencies

`./hydra.sh deps` installs everything below via your distro's package manager
(`apt`, `dnf`, or `pacman` — detected automatically). All of these are
mainstream and freely available.

| Tool | Purpose |
|---|---|
| **[aria2](https://aria2.github.io/)** | **Required for Kali Live download.** Kali distributes Live ISOs only via BitTorrent on cdimage.kali.org. `aria2c` speaks both HTTP and BitTorrent, so the `download` step fetches the `.torrent` file via HTTP and then pulls the actual ISO from peers. The script will refuse to download Kali without `aria2c` on `PATH`. |
| **qemu-system-x86 / qemu-utils** | Boot-test step. `hydra test` launches a QEMU/KVM VM that boots from your physical USB stick. |
| **ovmf / edk2-ovmf** | UEFI firmware for QEMU. Lets the VM emulate a modern UEFI machine instead of legacy BIOS. |
| **parted / gdisk** | Used internally by Ventoy when partitioning the USB. |
| **wget / curl / tar** | Fetch Ventoy + Ubuntu, extract the Ventoy archive. |

If you can't (or don't want to) install dependencies via `./hydra.sh deps` —
e.g. you're on a hardened system — install just `aria2` manually for the Kali
step, and skip the `test` subcommand to avoid needing QEMU.

---

## Configuration

All paths and versions are env-overridable. Defaults:

| Variable | Default | Notes |
|---|---|---|
| `HYDRA_ISO_DIR` | `~/Downloads/iso` | Where ISOs + Ventoy tarball live |
| `HYDRA_VENTOY_VERSION` | `1.1.12` | [Ventoy releases](https://github.com/ventoy/Ventoy/releases) |
| `HYDRA_UBUNTU_VERSION` | `26.04` | LTS; set to `24.04` for prior LTS |
| `HYDRA_KALI_VERSION` | `2026.1` | https://www.kali.org/get-kali/ |
| `HYDRA_VM_MEMORY` | `4096` (MB) | QEMU RAM for boot test |
| `HYDRA_VM_VCPUS` | `2` | QEMU vCPU count |

Example:

```bash
HYDRA_UBUNTU_VERSION=24.04 HYDRA_VM_MEMORY=8192 ./hydra.sh all /dev/sdc
```

---

## Safety

The `usb` and `all` subcommands write to a block device. Before writing, the
script:

1. Refuses if the target isn't a block device.
2. Refuses if the device's `RM` flag (removable) is 0 — i.e. internal disk.
3. Refuses if the device is smaller than 4 GB or larger than 2 TB.
4. Refuses if the device backs the host root filesystem.
5. Prompts you to type the device path again as confirmation before writing.

Adding a USB? Run `./hydra.sh check` first to see your removable-disk candidates.

---

## Why torrent for Kali?

Kali Linux distributes their **Live** ISO only via BitTorrent on
cdimage.kali.org (only their installer ISOs are direct HTTP). `hydra deps`
installs `aria2`, which speaks both HTTP and BitTorrent. The
`hydra.sh download` step grabs the `.torrent` file via HTTP, then uses aria2c
to fetch the actual ISO from peers.

If you want the **installer** ISO instead of Live, edit the URLs near the
top of `hydra.sh`.

---

## Why QEMU instead of VirtualBox / VMware?

QEMU/KVM is kernel-native on Linux, has zero proprietary dependencies, and
can boot directly from a raw block device with one flag
(`-drive file=/dev/sdX,format=raw,if=virtio,readonly=on`). VirtualBox can do
this too via `vboxmanage internalcommands createrawvmdk`, but it's a more
involved setup and requires the proprietary extension pack for some features.

---

## Testing

```bash
sudo apt install bats   # (or dnf / pacman; also installed by ./hydra.sh deps)
bats tests/
```

The suite covers CLI dispatch, error paths on the destructive subcommands,
URL constant substitution from `HYDRA_*_VERSION` env overrides, and the
script-structure invariants (shebang, SPDX header, sourcing guard). No
sudo, no real block devices, no network — safe to run on any host.

See `tests/README.md` for the full inventory and how to add tests for new
functionality.

---

## Upstream projects

Hydra is a thin orchestrator on top of several excellent tools — please
support and credit them:

- **[Ventoy](https://github.com/ventoy/Ventoy)** — the multi-boot magic.
  Drop ISOs on a Ventoy USB and it boots them with no per-ISO setup.
  GPLv3, by [longpanda](https://github.com/longpanda).
- **[Ubuntu](https://ubuntu.com/)** — Canonical's Linux distribution.
- **[Kali Linux](https://www.kali.org/)** — Offensive Security's pentest distro.
- **[QEMU](https://www.qemu.org/)** + **KVM** — open-source virtualization
  used for the boot-test step.
- **[aria2](https://aria2.github.io/)** — multi-protocol downloader, used
  to fetch Kali's torrent-only Live image.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Note: Hydra's code is Apache 2.0, but the *tools it orchestrates* carry their
own licenses (Ventoy is GPLv3, etc.). Hydra does not redistribute them; it
downloads them from their official sources at runtime.

Proudly Made in Nebraska. Go Big Red! 🌽 https://xkcd.com/1654/
