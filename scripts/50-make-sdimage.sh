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
# One more entry per bring-up device tree, picked from OpenABL's Boot entries.
for t in "$K"/dtbs-test/*.dtb; do
	[ -e "$t" ] || continue
	n=$(basename "$t" .dtb)
	printf 'LABEL %s\n  LINUX /Image\n  FDT /dtbs/test/%s.dtb\n  APPEND %s\n' "$n" "$n" "$CMDLINE" >> "$W/extlinux.conf"
done
# Experimental KGSL entry (15-build-kgsl.sh): its tree gives the GPU to KGSL,
# so the kgsl-shim that fakes KGSL on top of msm must stay unloaded, and msm
# must not expose a render node that the shim's udev rule would turn into
# /dev/kgsl-3d0 (separate_gpu_kms: a display-only msm device has none).
if [ -f "$OUT/kgsl/rp6-kgsl.dtb" ]; then
	printf 'LABEL rp6-vibeos-kgsl\n  LINUX /Image\n  FDT /dtbs/kgsl/rp6-kgsl.dtb\n  APPEND %s modprobe.blacklist=kgsl_shim msm.separate_gpu_kms=1\n' "$CMDLINE" >> "$W/extlinux.conf"
fi
truncate -s "${ESP_MB}M" "$W/esp.img"
mkfs.vfat -F 32 -n RP6BOOT "$W/esp.img" >/dev/null
mmd -i "$W/esp.img" ::/extlinux ::/dtbs ::/dtbs/qcom
mcopy -i "$W/esp.img" "$W/extlinux.conf" ::/extlinux/extlinux.conf
mcopy -i "$W/esp.img" "$K/Image" ::/Image
mcopy -i "$W/esp.img" "$K/rp6.dtb" "::/dtbs/$DTB"
if [ -f "$OUT/kgsl/rp6-kgsl.dtb" ]; then
	mmd -i "$W/esp.img" ::/dtbs/kgsl
	mcopy -i "$W/esp.img" "$OUT/kgsl/rp6-kgsl.dtb" ::/dtbs/kgsl/
fi
if compgen -G "$K/dtbs-test/*.dtb" >/dev/null; then
	mmd -i "$W/esp.img" ::/dtbs/test
	mcopy -i "$W/esp.img" "$K"/dtbs-test/*.dtb ::/dtbs/test/
fi

# Root
mkfs.ext4 -q -L "$ROOT_LABEL" -d "$root_src" "$W/root.img" "${ROOT_MB}M"

# GPT image: 1 MiB alignment, ESP then root.
# p1 is typed "basic data", not ESP: OpenABL reads any FAT partition, and
# macOS then mounts it on its own (it never automounts an ESP), so logs and
# files on it are easy to reach from a Mac.
BASIC_DATA=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
total_mb=$(( 1 + ESP_MB + ROOT_MB + 1 ))
rm -f "$IMG" && truncate -s "${total_mb}M" "$IMG"
sfdisk -q "$IMG" <<-EOF
	label: gpt
	start=1MiB, size=${ESP_MB}MiB, type=$BASIC_DATA, name=rp6-boot
	size=${ROOT_MB}MiB, type=linux, name=$ROOT_LABEL
EOF
dd if="$W/esp.img" of="$IMG" bs=1M seek=1 conv=notrunc status=none
dd if="$W/root.img" of="$IMG" bs=1M seek=$(( 1 + ESP_MB )) conv=notrunc status=none

rm -rf "$W"
ls -l "$IMG"
