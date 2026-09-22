#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
tool_root="${RISCV_TOOL_ROOT:-/opt/riscv/bin}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
log_root="logs/mdu-matrix-rv${xlen}"
build_root="build/verilator/mdu-matrix-rv${xlen}"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "${log_root}" "${build_root}"

um_tests=(mul mulh mulhsu mulhu div divu rem remu)
if [[ "${xlen}" == 64 ]]; then
    um_tests+=(mulw divw divuw remw remuw)
fi
for name in "${um_tests[@]}"; do
    if [[ ! -f "build/riscv-tests/rv${xlen}/um/${name}/${name}.elf" ]]; then
        echo "Missing UM image: run make riscv-tests XLEN=${xlen} first."
        exit 1
    fi
done

check_log() {
    local path="$1" expected="$2"
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "${path}" || ! grep -Fq "${expected}" "${path}"; then
        tail -n 16 "${path}"
        exit 1
    fi
}

passes=0
for mul in 0 1 2; do
    for div in 0 1; do
        config="m${mul}d${div}"
        for top in tb_core_m tb_core_m_wait tb_core_m_trap tb_riscv_test; do
            out_dir="${build_root}/${config}/${top}"
            mkdir -p "${out_dir}"
            tb_path="tb/core/${top}.sv"
            if [[ "${top}" == tb_riscv_test ]]; then
                tb_path="tb/riscv_tests/${top}.sv"
            fi
            verilator -Wall -Wno-fatal --assert --timing --binary -j 4 \
                -DCORE_XLEN="${xlen}" -DCORE_MUL_IMPL="${mul}" -DCORE_DIV_IMPL="${div}" \
                -Mdir "${out_dir}" -f scripts/sim_files.f \
                tb/common/rv_asm_pkg.sv tb/common/store_result_monitor.sv "${tb_path}" \
                --top-module "${top}" >"${log_root}/${config}-${top}-build.log" 2>&1
            if [[ "${top}" != tb_riscv_test ]]; then
                run_log="${log_root}/${config}-${top}.log"
                "${out_dir}/V${top}" >"${run_log}" 2>&1
                check_log "${run_log}" "PASS ${top}"
                passes=$((passes + 1))
                grep "PASS ${top}" "${run_log}"
            fi
        done
        for name in "${um_tests[@]}"; do
            image_dir="build/riscv-tests/rv${xlen}/um/${name}"
            tohost="$("${tool_root}/riscv64-unknown-elf-nm" -n "${image_dir}/${name}.elf" | \
                awk '$3 == "tohost" {print $1; exit}')"
            [[ -n "${tohost}" ]] || { echo "Missing tohost: ${name}"; exit 1; }
            run_log="${log_root}/${config}-um-${name}.log"
            "${build_root}/${config}/tb_riscv_test/Vtb_riscv_test" \
                +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
                +TOHOST="${tohost}" +TEST="um/${name}" >"${run_log}" 2>&1
            check_log "${run_log}" "PASS um/${name}"
            passes=$((passes + 1))
        done
        echo "PASS MDU configuration RV${xlen} ${config}: directed=3 UM=${#um_tests[@]}"
    done
done
echo "PASS MDU matrix RV${xlen}: configurations=6 checks=${passes}"
