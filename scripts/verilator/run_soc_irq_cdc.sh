#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/irq-cdc-$p2_core_build_tag}"
out="build/p2/irq-cdc-rv$xlen-$p2_core_build_tag"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
commands="$log_root/irq-cdc-rv$xlen.commands.txt"
[[ ! -e "$commands" ]] || { echo "refusing to overwrite $commands" >&2; exit 2; }
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -CFLAGS -O1
    -DCORE_XLEN="$xlen" "${p2_core_flags[@]}" -f scripts/system_files.f
    tb/soc/tb_soc_irq_cdc.sv --top-module tb_soc_irq_cdc -Mdir "$out")
printf '%q ' "${command[@]}" >"$commands"
printf '\n' >>"$commands"
"${command[@]}" >"$log_root/irq-cdc-rv$xlen.build.log" 2>&1 || {
    tail -40 "$log_root/irq-cdc-rv$xlen.build.log"; exit 1;
}
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/irq-cdc-rv$xlen.build.log"; then exit 1; fi
for clocks in 5000:20000 4000:12500 5882:13514; do
    IFS=: read -r core_half periph_half <<< "$clocks"
    log="$log_root/irq-cdc-rv$xlen-$core_half-$periph_half.run.log"
    command=("$out/Vtb_soc_irq_cdc" "+CORE_HALF_PS=$core_half" "+PERIPH_HALF_PS=$periph_half")
    printf '%q ' "${command[@]}" >>"$commands"
    printf '\n' >>"$commands"
    "${command[@]}" >"$log" 2>&1 || { tail -30 "$log"; exit 1; }
    rg '^PASS ' "$log"
done
python3 scripts/verilator/p2_manifest.py "$log_root/irq-cdc-rv$xlen.manifest.json" \
    --binary "$out/Vtb_soc_irq_cdc" --commands "$commands"
