#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/m1-local-followup-20261022/tcm-$p2_core_build_tag}"
out="build/p2/tcm-bank-equivalence-rv$xlen-$p2_core_build_tag"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root" "$out"
build_log="$log_root/build-rv$xlen.log"
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -CFLAGS -O1
    -DCORE_XLEN="$xlen" "${p2_core_flags[@]}"
    vsrc/pkg/core_config_pkg.sv vsrc/pkg/riscv_unpriv_pkg.sv vsrc/pkg/riscv_priv_pkg.sv
    vsrc/pkg/core_types_pkg.sv vsrc/pkg/soc_config_pkg.sv vsrc/pkg/soc_addr_pkg.sv
    vsrc/pkg/bus_types_pkg.sv vsrc/soc/memory/tcm_dual_bank.sv
    tb/soc/tb_tcm_dual_bank_equivalence.sv --top-module tb_tcm_dual_bank_equivalence -Mdir "$out")
printf '%q ' "${command[@]}" > "$log_root/commands-rv$xlen.txt"
printf '\n' >> "$log_root/commands-rv$xlen.txt"
"${command[@]}" > "$build_log" 2>&1 || { tail -40 "$build_log"; exit 1; }
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$build_log"; then exit 1; fi
for seed in 430097725 19349663 83492791; do
    run_log="$log_root/run-rv$xlen-seed$seed.log"
    command=("$out/Vtb_tcm_dual_bank_equivalence" "+SEED=$seed")
    printf '%q ' "${command[@]}" >> "$log_root/commands-rv$xlen.txt"
    printf '\n' >> "$log_root/commands-rv$xlen.txt"
    "${command[@]}" > "$run_log" 2>&1 || { tail -30 "$run_log"; exit 1; }
    if rg '(%Fatal|%Error|Assertion failed)' "$run_log"; then exit 1; fi
    rg '^PASS ' "$run_log"
done
python3 scripts/verilator/p2_manifest.py "$log_root/tcm-rv$xlen.manifest.json" \
    --binary "$out/Vtb_tcm_dual_bank_equivalence" --commands "$log_root/commands-rv$xlen.txt"
