#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
app="${RT_APP:-smoke}"
mode="${RT_COREMARK_MODE:-performance}"
layout="${RT_COREMARK_LAYOUT:-tcm}"
case "$layout" in tcm|ddr);; *) echo 'RT_COREMARK_LAYOUT must be tcm or ddr' >&2; exit 2;; esac
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
case "$app" in smoke|coremark);; *) echo 'RT_APP must be smoke or coremark' >&2; exit 2;; esac
case "$mode" in performance|validation);; *) echo 'invalid CoreMark mode' >&2; exit 2;; esac
rt="${RTTHREAD_ROOT:-build/rt-thread-v5.2.2}"
revision=ddf52e2cdd977f14fc04035c88672ac204aec713
[[ "$(git -C "$rt" rev-parse HEAD)" == "$revision" ]] || { echo 'RT-Thread revision mismatch'; exit 1; }
[[ -z "$(git -C "$rt" status --porcelain --untracked-files=no)" ]] || { echo 'RT-Thread dependency is modified'; exit 1; }
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-}"
bsp=software/rt-thread
out="build/rt-thread/rv$xlen"
linker="$bsp/link.ld"
if [[ "$app" == coremark ]]; then
    out="build/rt-thread/coremark-$mode-rv$xlen"
    linker="$bsp/link_coremark.ld"
    if [[ "$layout" == ddr ]]; then
        out="build/rt-thread/coremark-ddr-$mode-rv$xlen"
        linker="$bsp/link_coremark_ddr.ld"
    fi
    if [[ "${RT_COREMARK_RESIDENT:-0}" == 1 ]]; then out="$out-resident"; fi
    if [[ "${RT_COREMARK_BAUD:-115200}" != 115200 ]]; then out="$out-baud${RT_COREMARK_BAUD}"; fi
fi
mkdir -p "$out" logs
flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=gnu99 -Os -g -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-stack-protector -fno-tree-loop-distribute-patterns -mstrict-align
    -ffunction-sections -fdata-sections -Wall -Wextra -Wno-unused-parameter
    -D__RTTHREAD__ -D__RT_KERNEL_SOURCE__ -I"$bsp" -I"$rt/include"
    -I"$rt/components/drivers/include" -I"$rt/libcpu/risc-v/common")
sources=("$bsp/startup.S" "$bsp/trap.S" "$bsp/board.c" "$bsp/drv_uart.c" "$bsp/drv_gpio.c"
    "$rt/libcpu/risc-v/common/cpuport.c" "$rt/libcpu/risc-v/common/context_gcc.S")
if [[ "$app" == smoke ]]; then
    sources+=("$bsp/smoke.c" "$bsp/context_probe.S")
else
    flags+=(-DHGB_MUL_IMPL="${MUL_IMPL:-0}" -DHGB_DIV_IMPL="${DIV_IMPL:-0}"
        -DHGB_COREMARK_BAUD="${RT_COREMARK_BAUD:-115200}")
    if [[ "${RT_COREMARK_RESIDENT:-0}" == 1 ]]; then flags+=(-DHGB_COREMARK_RESIDENT=1); fi
    if [[ "$layout" == ddr ]]; then
        flags+=(-DHGB_COREMARK_DDR=1)
        sources+=("$bsp/bootstrap_ddr.S")
    fi
    flags+=(-I benchmark/coremark/vendor/coremark -I benchmark/bsp
        -DITERATIONS="${RT_COREMARK_ITERATIONS:-1}" -DTOTAL_DATA_SIZE=2000
        -Dmain=coremark_main)
    if [[ "$mode" == performance ]]; then flags+=(-DPERFORMANCE_RUN=1)
    else flags+=(-DVALIDATION_RUN=1); fi
    sources+=("$bsp/coremark_app.c" "$bsp/coremark_port.c"
        benchmark/coremark/port/ee_printf.c
        benchmark/coremark/vendor/coremark/core_list_join.c
        benchmark/coremark/vendor/coremark/core_main.c
        benchmark/coremark/vendor/coremark/core_matrix.c
        benchmark/coremark/vendor/coremark/core_state.c
        benchmark/coremark/vendor/coremark/core_util.c)
fi
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
    -Wl,--build-id=none,--no-relax,--gc-sections -Wl,-T,"$linker" \
    -Wl,-Map,"$out/program.map" "${objects[@]}" -o "$out/program.elf"
[[ -z "$("${prefix}nm" -u "$out/program.elf")" ]]
imem_section=.text
if [[ "$app" == coremark && "$layout" == ddr ]]; then imem_section=.init; fi
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section="$imem_section" "$out/program.elf" "$out/imem.vhex"
# .hot 的 VMA 在 I-TCM，LMA 在 D-TCM；绝不能预先写进 I-TCM 测试作弊。
if [[ "$app" == coremark && "$layout" == ddr ]]; then
    "${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.observe --only-section=.hot "$out/program.elf" "$out/dmem.vhex"
    "${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.text --only-section=.data "$out/program.elf" "$out/ddr.vhex"
    python3 scripts/verilator/verilog_hex_to_mem.py "$out/ddr.vhex" "$out/ddr.hex" --word-bytes "$((xlen/8))" --depth "$((262144/(xlen/8)))" --base 0x80000000
else
    "${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.data --only-section=.hot "$out/program.elf" "$out/dmem.vhex"
fi
python3 scripts/verilator/verilog_hex_to_mem.py "$out/imem.vhex" "$out/imem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01000000
python3 scripts/verilator/verilog_hex_to_mem.py "$out/dmem.vhex" "$out/dmem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01100000
"${prefix}objdump" -d "$out/program.elf" > "$out/program.dump"
"${prefix}nm" -n "$out/program.elf" > "$out/program.nm"
"${prefix}size" "$out/program.elf"
python3 scripts/rt-thread/check_image.py "$out" "$xlen" "$app" "$layout"
