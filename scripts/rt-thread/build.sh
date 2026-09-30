#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
rt="${RTTHREAD_ROOT:-build/rt-thread-v5.2.2}"
revision=ddf52e2cdd977f14fc04035c88672ac204aec713
[[ "$(git -C "$rt" rev-parse HEAD)" == "$revision" ]] || { echo 'RT-Thread revision mismatch'; exit 1; }
[[ -z "$(git -C "$rt" status --porcelain --untracked-files=no)" ]] || { echo 'RT-Thread dependency is modified'; exit 1; }
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-}"
bsp=software/rt-thread
out="build/rt-thread/rv$xlen"
mkdir -p "$out" logs
flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=gnu99 -Os -g -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-stack-protector -fno-tree-loop-distribute-patterns -mstrict-align
    -ffunction-sections -fdata-sections -Wall -Wextra -Wno-unused-parameter
    -D__RTTHREAD__ -D__RT_KERNEL_SOURCE__ -I"$bsp" -I"$rt/include"
    -I"$rt/components/drivers/include" -I"$rt/libcpu/risc-v/common")
sources=("$bsp/startup.S" "$bsp/trap.S" "$bsp/board.c" "$bsp/drv_uart.c" "$bsp/drv_gpio.c" "$bsp/smoke.c"
    "$bsp/context_probe.S"
    "$rt/libcpu/risc-v/common/cpuport.c" "$rt/libcpu/risc-v/common/context_gcc.S")
for f in clock cpu_up defunct idle ipc irq kservice mem object scheduler_comm scheduler_up thread timer; do
    sources+=("$rt/src/$f.c")
done
for f in kerrno kstdio kstring rt_vsnprintf_tiny; do sources+=("$rt/src/klibc/$f.c"); done
sources+=("$rt/components/drivers/core/device.c" "$rt/components/drivers/ipc/completion_up.c"
    "$rt/components/drivers/ipc/completion_comm.c"
    "$rt/components/drivers/serial/dev_serial.c" "$rt/components/drivers/pin/dev_pin.c"
    benchmark/bsp/softarith.c)
objects=()
for src in "${sources[@]}"; do
    obj="$out/$(basename "${src%.*}").o"
    "${prefix}gcc" "${flags[@]}" -c "$src" -o "$obj"
    objects+=("$obj")
done
"${prefix}gcc" "${flags[@]}" -nostdlib -nostartfiles -static -no-pie \
    -Wl,--build-id=none,--no-relax,--gc-sections -Wl,-T,"$bsp/link.ld" \
    -Wl,-Map,"$out/program.map" "${objects[@]}" -o "$out/program.elf"
[[ -z "$("${prefix}nm" -u "$out/program.elf")" ]]
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.text "$out/program.elf" "$out/imem.vhex"
# .hot 的 VMA 在 I-TCM，LMA 在 D-TCM；绝不能预先写进 I-TCM 测试作弊。
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.data --only-section=.hot "$out/program.elf" "$out/dmem.vhex"
python3 scripts/verilator/verilog_hex_to_mem.py "$out/imem.vhex" "$out/imem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01000000
python3 scripts/verilator/verilog_hex_to_mem.py "$out/dmem.vhex" "$out/dmem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01100000
"${prefix}objdump" -d "$out/program.elf" > "$out/program.dump"
"${prefix}nm" -n "$out/program.elf" > "$out/program.nm"
"${prefix}size" "$out/program.elf"
python3 scripts/rt-thread/check_image.py "$out" "$xlen"
