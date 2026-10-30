#!/usr/bin/env bash
# Build only; no RTL simulator, PDS, or board programming is started.
set -euo pipefail
xlen="${1:-32}"
output="${2:-build/yolo/demo-rv${xlen}}"
case "$xlen" in 32|64) ;; *) echo 'width must be 32 or 64' >&2; exit 2;; esac
opt="${SOFTWARE_OPT:-O3}"
case "$opt" in O2|O3|Ofast) ;; *) echo 'SOFTWARE_OPT must be O2, O3 or Ofast' >&2; exit 2;; esac
hdmi="${YOLO_DEMO_HDMI:-1}"
[[ "$hdmi" == 0 || "$hdmi" == 1 ]] || { echo 'YOLO_DEMO_HDMI must be 0 or 1' >&2; exit 2; }
if [[ "$xlen" == 32 ]]; then march=rv32im_zicsr; abi=ilp32; else march=rv64im_zicsr; abi=lp64; fi
mkdir -p "$output"
math_libraries=(-lm -lgcc)
if [[ "$xlen" == 64 ]]; then
    # 此安装未提供无C的RV64IM软浮点multilib，不能链接默认FD或IMAC库。
    softmath="${YOLO_SOFTMATH_ARCHIVE:-$output/softmath/libyolo_softmath.a}"
    if [[ ! -f "$softmath" ]]; then
        bash scripts/yolo/build_softmath.sh "$output/softmath"
    fi
    math_libraries=("$softmath")
fi
python3 scripts/yolo/firmware.py prepare --output "$output" --xlen "$xlen" \
    --optimization "$opt" --hdmi "$hdmi" --baud "${YOLO_DEMO_BAUD:-115200}"
# 自动卷积回归源码及默认 main 保持原样，只对本对象改名供 UART 命令调用。
"${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-gcc" \
    -march="$march" -mabi="$abi" -mcmodel=medany -mno-relax -std=gnu99 "-$opt" \
    -g -ffreestanding -fno-builtin -fno-common -fno-pie -mstrict-align \
    -fno-tree-loop-distribute-patterns -Wall -Wextra -Werror \
    -Dmain=yolo_operator_selftest -c software/yolo/main.c -o "$output/operator.o"
SOC=1 SOC_DDR=0 bash scripts/verilator/build_baremetal_image.sh "$xlen" "$output" \
    -Wall -Wextra -Werror -fno-fast-math -ffp-contract=off -fstack-usage \
    -DYOLO_DEMO_HDMI="$hdmi" -DYOLO_DEMO_BAUD="${YOLO_DEMO_BAUD:-115200}" \
    -include "$output/build-id.h" \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    software/common/baremetal/crt0.S software/common/baremetal/runtime.c \
    software/common/baremetal/softarith.c "$output/operator.o" \
    software/yolo/demo_protocol.c software/yolo/conv_schedule.c software/yolo/demo_main.c \
    software/yolo/network.c software/yolo/network_service.c software/yolo/network_pool.c \
    software/yolo/video_service.c software/yolo/demo_libc.c \
    "${math_libraries[@]}"

python3 scripts/yolo/firmware.py seal --output "$output" --tool-root "$RISCV_TOOL_ROOT"
