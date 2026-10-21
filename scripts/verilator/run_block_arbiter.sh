#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ ]] || { echo 'usage: run_block_arbiter.sh [32|64]' >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
out="build/verilator/block-arbiter-rv$xlen"
log="logs/block-arbiter-rv$xlen.build.log"
mkdir -p "$out" logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
    -DCORE_XLEN="$xlen" -Mdir "$out" \
    vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv \
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv \
    vsrc/soc/bus/block_arbiter.sv tb/soc/tb_block_arbiter.sv \
    --top-module tb_block_arbiter >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
if rg -n '%(Error|Warning-(WIDTH|UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
for seed in 2970378289 101 8675309; do
    run_log="logs/block-arbiter-rv${xlen}-seed${seed}.log"
    "$out/Vtb_block_arbiter" "+SEED=$seed" >"$run_log" 2>&1 || { tail -n 25 "$run_log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$run_log" || ! rg -q '^PASS tb_block_arbiter ' "$run_log"; then
        tail -n 25 "$run_log"; exit 1
    fi
    rg '^PASS tb_block_arbiter ' "$run_log"
done
echo "PASS block arbiter RV$xlen: 3 seeds, 0 SKIP"
