# GPU: a KGSL face for the msm driver

DroidDeck is written for Android phones, where the Adreno GPU is driven by Qualcomm's KGSL
driver (`/dev/kgsl-3d0`). Mainline Linux drives the same GPU with DRM msm
(`/dev/dri/renderD128`) and has no KGSL. This directory makes the unmodified DroidDeck APK,
running in Waydroid, find and use the msm GPU.

Status: prototype, not yet run on the device. The kernel module compiles against the 7.3 tree;
the Turnip build runs in CI (`.github/workflows/turnip-msm.yml`).

## What DroidDeck looks at

Read from DroidDeck `0b671b2` (2026-10-24). Paths are relative to `app/src/main/java/com/droiddeck/launcher/`.

| Where | What it does with KGSL | Needed here |
|---|---|---|
| `core/DeviceSupport.adreno()`, `gpu/GpuInfo.detect()` | GPU is "Adreno" only if `/sys/class/kgsl/kgsl-3d0` exists; model from its `gpu_model` (`Adreno740v2` → 740), chip id from `gpu_chipid` | sysfs |
| `runtime/LinuxRuntime.bindGpuNode()` | `stat("/dev/kgsl-3d0")`, then binds that node into the Linux runtime as `/dev/dri/renderD<minor>` with a fake `/sys/dev/char/<maj>:<min>` (`uevent`: `DRIVER=kgsl-3d0`, `MODALIAS=platform:kgsl-3d0`; `driver` → `msm_drm`) | device node |
| `runtime/BwrapSpawner.gpu()` | Uses the runtime's own Turnip only if `/dev/kgsl-3d0` exists | device node |
| Runtime preloads `tools/linuxfs/preload/{drm,netif}.c` | Any fd whose device equals `/dev/kgsl-3d0`'s gets fake libdrm PRIME handles, and its `DRM_IOCTL_GEM_CLOSE` never reaches the kernel | see below |
| `session/GpuStatsComponent`, `gpu/DeviceInfo` | HUD and device page read `gpubusy`, `gpu_busy_percentage`, `gpuclk`, `max_gpuclk`, `gpu_available_frequencies`, `temp`, `devfreq/*` | sysfs (nice to have) |
| `session/GpuClockPin`, `waylandcomp/gpu_clock_pin.c` | KGSL ioctls to hold the clock high | fails cleanly on msm, clock stays governed |
| `gpu/TurnipDriver` (Android side) | The compositor draws with a bundled AdrenoTools Turnip, which is built for KGSL | open, see below |

Waydroid already passes `/dev/kgsl-3d0` into the container when the host has it
(`tools/helpers/lxc.py`, "Graphic dev nodes"), and mounts the host's `/sys` read-only, so
nothing in Waydroid needs to change.

## The three pieces

1. **`/dev/kgsl-3d0` is the msm render node.** `overlay/etc/udev/rules.d/70-kgsl-node.rules`
   makes a second device node with the render node's own major:minor (226:128). DroidDeck then
   binds the real msm render node into its runtime, under the name and with the sysfs it already
   fakes for KGSL. libdrm accepts that fake sysfs (it falls back to `MODALIAS` when there is no
   `OF_FULLNAME`), so an msm Turnip inside the runtime enumerates it as a normal platform DRM
   device. A drop-in makes `waydroid-container` wait for the node, since Waydroid only passes
   nodes that exist when it starts.
2. **`/sys/class/kgsl/kgsl-3d0` is a small kernel module.** `kgsl-shim/kgsl_shim.c` registers a
   `kgsl` class with one device and no device node. Its files are read-only and filled from the
   msm GPU's devfreq (clock, levels, busy time) and the `gpuss-0` thermal zone. It never talks to
   the GPU. Built by `scripts/16-build-kgsl-shim.sh`, loaded through `modules-load.d`. It is the
   alternative to the real KGSL from `scripts/15-build-kgsl.sh`: both register the `kgsl` class,
   so only one of them can be installed.
3. **A Turnip built for msm, which the runtime preloads cannot reach.** The runtime's own Turnip
   speaks KGSL only, so DroidDeck gets an msm one through its "Linux runtime driver" import
   (on its Components page; a zip with `libvulkan_freedreno.so` and `meta.json`).
   `turnip/build.sh` builds it. Because `/dev/kgsl-3d0` is now the msm node, the runtime's
   preloads would take every fd Turnip opens for a KGSL fd: `drmPrimeFDToHandle` would return a
   made-up handle that msm does not know, and `GEM_CLOSE` would be swallowed, leaking every
   buffer. The build avoids both without patching Mesa:
   - libdrm is linked **static** and `-Wl,--exclude-libs,ALL` hides its symbols, so Turnip's
     libdrm calls stay inside the library and cannot be interposed;
   - `-Wl,--wrap=ioctl` sends every `ioctl()` in the driver (libdrm's included) to
     `turnip/ioctl_wrap.c`, which enters the kernel with `svc #0`. The runtime also preloads
     `syscall()`, so that is avoided too.

   `build.sh` checks the result: no `libdrm.so` dependency and no `ioctl` or `drm*` dynamic
   symbol. Mesa's default is 26.2.5, the release DroidDeck's own desktop pins.

## Still open

- **The compositor (Android side).** DroidDeck's compositor runs on Android and loads a bundled
  KGSL Turnip through AdrenoTools by default. In Waydroid there is no KGSL, so it has to use
  either the system driver (create `Download/droiddeck-driver` containing `system` in Waydroid's
  shared storage; that is the Vulkan driver of the Waydroid image) or an imported AdrenoTools zip
  of an Android Turnip built for msm. Which of the two works is the first thing to check on the
  device. If the image has no usable Vulkan, the next step is an Android (bionic) msm Turnip
  build, the same way as above but with the NDK.
- **Other runtime programs on the GPU node.** gamescope, Xwayland and KWin also get the fake
  PRIME handles. They already get them on real KGSL phones, where the same preloads run, and
  draw through Vulkan (Turnip) or Zink, so this should not matter. It is still worth watching.
- **The GPU firmware** (`a740_zap.mbn`, `a740_sqe.fw`, `gmu_gen70200.bin`) must be in place,
  or the msm GPU never comes up and there is no render node at all.

## Testing on the device

1. Boot the full image, then `sudo gpu/check-kgsl.sh`: module loaded, every sysfs file
   readable, `/dev/kgsl-3d0` equal to the msm render node, and the same seen from Waydroid.
2. `sudo gpu/check-kgsl.sh turnip-msm-26.2.5-Linux.zip` (the zip from the CI artifact, which
   GitHub wraps in a second zip) runs `vulkaninfo` on the host with that Turnip: the device
   should be a Turnip Adreno 740.
3. In DroidDeck: the device page should say Adreno 740. Import the zip as the Linux runtime
   driver, pick the display driver (see "Still open"), and start a Steam session.
4. If the session falls back to drawing on the CPU, the session folder's log tells which piece
   is missing (`gpu: the runtime has no …`, `LinuxVulkanDriver`, `TurnipDriver`).
