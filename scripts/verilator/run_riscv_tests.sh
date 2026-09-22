#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
tests_root="${RISCV_TESTS_DIR:-tb/riscv_tests/vendor/riscv-tests}"
tool_root="${RISCV_TOOL_ROOT:-/opt/riscv/bin}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
build_root="build/riscv-tests/rv${xlen}"
sim_dir="build/verilator/riscv-tests-rv${xlen}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"

if [[ "${xlen}" == "32" ]]; then
    march="rv32im_zicsr"
    mabi="ilp32"
    mi_tests=(csr illegal scall sbreak mcsr ma_addr lh-misaligned lw-misaligned sh-misaligned sw-misaligned)
    ui_tests=(
        add addi and andi auipc
        beq bge bgeu blt bltu bne
        jal jalr
        lb lbu ld_st lh lhu lui lw
        or ori sb sh simple
        sll slli slt slti sltiu sltu sra srai srl srli
        st_ld sub sw xor xori
    )
    um_tests=(mul mulh mulhsu mulhu div divu rem remu)
else
    march="rv64im_zicsr"
    mabi="lp64"
    mi_tests=(csr illegal scall sbreak mcsr ma_addr lh-misaligned lw-misaligned ld-misaligned sh-misaligned sw-misaligned sd-misaligned instret_overflow)
    ui_tests=(
        add addi addiw addw and andi auipc
        beq bge bgeu blt bltu bne
        jal jalr
        lb lbu ld ld_st lh lhu lui lw lwu
        or ori sb sd sh simple
        sll slli slliw sllw slt slti sltiu sltu
        sra srai sraiw sraw srl srli srliw srlw
        st_ld sub subw sw xor xori
    )
    um_tests=(mul mulh mulhsu mulhu div divu rem remu mulw divw divuw remw remuw)
fi

mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "${build_root}" "${sim_dir}" logs

verilator -Wall -Wno-fatal --assert --timing --binary \
    -DCORE_XLEN="${xlen}" \
    -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
    -Mdir "${sim_dir}" \
    -f scripts/sim_files.f \
    tb/common/store_result_monitor.sv \
    tb/riscv_tests/tb_riscv_test.sv \
    --top-module tb_riscv_test \
    >"logs/riscv-tests-build-rv${xlen}.log" 2>&1

failures=0
passes=0

run_test() {
    local suite="$1"
    local test_name="$2"
    local test_dir="${build_root}/${suite}/${test_name}"
    local source_file="${tests_root}/isa/rv${xlen}${suite}/${test_name}.S"
    local run_log="logs/riscv-${suite}-${test_name}-rv${xlen}.log"

    if [[ ! -f "${source_file}" ]]; then
        echo "FAIL missing vendored source: ${source_file}"
        failures=$((failures + 1))
        return
    fi

    mkdir -p "${test_dir}"

    if ! "${tool_prefix}gcc" \
        -march="${march}" -mabi="${mabi}" -mcmodel=medany \
        -nostdlib -nostartfiles -static -no-pie \
        -I tb/riscv_tests/env \
        -I "${tests_root}/env" \
        -I "${tests_root}/isa/macros/scalar" \
        -Wl,--no-relax -Wl,-T,tb/riscv_tests/env/link.ld \
        -Wl,-Map,"${test_dir}/${test_name}.map" \
        "${source_file}" -o "${test_dir}/${test_name}.elf" \
        >"logs/riscv-${suite}-${test_name}-rv${xlen}-compile.log" 2>&1; then
        echo "FAIL compile ${suite}/${test_name}"
        failures=$((failures + 1))
        return
    fi

    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.text "${test_dir}/${test_name}.elf" "${test_dir}/imem.vhex"
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.data "${test_dir}/${test_name}.elf" "${test_dir}/dmem.vhex"
    python3 scripts/verilator/verilog_hex_to_mem.py \
        "${test_dir}/imem.vhex" "${test_dir}/imem.hex" --word-bytes 4
    python3 scripts/verilator/verilog_hex_to_mem.py \
        "${test_dir}/dmem.vhex" "${test_dir}/dmem.hex" --word-bytes "$((xlen / 8))"
    "${tool_prefix}objdump" -d "${test_dir}/${test_name}.elf" >"${test_dir}/${test_name}.dump"

    local tohost_addr
    tohost_addr="$("${tool_prefix}nm" -n "${test_dir}/${test_name}.elf" | \
        awk '$3 == "tohost" { print $1; exit }')"
    if [[ -z "${tohost_addr}" ]]; then
        echo "FAIL missing tohost symbol: ${suite}/${test_name}"
        failures=$((failures + 1))
        return
    fi

    if "${sim_dir}/Vtb_riscv_test" \
        +IMEM="${test_dir}/imem.hex" \
        +DMEM="${test_dir}/dmem.hex" \
        +TOHOST="${tohost_addr}" \
        +TEST="${suite}/${test_name}" >"${run_log}" 2>&1 &&
        ! grep -Eq '(%Fatal|%Error|Assertion failed)' "${run_log}"; then
        grep "PASS ${suite}/${test_name}" "${run_log}" | tail -n 1
        passes=$((passes + 1))
    else
        failures=$((failures + 1))
        tail -n 8 "${run_log}"
    fi
}

for test_name in "${mi_tests[@]}"; do
    run_test mi "${test_name}"
done
for test_name in "${ui_tests[@]}"; do
    run_test ui "${test_name}"
done
for test_name in "${um_tests[@]}"; do
    run_test um "${test_name}"
done

if ((failures != 0)); then
    echo "FAIL riscv-tests RV${xlen}: pass=${passes} fail=${failures}"
    exit 1
fi
echo "SKIP riscv-tests RV${xlen} UI: fence_i (Zifencei/Harvard coherence), ma_data (misaligned completion policy)"
echo "PASS riscv-tests RV${xlen}: ${passes}/${passes} (MI=${#mi_tests[@]} UI=${#ui_tests[@]} UM=${#um_tests[@]})"
