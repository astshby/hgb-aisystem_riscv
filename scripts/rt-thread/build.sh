#!/usr/bin/env bash
# Module: rt_thread_build
# Description: Standalone RT-Thread image for the complete four-domain DDR SoC.
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
opt="${SOFTWARE_OPT:-O3}"
case "$opt" in O2|O3|Ofast) ;; *) echo 'SOFTWARE_OPT must be O2, O3 or Ofast' >&2; exit 2;; esac
rt="${RTTHREAD_ROOT:-build/rt-thread-v5.2.2}"
revision=ddf52e2cdd977f14fc04035c88672ac204aec713
[[ "$(git -C "$rt" rev-parse HEAD)" == "$revision" ]] || { echo 'RT-Thread revision mismatch'; exit 1; }
[[ -z "$(git -C "$rt" status --porcelain --untracked-files=no)" ]] || { echo 'RT-Thread dependency is modified'; exit 1; }
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}/riscv64-unknown-elf-}"
bsp=software/rt-thread
out="build/rt-thread/system-rv${xlen}-${opt}"
mkdir -p "$out" logs
flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=gnu99 "-$opt" -g -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-stack-protector -fno-tree-loop-distribute-patterns -mstrict-align
    -ffunction-sections -fdata-sections -Wall -Wextra -Wno-unused-parameter
    -D__RTTHREAD__ -D__RT_KERNEL_SOURCE__ -I"$bsp" -I"$rt/include"
    -I"$rt/components/drivers/include" -I"$rt/libcpu/risc-v/common")
sources=("$bsp/bootstrap_ddr.S" "$bsp/startup.S" "$bsp/trap.S" "$bsp/board.c" "$bsp/drv_uart.c" "$bsp/drv_gpio.c"
    "$rt/libcpu/risc-v/common/cpuport.c" "$rt/libcpu/risc-v/common/context_gcc.S" "$bsp/smoke.c" "$bsp/context_probe.S")
for f in clock cpu_up defunct idle ipc irq kservice mem object scheduler_comm scheduler_up thread timer; do
    sources+=("$rt/src/$f.c")
done
for f in kerrno kstdio kstring rt_vsnprintf_tiny; do sources+=("$rt/src/klibc/$f.c"); done
sources+=("$rt/components/drivers/core/device.c" "$rt/components/drivers/ipc/completion_up.c"
    "$rt/components/drivers/ipc/completion_comm.c" "$rt/components/drivers/serial/dev_serial.c"
    "$rt/components/drivers/pin/dev_pin.c" software/common/baremetal/softarith.c)
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
# 初始热代码仅存在 DTCM 装载区，启动后由真实 DMA 搬入 ITCM。
for spec in imem:0x01000000:.init dmem:0x01100000:.observe,.hot ddr:0x80000000:.text,.data; do
    IFS=: read -r name base sections <<< "$spec"
    selected=(); IFS=, read -ra names <<< "$sections"
    for section in "${names[@]}"; do selected+=("--only-section=$section"); done
    "${prefix}objcopy" -O verilog --verilog-data-width 1 "${selected[@]}" "$out/program.elf" "$out/$name.vhex"
    bytes=65536; [[ "$name" != ddr ]] || bytes=262144
    python3 scripts/verilator/verilog_hex_to_mem.py "$out/$name.vhex" "$out/$name.hex" \
        --word-bytes "$((xlen/8))" --depth "$((bytes/(xlen/8)))" --base "$base"
done
"${prefix}objdump" -d "$out/program.elf" > "$out/program.dump"
"${prefix}nm" -n "$out/program.elf" > "$out/program.nm"
"${prefix}size" "$out/program.elf"
python3 scripts/rt-thread/check_image.py "$out" "$xlen"
