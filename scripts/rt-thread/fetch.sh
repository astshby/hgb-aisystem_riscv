#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
dest=build/rt-thread-v5.2.2
revision=ddf52e2cdd977f14fc04035c88672ac204aec713
if [[ ! -e "$dest" ]]; then
    mkdir -p build
    git clone --depth 1 --branch v5.2.2 --sparse https://github.com/RT-Thread/rt-thread.git "$dest"
    git -C "$dest" sparse-checkout set include src libcpu/risc-v/common components/drivers
fi
[[ "$(git -C "$dest" rev-parse HEAD)" == "$revision" ]] || { echo 'dependency revision mismatch'; exit 1; }
echo "RT-Thread v5.2.2 $revision"
