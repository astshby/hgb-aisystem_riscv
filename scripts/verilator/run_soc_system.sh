#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/system-$p2_core_build_tag}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
base_out="build/p2/system-rv$xlen-$p2_core_build_tag${SYSTEM_BUILD_TAG:-}"
fill_bytes="${SOC_ICACHE_FILL_BYTES:-4}"
[[ "$fill_bytes" == 4 || "$fill_bytes" == 8 ]] || { echo "invalid SOC_ICACHE_FILL_BYTES" >&2; exit 2; }
platform_options=()
if [[ -n "${SYSTEM_DDR_BYTES:-}" ]]; then platform_options+=("-GDDR_BYTES=$SYSTEM_DDR_BYTES"); fi
if [[ -n "${SYSTEM_DDR_MODEL_BYTES:-}" ]]; then platform_options+=("-GDDR_MODEL_BYTES=$SYSTEM_DDR_MODEL_BYTES"); fi
commands="$log_root/${SYSTEM_TEST_NAME:-soc-system}-rv$xlen.commands.txt"
[[ ! -e "$commands" ]] || { echo "refusing to overwrite $commands" >&2; exit 2; }
: > "$commands"
image_dir="${SYSTEM_IMAGE_DIR:-build/p2/software-rv$xlen}"
if [[ -z "${SYSTEM_IMAGE_DIR:-}" ]]; then
    SOC=1 SOC_DDR="${SOC_DDR:-0}" bash scripts/verilator/build_benchmark_image.sh "$xlen" "$image_dir" \
        benchmark/bsp/crt0.S benchmark/bsp/runtime.c benchmark/bsp/softarith.c tb/software/soc_system.c \
        >"${log_root}/software-build$xlen.log" 2>&1
fi
ddr_args=()
if [[ "${SOC_DDR:-0}" == "1" ]]; then
    [[ -f "$image_dir/ddr.hex" ]] || { echo "missing $image_dir/ddr.hex" >&2; exit 1; }
    ddr_args=("+DDR=$image_dir/ddr.hex")
fi
prefix="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-"
tohost="$("${prefix}nm" -n "$image_dir/program.elf" | awk '$3=="tohost" {print $1; exit}')"
console="$("${prefix}nm" -n "$image_dir/program.elf" | awk '$3=="sim_console" {print $1; exit}')"
for config in ${SYSTEM_CLOCK_CONFIGS:-0 1 2 3 4}; do
    [[ "$config" =~ ^[0-4]$ ]] || { echo "invalid SYSTEM_CLOCK_CONFIGS" >&2; exit 2; }
    out="${base_out}-c${config}-if${fill_bytes}"
    log="${log_root}/system-build${xlen}-c${config}-if${fill_bytes}.log"
    command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -CFLAGS -O1
        "${platform_options[@]}" -DCORE_XLEN="$xlen" "${p2_core_flags[@]}"
        "-GCLOCK_PROFILE=$config" "-DSOC_ICACHE_FILL_BYTES=$fill_bytes"
        -f scripts/system_files.f tb/common/store_result_monitor.sv tb/soc/axi_system_memory_model.sv
        tb/soc/spi_flash_model.sv tb/soc/tb_soc_system.sv --top-module tb_soc_system -Mdir "$out")
    printf '%q ' "${command[@]}" >>"$commands"
    printf '\n' >>"$commands"
    "${command[@]}" >"$log" 2>&1 || { tail -40 "$log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log"; then exit 1; fi
    extra_args=()
    if [[ -n "${SYSTEM_EXTRA_PLUSARGS:-}" ]]; then read -r -a extra_args <<< "$SYSTEM_EXTRA_PLUSARGS"; fi
    log="${log_root}/${SYSTEM_TEST_NAME:-soc-system}-rv$xlen-c$config.log"
    printf '%q ' "$out/Vtb_soc_system" +IMEM="$image_dir/imem.hex" +DMEM="$image_dir/dmem.hex" +TOHOST="$tohost" +CONSOLE="$console" \
        +TEST="${SYSTEM_TEST_NAME:-soc-system}" +CLOCK_CONFIG="$config" +MAX_CYCLES="${SYSTEM_MAX_CYCLES:-3000000}" "${ddr_args[@]}" "${extra_args[@]}" >>"$commands"
    printf '\n' >>"$commands"
    "$out/Vtb_soc_system" +IMEM="$image_dir/imem.hex" +DMEM="$image_dir/dmem.hex" +TOHOST="$tohost" +CONSOLE="$console" \
        +TEST="${SYSTEM_TEST_NAME:-soc-system}" +CLOCK_CONFIG="$config" +MAX_CYCLES="${SYSTEM_MAX_CYCLES:-3000000}" "${ddr_args[@]}" "${extra_args[@]}" \
        >"$log" 2>&1 || { tail -30 "$log"; exit 1; }
    if rg '(%Fatal|%Error|Assertion failed)' "$log"; then exit 1; fi
    rg '^PASS ' "$log"
    python3 scripts/verilator/p2_manifest.py "$log_root/${SYSTEM_TEST_NAME:-soc-system}-rv$xlen-c$config.manifest.json" \
        --binary "$out/Vtb_soc_system" --image-dir "$image_dir" --commands "$commands"
done
