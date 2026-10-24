#!/usr/bin/env bash
# Configure and cross-compile the Retroid 7.3 kernel for the RP6 only.
#   1. arm64 defconfig with every non-Qualcomm platform switched off
#   2. + driver symbols resolved from the RP6 device tree (dt2config.py)
#   3. + kernel/rp6.config, last so its choices win
# kernel/patches/*.patch are applied to the source first (once).
# Output: $OUT/kernel/{Image,rp6.dtb,dtbs-test/,modules/}
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

K=$SRC/linux
B=$OUT/kernel/build
mk() { make -C "$K" O="$B" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" "$@"; }

for p in "$TOP"/kernel/patches/*.patch; do
	[ -e "$p" ] || continue
	git -C "$K" apply --check -R "$p" 2>/dev/null || git -C "$K" apply "$p"
done

mkdir -p "$B"
mk defconfig

# Only the Qualcomm platform.
frag=$B/platforms.config
sed -nE 's/^config (ARCH_[A-Z0-9_]+)$/# CONFIG_\1 is not set/p' "$K/arch/arm64/Kconfig.platforms" \
	| grep -v 'CONFIG_ARCH_QCOM ' > "$frag"

# Driver symbols for every enabled node of the RP6 device tree.
mk "$DTB"
dtc -q -I dtb -O dts "$B/arch/arm64/boot/dts/$DTB" > "$B/rp6.dts"
python3 -I "$TOP/scripts/dt2config.py" "$K" "$B/rp6.dts" > "$B/dt.config" 2> "$B/dt-unresolved.txt"
echo "dt2config: $(wc -l < "$B/dt.config") symbols, $(wc -l < "$B/dt-unresolved.txt") unresolved compatibles (see $B/dt-unresolved.txt)"

KCONFIG_CONFIG=$B/.config "$K/scripts/kconfig/merge_config.sh" -m -O "$B" \
	"$B/.config" "$frag" "$B/dt.config" "$TOP/kernel/rp6.config"
mk olddefconfig

# Report fragment symbols that Kconfig refused (missing dependencies).
grep -hE '^CONFIG_' "$TOP/kernel/rp6.config" | while IFS= read -r want; do
	grep -qxF "$want" "$B/.config" || echo "not applied: $want"
done | tee "$B/not-applied.txt"

mk Image modules "$DTB"
rm -rf "$OUT/kernel/modules"
mk INSTALL_MOD_PATH="$OUT/kernel/modules" INSTALL_MOD_STRIP=1 modules_install
cp "$B/arch/arm64/boot/Image" "$OUT/kernel/Image"
cp "$B/arch/arm64/boot/dts/$DTB" "$OUT/kernel/rp6.dtb"
cp "$B/.config" "$OUT/kernel/config"

# Bring-up variants of the RP6 tree (kernel/dts-test), offered as extra boot
# entries by 50-make-sdimage.sh.
rm -rf "$OUT/kernel/dtbs-test" && mkdir -p "$OUT/kernel/dtbs-test"
for d in "$TOP"/kernel/dts-test/*.dts; do
	[ -e "$d" ] || continue
	n=$(basename "$d" .dts)
	"${CROSS_COMPILE}gcc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
		-I "$TOP/kernel/dts-test" -I "$K/arch/arm64/boot/dts" -I "$K/include" "$d" \
		| "$B/scripts/dtc/dtc" -q -@ -I dts -O dtb -i "$K/arch/arm64/boot/dts" -o "$OUT/kernel/dtbs-test/$n.dtb"
done
echo "kernel: $(du -h "$OUT/kernel/Image" | cut -f1), modules: $(du -sh "$OUT/kernel/modules" | cut -f1)"
