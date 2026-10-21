#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-all}" in
    32|64) widths=("$1") ;;
    all) widths=(32 64) ;;
    *) echo 'usage: run_block_backends.sh [32|64|all]' >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" logs
for xlen in "${widths[@]}"; do
    for top in tb_block_to_axi tb_pango_block_bridge; do
        if [[ "$top" == tb_block_to_axi ]]; then
            sources=(vsrc/soc/bus/block_to_axi.sv tb/soc/axi_block_memory_model.sv tb/soc/tb_block_to_axi.sv)
        else
            sources=(vsrc/cpu/pango_block_bridge.sv tb/unit/tb_pango_block_bridge.sv)
        fi
        out="build/verilator/block-backend-rv${xlen}/${top}"
        log="logs/block-backend-rv${xlen}-${top}.log"
        mkdir -p "$out"
        verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
            -DCORE_XLEN="$xlen" -Mdir "$out" \
            vsrc/pkg/core_config_pkg.sv vsrc/pkg/core_types_pkg.sv \
            vsrc/pkg/soc_addr_pkg.sv vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv \
            "${sources[@]}" --top-module "$top" >"$log" 2>&1 || { tail -n 40 "$log"; exit 1; }
        if rg -q '%Error|Warning-(WIDTH[A-Z]*|UNOPTFLAT|LATCH|MULTIDRIVEN|DECLFILENAME)' "$log"; then
            tail -n 45 "$log"
            exit 1
        fi
        "$out/V${top}" >>"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
        rg "^PASS ${top}" "$log"
    done
done
