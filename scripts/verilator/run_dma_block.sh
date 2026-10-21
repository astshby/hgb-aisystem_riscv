#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ ]] || { echo 'usage: run_dma_block.sh [32|64]' >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
out="build/verilator/dma-block-rv$xlen"
log="logs/dma-block-rv$xlen.build.log"
mkdir -p "$out" logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
    -DCORE_XLEN="$xlen" -Mdir "$out" -f scripts/soc_files.f \
    tb/soc/axi_block_memory_model.sv tb/soc/tb_dma_block.sv \
    --top-module tb_dma_block >"$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
if rg -n '%(Error|Warning-(WIDTH|UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
for seed in 1396970114 101 8675309; do
    run_log="logs/dma-block-rv${xlen}-seed${seed}.log"
    "$out/Vtb_dma_block" "+SEED=$seed" >"$run_log" 2>&1 || { tail -n 30 "$run_log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$run_log" || ! rg -q '^PASS tb_dma_block ' "$run_log"; then
        tail -n 30 "$run_log"; exit 1
    fi
    rg '^PASS tb_dma_block ' "$run_log"
done
echo "PASS DMA block RV$xlen: 3 seeds, 0 SKIP"
