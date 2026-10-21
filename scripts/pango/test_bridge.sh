#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR"

for xlen in 32 64; do
    out="build/verilator/pango-bridge-rv$xlen"
    mkdir -p "$out" logs
    verilator -Wall -Wno-fatal -Wno-TIMESCALEMOD --assert --timing --binary -j 1 \
        -DCORE_XLEN="$xlen" -Mdir "$out" \
        vsrc/pkg/core_config_pkg.sv vsrc/pkg/core_types_pkg.sv \
        vsrc/pkg/soc_addr_pkg.sv vsrc/pkg/bus_types_pkg.sv \
        vsrc/cpu/pango_ddr3_bridge.sv vsrc/soc/bus/ddr_port_arbiter.sv tb/unit/tb_pango_ddr3_bridge.sv \
        --top-module tb_pango_ddr3_bridge > "logs/pango-bridge-build-rv$xlen.log" 2>&1 || {
        tail -n 40 "logs/pango-bridge-build-rv$xlen.log"
        exit 1
    }
    if rg -q '%Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|WIDTH[A-Z]*)' "logs/pango-bridge-build-rv$xlen.log"; then
        tail -n 40 "logs/pango-bridge-build-rv$xlen.log"
        exit 1
    fi
    "$out/Vtb_pango_ddr3_bridge" | tee "logs/pango-bridge-rv$xlen.log"
done
