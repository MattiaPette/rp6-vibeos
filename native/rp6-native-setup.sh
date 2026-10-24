#!/bin/sh
# Prototype: games without Android. Run as root on a booted RP6 image.
#
#   native Steam client (Valve's ARM64 public beta) inside gamescope on DRM
#   -> Proton ARM64 (Steam downloads it; it carries FEX for x86 games)
#   -> DXVK/VKD3D -> Mesa Turnip on the mainline msm driver
#
# Steam keeps the client, Proton and the runtime up to date by itself, so
# nothing here has to follow FEX or DXVK releases. The kernel must use 4K
# pages (the ARM64 client does not load on 16K kernels); arm64 default is 4K.
#
# Reversible: "rp6-native-setup.sh off" goes back to the Waydroid kiosk.
set -eu

if [ "${1:-}" = off ]; then
	systemctl disable --now steam-session.service
	systemctl enable --now waydroid-container.service kiosk.service
	exit 0
fi

apt-get update
apt-get install -y gamescope xwayland mesa-vulkan-drivers vulkan-tools \
	libgtk2.0-0t64 libnss3 libvdpau1 libxss1 libpci3 libvpx9 unzip

# Valve's ARM64 bootstrap, the same steps the Asahi community scripts use.
S=/home/deck/.local/share/Steam
if [ ! -x "$S/steamrtarm64/steam" ]; then
	base=https://client-update.steamstatic.com
	zip=$(curl -fsSL "$base/steam_client_publicbeta_linuxarm64" \
		| grep -o 'bins_linuxarm64_linuxarm64\.zip[^"]*"' | head -n1 | tr -d '"')
	[ -n "$zip" ] || { echo "ARM64 manifest changed, check $base" >&2; exit 1; }
	tmp=$(mktemp -d)
	curl -fL "$base/$zip" -o "$tmp/steam.zip"
	mkdir -p "$S/package"
	unzip -oq "$tmp/steam.zip" -d "$S"
	rm -rf "$tmp"
	echo publicbeta > "$S/package/beta"
	ln -sfn steamrtarm64 "$S/steamrt64"
	touch "$S/.steam-enable-steamrt64-client"
	mkdir -p /home/deck/.steam
	for l in steam root sdkarm64; do ln -sfn "$S" "/home/deck/.steam/$l"; done
	chmod +x "$S"/steamrtarm64/* "$S"/*.sh 2>/dev/null || true
	chown -R deck:deck /home/deck/.local /home/deck/.steam
fi
# Libraries the client wants that the host lacks: fix these first if it fails.
echo "missing libraries:"
LD_LIBRARY_PATH=$S/steamrtarm64 ldd "$S/steamrtarm64/steam" | grep 'not found' || echo "  none"

# The panel is natively portrait (1080x1920): gamescope rotates it itself.
install -Dm644 /dev/stdin /etc/systemd/system/steam-session.service <<-'UNIT'
	[Unit]
	Description=Steam Big Picture in gamescope
	After=systemd-user-sessions.service network-online.target
	Conflicts=kiosk.service

	[Service]
	User=deck
	PAMName=login
	TTYPath=/dev/tty1
	StandardInput=tty
	Environment=LD_LIBRARY_PATH=/home/deck/.local/share/Steam/steamrtarm64
	ExecStart=/usr/bin/gamescope --backend drm --force-orientation left \
		-W 1920 -H 1080 -f -e -- \
		/home/deck/.local/share/Steam/steamrtarm64/steam -gamepadui -noverifyfiles
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=graphical.target
UNIT
systemctl disable --now kiosk.service waydroid-container.service
systemctl daemon-reload
systemctl enable --now steam-session.service
echo "Steam starting on screen; measure with: rp6-native-ram.sh"
