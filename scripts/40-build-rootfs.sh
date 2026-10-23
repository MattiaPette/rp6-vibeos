#!/usr/bin/env bash
# Build the host rootfs: Debian minbase + Waydroid + a kiosk compositor.
#
# The prototype uses systemd because Waydroid's container and session units
# assume it; swapping it for a lighter init is a later trimming step.
# Needs root, debootstrap and qemu-user-static (binfmt) when not on arm64.
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
rm -rf "$R"/var/lib/apt/lists/*

# Retroid audio files, firmware and kernel modules from the earlier steps.
for part in audio firmware; do
	[ -d "$OUT/$part" ] && cp -a "$OUT/$part/." "$R/"
done
[ -d "$OUT/kernel/modules/lib/modules" ] && cp -a "$OUT/kernel/modules/lib/modules" "$R/lib/"

# User that runs the kiosk session.
chroot_run useradd -m -G video,render,audio,input deck
chroot_run passwd -d deck
echo rp6 > "$R/etc/hostname"

# zram: half of RAM as compressed swap, no disk swap.
printf 'ALGO=zstd\nPERCENT=50\n' > "$R/etc/default/zramswap"

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
chroot_run systemctl enable kiosk.service waydroid-container.service zramswap.service iwd.service
chroot_run systemctl set-default graphical.target
chroot_run systemctl disable getty@tty1.service || true
# Units a handheld does not need.
chroot_run systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer \
	e2scrub_all.timer fstrim.timer systemd-timesyncd.service 2>/dev/null || true

tar -C "$R" -I 'zstd -19 -T0' -cf "$OUT/rootfs.tar.zst" .
du -sh "$R" "$OUT/rootfs.tar.zst"
