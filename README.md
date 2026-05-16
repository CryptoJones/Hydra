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

# Optional: add LUKS-encrypted persistence file(s). Default = Kali fills
# the remaining free space. Pass --kali / --ubuntu to override per-OS.
# Prompts for each passphrase (no recovery if lost).
./hydra.sh persistence /dev/sdX                          # Kali, fill remaining
./hydra.sh persistence /dev/sdX --kali 8G                # Kali fixed 8 GiB
./hydra.sh persistence /dev/sdX --kali 8G --ubuntu max   # Kali fixed, Ubuntu absorbs rest
./hydra.sh persistence /dev/sdX --kali 4G --ubuntu 4G    # Both fixed

# Verify the stick boots — opens a QEMU window with your USB as the boot drive
./hydra.sh test /dev/sdX
```

Or, all in one shot:

```bash
./hydra.sh all /dev/sdX                       # full flow: deps -> download -> usb -> copy -> test
./hydra.sh all /dev/sdX --skip-downloads      # ISOs already in place; skip the download step
./hydra.sh all /dev/sdX --skip-deps           # deps already installed; skip apt/dnf/pacman
./hydra.sh all /dev/sdX --skip-downloads --skip-deps   # straight to the destructive write
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
| **cryptsetup** | LUKS-encrypted Kali persistence (`./hydra.sh persistence`). |
| **jq** | Persistence step writes/merges `ventoy/ventoy.json` via jq. |
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
| `HYDRA_PERSISTENCE_KALI` | unset | Default for `--kali` (e.g. `2G`, `max`) |
| `HYDRA_PERSISTENCE_UBUNTU` | unset | Default for `--ubuntu` (e.g. `2G`, `max`) |
| `HYDRA_PERSISTENCE_SIZE` | (deprecated) | Back-compat alias for `HYDRA_PERSISTENCE_KALI` |
| `HYDRA_REPO_URL` | `https://github.com/CryptoJones/Hydra` | URL written to `Hydra.url` on the stick |

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

## Encrypted persistence

`./hydra.sh persistence /dev/sdX` adds LUKS-encrypted persistence
file(s) to the Ventoy partition so the changes you make in a Live
session survive reboots.

### Choosing the layout

Each enabled OS gets its own `persistence-<os>.dat` file (separate LUKS
volume, separate passphrase). Pick how to divide the free space:

| Command | Layout |
|---|---|
| `./hydra.sh persistence /dev/sdX` | Kali absorbs all free space. Backwards-compatible default. |
| `./hydra.sh persistence /dev/sdX --kali 8G` | Kali fixed at 8 GiB, the rest stays as free Ventoy space. |
| `./hydra.sh persistence /dev/sdX --kali 8G --ubuntu max` | Kali fixed at 8 GiB, Ubuntu absorbs the remainder. |
| `./hydra.sh persistence /dev/sdX --kali 4G --ubuntu 4G` | Two fixed 4 GiB images, anything left over is free Ventoy space. |
| `./hydra.sh persistence /dev/sdX --ubuntu 6G` | Ubuntu only, no Kali persistence. |

Size accepts iec values (`500M`, `2G`, `8G`, etc.) or the literal `max`.
Only one OS can be `max` per run. Each image must be at least 256 MiB.

Env vars `HYDRA_PERSISTENCE_KALI` / `HYDRA_PERSISTENCE_UBUNTU` set the
defaults that flags override. The older `HYDRA_PERSISTENCE_SIZE` env var
is honoured as a Kali-only alias for back-compat.

### Under the hood

For each enabled OS:

1. Allocate a `persistence-<os>.dat` file at the requested size (FAT32
   capped at 4 GiB - 1 byte; exFAT or newer Ventoy partitions don't cap).
2. `cryptsetup luksFormat` (LUKS2) — prompts twice for the passphrase.
   **There is no recovery if you forget it.**
3. Open the LUKS container, format ext4, label it for the OS that boots it:
   - Kali: label `persistence`, conf file `/persistence.conf`
   - Ubuntu: label `writable`, conf file `/writable.conf`
4. Write `/ union` into the conf file, close LUKS.
5. Add (or update) a per-ISO entry in `ventoy/ventoy.json`'s persistence
   plugin pointing the ISO at the `.dat` backing file.

### Booting with persistence

- **Kali**: at the boot menu, pick **Live USB Encrypted Persistence** and
  enter the Kali passphrase.
- **Ubuntu**: pick the persistent live entry. Note that Ubuntu's newer
  Subiquity-based installer ISOs may not honour persistence in all
  releases — test before relying on it.

The same step also drops a `Hydra.url` shortcut at the partition root
pointing back at this repo, so anyone who plugs the stick into a
Windows host has a single click back to the source.

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

### Unit tests (bats)

```bash
sudo apt install bats   # (or dnf / pacman; also installed by ./hydra.sh deps)
bats tests/
```

The suite covers CLI dispatch, error paths on the destructive subcommands,
URL constant substitution from `HYDRA_*_VERSION` env overrides, the
`run_ventoy_installer` cwd / arg / stdin contract, the `mkexfatfs` alias
helper, the `.url` writer, and the script-structure invariants (shebang,
SPDX header, sourcing guard). No sudo, no real block devices, no
network — safe to run on any host.

See `tests/README.md` for the full inventory and how to add tests for new
functionality.

### Manual integration test (real USB + QEMU)

End-to-end verification that the stick you just built actually boots.
Run this after any non-trivial change to `cmd_usb`, `cmd_copy`, `cmd_persistence`,
or the Ventoy version pin.

**Prerequisites:** a 4–32 GB USB stick you don't mind wiping, plus a host
with KVM (`/dev/kvm` accessible to your user — group `kvm` membership is
the usual fix).

**1. Build the stick.** Both subcommands need sudo; both write to the device.

```bash
# Wipe + reinstall Ventoy. The post-install probe will refuse to claim
# success unless a Ventoy-labelled partition actually appears.
./hydra.sh usb --force /dev/sdX

# Copy Ubuntu + Kali ISOs to the Ventoy data partition. Also writes
# Hydra.url to the partition root for Windows-host discoverability.
./hydra.sh copy /dev/sdX
```

**2. (Optional) Add encrypted persistence.** Skip if you only want a
fresh boot test.

```bash
./hydra.sh persistence /dev/sdX
# Default: Kali absorbs the remaining free space, LUKS-encrypted.
# Prompts twice for the passphrase. No recovery if you forget it.
```

**3. Install QEMU + UEFI firmware.** Only needed for the boot test;
`./hydra.sh deps` covers it, or install manually for a lighter touch:

```bash
sudo apt install qemu-system-x86 qemu-utils ovmf
```

**4. Boot the stick in QEMU.**

Two modes:

```bash
./hydra.sh test /dev/sdX                    # read-only — safe but persistence won't activate
./hydra.sh test /dev/sdX --writable-scratch # writable scratch copy — full persistence verification
```

**Plain `./hydra.sh test`** mounts the physical stick read-only as a
virtio drive. Fast (no copy) and the real stick is untouched, but
Ventoy's initramfs persistence-loading hook doesn't fire reliably
under this configuration — meaning persistence verification fails
inside QEMU even when the build is correct on real hardware.

**`--writable-scratch`** first `dd`'s the stick into a temp image
under `$HYDRA_SCRATCH_DIR` (default `/var/tmp`), then boots QEMU
against the scratch image with writes enabled. Persistence works
(writes go to the scratch image, not the real stick), and the
scratch is deleted on QEMU exit. The dd step takes a few minutes
on a USB 3.0 stick.

Either way, a QEMU window opens with Ventoy's menu listing Ubuntu +
Kali. Pick either; verify it boots all the way to a desktop. Close
the QEMU window when satisfied.

**What "pass" looks like:**

- [ ] `lsblk /dev/sdX` shows two partitions: a large `Ventoy`-labelled
      one and a small `VTOYEFI` one.
- [ ] `/dev/sdX1` mounted on the host shows `Hydra.url`,
      `ubuntu-*.iso`, `kali-*.iso`, and (if persistence was added)
      `persistence-kali.dat` + `ventoy/ventoy.json`.
- [ ] QEMU boot reaches the Ventoy menu without complaint.
- [ ] Picking Ubuntu boots to the GNOME desktop.
- [ ] **With `--writable-scratch`**, picking Kali → **Live USB Encrypted
      Persistence** prompts for the passphrase, then boots Kali with `/`
      writable. Create a file in `/home/kali`, reboot via QEMU, re-enter
      the passphrase, confirm the file is still there.
- [ ] Without `--writable-scratch`, persistence is expected NOT to
      activate (Ventoy hook limitation under read-only virtio).
      Validate persistence on real hardware instead, or rerun with
      `--writable-scratch`.

**If any step fails:**

- `usb` step prints "Some tools can not run" — re-run `./hydra.sh deps`
  to refresh the `mkexfatfs` symlink, then retry.
- `usb` claims success but `lsblk` shows only the manufacturer FAT32 —
  the post-install probe should have caught this; if it didn't, file an
  issue with the contents of `~/Downloads/iso/ventoy-1.1.12/log.txt`.
- QEMU window is black for >30s with no menu — `dmesg` on the host
  often points at a missing `ovmf` or KVM permission issue.

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

Proudly Made in Nebraska. Go Big Red! 🌽 https://xkcd.com/2347/
