#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
width="${1:-64}"
[[ "$width" =~ ^(32|64)$ ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" logs/p0
tests=("$@")
tests=("${tests[@]:1}")
[[ ${#tests[@]} -gt 0 ]] || tests=(contracts rename operands operands_wide operands_issue issue recovery retirement completion completion_wide completion_queue lsu lsu_slots lsu_forward metrics core events)
predictor="${PREDICTOR_MODE:-0}"
ras="${RAS_ENABLE:-0}"
[[ "$predictor" =~ ^[01]$ && "$ras" =~ ^[01]$ ]] || exit 2
suffix=""
if [[ "$predictor$ras" != 00 ]]; then suffix="-p${predictor}r${ras}"; fi
if [[ "${LSQ_EQUIVALENCE:-0}" == 1 ]]; then suffix="${suffix}-lsq-equivalence"; fi
for test in "${tests[@]}"; do
    [[ "$test" =~ ^[a-z_]+$ ]] || exit 2
    top="tb_scoreboard_$test"
    extra_options=()
    if [[ "$test" == completion_wide ]]; then
        top=tb_scoreboard_completion
        extra_options+=(-GSOURCES=11)
    fi
    if [[ "$test" == operands_wide ]]; then
        top=tb_scoreboard_operands
        extra_options+=(-GBROADCAST_PORTS=7)
    fi
    if [[ "$test" == operands_issue ]]; then
        top=tb_scoreboard_operands
        extra_options+=(-GBROADCAST_PORTS=7 -GISSUE_BYPASS=1)
    fi
    out="build/verilator/p0-$test-rv$width$suffix"
    log="logs/p0/$test-rv$width$suffix"
    extra_sources=()
    if [[ "$test" == metrics ]]; then extra_sources+=(tb/common/scoreboard_metrics.sv); fi
    if [[ "${LSQ_EQUIVALENCE:-0}" == 1 ]]; then
        extra_sources+=(build/p1-reference/load_store_queue_reference.sv tb/unit/scoreboard/lsq_equivalence_checker.sv)
    fi
    mkdir -p "$out"
    verilator -Wall -Wno-fatal --assert --timing --binary -j 2 -CFLAGS -O1 \
        -DCORE_XLEN="$width" -DCORE_ISSUE_WIDTH=2 -DCORE_RETIRE_ENTRIES=16 \
        -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 -DCORE_PREDICTOR_MODE="$predictor" -DCORE_RAS_ENABLE="$ras" \
        -Mdir "$out" -f scripts/rtl_files.f tb/common/rv_asm_pkg.sv "${extra_sources[@]}" \
        "tb/unit/scoreboard/$top.sv" "${extra_options[@]}" --top-module "$top" \
        >"$log.build.log" 2>&1 || {
            tail -n 50 "$log.build.log"; exit 1;
        }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' \
        "$log.build.log"; then exit 1; fi
    "$out/V$top" >"$log.run.log" 2>&1 || {
        tail -n 50 "$log.run.log"; exit 1;
    }
    rg "^PASS $top " "$log.run.log"
done
