#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
mul_impl="${MUL_IMPL:-0}"
div_impl="${DIV_IMPL:-0}"
config="m${mul_impl}d${div_impl}"
tool_root="${RISCV_TOOL_ROOT:-/opt/riscv/bin}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
coremark_root="benchmark/coremark/vendor/coremark"
target_ticks=11000000

coremark_sources=(
    benchmark/bsp/crt0.S
    benchmark/bsp/runtime.c
    benchmark/bsp/softarith.c
    benchmark/coremark/port/core_portme.c
    benchmark/coremark/port/ee_printf.c
    "${coremark_root}/core_list_join.c"
    "${coremark_root}/core_main.c"
    "${coremark_root}/core_matrix.c"
    "${coremark_root}/core_state.c"
    "${coremark_root}/core_util.c"
)

build_image() {
    local mode="$1"
    local iterations="$2"
    local output_dir="$3"
    local mode_define

    if [[ "${mode}" == "performance" ]]; then
        mode_define="-DPERFORMANCE_RUN=1"
    else
        mode_define="-DVALIDATION_RUN=1"
    fi
    bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${output_dir}" \
        -I benchmark/coremark/port \
        -I "${coremark_root}" \
        -DITERATIONS="${iterations}" \
        -DTOTAL_DATA_SIZE=2000 \
        "${mode_define}" \
        "${coremark_sources[@]}" \
        >"logs/coremark-${mode}-build-rv${xlen}-${config}.log" 2>&1
}

run_image() {
    local name="$1"
    local image_dir="$2"
    local max_cycles="$3"
    local run_log="$4"
    local tohost_addr
    local console_addr

    tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
    console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
    if [[ -z "${tohost_addr}" || -z "${console_addr}" ]]; then
        echo "FAIL ${name} is missing host symbols"
        exit 1
    fi

    "${sim_dir}/Vtb_benchmark" \
        +IMEM="${image_dir}/imem.hex" \
        +DMEM="${image_dir}/dmem.hex" \
        +TOHOST="${tohost_addr}" \
        +CONSOLE="${console_addr}" \
        +TEST="${name}" \
        +MAX_CYCLES="${max_cycles}" >"${run_log}" 2>&1
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "${run_log}" ||
        ! grep -q "PASS ${name} RV${xlen}" "${run_log}"; then
        tail -n 20 "${run_log}"
        exit 1
    fi
}

read_ticks() {
    awk '/^Total ticks/ { print $NF; exit }' "$1"
}

bash scripts/verilator/build_benchmark_sim.sh "${xlen}"

calibration_dir="build/benchmark/coremark-rv${xlen}-${config}/calibration"
calibration_log="logs/coremark-calibration-rv${xlen}-${config}.log"
build_image performance 1 "${calibration_dir}"
run_image coremark-calibration "${calibration_dir}" 100000000 "${calibration_log}"
calibration_ticks="$(read_ticks "${calibration_log}")"
if [[ -z "${calibration_ticks}" || "${calibration_ticks}" == "0" ]]; then
    echo "FAIL CoreMark RV${xlen} calibration did not report Total ticks"
    exit 1
fi

iterations="${COREMARK_ITERATIONS:-$(((target_ticks + calibration_ticks - 1) / calibration_ticks))}"
if ((iterations < 1)); then
    iterations=1
fi
max_cycles=$((iterations * calibration_ticks * 2 + 5000000))

for mode in performance validation; do
    image_dir="build/benchmark/coremark-rv${xlen}-${config}/${mode}"
    run_log="logs/coremark-${mode}-rv${xlen}-${config}.log"
    build_image "${mode}" "${iterations}" "${image_dir}"
    run_image "coremark-${mode}" "${image_dir}" "${max_cycles}" "${run_log}"
    if ! grep -q "Correct operation validated" "${run_log}"; then
        tail -n 20 "${run_log}"
        echo "FAIL CoreMark RV${xlen} ${mode} validation"
        exit 1
    fi
    grep -E "^(2K|Total ticks|Total time|Iterations |seedcrc|\[0\]crc|Correct operation|PASS coremark)" "${run_log}"
done

performance_log="logs/coremark-performance-rv${xlen}-${config}.log"
performance_ticks="$(read_ticks "${performance_log}")"
score_per_mhz="$(awk -v iterations="${iterations}" -v ticks="${performance_ticks}" \
    'BEGIN { printf "%.6f", iterations * 1000000.0 / ticks }')"

echo "PASS CoreMark RV${xlen} ${config}: iterations=${iterations} cycles=${performance_ticks} CoreMark/MHz=${score_per_mhz}"
if [[ -n "${COREMARK_FREQ_MHZ:-}" ]]; then
    score="$(awk -v normalized="${score_per_mhz}" -v frequency="${COREMARK_FREQ_MHZ}" \
        'BEGIN { printf "%.6f", normalized * frequency }')"
    echo "INFO CoreMark RV${xlen} @ ${COREMARK_FREQ_MHZ} MHz: CoreMark=${score}"
fi
