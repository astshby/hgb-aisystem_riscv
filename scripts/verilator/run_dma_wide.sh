#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || { echo 'XLEN must be 32 or 64' >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" logs
for wide in 0 1; do
    out="build/verilator/dma-wide-rv${xlen}-w${wide}"
    log="logs/dma-wide-rv${xlen}-w${wide}.log"
    mkdir -p "$out"
    verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
        -DCORE_XLEN="$xlen" -Mdir "$out" -f scripts/soc_files.f \
        tb/soc/axi_memory_model.sv tb/soc/tb_dma_fabric.sv \
        -GREGISTERED=1 -GWIDE_ENABLE="$wide" --top-module tb_dma_fabric >"$log" 2>&1
    if rg -q '%Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|DECLFILENAME|WIDTH[A-Z]*)' "$log"; then
        tail -n 30 "$log"; exit 1
    fi
    "$out/Vtb_dma_fabric" >>"$log" 2>&1
    if rg -q '%Fatal|%Error|Assertion failed' "$log"; then tail -n 30 "$log"; exit 1; fi
    rg '^DMA_COPY|^PASS tb_dma_fabric' "$log"
done
for top in tb_ddr_port_arbiter tb_ddr_to_axi; do
out="build/verilator/${top}-rv${xlen}"
log="logs/${top}-rv${xlen}.log"
mkdir -p "$out"
verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
    -DCORE_XLEN="$xlen" -Mdir "$out" -f scripts/soc_files.f \
    "tb/soc/${top}.sv" --top-module "$top" >"$log" 2>&1
if rg -q '%Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|DECLFILENAME|WIDTH[A-Z]*)' "$log"; then tail -n 30 "$log"; exit 1; fi
"$out/V${top}" >>"$log" 2>&1
if rg -q '%Fatal|%Error|Assertion failed' "$log"; then tail -n 30 "$log"; exit 1; fi
rg "^PASS ${top}" "$log"
done
