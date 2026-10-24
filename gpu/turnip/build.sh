#!/usr/bin/env bash
# Build a glibc Turnip that drives the GPU through mainline DRM msm, packaged
# as a zip DroidDeck imports as its "Linux runtime driver".
# See gpu/README.md for why each link flag is there.
#
# Runs on arm64 Debian (trixie or later). With --install-deps it installs the
# build packages first, e.g. on a Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/w" -w /w debian:trixie \
#     gpu/turnip/build.sh --install-deps
# Output: out/turnip/turnip-msm-<mesa version>-Linux.zip
set -euo pipefail

MESA_VERSION=${MESA_VERSION:-26.2.5}
LIBDRM_VERSION=${LIBDRM_VERSION:-latest}
TOP=$(cd "$(dirname "$0")/../.." && pwd)
W=${WORK:-$TOP/out/turnip/build}
DEST=$TOP/out/turnip
FDO=https://gitlab.freedesktop.org/mesa
JOBS=${JOBS:-$(nproc)}

if [ "${1:-}" = --install-deps ]; then
	apt-get update
	# No libdrm-dev on purpose: libdrm is built static below.
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		ca-certificates git build-essential meson ninja-build pkg-config python3-mako python3-yaml \
		python3-packaging python3-ply bison flex glslang-tools zip binutils \
		libwayland-dev libwayland-bin wayland-protocols \
		libx11-dev libx11-xcb-dev libxcb1-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev \
		libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev libxshmfence-dev libxrandr-dev libxext-dev \
		libzstd-dev zlib1g-dev
fi

[ "$(uname -m)" = aarch64 ] || { echo "build on arm64 (natively or in an arm64 container)" >&2; exit 1; }
if dpkg -s libdrm-dev >/dev/null 2>&1; then
	echo "libdrm-dev is installed; remove it so Mesa links the static libdrm" >&2
	exit 1
fi

if [ "$LIBDRM_VERSION" = latest ]; then
	LIBDRM_VERSION=$(git ls-remote --tags --refs "$FDO/drm.git" 'libdrm-2.4.*' \
		| sed 's|.*refs/tags/libdrm-||' | sort -V | tail -1)
fi

rm -rf "$W" && mkdir -p "$W" "$DEST"
git clone -q --depth 1 -b "libdrm-$LIBDRM_VERSION" "$FDO/drm.git" "$W/libdrm"
git clone -q --depth 1 -b "mesa-$MESA_VERSION" "$FDO/mesa.git" "$W/mesa"
for p in "$TOP"/gpu/turnip/patches/*.patch; do
	[ -e "$p" ] || continue
	git -C "$W/mesa" apply "$p"
done

# 1. libdrm, static and position independent, so its symbols end up hidden
#    inside the driver. DroidDeck's runtime preloads drmPrimeFDToHandle,
#    drmPrimeHandleToFD and drmCloseBufferHandle replacements meant for KGSL;
#    a driver that calls the exported libdrm functions would get those.
P=$W/prefix
off=""
for o in intel radeon amdgpu nouveau vmwgfx omap exynos freedreno tegra vc4 etnaviv cairo-tests man-pages valgrind; do
	off="$off -D$o=disabled"
done
# shellcheck disable=SC2086
meson setup "$W/libdrm-build" "$W/libdrm" --prefix="$P" --libdir=lib --buildtype=release \
	-Ddefault_library=static -Db_staticpic=true -Dtests=false $off
ninja -C "$W/libdrm-build" -j"$JOBS" install

# 2. Turnip, msm kernel interface only.
cc -O2 -fPIC -c "$TOP/gpu/turnip/ioctl_wrap.c" -o "$W/ioctl_wrap.o"
link="$W/ioctl_wrap.o -Wl,--wrap=ioctl -Wl,--exclude-libs,ALL"
PKG_CONFIG_PATH=$P/lib/pkgconfig meson setup "$W/mesa-build" "$W/mesa" --prefix="$W/mesa-install" \
	--buildtype=release -Db_ndebug=true -Dstrip=true \
	-Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm -Dgallium-drivers= \
	-Dplatforms=x11,wayland -Dglx=disabled -Degl=disabled -Dgbm=disabled \
	-Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dllvm=disabled \
	-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dxmlconfig=disabled -Dzstd=enabled \
	-Dc_link_args="$link" -Dcpp_link_args="$link"
ninja -C "$W/mesa-build" -j"$JOBS" src/freedreno/vulkan/libvulkan_freedreno.so
so=$W/mesa-build/src/freedreno/vulkan/libvulkan_freedreno.so

# 3. Prove the preloads cannot reach the driver.
fail=0
if readelf -dW "$so" | grep -q 'NEEDED.*libdrm'; then
	echo "check: links libdrm.so dynamically" >&2; fail=1
fi
if readelf --dyn-syms -W "$so" | awk '{print $8}' | grep -qE '^(ioctl|drm[A-Z][A-Za-z0-9]*)(@|$)'; then
	echo "check: imports or exports ioctl/drm* symbols:" >&2
	readelf --dyn-syms -W "$so" | awk '{print $7, $8}' | grep -E ' (ioctl|drm[A-Z])' >&2
	fail=1
fi
[ "$fail" = 0 ] || exit 1
glibc=$(objdump -T "$so" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -V | tail -1)

# 4. The zip DroidDeck's "Linux runtime driver" import takes: the library
#    and a meta.json (LinuxVulkanDriverManager.installDriver).
pkg=$W/pkg && rm -rf "$pkg" && mkdir -p "$pkg"
cp "$so" "$pkg/libvulkan_freedreno.so"
cat > "$pkg/meta.json" <<-JSON
	{
	  "schemaVersion": 1,
	  "kind": "linux-vulkan-icd",
	  "name": "Turnip msm $MESA_VERSION (rp6-vibeos)",
	  "driverVersion": "$MESA_VERSION",
	  "libc": "glibc",
	  "minGlibc": "$glibc",
	  "libdrm": "$LIBDRM_VERSION"
	}
JSON
zip="$DEST/turnip-msm-$MESA_VERSION-Linux.zip"
rm -f "$zip" && (cd "$pkg" && zip -q -9 "$zip" libvulkan_freedreno.so meta.json)
echo "turnip: $zip (Mesa $MESA_VERSION, libdrm $LIBDRM_VERSION, glibc >= $glibc)"
