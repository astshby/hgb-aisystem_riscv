#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
entries="$core_retire_entries"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ && "$entries" =~ ^(2|4|8)$ ]] || {
    echo 'usage: CORE_RETIRE_ENTRIES=2|4|8 C3C_TESTS="tb_name ..." run_nonblocking_lsu.sh [32|64]' >&2; exit 2;
}
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
read -r -a names <<< "${C3C_TESTS:-tb_pipeline_ctrl tb_core_nonblocking_lsu tb_core_lsu_ownership tb_core_load_pipeline tb_core_bus_contract tb_core_interrupt tb_core_trap_wait tb_core_m_forward tb_core_m_wait tb_core_nonblocking tb_core_retire_queue}"
passes=0
skips=0
for name in "${names[@]}"; do
    [[ "$name" =~ ^tb_[a-z0-9_]+$ ]] || { echo "invalid test: $name" >&2; exit 2; }
    group=core
    [[ -f "tb/core/$name.sv" ]] || group=unit
    [[ -f "tb/$group/$name.sv" ]] || { echo "missing test: $name" >&2; exit 2; }
    # 新分源跨退休场景同时容纳旧 DIV、ALU 源、Load 源、消费者；两槽不能构成该刺激。
    # 两槽继续用独立 nonblocking_lsu/retire_queue 等覆盖，不把无法形成的场景计为通过。
    if [[ "$entries" == 2 && "$name" == tb_core_m_wait ]]; then
        echo 'SKIP tb_core_m_wait: split-source lifetime requires at least four entries'
        skips=$((skips+1))
        continue
    fi
    tag="c3c-rv${xlen}-${core_build_tag}-n${entries}-${name}"
    out="build/verilator/$tag"
    log="logs/$tag.log"
    mkdir -p "$out"
    verilator "${core_microarch_flags[@]:0:2}" "-DCORE_ISSUE_WIDTH=$core_issue_width" -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
        -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 -DCORE_RETIRE_ENTRIES="$entries" \
        -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
        tb/common/store_result_monitor.sv tb/common/retire_contract_monitor.sv \
        "tb/$group/$name.sv" --top-module "$name" >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
    if rg -n '%(Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
    "$out/V$name" >>"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS $name" "$log"; then
        tail -n 25 "$log"; exit 1;
    fi
    rg "^PASS $name" "$log"
    passes=$((passes+1))
done
echo "PASS nonblocking LSU RV$xlen entries=$entries: $passes runs, $skips SKIP"
