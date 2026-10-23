#!/usr/bin/env bash
# Shallow-clone the Retroid kernel, audio topology, UCM and linux-firmware.
set -euo pipefail
# shellcheck source=config.env
. "$(dirname "$0")/../config.env"

clone() { # url branch dir [extra git args]
	local url=$1 branch=$2 dir=$3; shift 3
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch --depth 1 origin "$branch"
		git -C "$dir" checkout -q FETCH_HEAD
	else
		git clone --depth 1 -b "$branch" "$@" "$url" "$dir"
	fi
}

mkdir -p "$SRC"
clone "$KERNEL_REPO" "$KERNEL_BRANCH" "$SRC/linux"
clone "$TOPOLOGY_REPO" "$TOPOLOGY_BRANCH" "$SRC/audioreach-topology"
clone "$UCM_REPO" "$UCM_BRANCH" "$SRC/alsa-ucm-conf"
# linux-firmware is >1 GB; fetch only the few directories the RP6 needs.
clone "$LINUX_FIRMWARE_REPO" main "$SRC/linux-firmware" --filter=blob:none --sparse
git -C "$SRC/linux-firmware" sparse-checkout set --no-cone \
	'/qcom/a740_sqe.fw' '/qcom/gmu_gen70200.bin' '/qcom/vpu/' \
	'/ath12k/WCN7850/' '/qca/hmt*' '/WHENCE' '/LICENSE.*'
