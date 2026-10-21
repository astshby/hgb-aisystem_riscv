#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ ]] || { echo 'usage: run_m_wait_backends.sh [32|64]' >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
passes=0
for mul in 0 1 2; do
    for div in 0 1; do
        for top in tb_core_m_wait tb_core_m_forward; do
            tag="c3c-m-source-rv${xlen}-${core_build_tag}-m${mul}d${div}-${top}"
            out="build/verilator/$tag"
            log="logs/$tag.log"
            mkdir -p "$out"
            # 六后端共用同一整核程序与完整 ID 检查；宿主 -O0 只降低构建耗时。
            verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
                -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL="$mul" -DCORE_DIV_IMPL="$div" \
                -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
                tb/common/retire_contract_monitor.sv "tb/core/$top.sv" --top-module "$top" \
                >"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
            if rg -n '%(Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
            "$out/V$top" >>"$log" 2>&1 || { tail -n 25 "$log"; exit 1; }
            if rg -q '%Fatal|%Error|Assertion failed' "$log" || ! rg -q "^PASS $top" "$log"; then
                tail -n 25 "$log"; exit 1;
            fi
            rg '^M_WAIT_CAPTURE|^PASS ' "$log"
            passes=$((passes+1))
        done
    done
done
echo "PASS M source lifetime RV$xlen: configurations=6 directed=$passes SKIP=0"
