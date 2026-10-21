#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/verilator/core_build_config.sh
group="${2:-core}"
entries="$core_retire_entries"
[[ $# -le 2 && "$xlen" =~ ^(32|64)$ && "$group" =~ ^(unit|core)$ && "$entries" =~ ^(2|4|8)$ ]] || {
    echo "usage: CORE_RETIRE_ENTRIES=2|4|8 C4_TESTS='tb_name ...' $0 [32|64] [unit|core]" >&2; exit 2;
}
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
if [[ "$group" == unit ]]; then
    defaults="tb_predictor_commit_update tb_predictor tb_predictor_direction tb_predictor_ras tb_ras_replay_builder tb_btb tb_gshare tb_ex_stage tb_mem_stage tb_wb_stage tb_retire_queue"
else
    defaults="tb_core_predictor_retire tb_core_ras tb_core_predictor tb_core_nonblocking tb_core_nonblocking_lsu tb_core_bus_contract tb_core_interrupt"
fi
read -r -a names <<< "${C4_TESTS:-$defaults}"
passes=0
skips=0
for name in "${names[@]}"; do
    [[ "$name" =~ ^tb_[a-z0-9_]+$ && -f "tb/$group/$name.sv" ]] || { echo "invalid test: $name" >&2; exit 2; }
    suffix="c4-retire-rv$xlen-${core_build_tag}-$name"
    out="build/verilator/$suffix"
    log="logs/$suffix.log"
    mkdir -p "$out"
    verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
        -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 \
        -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
        tb/common/store_result_monitor.sv tb/common/retire_contract_monitor.sv \
        "tb/$group/$name.sv" --top-module "$name" >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
    if rg -n '%(Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
    "$out/V$name" >>"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS $name" "$log"; then
        tail -n 25 "$log"; exit 1;
    fi
    rg "^PASS $name" "$log"
    if rg -q "^PASS $name .*SKIP|^PASS $name SKIP" "$log"; then
        skips=$((skips + 1))
    else
        passes=$((passes + 1))
    fi
done
echo "PASS predictor retirement RV$xlen entries=$entries $group: $passes runs, $skips SKIP"
