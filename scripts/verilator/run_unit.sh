#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "build/verilator/unit-rv${xlen}" "logs"

# SRT 的展开组合逻辑在 g++ -Os 下会让单个定向 TB 的编译耗时过长；
# C++ 宿主优化不影响 RTL 仿真语义，SRT 回归改用快速编译。
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi

for tb_path in tb/unit/tb_*.sv; do
    test_name="$(basename "${tb_path}" .sv)"
    out_dir="build/verilator/unit-rv${xlen}/${test_name}"
    verilator -Wall -Wno-fatal --assert --timing --binary \
        "${host_cflags[@]}" \
        -DCORE_XLEN="${xlen}" \
        -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
        -Mdir "${out_dir}" \
        -f scripts/rtl_files.f \
        vsrc/cpu/pango_ddr3_bridge.sv \
        vsrc/sim_cpu/sim_imem.sv \
        vsrc/sim_cpu/sim_dmem.sv \
        tb/common/rv_asm_pkg.sv \
        tb/common/muldiv_checker.sv \
        tb/common/store_result_monitor.sv \
        "${tb_path}" \
        --top-module "${test_name}" \
        >"logs/${test_name}-rv${xlen}.log" 2>&1
    "${out_dir}/V${test_name}" >>"logs/${test_name}-rv${xlen}.log" 2>&1
    # 不能只相信进程返回码或 PASS；当前仿真器可能在 $finish 后仍打印致命错误。
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "logs/${test_name}-rv${xlen}.log"; then
        tail -n 12 "logs/${test_name}-rv${xlen}.log"
        exit 1
    fi
    grep "PASS ${test_name}" "logs/${test_name}-rv${xlen}.log" | tail -n 1
done
