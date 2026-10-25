#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/joint-step3-20261023/dma-saturation}"
out="build/p2/dma-saturation-rv$xlen"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root" "$out"
commands="$log_root/dma-saturation-rv$xlen.commands.txt"
[[ ! -e "$commands" ]] || { echo "refusing to overwrite $commands" >&2; exit 2; }
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -CFLAGS -O1
    -DCORE_XLEN="$xlen" -f scripts/system_files.f tb/soc/axi_system_memory_model.sv
    tb/soc/tb_dma_saturation.sv --top-module tb_dma_saturation -Mdir "$out")
printf '%q ' "${command[@]}" > "$commands"
printf '\n' >> "$commands"
"${command[@]}" > "$log_root/dma-saturation-build-rv$xlen.log" 2>&1 || { tail -40 "$log_root/dma-saturation-build-rv$xlen.log"; exit 1; }
if rg '%(Error|Warning-(WIDTH|LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/dma-saturation-build-rv$xlen.log"; then exit 1; fi
for half in 6250 5000; do
    for metrics in off on; do
        args=("+SYS_HALF_PS=$half")
        if [[ "$metrics" == on ]]; then args+=(+METRICS); fi
        command=("$out/Vtb_dma_saturation" "${args[@]}")
        printf '%q ' "${command[@]}" >> "$commands"
        printf '\n' >> "$commands"
        "${command[@]}" > "$log_root/dma-saturation-rv$xlen-h$half-$metrics.log" 2>&1
        rg '^PASS ' "$log_root/dma-saturation-rv$xlen-h$half-$metrics.log"
    done
    diff <(rg '^PASS ' "$log_root/dma-saturation-rv$xlen-h$half-off.log") <(rg '^PASS ' "$log_root/dma-saturation-rv$xlen-h$half-on.log")
done
python3 scripts/verilator/p2_manifest.py "$log_root/dma-saturation-rv$xlen.manifest.json" \
    --binary "$out/Vtb_dma_saturation" --commands "$commands"
