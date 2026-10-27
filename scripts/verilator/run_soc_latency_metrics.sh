#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/measure-optimize-20261022/step2}"
out="build/p2/latency-metrics-rv$xlen"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root" "$out"
commands="$log_root/metrics-rv$xlen.commands.txt"
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -CFLAGS -O1
    -DCORE_XLEN="$xlen" vsrc/pkg/core_config_pkg.sv vsrc/pkg/axi_types_pkg.sv
    tb/soc/tb_soc_latency_metrics.sv --top-module tb_soc_latency_metrics -Mdir "$out")
printf '%q ' "${command[@]}" > "$commands"
printf '\n' >> "$commands"
"${command[@]}" > "$log_root/metrics-build-rv$xlen.log" 2>&1 || { tail -40 "$log_root/metrics-build-rv$xlen.log"; exit 1; }
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/metrics-build-rv$xlen.log"; then exit 1; fi
command=("$out/Vtb_soc_latency_metrics")
printf '%q ' "${command[@]}" >> "$commands"
printf '\n' >> "$commands"
"${command[@]}" > "$log_root/metrics-rv$xlen.log" 2>&1
rg '^PASS ' "$log_root/metrics-rv$xlen.log"
# 子进程异常退出是负测预期；禁用 core dump，核对具体失败点以防无关崩溃被计为通过。
ulimit -c 0
for kind in UNMATCHED UNSTABLE OVERFLOW W_LENGTH W_AW_OVERFLOW W_DATA_OVERFLOW; do
    command=("$out/Vtb_soc_latency_metrics" "+NEG_$kind")
    printf '%q ' "${command[@]}" >> "$commands"
    printf '\n' >> "$commands"
    if "${command[@]}" > "$log_root/metrics-rv$xlen-negative-$kind.log" 2>&1; then
        echo "negative test unexpectedly passed: $kind" >&2; exit 1
    fi
    case "$kind" in
        UNMATCHED) rg -q 'unmatched response id=7' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
        UNSTABLE) rg -q 'soc_latency_metrics.sv:.*Assertion failed' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
        OVERFLOW) rg -q 'ID FIFO overflow' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
        W_LENGTH) rg -q 'WLAST/length mismatch' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
        W_AW_OVERFLOW) rg -q 'AW/W join overflow on AW' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
        W_DATA_OVERFLOW) rg -q 'AW/W join overflow on W' "$log_root/metrics-rv$xlen-negative-$kind.log" ;;
    esac
    echo "PASS soc-latency-metrics-negative RV$xlen case=$kind"
done
python3 scripts/verilator/p2_manifest.py "$log_root/metrics-rv$xlen.manifest.json" \
    --binary "$out/Vtb_soc_latency_metrics" --commands "$commands"
