# Sourced by scripts/40-build-rootfs.sh : Steam ARM64 inside
# cage, no Android. Expects R, chroot_run and the deck user to exist.
#
# Valve's ARM64 bootstrap, done at build time so the first boot
# does not download it. The kernel must use 4K pages (arm64 default).

S=/home/deck/.local/share/Steam

# The rootfs resolver is a symlink into /run: give the chroot the build host's
# for the downloads below, and put the symlink back at the end.
rm -f "$R/etc/resolv.conf"
cp /etc/resolv.conf "$R/etc/resolv.conf"

# Valve's ARM64 bootstrap.
chroot_run /bin/sh -eu <<-'BOOT'
	base=https://client-update.steamstatic.com
	zip=$(curl -fsSL "$base/steam_client_publicbeta_linuxarm64" \
		| grep -o 'bins_linuxarm64_linuxarm64\.zip[^"]*"' | head -n1 | tr -d '"')
	[ -n "$zip" ] || { echo "ARM64 manifest changed, check $base" >&2; exit 1; }
	S=/home/deck/.local/share/Steam
	mkdir -p "$S/package" /tmp/steam-boot
	curl -fL "$base/$zip" -o /tmp/steam-boot/steam.zip
	unzip -oq /tmp/steam-boot/steam.zip -d "$S"
	rm -rf /tmp/steam-boot
	echo publicbeta > "$S/package/beta"
	ln -sfn steamrtarm64 "$S/steamrt64"
	touch "$S/.steam-enable-steamrt64-client"
	mkdir -p /home/deck/.steam
	for l in steam root sdkarm64; do ln -sfn "$S" "/home/deck/.steam/$l"; done
	chmod +x "$S"/steamrtarm64/* "$S"/*.sh 2>/dev/null || true
BOOT

# Optional first self-update, STEAM_PREUPDATE=1 (off: the client asserts under
# Xvfb in the build chroot, not solved yet). ~670 MB download, ~2 GB extracted; on the SD card it
# takes more than ten minutes, so run the client once here under Xvfb and let
# it finish. Best effort: when it does not complete, the device does it on
# first boot as usual.
if [ "${STEAM_PREUPDATE:-0}" = 1 ]; then
	chroot_run apt-get update
	chroot_run apt-get install -y xvfb xauth
	mount -t proc proc "$R/proc"; mount --rbind /dev "$R/dev"; mount -t sysfs sys "$R/sys"
	chroot_run /bin/sh -u <<-'UPD' || echo "Steam pre-update did not complete: the first boot will do it" >&2
		chown -R deck:deck /home/deck/.local /home/deck/.steam
		su deck -c '
			export HOME=/home/deck LD_LIBRARY_PATH=/home/deck/.local/share/Steam/steamrtarm64
			log=$HOME/.local/share/Steam/logs/bootstrap_log.txt
			xvfb-run -a $HOME/.local/share/Steam/steamrtarm64/steam -gamepadui -noverifyfiles </dev/null >/tmp/steam-pre.log 2>&1 &
			# Done once the update was applied and the real client started.
			for i in $(seq 1 120); do
				sleep 15
				pgrep -x steamwebhelper >/dev/null && exit 0
			done
			exit 1'
	UPD
	[ -z "${STEAM_LOG_DIR:-}" ] || cp "$R"/tmp/steam-pre.log "$R"/home/deck/.local/share/Steam/logs/*.txt "$STEAM_LOG_DIR" 2>/dev/null || true
	chroot_run pkill -u deck || true
	sleep 3
	umount -R "$R/dev" "$R/sys" "$R/proc" || true
	chroot_run apt-get purge -y --autoremove xvfb xauth
	chroot_run apt-get clean
	rm -rf "$R"/var/lib/apt/lists/* "$R/tmp/steam-pre.log" "$R/tmp/dumps" "$R"/home/deck/.local/share/Steam/logs/*
fi
chroot_run chown -R deck:deck /home/deck/.local /home/deck/.steam
rm -f "$R/etc/resolv.conf"
ln -s /run/resolvconf/resolv.conf "$R/etc/resolv.conf"

# The panel is natively portrait (1080x1920): rotate it from inside cage.
install -Dm755 /dev/stdin "$R/usr/local/bin/rp6-steam-launch" <<-'EOF2'
	#!/bin/sh
	out=$(wlr-randr | awk '/^[^ ]/{print $1; exit}')
	[ -n "$out" ] && wlr-randr --output "$out" --transform 90
	# Wi-Fi is not up yet at boot and iwd never reports "online" (so
	# network-online.target does not wait for it): without the network the
	# first self-update fails and Steam dies on a missing steamui.so.
	until curl -fsS -m 10 -o /dev/null https://client-update.steamstatic.com/steam_client_publicbeta_linuxarm64; do sleep 3; done
	exec /home/deck/.local/share/Steam/steamrtarm64/steam -gamepadui -noverifyfiles
EOF2
install -Dm644 /dev/stdin "$R/etc/systemd/system/steam-session.service" <<-'EOF2'
	[Unit]
	Description=Steam Big Picture in cage
	After=systemd-user-sessions.service network-online.target

	[Service]
	User=deck
	PAMName=login
	TTYPath=/dev/tty1
	StandardInput=tty
	UtmpIdentifier=tty1
	UtmpMode=user
	Environment=LD_LIBRARY_PATH=/home/deck/.local/share/Steam/steamrtarm64
	Environment=WLR_NO_HARDWARE_CURSORS=1
	ExecStart=/usr/bin/cage -s -- /usr/local/bin/rp6-steam-launch
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=graphical.target
EOF2
