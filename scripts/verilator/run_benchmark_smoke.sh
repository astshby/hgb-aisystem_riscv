#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
tool_root="${RISCV_TOOL_ROOT:-/opt/riscv/bin}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
build_dir="build/benchmark/smoke-rv${xlen}"
sim_dir="build/verilator/benchmark-rv${xlen}"
run_log="logs/benchmark-smoke-rv${xlen}.log"

bash scripts/verilator/build_benchmark_sim.sh "${xlen}"
bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${build_dir}" \
    benchmark/bsp/crt0.S \
    benchmark/bsp/runtime.c \
    benchmark/bsp/softarith.c \
    benchmark/smoke/main.c \
    >"logs/benchmark-smoke-build-rv${xlen}.log" 2>&1

tohost_addr="$("${tool_prefix}nm" -n "${build_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
console_addr="$("${tool_prefix}nm" -n "${build_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
if [[ -z "${tohost_addr}" || -z "${console_addr}" ]]; then
    echo "FAIL benchmark smoke is missing host symbols"
    exit 1
fi

"${sim_dir}/Vtb_benchmark" \
    +IMEM="${build_dir}/imem.hex" \
    +DMEM="${build_dir}/dmem.hex" \
    +TOHOST="${tohost_addr}" \
    +CONSOLE="${console_addr}" \
    +TEST="benchmark-smoke" \
    +MAX_CYCLES=1000000 >"${run_log}" 2>&1
grep "PASS benchmark-smoke RV${xlen}" "${run_log}" | tail -n 1
