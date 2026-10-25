#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
shift || true
requested_tests=("$@")
source scripts/verilator/core_build_config.sh
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "build/verilator/directed-rv${xlen}-${core_build_tag}" "logs"
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi

shopt -s nullglob
for tb_path in tb/core/tb_*.sv; do
    test_name="$(basename "${tb_path}" .sv)"
    if [[ ${#requested_tests[@]} -gt 0 ]]; then
        selected=0
        for requested in "${requested_tests[@]}"; do
            if [[ "$test_name" == "$requested" ]]; then selected=1; fi
        done
        if [[ "$selected" == 0 ]]; then continue; fi
    fi
    actual_backend=legacy
    if rg -q 'sim_cpu_top dut' "$tb_path"; then actual_backend="$core_backend"; fi
    test_flags=("${core_microarch_flags[@]}")
    test_tag="$core_build_tag"
    actual_issue="$core_issue_width"
    actual_retire="$core_retire_entries"
    monitor_sources=(tb/common/retire_contract_monitor.sv)
    # 直接实例化旧 core 的结构测试仍验证单发射后端；不能套双退休参数后漏采 lane1。
    # scoreboard 的对应访存/取消/双退休覆盖由 scoreboard-test 与 SoC 回归承担。
    if [[ "$actual_backend" == legacy && "$core_backend" == scoreboard ]]; then
        actual_issue=1
        actual_retire=4
        if [[ "$test_name" == tb_core_dual_issue ]]; then actual_issue=2; fi
        test_flags=("-DCORE_PREDICTOR_MODE=$core_predictor_mode" "-DCORE_RAS_ENABLE=$core_ras_enable"
            "-DCORE_RETIRE_ENTRIES=$actual_retire" "-DCORE_ISSUE_WIDTH=$actual_issue")
        test_tag="p${core_predictor_mode}r${core_ras_enable}q${actual_retire}i${actual_issue}-legacy"
    fi
    # 双发射 TB 自带逐 lane 的独立架构/完整 ID 队列模型；旧公共 monitor 只有一个分配口。
    if [[ "$test_name" == tb_core_dual_issue ]]; then
        monitor_sources=()
    fi
    out_dir="build/verilator/directed-rv${xlen}-${test_tag}/${test_name}"
    log="logs/${test_name}-rv${xlen}-${test_tag}.log"
    mkdir -p "$out_dir"
    echo "DIRECTED_CONFIG test=$test_name RV$xlen selected=$core_backend actual=$actual_backend issue=$actual_issue rob=$actual_retire"
    verilator "${test_flags[@]}" -Wall -Wno-fatal --assert --timing --binary \
        "${host_cflags[@]}" \
        -DCORE_XLEN="${xlen}" \
        -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
        -Mdir "${out_dir}" \
        -f scripts/sim_files.f \
        tb/common/rv_asm_pkg.sv \
        tb/common/store_result_monitor.sv \
        "${monitor_sources[@]}" \
        "${tb_path}" \
        --top-module "${test_name}" \
        >"$log" 2>&1 || {
            echo "FAIL compile $test_name RV$xlen log=$log"
            tail -n 25 "$log"; exit 1;
        }
    "${out_dir}/V${test_name}" >>"$log" 2>&1 || {
        echo "FAIL run $test_name RV$xlen log=$log"
        tail -n 25 "$log"; exit 1;
    }
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "$log"; then
        tail -n 12 "$log"
        exit 1
    fi
    if rg -q "^SKIP ${test_name}" "$log"; then
        rg "^SKIP ${test_name}" "$log"
    else
        rg "^PASS ${test_name}" "$log" | tail -n 1
    fi
done
