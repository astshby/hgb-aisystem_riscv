#!/usr/bin/env bash
# Module: rt_thread_build
# Description: Standalone RT-Thread image for the complete four-domain DDR SoC.
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
opt="${SOFTWARE_OPT:-O3}"
case "$opt" in O2|O3|Ofast) ;; *) echo 'SOFTWARE_OPT must be O2, O3 or Ofast' >&2; exit 2;; esac
rt="${RTTHREAD_ROOT:-third_party/rt-thread}"
revision=ddf52e2cdd977f14fc04035c88672ac204aec713
python3 scripts/rt-thread/verify.py "$rt"
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}/riscv64-unknown-elf-}"
bsp=software/rt-thread
app="${RTTHREAD_APP:-smoke}"
case "$app" in smoke|demo) ;; *) echo 'RTTHREAD_APP must be smoke or demo' >&2; exit 2;; esac
suffix=""; [[ "$app" == smoke ]] || suffix="-demo"
out="${RTTHREAD_BUILD_DIR:-build/rt-thread/system-rv${xlen}-${opt}${suffix}}"
mkdir -p "$out" logs
flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=gnu99 "-$opt" -g -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-stack-protector -fno-tree-loop-distribute-patterns -mstrict-align
    -ffunction-sections -fdata-sections -Wall -Wextra -Wno-unused-parameter
    -D__RTTHREAD__ -D__RT_KERNEL_SOURCE__ -I"$bsp" -I"$rt/include"
    -I"$rt/components/drivers/include" -I"$rt/libcpu/risc-v/common")
sources=("$bsp/bootstrap_ddr.S" "$bsp/startup.S" "$bsp/trap.S" "$bsp/board.c" "$bsp/drv_uart.c" "$bsp/drv_gpio.c"
    "$rt/libcpu/risc-v/common/cpuport.c" "$rt/libcpu/risc-v/common/context_gcc.S" "$bsp/$app.c" "$bsp/context_probe.S")
[[ "$app" != demo ]] || sources+=("$bsp/demo_command.c")
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
python3 - "$out" "$xlen" "$opt" "$app" "$rt" "${prefix}gcc" "${sources[@]}" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]); width,opt,app,rt,compiler=sys.argv[2:7]
sources=sys.argv[7:]+['software/rt-thread/board.h','software/rt-thread/rtconfig.h',
    'software/rt-thread/link.ld','scripts/rt-thread/build.sh',
    'software/common/soc_clocks.h','software/common/soc_capabilities.h']
if app=='demo': sources+=['software/rt-thread/demo_command.h']
receipt=dict(app=app,xlen=int(width),optimization=opt,coremark=False,
    compiler=subprocess.check_output([compiler,'--version'],text=True).splitlines()[0],
    source_branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),
    source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    rt_revision='ddf52e2cdd977f14fc04035c88672ac204aec713',
    source_sha256={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sources},
    image_sha256={p:hashlib.sha256((out/p).read_bytes()).hexdigest()
                  for p in ('program.elf','imem.hex','dmem.hex','ddr.hex')},
    loading='DDR preload required; this build does not implement Flash/TF loading')
(out/'manifest.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
