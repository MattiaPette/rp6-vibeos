# rp6-vibeos

A minimal system for the Retroid Pocket 6 (QCS8550, 8 GB) whose only purpose is to run
Steam while leaving as much RAM and storage as possible to games and the GPU. No Android.

Architecture: Retroid's mainline 7.3 kernel → minimal Debian (trixie) → `cage` (one-window
Wayland compositor, with Xwayland) running Valve's native ARM64 Steam client in Big Picture
mode, rotated to landscape → Proton ARM64 (it carries FEX for x86 games) → DXVK/VKD3D → Mesa
Turnip on the mainline `msm` driver. Steam updates the client, Proton and the runtime itself.

> Status: early prototype. The kernel-only test image boots from microSD and shows the kernel
> log on the built-in display. Turnip works on the device (`vulkaninfo` reports Adreno 740).
> Steam as a whole has not been verified to run yet.

## Build

On an x86_64 or arm64 Linux host with `gcc-aarch64-linux-gnu`, `bc`, `flex`, `bison`,
`libssl-dev`, `device-tree-compiler`, `m4`, `alsa-utils` (`alsatplg`), `dosfstools`,
`mtools`, `e2fsprogs`, `fdisk` (`sfdisk`), `debootstrap`, `qemu-user-static`, `zstd`
(`scripts/40-build-rootfs.sh` also downloads Valve's Steam ARM64 bootstrap and, best effort, runs its
first self-update under Xvfb so the SD card does not extract it on first boot; `STEAM_PREUPDATE=0` skips that):

```sh
scripts/01-fetch-sources.sh            # kernel, topology, UCM, linux-firmware (only the files needed)
scripts/10-build-kernel.sh             # RP6 config + drivers derived from the device tree
scripts/20-build-audio.sh              # AudioReach topology + UCM
scripts/30-collect-firmware.sh <dump>  # generic firmware + signed blobs from stock Android
sudo scripts/40-build-rootfs.sh        # Debian minbase + cage + Steam ARM64 (BUILD_CA=<pem> behind a TLS proxy)
sudo scripts/50-make-sdimage.sh        # microSD image for OpenABL (no root needed without a rootfs)
```

Shared settings live in `config.env`, the kernel config fragments in `kernel/`.
`scripts/dt2config.py` reads the RP6 DTB and enables the driver for every active node, so the
config does not have to be written by hand. `kernel/rp6-slim.config` and a generated filter
drop what arm64 defconfig builds for other hardware (other Qualcomm SoCs, NICs, cameras, codecs,
Type-C chips...), and `kernel/rp6.config` comes last with the RP6's own choices. The build
prints any symbol the device tree or `rp6.config` asks for that Kconfig refused.

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

4. The kernel-only image saves the boot logs to `rp6-log/` on the FAT partition (`RP6BOOT`)
   for 2 minutes, readable from any computer.

## Wi-Fi and Steam on first boot

Before the first boot, create `wifi.txt` on the `RP6BOOT` FAT partition with two lines: the
network name and the password. Three more optional lines set a static IPv4 address instead of
DHCP: address with prefix, gateway, DNS server (the gateway when left out):

```
MyNetwork
MyPassword
192.168.1.50/24
192.168.1.1
```

At boot the system turns it into an iwd profile and deletes the file. The first boot also grows
the root partition to the whole card; its log is `rp6-grow-root.log` on `RP6BOOT`. Steam then starts full screen in cage; log in with the on-screen
keyboard or a controller. If the client was not updated at build time, the first start downloads
and extracts about 670 MB, which takes many minutes on a microSD: do not power off meanwhile.

There is no login prompt on the screen: `deck` (no password) runs Steam (`steam-session.service`). For debugging,
switch to tty2 (`Ctrl+Alt+F2` with a USB keyboard) and log in as `root` (no password on this
prototype image).

For SSH, copy your public key to `RP6BOOT` as `authorized_keys`
(`cp ~/.ssh/id_ed25519.pub /Volumes/RP6BOOT/authorized_keys`), then `ssh root@<rp6-ip>`.
Only key logins are accepted.

## License

GPL-2.0-only, the same license as the Linux kernel; see [LICENSE](LICENSE). Patches in
`kernel/patches/` keep their upstream authors' copyright.
