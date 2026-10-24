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
	waydroid weston bluez \
	libgl1-mesa-dri mesa-vulkan-drivers \
	pipewire pipewire-pulse wireplumber alsa-ucm-conf \
	seatd zram-tools \
	kmscube vulkan-tools alsa-utils \
	fdisk e2fsprogs openresolv dropbear-bin systemd-timesyncd
chroot_run apt-get clean
# The slim kernel only has the nftables backend. waydroid-net.sh prefers
# iptables-legacy when present, which fails without ip_tables.ko, so drop the
# legacy binaries and let it fall back to iptables (= iptables-nft).
rm -f "$R"/usr/sbin/{iptables,ip6tables}-legacy{,-save,-restore}
if [ -n "${BUILD_CA:-}" ]; then
	rm "$R/usr/local/share/ca-certificates/rp6-build-ca.crt"
	chroot_run update-ca-certificates --fresh >/dev/null
fi
rm -rf "$R"/var/lib/apt/lists/*
# debootstrap copied the build host's resolvers. iwd runs resolvconf under
# ProtectSystem=strict, which keeps it from writing /etc, so resolvconf writes
# in /run (still writable for it) and /etc/resolv.conf points there.
rm -f "$R/etc/resolv.conf"
ln -s /run/resolvconf/resolv.conf "$R/etc/resolv.conf"
sed -i 's|^#\?resolv_conf=.*|resolv_conf=/run/resolvconf/resolv.conf|' "$R/etc/resolvconf.conf"
grep -q '^resolv_conf=/run/resolvconf/resolv.conf$' "$R/etc/resolvconf.conf" \
	|| echo 'resolv_conf=/run/resolvconf/resolv.conf' >> "$R/etc/resolvconf.conf"

# Retroid audio files, firmware and kernel modules from the earlier steps.
# tar, not cp: /lib is a symlink to usr/lib in Debian and must stay one.
# kgsl-shim/root is the /dev/kgsl-3d0 overlay from 16-build-kgsl-shim.sh.
for part in audio firmware kernel/modules kgsl-shim/root; do
	[ -d "$OUT/$part" ] || continue
	tar -C "$OUT/$part" -cf - . | tar -C "$R" -xf - --keep-directory-symlink
done
# The real KGSL from 15-build-kgsl.sh only binds with its own device tree,
# which the SD image offers as a separate boot entry.
if [ -f "$OUT/kgsl/msm_kgsl.ko" ]; then
	kver=$(cat "$OUT/kernel/build/include/config/kernel.release")
	install -Dm644 "$OUT/kgsl/msm_kgsl.ko" "$R/lib/modules/$kver/extra/msm_kgsl.ko"
	depmod -b "$R" "$kver"
fi

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

# Wi-Fi: iwd does DHCP itself and hands the DNS servers to resolvconf, which
# needs no daemon (iwd's default is systemd-resolved). Credentials come from
# wifi.txt on the FAT partition (two lines: network name, password), which is
# easy to write from any computer before the first boot.
install -Dm644 /dev/stdin "$R/etc/iwd/main.conf" <<-'EOF'
	[General]
	EnableNetworkConfiguration=true

	[Network]
	NameResolvingService=resolvconf
EOF
install -Dm755 /dev/stdin "$R/usr/local/sbin/rp6-wifi-from-boot" <<-'EOF'
	#!/bin/sh
	# Turn /boot/wifi.txt into an iwd profile, then delete it.
	set -eu
	f=/boot/wifi.txt
	[ -f "$f" ] || exit 0
	ssid=$(sed -n 1p "$f" | tr -d '\r')
	pass=$(sed -n 2p "$f" | tr -d '\r')
	# Optional static IPv4: line 3 address/prefix, line 4 gateway, line 5 DNS
	# (the gateway when empty). Without line 3 iwd uses DHCP.
	addr=$(sed -n 3p "$f" | tr -d '\r ')
	gw=$(sed -n 4p "$f" | tr -d '\r ')
	dns=$(sed -n 5p "$f" | tr -d '\r ')
	[ -n "$ssid" ] || exit 0
	# iwd names profiles after the SSID only when it is plain alphanumeric,
	# space, - or _; any other SSID is written as = and its hex bytes.
	case $ssid in
	*[!A-Za-z0-9\ _-]*) name="=$(printf %s "$ssid" | od -An -tx1 | tr -d ' \n')" ;;
	*) name=$ssid ;;
	esac
	mkdir -p /var/lib/iwd
	umask 077
	printf '[Security]\nPassphrase=%s\n' "$pass" > "/var/lib/iwd/$name.psk"
	if [ -n "$addr" ]; then
		bits=${addr#*/}
		[ "$bits" != "$addr" ] || bits=24
		# Prefix length to dotted netmask, which is what iwd wants.
		mask= n=$bits
		for i in 1 2 3 4; do
			if [ "$n" -ge 8 ]; then o=255; n=$((n - 8)); else o=$((256 - (1 << (8 - n)))); n=0; fi
			mask=$mask${mask:+.}$o
		done
		printf '\n[IPv4]\nAddress=%s\nNetmask=%s\nGateway=%s\nDNS=%s\n' \
			"${addr%/*}" "$mask" "$gw" "${dns:-$gw}" >> "/var/lib/iwd/$name.psk"
	fi
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

# The image is only as big as the rootfs; grow the root partition and its
# filesystem to the whole card on first boot, before Waydroid needs the space.
install -Dm755 /dev/stdin "$R/usr/local/sbin/rp6-grow-root" <<-'EOF'
	#!/bin/sh
	# Grow the partition holding / to the end of its disk, then ext4 online.
	set -eux
	# Without an initramfs / shows up as /dev/root, so find the partition by
	# its device number: /sys/dev/block/<maj:min> -> .../<disk>/<partition>.
	# findmnt pads its column with spaces.
	sys=$(readlink -f "/sys/dev/block/$(findmnt -no MAJ:MIN / | tr -d ' ')")
	dev=/dev/$(basename "$sys")
	disk=/dev/$(basename "$(dirname "$sys")")
	part=$(cat "$sys/partition")
	# --force: the disk is in use (it holds /). The write also moves the
	# backup GPT header to the new end of the card.
	echo ', +' | sfdisk -q --no-reread --force -N "$part" "$disk"
	partx -u -n "$part" "$disk"
	resize2fs "$dev"
	touch /var/lib/rp6-root-grown
EOF
install -Dm644 /dev/stdin "$R/etc/systemd/system/rp6-grow-root.service" <<-'EOF'
	[Unit]
	Description=Grow the root partition to the whole card
	Before=waydroid-firstboot.service
	RequiresMountsFor=/boot
	ConditionPathExists=!/var/lib/rp6-root-grown

	[Service]
	Type=oneshot
	ExecStart=/usr/local/sbin/rp6-grow-root
	# Readable from any computer: there may be no keyboard on the device.
	StandardOutput=append:/boot/rp6-grow-root.log
	StandardError=append:/boot/rp6-grow-root.log

	[Install]
	WantedBy=multi-user.target
EOF

# SSH for debugging from a computer: dropbear (small, socket-activated so it
# costs no RAM while idle), key login only. The key comes from
# authorized_keys on the FAT partition, copied over on every boot.
install -Dm755 /dev/stdin "$R/usr/local/sbin/rp6-ssh-keys-from-boot" <<-'EOF'
	#!/bin/sh
	set -eu
	[ -f /boot/authorized_keys ] || exit 0
	install -d -m700 /root/.ssh
	tr -d '\r' < /boot/authorized_keys > /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys
EOF
install -Dm644 /dev/stdin "$R/etc/systemd/system/rp6-ssh-keys-from-boot.service" <<-'EOF'
	[Unit]
	Description=Import SSH keys from the boot partition
	RequiresMountsFor=/boot

	[Service]
	Type=oneshot
	ExecStart=/usr/local/sbin/rp6-ssh-keys-from-boot

	[Install]
	WantedBy=multi-user.target
EOF
# dropbear -R writes its host keys here, but dropbear-bin does not create it.
install -d -m700 "$R/etc/dropbear"
install -Dm644 /dev/stdin "$R/etc/systemd/system/dropbear.socket" <<-'EOF'
	[Unit]
	Description=SSH (dropbear)

	[Socket]
	ListenStream=22
	Accept=yes

	[Install]
	WantedBy=sockets.target
EOF
install -Dm644 /dev/stdin "$R/etc/systemd/system/dropbear@.service" <<-'EOF'
	[Unit]
	Description=SSH session (dropbear)

	[Service]
	# -i: inetd mode, -s: no password logins, -R: make host keys on first use
	ExecStart=-/usr/sbin/dropbear -i -s -R
	StandardInput=socket
	StandardError=journal
EOF

# Waydroid's Android images are about 1 GB and need network: download them on
# the first boot that has Wi-Fi, before the kiosk starts.
install -Dm644 /dev/stdin "$R/etc/systemd/system/waydroid-firstboot.service" <<-'EOF'
	[Unit]
	Description=Download Waydroid images on first boot
	Wants=network-online.target
	After=network-online.target
	Before=waydroid-container.service kiosk.service
	# waydroid init writes waydroid.cfg before downloading, so it is no proof
	# that the images are there: use a marker written only on success.
	ConditionPathExists=!/var/lib/rp6-waydroid-ready

	[Service]
	Type=oneshot
	# iwd does not report "online", so retry within this one start job: the
	# container and the kiosk stay ordered after a successful init.
	ExecStart=/bin/sh -c 'until /usr/bin/waydroid init; do sleep 30; done'
	ExecStartPost=/usr/bin/touch /var/lib/rp6-waydroid-ready
	TimeoutStartSec=infinity

	[Install]
	WantedBy=multi-user.target
EOF

# The panel is natively portrait (1080x1920, DT rotation=270) and cage cannot
# rotate its output, so use weston's kiosk shell, which can.
install -Dm644 /dev/stdin "$R/etc/rp6/weston.ini" <<-'EOF2'
	[core]
	shell=kiosk-shell.so
	idle-time=0

	[output]
	name=DSI-1
	transform=rotate-270

	[autolaunch]
	path=/usr/bin/waydroid
	args=show-full-ui
EOF2

# Boot straight into Waydroid's full UI inside weston on tty1.
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
	ExecStart=/usr/bin/weston --config=/etc/rp6/weston.ini --socket=wayland-1
	Restart=always

	[Install]
	WantedBy=graphical.target
EOF
chroot_run systemctl enable kiosk.service waydroid-container.service zramswap.service iwd.service \
	rp6-wifi-from-boot.service waydroid-firstboot.service rp6-grow-root.service \
	rp6-ssh-keys-from-boot.service dropbear.socket systemd-timesyncd.service
chroot_run systemctl set-default graphical.target
chroot_run systemctl disable getty@tty1.service || true
# A short press of the power button must not shut the system down (logind's
# default): it is how one turns the screen off on a handheld. Hold it to power off.
install -Dm644 /dev/stdin "$R/etc/systemd/logind.conf.d/10-rp6-power-key.conf" <<-'EOF'
	[Login]
	HandlePowerKey=ignore
	HandlePowerKeyLongPress=poweroff
EOF
# Android has no lights HAL here, so brightness lives on the host backlight.
# Start at half on the first boot only; later boots keep whatever was set.
install -Dm755 /dev/stdin "$R/usr/local/bin/rp6-brightness" <<-'EOF2'
	#!/bin/sh
	# rp6-brightness <0-100>
	bl=$(ls -d /sys/class/backlight/* | head -n1)
	max=$(cat "$bl/max_brightness")
	echo $(( max * $1 / 100 )) > "$bl/brightness"
EOF2
install -Dm644 /dev/stdin "$R/etc/systemd/system/rp6-brightness.service" <<-'EOF2'
	[Unit]
	Description=Set a sane first-boot brightness
	ConditionPathExists=!/var/lib/rp6-brightness-set
	Before=kiosk.service

	[Service]
	Type=oneshot
	ExecStart=/usr/local/bin/rp6-brightness 50
	ExecStartPost=/usr/bin/touch /var/lib/rp6-brightness-set

	[Install]
	WantedBy=multi-user.target
EOF2
chroot_run systemctl enable rp6-brightness.service bluetooth.service
# Units a handheld does not need.
chroot_run systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer \
	e2scrub_all.timer fstrim.timer 2>/dev/null || true
# Pulled in by Waydroid's lxc dependency: Waydroid sets up its own bridge and
# starts its container itself. weston gets the seat from logind, not seatd.
chroot_run systemctl disable lxc.service lxc-net.service lxc-monitord.service seatd.service

tar -C "$R" -I 'zstd -19 -T0' -cf "$OUT/rootfs.tar.zst" .
du -sh "$R" "$OUT/rootfs.tar.zst"
