#!/usr/bin/env bash
set -euo pipefail
xlen="${1:-32}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" logs
for test_name in tb_icache tb_dcache; do
    for config in small default disabled absent; do
        parameters=()
        case "${config}" in
            default) parameters+=(-GCACHE_BYTES=4096) ;;
            disabled) parameters+=(-GENABLE=0) ;;
            absent) parameters+=(-GDDR_BYTES=0) ;;
        esac
        out_dir="build/verilator/cache-rv${xlen}/${test_name}-${config}"
        log="logs/cache-rv${xlen}-${test_name}-${config}.log"
        mkdir -p "${out_dir}"
        verilator -Wall -Wno-fatal --assert --timing --binary \
            -DCORE_XLEN="${xlen}" -Mdir "${out_dir}" -f scripts/soc_files.f \
            "tb/cache/${test_name}.sv" "${parameters[@]}" --top-module "${test_name}" >"${log}" 2>&1
        "${out_dir}/V${test_name}" >>"${log}" 2>&1 || { tail -n 20 "${log}"; exit 1; }
        if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then
            tail -n 20 "${log}"
            exit 1
        fi
        grep "PASS ${test_name}" "${log}"
    done
done
bash scripts/verilator/run_icache_software.sh "${xlen}"
bash scripts/verilator/run_dcache_software.sh "${xlen}"
