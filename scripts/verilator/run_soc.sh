#!/usr/bin/env bash
set -euo pipefail
xlen="${1:-32}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" logs
# 镜像驱动 harness 由 benchmark/ISA runner 单独运行。
for test_name in tb_soc_fabric; do
    out_dir="build/verilator/soc-rv${xlen}/${test_name}"
    mkdir -p "${out_dir}"
    log="logs/${test_name}-rv${xlen}.log"
    verilator -Wall -Wno-fatal --assert --timing --binary \
        -DCORE_XLEN="${xlen}" -Mdir "${out_dir}" \
        -f scripts/soc_files.f "tb/soc/${test_name}.sv" \
        --top-module "${test_name}" >"${log}" 2>&1
    "${out_dir}/V${test_name}" >>"${log}" 2>&1
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then
        tail -n 15 "${log}"
        exit 1
    fi
    grep "PASS ${test_name}" "${log}" | tail -n 1
done
