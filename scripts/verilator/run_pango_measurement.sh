#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
layer="${2:-all}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
[[ "$layer" =~ ^(0|1|2|all)$ ]] || exit 2
source scripts/verilator/p1_core_config.sh
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${PANGO_MEASURE_LOG_ROOT:-logs/pango-measurement/rv$xlen}"
build_root="${PANGO_MEASURE_BUILD_ROOT:-build/pango-measurement/rv$xlen}"
mkdir -p "$log_root" "$build_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
new_sources=(vsrc/cpu/pango_measure_scan.sv vsrc/cpu/pango_measure_hot.sv vsrc/cpu/pango_measure_top.sv)
layers=(0 1 2)
[[ "$layer" == all ]] || layers=("$layer")
jobs=()
[[ "${PANGO_MEASURE_SKIP_SCAN:-0}" == 1 ]] || jobs+=(scan)
for current in "${layers[@]}"; do jobs+=("h$current"); done
for job in "${jobs[@]}"; do
    [[ ! -e "$log_root/$job.build.log" ]] || { echo "use a new log directory: $log_root" >&2; exit 2; }
    if [[ "$job" == scan ]]; then
        top=tb_pango_measure_scan
        flags=()
        sources=(vsrc/cpu/pango_measure_scan.sv tb/fpga/tb_pango_measure_scan.sv)
    else
        top=tb_pango_measure_top
        flags=("-GMEASURE_LAYER=${job#h}")
        sources=(-f scripts/soc_files.f "${new_sources[@]}" tb/fpga/tb_pango_measure_top.sv)
    fi
    out="$build_root/$job"
    command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen"
        "${p2_core_flags[@]}" "${flags[@]}" "${sources[@]}" --top-module "$top" -Mdir "$out")
    printf '%q ' "${command[@]}" > "$log_root/$job.commands.txt"
    printf '\n%q\n' "$out/V$top" >> "$log_root/$job.commands.txt"
    sha256sum "${new_sources[@]}" tb/fpga/tb_pango_measure_scan.sv tb/fpga/tb_pango_measure_top.sv \
        scripts/verilator/run_pango_measurement.sh > "$log_root/$job.measurement-sources.sha256"
    mkdir -p "$log_root/$job.sources"
    cp "${new_sources[@]}" tb/fpga/tb_pango_measure_scan.sv tb/fpga/tb_pango_measure_top.sv \
        scripts/verilator/run_pango_measurement.sh "$log_root/$job.sources/"
    "${command[@]}" > "$log_root/$job.build.log" 2>&1 || { tail -50 "$log_root/$job.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/$job.build.log"; then exit 1; fi
    "$out/V$top" > "$log_root/$job.run.log" 2>&1 || { tail -50 "$log_root/$job.run.log"; exit 1; }
    rg '^PASS' "$log_root/$job.run.log"
    python3 scripts/verilator/p2_manifest.py "$log_root/$job.manifest.json" --binary "$out/V$top" --commands "$log_root/$job.commands.txt"
    sha256sum --check --quiet "$log_root/$job.measurement-sources.sha256"
done
