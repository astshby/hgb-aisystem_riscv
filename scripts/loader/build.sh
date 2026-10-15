#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) exit 2;; esac
prefix="${CROSS_COMPILE:-/usr/bin/riscv64-linux-gnu-}"
out="build/loader/rv$xlen"
if [[ "${LOADER_BAUD:-115200}" != 115200 || "${LOADER_QUIET_MS:-100}" != 100 ]]; then
    out="build/loader/sim-rv$xlen"
fi
mkdir -p "$out"
"${prefix}gcc" -march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany \
    -Os -g -ffreestanding -fno-builtin -fno-pie -fno-stack-protector -mno-relax \
    -Wall -Wextra -Werror -nostdlib -nostartfiles -static -no-pie \
    -DLOADER_BAUD="${LOADER_BAUD:-115200}" -DLOADER_QUIET_MS="${LOADER_QUIET_MS:-100}" \
    -Wl,--build-id=none,--no-relax,-T,software/loader/link.ld,-Map,"$out/loader.map" \
    software/loader/startup.S software/loader/platform.c software/loader/protocol.c \
    -o "$out/loader.elf"
[[ -z "$("${prefix}nm" -u "$out/loader.elf")" ]]
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.text "$out/loader.elf" "$out/imem.vhex"
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.data "$out/loader.elf" "$out/dmem.vhex"
for name in imem dmem; do
    base=0x01000000
    if [[ "$name" == dmem ]]; then base=0x01100000; fi
    python3 scripts/verilator/verilog_hex_to_mem.py "$out/$name.vhex" "$out/$name.hex" \
        --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base "$base"
done
"${prefix}objdump" -d "$out/loader.elf" > "$out/loader.dump"
"${prefix}size" "$out/loader.elf"
echo "PASS loader build RV$xlen"
