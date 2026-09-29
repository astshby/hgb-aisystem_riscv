#!/usr/bin/env bash
set -euo pipefail
xlen="${1:-32}"
tool_prefix="${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-"
export SOC=1 SOC_DDR_BYTES=65536
config="m${MUL_IMPL:-0}d${DIV_IMPL:-0}"
source scripts/verilator/benchmark_platform.sh
image_dir="build/benchmark/soc-icache-rv${xlen}-${config}"
sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
log="logs/soc-icache-rv${xlen}-${config}.log"
mkdir -p logs
bash scripts/verilator/build_benchmark_sim.sh "${xlen}"
bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${image_dir}" \
    -march="rv${xlen}im_zicsr_zifencei" benchmark/bsp/crt0.S tb/cache/icache_smoke.c \
    benchmark/bsp/runtime.c benchmark/bsp/softarith.c \
    >"logs/soc-icache-build-rv${xlen}-${config}.log" 2>&1
tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
"${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
    +TOHOST="${tohost_addr}" +CONSOLE="${console_addr}" +CACHE_CHECKS \
    +TEST=soc-icache +MAX_CYCLES=2000000 >"${log}" 2>&1 || { tail -n 20 "${log}"; exit 1; }
if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then
    tail -n 20 "${log}"
    exit 1
fi
grep -E '^(PASS soc-icache|CACHE )' "${log}"

# 已退休 Store 的写回失败不能假装 FENCE.I 成功，观察停取指且无更年轻提交。
fatal_log="${log%.log}-fatal.log"
"${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
    +TOHOST="${tohost_addr}" +CONSOLE="${console_addr}" +FAULT_WRITE=80000200 \
    +EXPECT_CACHE_FATAL +TEST=soc-cache-fatal +MAX_CYCLES=2000000 >"${fatal_log}" 2>&1 || { tail -n 20 "${fatal_log}"; exit 1; }
grep '^PASS soc-cache-fatal' "${fatal_log}"
