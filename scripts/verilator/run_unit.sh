#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "build/verilator/unit-rv${xlen}" "logs"

for tb_path in tb/unit/tb_*.sv; do
    test_name="$(basename "${tb_path}" .sv)"
    out_dir="build/verilator/unit-rv${xlen}/${test_name}"
    verilator -Wall -Wno-fatal --timing --binary \
        -DCORE_XLEN="${xlen}" \
        -Mdir "${out_dir}" \
        -f scripts/rtl_files.f \
        vsrc/sim_cpu/sim_imem.sv \
        vsrc/sim_cpu/sim_dmem.sv \
        tb/common/rv_asm_pkg.sv \
        tb/common/store_result_monitor.sv \
        "${tb_path}" \
        --top-module "${test_name}" \
        >"logs/${test_name}-rv${xlen}.log" 2>&1
    "${out_dir}/V${test_name}" >>"logs/${test_name}-rv${xlen}.log" 2>&1
    grep "PASS ${test_name}" "logs/${test_name}-rv${xlen}.log" | tail -n 1
done
