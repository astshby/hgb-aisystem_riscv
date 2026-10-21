#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
group="${2:-unit}"
entries="$core_retire_entries"
[[ $# -le 2 && "$xlen" =~ ^(32|64)$ && "$group" =~ ^(unit|core)$ && "$entries" =~ ^(2|4|8)$ ]] || {
    echo "usage: CORE_RETIRE_ENTRIES=2|4|8 C3_TESTS='tb_name ...' $0 [32|64] [unit|core]" >&2; exit 2;
}
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
if [[ "$group" == unit ]]; then
    defaults="tb_completion_arbiter tb_ex_operand_register tb_mem_stage tb_wb_stage tb_pipeline_ctrl"
else
    defaults="tb_core_lsu_ownership tb_core_load_pipeline tb_core_bus_contract tb_core_trap_wait tb_core_interrupt tb_core_minstret tb_core_retire_queue tb_core_nonblocking tb_core_m_wait tb_core_m_forward"
fi
read -r -a names <<< "${C3_TESTS:-$defaults}"
passes=0
for name in "${names[@]}"; do
    [[ "$name" =~ ^tb_[a-z0-9_]+$ && -f "tb/$group/$name.sv" ]] || { echo "invalid test: $name" >&2; exit 2; }
    suffix="c3b-rv$xlen-${core_build_tag}-n$entries-$name"
    out="build/verilator/$suffix"
    log="logs/$suffix.log"
    mkdir -p "$out"
    # 独立输出目录、单编译链；不覆盖基线或其他 agent 的产物。
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
    passes=$((passes + 1))
done
echo "PASS LSU ownership RV$xlen entries=$entries $group: $passes runs, 0 SKIP"
