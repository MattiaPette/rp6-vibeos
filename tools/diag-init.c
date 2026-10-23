/*
 * Minimal /sbin/init for the kernel-only test image.
 *
 * The screen may stay black while bring-up is in progress, so this init saves
 * what the kernel says to the microSD's FAT partition, which a Mac or PC can
 * read: rp6-log/dmesg.txt (kernel log) and rp6-log/deferred.txt (drivers
 * still waiting for something). Both are rewritten every 5 seconds for two
 * minutes; then init just sleeps.
 *
 * Build: aarch64-linux-gnu-gcc -static -Os -o init diag-init.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_BUF (4 << 20)
#define SYSLOG_ACTION_READ_ALL 3	/* glibc does not export the names */

static char buf[LOG_BUF];

static void save(const char *path, const char *data, ssize_t len)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0)
		return;
	if (len > 0 && write(fd, data, len) < 0)
		perror(path);
	fsync(fd);
	close(fd);
}

static void copy_file(const char *from, const char *to)
{
	int fd = open(from, O_RDONLY);
	ssize_t len = 0, n;

	if (fd < 0)
		return;
	while (len < LOG_BUF && (n = read(fd, buf + len, LOG_BUF - len)) > 0)
		len += n;
	close(fd);
	save(to, buf, len);
}

static int mount_esp(void)
{
	/* The SD card is the only mmc device; its first partition is the ESP. */
	static const char *const devs[] = { "/dev/mmcblk0p1", "/dev/mmcblk1p1" };

	for (unsigned i = 0; i < sizeof(devs) / sizeof(devs[0]); i++)
		if (mount(devs[i], "/boot", "vfat", 0, NULL) == 0)
			return 0;
	return -1;
}

int main(void)
{
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);

	printf("rp6 diag-init: saving logs to the SD card's FAT partition\n");
	for (int i = 0; i < 24; i++) {
		if (mount_esp() == 0) {
			mkdir("/boot/rp6-log", 0755);
			save("/boot/rp6-log/dmesg.txt", buf,
			     klogctl(SYSLOG_ACTION_READ_ALL, buf, LOG_BUF));
			copy_file("/sys/kernel/debug/devices_deferred", "/boot/rp6-log/deferred.txt");
			umount("/boot");
		}
		sleep(5);
	}
	printf("rp6 diag-init: done, logs are in rp6-log/ on the SD card\n");
	for (;;)
		pause();
}
