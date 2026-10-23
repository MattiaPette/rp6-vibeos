#!/usr/bin/env bash
# Pack kernel + DTB into an Android boot.img for the RP6 bootloader (ABL).
#
# Try it WITHOUT flashing first:   fastboot boot out/boot.img
# That boots once from RAM and leaves the stock Android untouched.
#
# The header version ABL accepts on this device is not verified yet; v2 with
# a separate DTB is the usual choice for mainline on Snapdragon handhelds.
# Override with BOOT_HEADER=<n> if fastboot refuses it.
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

BOOT_HEADER=${BOOT_HEADER:-2}
K=$OUT/kernel
ramdisk=$OUT/empty-ramdisk.cpio.gz
# No initramfs: UFS, SD and ext4 are built in. ABL still wants a ramdisk.
printf '' | cpio -o -H newc 2>/dev/null | gzip -9 > "$ramdisk"

args=(--kernel "$K/Image.gz" --ramdisk "$ramdisk" --cmdline "$CMDLINE"
	--header_version "$BOOT_HEADER" --pagesize 4096 --base 0x0
	--kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100
	--os_version 16.0.0 --os_patch_level 2026-10)
[ "$BOOT_HEADER" -ge 2 ] && args+=(--dtb "$K/rp6.dtb" --dtb_offset 0x1f00000)

mkbootimg "${args[@]}" -o "$OUT/boot.img"
ls -l "$OUT/boot.img"
