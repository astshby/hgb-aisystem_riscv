#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "${1:-all}" in
    32|64) widths=("$1") ;;
    all) widths=(32 64) ;;
    *) echo 'usage: run_fetch_fence_window.sh [32|64|all]' >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
sources=(vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/predictor_types_pkg.sv vsrc/pkg/pipeline_pkg.sv vsrc/pkg/soc_config_pkg.sv
    vsrc/pkg/soc_addr_pkg.sv vsrc/pkg/bus_types_pkg.sv vsrc/pkg/block_types_pkg.sv vsrc/pkg/cache_pkg.sv
    vsrc/core/frontend/fetch_queue.sv vsrc/core/frontend/fetch_pair_stage.sv
    vsrc/core/common/fetch_width_adapter.sv vsrc/soc/bus/address_decode.sv
    vsrc/soc/cache/cache_port.sv vsrc/soc/cache/cache_data_array.sv vsrc/soc/cache/cache_meta_array.sv
    vsrc/soc/cache/dcache_meta_array.sv vsrc/soc/cache/cache_refill.sv vsrc/soc/cache/cache_writeback.sv
    vsrc/soc/cache/icache.sv vsrc/soc/cache/dcache.sv vsrc/soc/cache/cache_maintenance_controller.sv
    vsrc/soc/bus/ddr_port_arbiter.sv vsrc/soc/bus/ddr_block_adapter.sv
    vsrc/soc/bus/block_arbiter.sv vsrc/soc/bus/ddr_block_fabric.sv vsrc/soc/bus/block_to_axi.sv
    tb/soc/axi_block_memory_model.sv tb/soc/tb_fetch_fence_window.sv)
passes=0
for xlen in "${widths[@]}"; do
    for line in 32 64; do
        tag="fetch-fence-window-rv${xlen}-l${line}"
        out="build/verilator/$tag"
        mkdir -p "$out"
        verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
            -DCORE_XLEN="$xlen" -DCORE_ISSUE_WIDTH=2 -GLINE_BYTES="$line" \
            -Mdir "$out" "${sources[@]}" --top-module tb_fetch_fence_window \
            >"logs/${tag}-build.log" 2>&1 || { tail -n 45 "logs/${tag}-build.log"; exit 1; }
        if rg -n '%Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|DECLFILENAME)' "logs/${tag}-build.log"; then exit 1; fi
        # 保留共享Cache原有RV64常量扩宽提示；新增TB自身不能带入位宽错误。
        if rg 'Warning-WIDTH[A-Z]*: tb/soc/tb_fetch_fence_window.sv' "logs/${tag}-build.log"; then exit 1; fi
        "$out/Vtb_fetch_fence_window" >"logs/${tag}.log" 2>&1 \
            || { tail -n 35 "logs/${tag}.log"; exit 1; }
        rg '^PASS tb_fetch_fence_window' "logs/${tag}.log"
        passes=$((passes+1))
    done
done
echo "PASS fetch-fence-window: ${passes} configurations, 0 SKIP"
