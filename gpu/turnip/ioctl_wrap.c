// SPDX-License-Identifier: GPL-2.0-only
/*
 * Linked into libvulkan_freedreno.so together with -Wl,--wrap=ioctl.
 *
 * DroidDeck's Linux runtime preloads an ioctl() wrapper that treats every fd
 * on the /dev/kgsl-3d0 device as KGSL: DRM_IOCTL_GEM_CLOSE on it is answered
 * from a table of made-up PRIME handles and never reaches the kernel. Here
 * /dev/kgsl-3d0 is the msm render node, so that would leak every buffer the
 * driver frees. The driver therefore enters the kernel itself; the runtime
 * also preloads syscall(), so not even that is called.
 */
#include <errno.h>
#include <stdarg.h>
#include <sys/syscall.h>

#ifndef __aarch64__
#error "aarch64 only"
#endif

__attribute__((visibility("hidden"))) int __wrap_ioctl(int fd, unsigned long request, ...)
{
	register long x8 __asm__("x8") = SYS_ioctl;
	register long x0 __asm__("x0") = fd;
	register long x1 __asm__("x1") = (long)request;
	register long x2 __asm__("x2");
	va_list ap;

	va_start(ap, request);
	x2 = (long)va_arg(ap, void *);
	va_end(ap);
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory", "cc");
	if (x0 < 0 && x0 > -4096) {
		errno = (int)-x0;
		return -1;
	}
	return (int)x0;
}
