#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/unified-bus-$p2_core_build_tag}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
for spec in 5000:5000:8:0 5000:6250:8:0 6250:4000:8:0 4274:5376:8:0 5000:5000:2:0 5000:6250:8:1; do
    IFS=: read -r sh th depth native <<< "$spec"
    name="fabric-rv$xlen-$sh-$th-d$depth-n$native"
    out="build/p2/$name-$p2_core_build_tag"
    verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen" "${p2_core_flags[@]}" \
        -f scripts/rtl_files.f -f scripts/axi_files.f vsrc/cpu/pango_block_bridge.sv tb/soc/axi_native_memory_model.sv tb/soc/axi_system_memory_model.sv tb/soc/tb_axi_system_fabric.sv \
        --top-module tb_axi_system_fabric -GSYS_HALF_PS="$sh" -GTARGET_HALF_PS="$th" -GCDC_DEPTH="$depth" -GNATIVE_DDR="$native" \
        -Mdir "$out" >"${log_root}/$name.build.log" 2>&1 || { tail -30 "${log_root}/$name.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "${log_root}/$name.build.log"; then exit 1; fi
    "$out/Vtb_axi_system_fabric" >"${log_root}/$name.run.log" 2>&1 || { tail -20 "${log_root}/$name.run.log"; exit 1; }
    if rg '(%Fatal|%Error)' "${log_root}/$name.run.log"; then exit 1; fi
    rg '^PASS' "${log_root}/$name.run.log"
done
for spec in tb_soc_cdc:2 tb_soc_cdc:8 tb_ddr_axi_target:0 tb_tcm_system_target:0 tb_axi_bus_target:0 tb_axi_bus_target:1; do
    IFS=: read -r top depth <<< "$spec"
    name="$top-rv$xlen-d$depth"
    out="build/p2/$name-$p2_core_build_tag"
    options=()
    sources=()
    if [[ "$top" == tb_soc_cdc ]]; then options=(-GDEPTH="$depth"); fi
    if [[ "$top" == tb_tcm_system_target ]]; then
        sources=(vsrc/soc/memory/tcm_address_decode.sv vsrc/soc/memory/tcm_system_target.sv)
    fi
    if [[ "$top" == tb_axi_bus_target ]]; then
        options=(-GREAD_ONLY="$depth")
        sources=(tb/soc/axi_bus_target_reference.sv)
    fi
    verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen" "${p2_core_flags[@]}" \
        -f scripts/rtl_files.f -f scripts/axi_files.f vsrc/cpu/pango_block_bridge.sv \
        tb/soc/axi_native_memory_model.sv "${sources[@]}" "tb/soc/$top.sv" --top-module "$top" "${options[@]}" \
        -Mdir "$out" >"$log_root/$name.build.log" 2>&1 || { tail -30 "$log_root/$name.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/$name.build.log"; then exit 1; fi
    "$out/V$top" >"$log_root/$name.run.log" 2>&1 || { tail -20 "$log_root/$name.run.log"; exit 1; }
    if rg '(%Fatal|%Error)' "$log_root/$name.run.log"; then exit 1; fi
    rg '^PASS' "$log_root/$name.run.log"
done
python3 scripts/verilator/p2_manifest.py "$log_root/axi-rv$xlen.manifest.json"
