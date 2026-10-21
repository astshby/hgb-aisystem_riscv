#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
width="${1:-64}"
[[ "$width" =~ ^(32|64)$ ]] || exit 2
shift
tests=("$@")
[[ ${#tests[@]} -gt 0 ]] || tests=(request_queue request_cancel tcm icache dcache)
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" logs/p0
for test in "${tests[@]}"; do
    [[ "$test" =~ ^[a-z_]+$ ]] || exit 2
    top="tb_scoreboard_$test"
    out="build/verilator/p0-$test-rv$width"
    log="logs/p0/$test-rv$width"
    mkdir -p "$out"
    verilator -Wall -Wno-fatal --assert --timing --binary -j 2 -CFLAGS -O1 \
        -DCORE_XLEN="$width" -DCORE_ISSUE_WIDTH=2 -DCORE_RETIRE_ENTRIES=16 \
        -Mdir "$out" -f scripts/soc_files.f "tb/unit/scoreboard/$top.sv" --top-module "$top" \
        >"$log.build.log" 2>&1 || { tail -40 "$log.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log.build.log"; then exit 1; fi
    "$out/V$top" >"$log.run.log" 2>&1 || { tail -40 "$log.run.log"; exit 1; }
    rg "^PASS $top " "$log.run.log"
done
