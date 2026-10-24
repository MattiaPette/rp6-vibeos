#!/usr/bin/env bash
# Collect only the firmware the RP6 needs.
#
# Usage: 30-collect-firmware.sh <stock-dump-dir>
#
# <stock-dump-dir> holds files copied from the RP6's stock Android, e.g.:
#   adb pull /vendor/firmware        <dir>/vendor-firmware
#   adb pull /vendor/firmware_mnt    <dir>/firmware_mnt   (modem partition)
#   adb pull /vendor/dsp             <dir>/dsp
# The device-signed blobs (GPU zap shader, ADSP, CDSP) exist only there.
# Split images (.mdt + .bNN) are joined into .mbn with pil-squasher.
#
# Output: $OUT/firmware/lib/firmware/...
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

DUMP=${1:?usage: $0 <stock-dump-dir>}
D=$OUT/firmware/lib/firmware
FW=$SRC/linux-firmware
rm -rf "$OUT/firmware" && mkdir -p "$D"

# Generic blobs from linux-firmware (GPU microcode, Wi-Fi, BT, video).
for f in qcom/a740_sqe.fw qcom/gmu_gen70200.bin; do
	install -Dm644 "$FW/$f" "$D/$f"
done
(cd "$FW" && cp -r --parents ath12k/WCN7850 qcom/vpu/vpu30_p4* qca/hmt* "$D/")

# Device-signed blobs: <name in the stock dump> <path the RP6 DTS asks for>
R=qcom/sm8550/retroidpocket
while read -r stock want; do
	src=$(find "$DUMP" -iname "$stock.mbn" -print -quit)
	if [ -z "$src" ]; then
		mdt=$(find "$DUMP" -iname "$stock.mdt" -print -quit)
		if [ -n "$mdt" ]; then
			command -v pil-squasher >/dev/null || { echo "need pil-squasher for $mdt" >&2; exit 1; }
			mkdir -p "$(dirname "$D/$want")"
			pil-squasher "$D/$want" "$mdt"
			continue
		fi
		echo "missing in dump: $stock (for $want)" >&2
		continue
	fi
	install -Dm644 "$src" "$D/$want"
done <<-EOF
	a740_zap $R/a740_zap.mbn
	adsp $R/rp6/adsp.mbn
	adsp_dtb $R/rp6/adsp_dtb.mbn
	cdsp $R/cdsp.mbn
	cdsp_dtb $R/cdsp_dtb.mbn
EOF

acf=$(find "$DUMP" -iname 'aw883xx_acf.bin' -print -quit)
if [ -n "$acf" ]; then install -Dm644 "$acf" "$D/$R/rp6/aw883xx_acf.bin"; else echo "missing in dump: aw883xx_acf.bin" >&2; fi

du -sh "$D"
