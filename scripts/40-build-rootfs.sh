#!/usr/bin/env bash
# Build the host rootfs: Debian minbase + Waydroid + a kiosk compositor.
#
# The prototype uses systemd because Waydroid's container and session units
# assume it; swapping it for a lighter init is a later trimming step.
# Needs root, debootstrap and qemu-user-static (binfmt) when not on arm64.
# Behind a TLS-intercepting proxy, set BUILD_CA=<proxy CA bundle>: it is
# trusted inside the chroot during the build only, and removed afterwards.
#
# Output: $OUT/rootfs/ and $OUT/rootfs.tar.zst
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
R=$OUT/rootfs
rm -rf "$R" && mkdir -p "$R"

debootstrap --arch=arm64 --variant=minbase \
	--include=systemd-sysv,udev,dbus,ca-certificates,curl,gnupg,kmod,iproute2,iwd \
	"$DEBIAN_SUITE" "$R" "$DEBIAN_MIRROR"

chroot_run() { chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

if [ -n "${BUILD_CA:-}" ]; then
	install -Dm644 "$BUILD_CA" "$R/usr/local/share/ca-certificates/rp6-build-ca.crt"
	chroot_run update-ca-certificates >/dev/null
fi

# Never pull docs, man pages or recommended extras.
cat > "$R/etc/apt/apt.conf.d/90minimal" <<-EOF
	APT::Install-Recommends "false";
	APT::Install-Suggests "false";
EOF
cat > "$R/etc/dpkg/dpkg.cfg.d/90nodoc" <<-EOF
	path-exclude=/usr/share/doc/*
	path-exclude=/usr/share/man/*
	path-exclude=/usr/share/info/*
	path-exclude=/usr/share/locale/*
	path-include=/usr/share/locale/locale.alias
	path-include=/usr/share/doc/*/copyright
EOF

# Waydroid's own repository (the Debian package lags behind).
curl -fsSL https://repo.waydro.id/waydroid.gpg -o "$R/usr/share/keyrings/waydroid.gpg"
echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ $DEBIAN_SUITE main" \
	> "$R/etc/apt/sources.list.d/waydroid.list"

chroot_run apt-get update
chroot_run apt-get install -y \
	waydroid cage \
	libgl1-mesa-dri mesa-vulkan-drivers \
	pipewire pipewire-pulse wireplumber alsa-ucm-conf \
	seatd zram-tools \
	kmscube vulkan-tools alsa-utils
chroot_run apt-get clean
if [ -n "${BUILD_CA:-}" ]; then
	rm "$R/usr/local/share/ca-certificates/rp6-build-ca.crt"
	chroot_run update-ca-certificates --fresh >/dev/null
fi
rm -rf "$R"/var/lib/apt/lists/*

# Retroid audio files, firmware and kernel modules from the earlier steps.
# tar, not cp: /lib is a symlink to usr/lib in Debian and must stay one.
for part in audio firmware kernel/modules; do
	[ -d "$OUT/$part" ] || continue
	tar -C "$OUT/$part" -cf - . | tar -C "$R" -xf - --keep-directory-symlink
done

# User that runs the kiosk session.
chroot_run useradd -m -G video,render,audio,input deck
chroot_run passwd -d deck
# Prototype: root without password on the local consoles (tty2-6) for
# debugging. There is no SSH server, so nothing is reachable over the network.
chroot_run passwd -d root
echo rp6 > "$R/etc/hostname"

# zram: half of RAM as compressed swap, no disk swap.
printf 'ALGO=zstd\nPERCENT=50\n' > "$R/etc/default/zramswap"

# The FAT partition is /boot, so kernel updates and wifi.txt are reachable.
cat > "$R/etc/fstab" <<-EOF
	PARTLABEL=$ROOT_LABEL  /      ext4  defaults,noatime  0 1
	PARTLABEL=rp6-boot     /boot  vfat  defaults,noatime,umask=0077  0 2
EOF

# Wi-Fi: iwd does DHCP itself. Credentials come from wifi.txt on the FAT
# partition (two lines: network name, password), which is easy to write
# from any computer before the first boot.
install -Dm644 /dev/stdin "$R/etc/iwd/main.conf" <<-'EOF'
	[General]
	EnableNetworkConfiguration=true
EOF
install -Dm755 /dev/stdin "$R/usr/local/sbin/rp6-wifi-from-boot" <<-'EOF'
	#!/bin/sh
	# Turn /boot/wifi.txt into an iwd profile, then delete it.
	set -eu
	f=/boot/wifi.txt
	[ -f "$f" ] || exit 0
	ssid=$(sed -n 1p "$f" | tr -d '\r')
	pass=$(sed -n 2p "$f" | tr -d '\r')
	[ -n "$ssid" ] || exit 0
	mkdir -p /var/lib/iwd
	printf '[Security]\nPassphrase=%s\n' "$pass" > "/var/lib/iwd/$ssid.psk"
	chmod 600 "/var/lib/iwd/$ssid.psk"
	rm -f "$f"
EOF
install -Dm644 /dev/stdin "$R/etc/systemd/system/rp6-wifi-from-boot.service" <<-'EOF'
	[Unit]
	Description=Import Wi-Fi credentials from the boot partition
	RequiresMountsFor=/boot
	Before=iwd.service
	ConditionPathExists=/boot/wifi.txt

	[Service]
	Type=oneshot
	ExecStart=/usr/local/sbin/rp6-wifi-from-boot

	[Install]
	WantedBy=multi-user.target
EOF

# Waydroid's Android images are about 1 GB and need network: download them on
# the first boot that has Wi-Fi, before the kiosk starts.
install -Dm644 /dev/stdin "$R/etc/systemd/system/waydroid-firstboot.service" <<-'EOF'
	[Unit]
	Description=Download Waydroid images on first boot
	Wants=network-online.target
	After=network-online.target
	Before=waydroid-container.service kiosk.service
	ConditionPathExists=!/var/lib/waydroid/waydroid.cfg

	[Service]
	Type=oneshot
	ExecStart=/usr/bin/waydroid init
	TimeoutStartSec=infinity
	# iwd does not report "online", so retry until the download works.
	Restart=on-failure
	RestartSec=30

	[Install]
	WantedBy=multi-user.target
EOF

# Boot straight into Waydroid's full UI inside cage on tty1.
install -Dm644 /dev/stdin "$R/etc/systemd/system/kiosk.service" <<-'EOF'
	[Unit]
	Description=Waydroid kiosk
	After=systemd-user-sessions.service waydroid-container.service
	Wants=waydroid-container.service

	[Service]
	User=deck
	PAMName=login
	TTYPath=/dev/tty1
	StandardInput=tty
	Environment=XDG_SESSION_TYPE=wayland
	ExecStart=/usr/bin/cage -s -- /usr/bin/waydroid show-full-ui
	Restart=always

	[Install]
	WantedBy=graphical.target
EOF
chroot_run systemctl enable kiosk.service waydroid-container.service zramswap.service iwd.service \
	rp6-wifi-from-boot.service waydroid-firstboot.service
chroot_run systemctl set-default graphical.target
chroot_run systemctl disable getty@tty1.service || true
# Units a handheld does not need.
chroot_run systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer \
	e2scrub_all.timer fstrim.timer systemd-timesyncd.service 2>/dev/null || true

tar -C "$R" -I 'zstd -19 -T0' -cf "$OUT/rootfs.tar.zst" .
du -sh "$R" "$OUT/rootfs.tar.zst"
