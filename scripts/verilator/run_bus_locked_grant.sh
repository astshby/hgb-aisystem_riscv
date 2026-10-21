#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in
    32|64) ;;
    *) echo "XLEN must be 32 or 64" >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"

# 通用反压复现与既有 fabric/DMA 回归独立存证；只运行一个编译进程。
passes=0
for name in tb_bus_locked_grant tb_soc_fabric tb_dma_fabric; do
    for mode in 0 1; do
        if [[ "$name" == tb_dma_fabric ]]; then
            parameter="-GREGISTERED=$mode"
        else
            parameter="-GDATA_PRIORITY=$mode"
        fi
        out="build/verilator/bus-locked-rv${xlen}/${name}-m${mode}"
        log="logs/bus-locked-rv${xlen}-${name}-m${mode}.log"
        mkdir -p "$out"
        verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
            -DCORE_XLEN="$xlen" -Mdir "$out" -f scripts/soc_files.f \
            tb/soc/axi_memory_model.sv "tb/soc/${name}.sv" "$parameter" \
            --top-module "$name" >"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
        "$out/V${name}" >>"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS ${name}" "$log"; then
            tail -n 25 "$log"
            exit 1
        fi
        rg "^PASS ${name}" "$log"
        passes=$((passes + 1))
    done
done
echo "PASS bus-locked RV${xlen}: ${passes} runs, 0 SKIP"
