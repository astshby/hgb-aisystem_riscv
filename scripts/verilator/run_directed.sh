#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
source scripts/verilator/core_build_config.sh
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "build/verilator/directed-rv${xlen}-${core_build_tag}" "logs"
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi

shopt -s nullglob
for tb_path in tb/core/tb_*.sv; do
    test_name="$(basename "${tb_path}" .sv)"
    out_dir="build/verilator/directed-rv${xlen}-${core_build_tag}/${test_name}"
    verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary \
        "${host_cflags[@]}" \
        -DCORE_XLEN="${xlen}" \
        -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
        -Mdir "${out_dir}" \
        -f scripts/sim_files.f \
        tb/common/rv_asm_pkg.sv \
        tb/common/store_result_monitor.sv \
        tb/common/retire_contract_monitor.sv \
        "${tb_path}" \
        --top-module "${test_name}" \
        >"logs/${test_name}-rv${xlen}-${core_build_tag}.log" 2>&1
    "${out_dir}/V${test_name}" >>"logs/${test_name}-rv${xlen}-${core_build_tag}.log" 2>&1
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "logs/${test_name}-rv${xlen}-${core_build_tag}.log"; then
        tail -n 12 "logs/${test_name}-rv${xlen}-${core_build_tag}.log"
        exit 1
    fi
    grep "PASS ${test_name}" "logs/${test_name}-rv${xlen}-${core_build_tag}.log" | tail -n 1
done
