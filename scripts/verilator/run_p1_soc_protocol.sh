#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/p1_core_config.sh
source scripts/verilator/core_build_config.sh
log_root="${P1_PROTOCOL_LOG_ROOT:-logs/p2/p1-adapt-20261023/protocol}"
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$log_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
commands="$log_root/commands.txt"
printf '%s\n' 'source scripts/verilator/p1_core_config.sh' 'source scripts/verilator/core_build_config.sh' >"$commands"
git rev-parse HEAD >"$log_root/base-commit.txt"
git branch --show-current >"$log_root/branch.txt"
for width in 32 64; do
    for test in request_queue request_cancel; do
        top="tb_scoreboard_$test"
        out="build/p2/p1-protocol-rv$width-$test-$core_build_tag"
        prefix="$log_root/rv$width-$test"
        mkdir -p "$out"
        command=(verilator -Wall -Wno-fatal --assert --timing --binary -j 2 -CFLAGS -O1
            -DCORE_XLEN="$width" "${core_microarch_flags[@]}" -DCORE_MUL_IMPL="$MUL_IMPL" -DCORE_DIV_IMPL="$DIV_IMPL"
            -Mdir "$out" -f scripts/rtl_files.f vsrc/soc/common/tagged_request_queue.sv
            "tb/unit/scoreboard/$top.sv" --top-module "$top")
        printf '%q ' "${command[@]}" >>"$commands"; printf '\n' >>"$commands"
        sha256sum scripts/rtl_files.f scripts/verilator/p1_core_config.sh scripts/verilator/core_build_config.sh \
            scripts/verilator/run_p1_soc_protocol.sh vsrc/soc/common/tagged_request_queue.sv \
            "tb/unit/scoreboard/$top.sv" $(cat scripts/rtl_files.f) >"$prefix.sources.sha256"
        "${command[@]}" >"$prefix.build.log" 2>&1 || { tail -50 "$prefix.build.log"; exit 1; }
        if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$prefix.build.log"; then exit 1; fi
        printf '%q\n' "$out/V$top" >>"$commands"
        "$out/V$top" >"$prefix.run.log" 2>&1 || { tail -50 "$prefix.run.log"; exit 1; }
        sha256sum "$out/V$top" >"$prefix.binary.sha256"
        sha256sum --check --quiet "$prefix.sources.sha256"
        rg "^PASS $top " "$prefix.run.log"
    done
done
