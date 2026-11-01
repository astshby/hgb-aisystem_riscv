#!/usr/bin/env bash
set -euo pipefail
xlen=${1:-32}
case "$xlen" in 32|64) ;; *) echo "XLEN must be32 or64" >&2; exit 2;; esac
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
build=${BOOT_OBSERVER_BUILD:-"$root/build/pango-boot-observer-rv$xlen"}
mkdir -p "$build"
verilator --binary --timing --assert -Wall -Wno-fatal -j 1 --top-module tb_pango_boot_observer     -GPC_WIDTH="$xlen" --Mdir "$build" vsrc/cpu/pango_boot_observer.sv tb/fpga/tb_pango_boot_observer.sv
"$build/Vtb_pango_boot_observer"
