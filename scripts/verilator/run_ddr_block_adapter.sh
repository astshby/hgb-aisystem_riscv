#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ ]] || { echo 'usage: run_ddr_block_adapter.sh [32|64]' >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
out="build/verilator/ddr-block-adapter-rv$xlen"
log="logs/ddr-block-adapter-rv$xlen.build.log"
mkdir -p "$out" logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
    -DCORE_XLEN="$xlen" -Mdir "$out" \
    vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv \
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv \
    vsrc/pkg/soc_addr_pkg.sv vsrc/soc/bus/ddr_block_adapter.sv tb/soc/tb_ddr_block_adapter.sv \
    --top-module tb_ddr_block_adapter >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
if rg -n '%(Error|Warning-(WIDTH|UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
run_log="logs/ddr-block-adapter-rv$xlen.run.log"
"$out/Vtb_ddr_block_adapter" >"$run_log" 2>&1 || { tail -n 25 "$run_log"; exit 1; }
if rg -q '(%Fatal|%Error|Assertion failed)' "$run_log" || ! rg -q '^PASS tb_ddr_block_adapter ' "$run_log"; then
    tail -n 25 "$run_log"; exit 1
fi
rg '^PASS tb_ddr_block_adapter ' "$run_log"
