#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
source scripts/verilator/core_build_config.sh
tests_root="${RISCV_TESTS_DIR:-tb/riscv_tests/vendor/riscv-tests}"
tool_root="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
platform_suffix="-${core_build_tag}"
tb_top=tb_riscv_test
tb_file=tb/riscv_tests/tb_riscv_test.sv
source_list=scripts/sim_files.f
linker=tb/riscv_tests/env/link.ld
source scripts/soc_profile.sh
platform_options=()
extra_sources=()
result_options=()
if [[ "${SOC:-0}" == "1" ]]; then
    local_tcm="${SOC_LOCAL_TCM_ENABLE:-0}"
    dma_wide="${SOC_DMA_WIDE_ENABLE:-0}"
    dma_block="${SOC_DMA_BLOCK_ENABLE:-0}"
    cache_block="${SOC_CACHE_BLOCK_ENABLE:-0}"
    [[ "$local_tcm" =~ ^[01]$ ]] || { echo 'SOC_LOCAL_TCM_ENABLE must be 0 or 1' >&2; exit 2; }
    [[ "$dma_wide" =~ ^[01]$ ]] || { echo 'SOC_DMA_WIDE_ENABLE must be 0 or 1' >&2; exit 2; }
    [[ "$dma_block" =~ ^[01]$ ]] || { echo 'SOC_DMA_BLOCK_ENABLE must be 0 or 1' >&2; exit 2; }
    [[ "$cache_block" =~ ^[01]$ ]] || { echo 'SOC_CACHE_BLOCK_ENABLE must be 0 or 1' >&2; exit 2; }
    platform_suffix="-${core_build_tag}-soc-p${soc_profile}-ltcm${local_tcm}-dw${dma_wide}-cb${cache_block}-db${dma_block}"
    platform_options+=("-GLOCAL_TCM_ENABLE=${local_tcm}")
    platform_options+=("-GDMA_WIDE_ENABLE=${dma_wide}")
    platform_options+=("-GDMA_BLOCK_ENABLE=${dma_block}")
    platform_options+=("-GCACHE_BLOCK_ENABLE=${cache_block}")
    platform_options+=("-GSOC_PROFILE=${soc_profile_id}")
    tb_top=tb_soc_benchmark
    tb_file=tb/soc/tb_soc_benchmark.sv
    source_list=scripts/soc_files.f
    if [[ "$core_backend" == scoreboard ]]; then
        platform_suffix="${platform_suffix}-axi4"
        tb_top=tb_soc_system
        tb_file=tb/soc/tb_soc_system.sv
        extra_sources=(tb/soc/axi_system_memory_model.sv tb/soc/spi_flash_model.sv)
    fi
    linker=tb/riscv_tests/env/link_soc.ld
    # ISA 的 .dword tohost 由两笔 SW 报告；bare/RT 的 unsigned int 仍使用默认四字节。
    result_options=(-GRESULT_BYTES=8)
fi
build_root="build/riscv-tests/rv${xlen}${platform_suffix}"
sim_dir="build/verilator/riscv-tests-rv${xlen}${platform_suffix}"
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

if [[ "${SOC:-0}" == "1" ]]; then
    march="${march}_zifencei"
    ui_tests+=(fence_i)
fi

mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "${build_root}" "${sim_dir}" logs
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi
if [[ "$core_backend" == scoreboard ]]; then host_cflags=(-CFLAGS -O1); fi

verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 2 "${result_options[@]}" \
    "${host_cflags[@]}" \
    -DCORE_XLEN="${xlen}" \
    -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
    -Mdir "${sim_dir}" \
    -f "${source_list}" \
    tb/common/store_result_monitor.sv \
    "${extra_sources[@]}" "${tb_file}" \
    "${platform_options[@]}" --top-module "${tb_top}" \
    >"logs/riscv-tests-build-rv${xlen}${platform_suffix}.log" 2>&1

failures=0
passes=0

run_test() {
    local suite="$1"
    local test_name="$2"
    local test_dir="${build_root}/${suite}/${test_name}"
    local source_file="${tests_root}/isa/rv${xlen}${suite}/${test_name}.S"
    local run_log="logs/riscv-${suite}-${test_name}-rv${xlen}${platform_suffix}.log"

    if [[ ! -f "${source_file}" ]]; then
        echo "FAIL missing vendored source: ${source_file}"
        failures=$((failures + 1))
        return
    fi

    mkdir -p "${test_dir}"

    if ! "${tool_prefix}gcc" \
        -march="${march}" -mabi="${mabi}" -mcmodel=medany -fno-pie -fno-pic \
        -nostdlib -nostartfiles -static -no-pie \
        -I tb/riscv_tests/env \
        -I "${tests_root}/env" \
        -I "${tests_root}/isa/macros/scalar" \
        -Wl,--build-id=none,--no-relax -Wl,-T,"${linker}" \
        -Wl,-Map,"${test_dir}/${test_name}.map" \
        "${source_file}" -o "${test_dir}/${test_name}.elf" \
        >"logs/riscv-${suite}-${test_name}-rv${xlen}${platform_suffix}-compile.log" 2>&1; then
        echo "FAIL compile ${suite}/${test_name}"
        failures=$((failures + 1))
        return
    fi

    if [[ "${SOC:-0}" == "1" ]]; then
        "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
            --only-section=.text --only-section=.tohost --only-section=.data \
            "${test_dir}/${test_name}.elf" "${test_dir}/imem.vhex"
        python3 scripts/verilator/verilog_hex_to_mem.py \
            "${test_dir}/imem.vhex" "${test_dir}/imem.hex" \
            --word-bytes "$((xlen / 8))" --depth "$((65536 / (xlen / 8)))" --base 0x01000000
        python3 scripts/verilator/verilog_hex_to_mem.py \
            /dev/null "${test_dir}/dmem.hex" --word-bytes "$((xlen / 8))" --depth "$((65536 / (xlen / 8)))"
    else
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.text "${test_dir}/${test_name}.elf" "${test_dir}/imem.vhex"
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.data "${test_dir}/${test_name}.elf" "${test_dir}/dmem.vhex"
    python3 scripts/verilator/verilog_hex_to_mem.py \
        "${test_dir}/imem.vhex" "${test_dir}/imem.hex" --word-bytes 4
    python3 scripts/verilator/verilog_hex_to_mem.py \
        "${test_dir}/dmem.vhex" "${test_dir}/dmem.hex" --word-bytes "$((xlen / 8))"
    fi
    "${tool_prefix}objdump" -d "${test_dir}/${test_name}.elf" >"${test_dir}/${test_name}.dump"

    local tohost_addr
    tohost_addr="$("${tool_prefix}nm" -n "${test_dir}/${test_name}.elf" | \
        awk '$3 == "tohost" { print $1; exit }')"
    if [[ -z "${tohost_addr}" ]]; then
        echo "FAIL missing tohost symbol: ${suite}/${test_name}"
        failures=$((failures + 1))
        return
    fi

    if "${sim_dir}/V${tb_top}" \
        +IMEM="${test_dir}/imem.hex" \
        +DMEM="${test_dir}/dmem.hex" \
        +TOHOST="${tohost_addr}" \
        +CONSOLE=0 +TEST="${suite}/${test_name}" >"${run_log}" 2>&1 &&
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
if [[ "${SOC:-0}" == "1" ]]; then
    echo "SKIP riscv-tests RV${xlen} SoC UI: ma_data (misaligned completion policy)"
else
    echo "SKIP riscv-tests RV${xlen} UI: fence_i (Zifencei/Harvard coherence), ma_data (misaligned completion policy)"
fi
echo "PASS riscv-tests RV${xlen}: ${passes}/${passes} (MI=${#mi_tests[@]} UI=${#ui_tests[@]} UM=${#um_tests[@]})"
