#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
case "$xlen" in
    32|64) ;;
    *) echo "XLEN must be 32 or 64" >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"

# 每种实际算法都通过同一完成通道；单进程与独立目录避免覆盖普通单测。
passes=0
for config in arbiter m0d0 m0d1 m1d0 m1d1 m2d0 m2d1; do
    if [[ "$config" == arbiter ]]; then
        name=tb_completion_arbiter
        mul=0
        div=0
    else
        name=tb_mdu_completion_adapter
        mul="${config:1:1}"
        div="${config:3:1}"
    fi
    out="build/verilator/completion-rv${xlen}-${core_build_tag}/${config}"
    log="logs/completion-rv${xlen}-${core_build_tag}-${config}.log"
    mkdir -p "$out"
    # SRT C++ 模型的宿主优化会显著拖慢编译，不影响 RTL 周期或算术结果。
    verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
        --x-initial unique --x-assign unique \
        -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL="$mul" -DCORE_DIV_IMPL="$div" \
        -Mdir "$out" -f scripts/rtl_files.f "tb/unit/${name}.sv" \
        --top-module "$name" >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
    "$out/V${name}" +verilator+rand+reset+2 +verilator+seed+31 >>"$log" 2>&1 \
        || { tail -n 30 "$log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS ${name}" "$log"; then
        tail -n 30 "$log"
        exit 1
    fi
    rg "^PASS ${name}" "$log"
    passes=$((passes + 1))
done
echo "PASS completion-channels RV${xlen}: ${passes} runs, 0 SKIP"
