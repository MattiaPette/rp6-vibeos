#!/usr/bin/env bash
# Assemble a microSD image that OpenABL (the ABL ROCKNIX installs) boots:
#   p1  FAT32 ESP  extlinux/extlinux.conf, Image, dtbs/<DTB>
#   p2  ext4       $OUT/rootfs, found by the kernel as PARTLABEL=$ROOT_LABEL
#
# Without $OUT/rootfs the image holds a test root whose only program is
# tools/diag-init.c: it copies the kernel log to rp6-log/ on the ESP, so a
# black screen can still be diagnosed from a computer. Firmware from
# 30-collect-firmware.sh goes in too when it is there.
#
# No loop devices: both filesystems are built in files and copied into the
# partitioned image. Packing a real rootfs needs root, because the Debian tree
# from 40-build-rootfs.sh holds root-only files and mkfs.ext4 -d must read them
# and keep their owners; the kernel-only image does not.
# Write it with: dd if=out/rp6-sd.img of=/dev/<sdcard> bs=4M conv=fsync
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

K=$OUT/kernel
IMG=$OUT/rp6-sd.img
W=$OUT/sdimage
rm -rf "$W" && mkdir -p "$W"

ESP_MB=256
if [ -d "$OUT/rootfs" ]; then
	[ "$(id -u)" = 0 ] || { echo "packing $OUT/rootfs needs root: sudo $0" >&2; exit 1; }
	root_src=$OUT/rootfs
else
	root_src=$W/test-root
	mkdir -p "$root_src"/{sbin,dev,proc,sys,boot}
	"${CROSS_COMPILE}gcc" -static -Os -o "$root_src/sbin/init" "$TOP/tools/diag-init.c"
	[ -d "$OUT/firmware/lib" ] && cp -r "$OUT/firmware/lib" "$root_src/"
	echo "no $OUT/rootfs: building a kernel-only test image"
fi
# Rootfs size plus 25% and 256 MB of headroom.
ROOT_MB=$(( $(du -sm "$root_src" | cut -f1) * 5 / 4 + 256 ))

# ESP
cat > "$W/extlinux.conf" <<-EOF
	DEFAULT rp6-vibeos
	LABEL rp6-vibeos
	  LINUX /Image
	  FDT /dtbs/$DTB
	  APPEND $CMDLINE
EOF
truncate -s "${ESP_MB}M" "$W/esp.img"
mkfs.vfat -F 32 -n RP6BOOT "$W/esp.img" >/dev/null
mmd -i "$W/esp.img" ::/extlinux ::/dtbs ::/dtbs/qcom
mcopy -i "$W/esp.img" "$W/extlinux.conf" ::/extlinux/extlinux.conf
mcopy -i "$W/esp.img" "$K/Image" ::/Image
mcopy -i "$W/esp.img" "$K/rp6.dtb" "::/dtbs/$DTB"

# Root
mkfs.ext4 -q -L "$ROOT_LABEL" -d "$root_src" "$W/root.img" "${ROOT_MB}M"

# GPT image: 1 MiB alignment, ESP then root.
total_mb=$(( 1 + ESP_MB + ROOT_MB + 1 ))
rm -f "$IMG" && truncate -s "${total_mb}M" "$IMG"
sfdisk -q "$IMG" <<-EOF
	label: gpt
	start=1MiB, size=${ESP_MB}MiB, type=uefi, name=rp6-boot
	size=${ROOT_MB}MiB, type=linux, name=$ROOT_LABEL
EOF
dd if="$W/esp.img" of="$IMG" bs=1M seek=1 conv=notrunc status=none
dd if="$W/root.img" of="$IMG" bs=1M seek=$(( 1 + ESP_MB )) conv=notrunc status=none

rm -rf "$W"
ls -l "$IMG"
