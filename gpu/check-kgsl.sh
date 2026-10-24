#!/bin/sh
# Run as root on the RP6: checks every piece DroidDeck needs to see a "KGSL"
# GPU, on the host and, when Waydroid is running, inside the container.
#   gpu/check-kgsl.sh [turnip-msm-*-Linux.zip]
# With the zip it also asks that Turnip, on the host, which GPU it finds.
K=/sys/class/kgsl/kgsl-3d0
ok=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; ok=1; }

lsmod | grep -q '^kgsl_shim' && pass "kgsl_shim loaded" || fail "kgsl_shim not loaded (modprobe kgsl_shim)"
for f in gpu_model gpu_chipid gpubusy gpu_busy_percentage gpuclk max_gpuclk \
	gpu_available_frequencies temp devfreq/cur_freq devfreq/gpu_load; do
	if v=$(cat "$K/$f" 2>/dev/null); then pass "$f = $v"; else fail "$f unreadable"; fi
done

render=""
for r in /sys/class/drm/renderD*; do
	case "$(basename "$(readlink -f "$r/device/driver")")" in msm*) render=$r ;; esac
done
[ -n "$render" ] && pass "msm render node: /dev/$(basename "$render") ($(cat "$render/dev"))" \
	|| fail "no msm render node (is the GPU up? dmesg | grep -i adreno)"
if [ -c /dev/kgsl-3d0 ]; then
	n=$(stat -c '%t:%T' /dev/kgsl-3d0)
	want=$(printf '%x:%x' "$(cut -d: -f1 "$render/dev")" "$(cut -d: -f2 "$render/dev")" 2>/dev/null)
	[ "$n" = "$want" ] && pass "/dev/kgsl-3d0 is the render node ($(stat -c %a /dev/kgsl-3d0))" \
		|| fail "/dev/kgsl-3d0 is $n, render node is $want"
else
	fail "/dev/kgsl-3d0 missing (udev rule 70-kgsl-node.rules)"
fi

if command -v waydroid >/dev/null && waydroid status 2>/dev/null | grep -q 'Container:.*RUNNING'; then
	waydroid shell -- ls -l /dev/kgsl-3d0 >/dev/null 2>&1 && pass "container sees /dev/kgsl-3d0" \
		|| fail "container has no /dev/kgsl-3d0 (restart waydroid-container after the node exists)"
	m=$(waydroid shell -- cat "$K/gpu_model" 2>/dev/null)
	[ -n "$m" ] && pass "container reads gpu_model = $m" || fail "container cannot read $K"
else
	echo "skip Waydroid checks (container not running)"
fi

if [ -n "$1" ]; then
	t=$(mktemp -d)
	unzip -q -o "$1" -d "$t"
	printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' \
		"$t/libvulkan_freedreno.so" > "$t/icd.json"
	if command -v vulkaninfo >/dev/null; then
		if out=$(VK_DRIVER_FILES=$t/icd.json VK_ICD_FILENAMES=$t/icd.json vulkaninfo --summary 2>&1) \
			&& echo "$out" | grep -q 'deviceName'; then
			echo "$out" | grep -E 'deviceName|driverName|driverInfo'
			pass "Turnip from $1 finds the GPU"
		else
			echo "$out" | tail -n 20
			fail "vulkaninfo found no device with $1"
		fi
	else
		echo "skip Turnip check (no vulkaninfo: apt install vulkan-tools)"
	fi
	rm -rf "$t"
fi
exit $ok
