# rp6-vibeos

A minimal system for the Retroid Pocket 6 (QCS8550, 8 GB) whose only purpose is to run
[DroidDeck](https://github.com/Droid-Deck/DroidDeck) while leaving as much RAM and storage as
possible to games and the GPU.

Architecture: Retroid's mainline 7.3 kernel → minimal Debian host → Waydroid (Android in a
container, with only DroidDeck installed) shown full screen by `cage`. Steam, Proton, FEX,
DXVK and their updates stay managed by DroidDeck.

> Status: early prototype. The kernel-only test image boots from microSD and shows the kernel
> log on the built-in display; the full rootfs has not been booted yet. GPU support inside
> DroidDeck still needs work: DroidDeck looks for the Android KGSL driver (`/dev/kgsl-3d0`),
> which the mainline kernel does not have. [gpu/](gpu/README.md) is the prototype that gives the
> msm driver a KGSL face, plus an msm Turnip that DroidDeck can import.

## Build

On an x86_64 or arm64 Linux host with `gcc-aarch64-linux-gnu`, `bc`, `flex`, `bison`,
`libssl-dev`, `device-tree-compiler`, `m4`, `alsa-utils` (`alsatplg`), `dosfstools`,
`mtools`, `e2fsprogs`, `fdisk` (`sfdisk`), `debootstrap`, `qemu-user-static`, `zstd`:

```sh
scripts/01-fetch-sources.sh            # kernel, topology, UCM, linux-firmware (only the files needed)
scripts/10-build-kernel.sh             # RP6 config + drivers derived from the device tree
scripts/15-build-kgsl.sh               # optional, experimental: KGSL GPU driver + its DTB
scripts/16-build-kgsl-shim.sh          # or instead: msm + a KGSL-style sysfs and node for DroidDeck (gpu/README.md)
scripts/20-build-audio.sh              # AudioReach topology + UCM
scripts/30-collect-firmware.sh <dump>  # generic firmware + signed blobs from stock Android
sudo scripts/40-build-rootfs.sh        # Debian minbase + Waydroid + cage
sudo scripts/50-make-sdimage.sh        # microSD image for OpenABL (no root needed without a rootfs)
```

Shared settings live in `config.env`, the kernel config fragment in `kernel/rp6.config`.
`scripts/dt2config.py` reads the RP6 DTB and enables the driver for every active node, so the
config does not have to be written by hand.

## Experimental: Qualcomm KGSL GPU driver

DroidDeck's Turnip expects the Android GPU driver, KGSL (`/dev/kgsl-3d0`). As a fallback to
faking that node on top of msm, `scripts/15-build-kgsl.sh` builds Qualcomm's KGSL
(`msm_kgsl.ko`, pinned in `config.env`) against the 7.3 kernel with the patch in
`kgsl/patches/`, and an RP6 device tree (`kgsl/dts/`) that gives the GPU to KGSL while msm
keeps driving the display. It runs after `10-build-kernel.sh` and writes to `out/kgsl/`. It
builds, but has not been tried on the device yet.

## Signed firmware

The GPU zap shader, ADSP and CDSP firmware are signed for the device and only exist in stock
Android. Before changing anything on the device, copy the firmware partitions and folders, for
example:

```sh
adb pull /vendor/firmware      dump/vendor-firmware
adb pull /vendor/firmware_mnt  dump/firmware_mnt
adb pull /vendor/dsp           dump/dsp
```

If there are only `.mdt` + `.bNN` files, you need
[pil-squasher](https://github.com/linux-msm/pil-squasher).

## First boot (Android stays intact)

The bootloader is [OpenABL](https://github.com/OpenHandheldCollective/OpenABL), the same one
ROCKNIX installs (version 1.1 or later). It boots Linux from the microSD by reading
`extlinux/extlinux.conf` from the FAT partition.

**Prerequisite:** OpenABL must already be installed in place of Retroid's ABL. With the stock
ABL, writing the microSD is not enough and the menu in step 3 does not exist. If it is not
installed, follow the [OpenABL instructions](https://github.com/OpenHandheldCollective/OpenABL#using-it)
(flashing `abl_a` and `abl_b` from fastboot) or the
[ROCKNIX guide for the RP6](https://rocknix.org/devices/retroid/retroid-pocket-6/), which also
backs up the stock ABL. This is the only step that writes to internal storage: make a backup
first. To check the version: `fastboot getvar version-bootloader`.

1. `scripts/50-make-sdimage.sh` creates `out/rp6-sd.img`: a FAT partition with the kernel, DTB
   and extlinux.conf, then the `rp6-root` ext4 partition. Without a rootfs it creates a
   kernel-only image, useful to check the display and the boot log.
2. Write it to the microSD: `dd if=out/rp6-sd.img of=/dev/<sd> bs=4M conv=fsync`
   (or with balenaEtcher or Raspberry Pi Imager).
3. Power on while holding Vol down, set *Boot mode* to Linux and *Boot source* to SD card, then
   *Start*. Holding Vol up at power-on goes back to Android.

## License

GPL-2.0-only, the same license as the Linux kernel; see [LICENSE](LICENSE). Patches in
`kernel/patches/` keep their upstream authors' copyright.
