#!/usr/bin/env bash
set -euo pipefail

xlen="$1"
output_dir="$2"
shift 2

tool_root="${RISCV_TOOL_ROOT:-/opt/riscv/bin}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
imem_depth=32768
dmem_bytes=131072

if [[ "${xlen}" == "32" ]]; then
    march="rv32i_zicsr"
    mabi="ilp32"
else
    march="rv64i_zicsr"
    mabi="lp64"
fi
dmem_word_bytes=$((xlen / 8))
dmem_depth=$((dmem_bytes / dmem_word_bytes))

mkdir -p "${output_dir}"
"${tool_prefix}gcc" \
    -march="${march}" -mabi="${mabi}" -mcmodel=medany -mno-relax \
    -std=gnu99 -O2 -g -ffreestanding -fno-builtin -fno-common \
    -fno-pie -fno-tree-loop-distribute-patterns -mstrict-align \
    -nostdlib -nostartfiles -static -no-pie \
    -I benchmark/bsp \
    -Wl,--no-relax -Wl,-T,benchmark/bsp/link.ld \
    -Wl,-Map,"${output_dir}/program.map" \
    "$@" -o "${output_dir}/program.elf"

if [[ -n "$("${tool_prefix}nm" -u "${output_dir}/program.elf")" ]]; then
    "${tool_prefix}nm" -u "${output_dir}/program.elf"
    echo "FAIL benchmark image has unresolved symbols"
    exit 1
fi

"${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
    --only-section=.text "${output_dir}/program.elf" "${output_dir}/imem.vhex"
"${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
    --only-section=.host --only-section=.data \
    "${output_dir}/program.elf" "${output_dir}/dmem.vhex"
python3 scripts/verilator/verilog_hex_to_mem.py \
    "${output_dir}/imem.vhex" "${output_dir}/imem.hex" \
    --word-bytes 4 --depth "${imem_depth}"
python3 scripts/verilator/verilog_hex_to_mem.py \
    "${output_dir}/dmem.vhex" "${output_dir}/dmem.hex" \
    --word-bytes "${dmem_word_bytes}" --depth "${dmem_depth}"
"${tool_prefix}objdump" -d "${output_dir}/program.elf" >"${output_dir}/program.dump"
"${tool_prefix}size" "${output_dir}/program.elf"
