#!/usr/bin/env bash
set -euo pipefail
xlen="${1:-32}"
export SOC=1
mul_impl="${MUL_IMPL:-0}"
div_impl="${DIV_IMPL:-0}"
config="m${mul_impl}d${div_impl}"
source scripts/verilator/benchmark_platform.sh
tool_prefix="${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-"
image_dir="build/benchmark/soc-peripherals-rv${xlen}-${config}"
sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
log="logs/soc-peripherals-rv${xlen}-${config}.log"
bash scripts/verilator/build_benchmark_sim.sh "${xlen}"
bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${image_dir}" \
    tb/soc/irq_crt0.S tb/soc/peripheral_smoke.c benchmark/bsp/runtime.c benchmark/bsp/softarith.c \
    >"logs/soc-peripherals-build-rv${xlen}.log" 2>&1
tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
"${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
    +TOHOST="${tohost_addr}" +CONSOLE="${console_addr}" +UART_LOOPBACK +GPIO_LOOPBACK \
    +TEST=soc-peripherals +MAX_CYCLES=2000000 >"${log}" 2>&1
if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then
    tail -n 20 "${log}"
    exit 1
fi
grep "PASS soc-peripherals RV${xlen}" "${log}"
