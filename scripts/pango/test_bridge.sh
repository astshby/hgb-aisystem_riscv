#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

for xlen in 32 64; do
    out="build/verilator/pango-bridge-rv$xlen"
    mkdir -p "$out" logs
    verilator -Wall -Wno-fatal -Wno-TIMESCALEMOD --assert --timing --binary \
        -DCORE_XLEN="$xlen" -Mdir "$out" \
        vsrc/pkg/core_config_pkg.sv vsrc/pkg/core_types_pkg.sv \
        vsrc/pkg/soc_addr_pkg.sv vsrc/pkg/bus_types_pkg.sv \
        vsrc/cpu/pango_ddr3_bridge.sv tb/unit/tb_pango_ddr3_bridge.sv \
        --top-module tb_pango_ddr3_bridge > "logs/pango-bridge-build-rv$xlen.log" 2>&1 || {
        tail -n 40 "logs/pango-bridge-build-rv$xlen.log"
        exit 1
    }
    "$out/Vtb_pango_ddr3_bridge" | tee "logs/pango-bridge-rv$xlen.log"
done
