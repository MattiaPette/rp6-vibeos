#!/usr/bin/env bash
# Build the kgsl-shim module against the kernel from 10-build-kernel.sh and
# stage the files that expose the GPU to DroidDeck as /dev/kgsl-3d0.
# See gpu/README.md.
# Output: the module in $OUT/kernel/modules, the rest in $OUT/kgsl-shim/
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

K=$SRC/linux
B=$OUT/kernel/build
M=$OUT/kgsl-shim/build
[ -f "$B/Module.symvers" ] || { echo "run scripts/10-build-kernel.sh first" >&2; exit 1; }

rm -rf "$M" && mkdir -p "$M"
cp "$TOP"/gpu/kgsl-shim/{Kbuild,kgsl_shim.c} "$M/"
mk() { make -C "$K" O="$B" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" M="$M" "$@"; }
mk W=1 modules
mk INSTALL_MOD_PATH="$OUT/kernel/modules" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra modules_install
kver=$(cat "$B/include/config/kernel.release")
depmod -b "$OUT/kernel/modules" "$kver"

rm -rf "$OUT/kgsl-shim/root" && mkdir -p "$OUT/kgsl-shim/root"
cp -a "$TOP/gpu/overlay/." "$OUT/kgsl-shim/root/"
echo "kgsl-shim: $(find "$OUT/kernel/modules" -name kgsl_shim.ko), overlay in $OUT/kgsl-shim/root"
