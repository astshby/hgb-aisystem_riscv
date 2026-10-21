#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32|64) ;; *) echo "XLEN must be 32 or 64" >&2; exit 2;; esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
sources=(vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv
    vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv vsrc/pkg/cache_pkg.sv
    vsrc/soc/bus/address_decode.sv vsrc/soc/cache/cache_port.sv
    vsrc/soc/cache/cache_data_array.sv vsrc/soc/cache/cache_meta_array.sv
    vsrc/soc/cache/cache_refill.sv vsrc/soc/cache/cache_writeback.sv
    vsrc/soc/cache/dcache_meta_array.sv vsrc/soc/cache/icache.sv vsrc/soc/cache/dcache.sv
    vsrc/soc/bus/ddr_port_arbiter.sv vsrc/soc/bus/ddr_block_adapter.sv
    vsrc/soc/bus/block_arbiter.sv vsrc/soc/bus/ddr_block_fabric.sv vsrc/soc/bus/block_to_axi.sv
    tb/soc/axi_block_memory_model.sv)
passes=0
for line in 32 64; do
    for instruction in 0 1; do
        tag="s3-cache-axi-rv${xlen}-l${line}-i${instruction}"
        out="build/verilator/$tag"
        mkdir -p "$out"
        verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
            -DCORE_XLEN="$xlen" -GLINE_BYTES="$line" -GINSTRUCTION="$instruction" \
            -Mdir "$out" "${sources[@]}" tb/cache/tb_cache_block_axi.sv \
            --top-module tb_cache_block_axi >"logs/${tag}-build.log" 2>&1 \
            || { tail -n 45 "logs/${tag}-build.log"; exit 1; }
        if rg -n '(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|%Error)' "logs/${tag}-build.log"; then exit 1; fi
        "$out/Vtb_cache_block_axi" >"logs/${tag}.log" 2>&1 \
            || { tail -n 35 "logs/${tag}.log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "logs/${tag}.log" || ! rg '^PASS tb_cache_block_axi' "logs/${tag}.log"; then exit 1; fi
        passes=$((passes+1))
    done
done
echo "PASS cache-block-axi RV${xlen}: ${passes} configurations, 0 SKIP"
