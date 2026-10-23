#!/usr/bin/env bash
# Build the RP6 AudioReach topology and stage it with Retroid's UCM tree.
# Output: $OUT/audio/{lib/firmware/qcom/$SOC/*-tplg.bin,usr/share/alsa/ucm2/}
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

T=$SRC/audioreach-topology
D=$OUT/audio
rm -rf "$D" && mkdir -p "$D/lib/firmware/qcom/$SOC" "$D/usr/share/alsa"

# Same two steps as the repo's CMakeLists.txt, for our one board only.
m4 -I "$T" "$T/$TOPOLOGY_NAME.m4" > "$OUT/$TOPOLOGY_NAME.conf"
alsatplg -c "$OUT/$TOPOLOGY_NAME.conf" -o "$D/lib/firmware/qcom/$SOC/$TOPOLOGY_NAME-tplg.bin"

# The whole ucm2 tree is ~4 MB and its files include each other across
# directories, so it is copied as is rather than picked apart.
cp -r "$SRC/alsa-ucm-conf/ucm2" "$D/usr/share/alsa/"
ls -l "$D/lib/firmware/qcom/$SOC"
