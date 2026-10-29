#!/usr/bin/env bash
# Build only; no RTL simulator, PDS, or board programming is started.
set -euo pipefail
xlen="${1:-32}"
output="${2:-build/yolo/demo-rv${xlen}}"
case "$xlen" in 32|64) ;; *) echo 'width must be 32 or 64' >&2; exit 2;; esac
opt="${SOFTWARE_OPT:-O3}"
case "$opt" in O2|O3|Ofast) ;; *) echo 'SOFTWARE_OPT must be O2, O3 or Ofast' >&2; exit 2;; esac
if [[ "$xlen" == 32 ]]; then march=rv32im_zicsr; abi=ilp32; else march=rv64im_zicsr; abi=lp64; fi
mkdir -p "$output"
# 自动卷积回归源码及默认 main 保持原样，只对本对象改名供 UART 命令调用。
"${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-gcc" \
    -march="$march" -mabi="$abi" -mcmodel=medany -mno-relax -std=gnu99 "-$opt" \
    -g -ffreestanding -fno-builtin -fno-common -fno-pie -mstrict-align \
    -fno-tree-loop-distribute-patterns -Wall -Wextra -Werror \
    -Dmain=yolo_operator_selftest -c software/yolo/main.c -o "$output/operator.o"
SOC=1 SOC_DDR=0 bash scripts/verilator/build_baremetal_image.sh "$xlen" "$output" \
    -Wall -Wextra -Werror \
    software/common/baremetal/crt0.S software/common/baremetal/runtime.c \
    software/common/baremetal/softarith.c "$output/operator.o" \
    software/yolo/demo_protocol.c software/yolo/conv_schedule.c software/yolo/demo_main.c
