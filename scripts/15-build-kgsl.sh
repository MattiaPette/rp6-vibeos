#!/usr/bin/env bash
# EXPERIMENTAL: build Qualcomm's KGSL GPU driver (msm_kgsl.ko) out of tree
# against the kernel from 10-build-kernel.sh, plus an RP6 device tree that
# gives the GPU to KGSL instead of msm. This is GPU plan B: DroidDeck's
# Turnip talks to /dev/kgsl-3d0 natively. Untested on hardware.
# Output: $OUT/kgsl/{msm_kgsl.ko,rp6-kgsl.dtb}
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

K=$SRC/linux
B=$OUT/kernel/build
G=$SRC/kgsl-modules
KGSL=$G/qcom/opensource/graphics-kernel
[ -f "$B/Module.symvers" ] || { echo "run scripts/10-build-kernel.sh first" >&2; exit 1; }

if [ ! -d "$G/.git" ]; then
	git clone --filter=blob:none --sparse --no-checkout "$KGSL_REPO" "$G"
	git -C "$G" sparse-checkout set qcom/opensource/graphics-kernel
fi
git -C "$G" fetch --depth 1 origin "$KGSL_COMMIT"
git -C "$G" checkout -q -f "$KGSL_COMMIT"
git -C "$G" clean -qfdx -- qcom/opensource/graphics-kernel
for p in "$TOP"/kgsl/patches/*.patch; do
	git -C "$G" apply --directory=qcom/opensource/graphics-kernel "$p"
done

make -C "$K" O="$B" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" \
	M="$KGSL" KERNEL_SRC="$K" KGSL_RP6=y modules

mkdir -p "$OUT/kgsl"
"${CROSS_COMPILE}strip" --strip-debug -o "$OUT/kgsl/msm_kgsl.ko" "$KGSL/msm_kgsl.ko"

d=$TOP/kgsl/dts/qcs8550-retroidpocket-rp6-kgsl.dts
"${CROSS_COMPILE}gcc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I "$K/arch/arm64/boot/dts" -I "$K/include" "$d" \
	| "$B/scripts/dtc/dtc" -q -@ -I dts -O dtb -i "$K/arch/arm64/boot/dts" -o "$OUT/kgsl/rp6-kgsl.dtb"
echo "kgsl: $(du -h "$OUT/kgsl/msm_kgsl.ko" | cut -f1) module, dtb in $OUT/kgsl"
