#!/usr/bin/env bash
set -euo pipefail

xlen="$1"
output_dir="$2"
shift 2
opt="${SOFTWARE_OPT:-O2}"
case "$opt" in O2|O3|Ofast) ;; *) echo "SOFTWARE_OPT must be O2, O3 or Ofast" >&2; exit 2;; esac

tool_root="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}"
tool_prefix="${tool_root}/riscv64-unknown-elf-"
linker=benchmark/bsp/link.ld
imem_base=0
dmem_base=0
imem_word_bytes=4
imem_depth=32768
dmem_bytes=131072
ddr_base=0
ddr_bytes=0

if [[ "${xlen}" == "32" ]]; then
    march="rv32im_zicsr"
    mabi="ilp32"
else
    march="rv64im_zicsr"
    mabi="lp64"
fi
if [[ "${SOC_DDR:-0}" == "1" ]]; then
    linker=benchmark/bsp/link_soc_ddr.ld
    imem_base=0x01000000
    dmem_base=0x01100000
    imem_word_bytes=$((xlen / 8))
    imem_depth=$((65536 / imem_word_bytes))
    dmem_bytes=65536
    ddr_base=0x80000000
    ddr_bytes="${SOC_DDR_MODEL_BYTES:-65536}"
elif [[ "${SOC:-0}" == "1" ]]; then
    linker=benchmark/bsp/link_soc.ld
    imem_base=0x01000000
    dmem_base=0x01100000
    imem_word_bytes=$((xlen / 8))
    imem_depth=$((65536 / imem_word_bytes))
    dmem_bytes=65536
fi
dmem_word_bytes=$((xlen / 8))
dmem_depth=$((dmem_bytes / dmem_word_bytes))

mkdir -p "${output_dir}"
"${tool_prefix}gcc" \
    -march="${march}" -mabi="${mabi}" -mcmodel=medany -mno-relax \
    -std=gnu99 "-$opt" -DHGB_OPT_LEVEL=\"-$opt\" -g -ffreestanding -fno-builtin -fno-common \
    -fno-pie -fno-tree-loop-distribute-patterns -mstrict-align \
    -nostdlib -nostartfiles -static -no-pie \
    -I benchmark/bsp \
    -Wl,--build-id=none,--no-relax -Wl,-T,"${linker}" \
    -Wl,-Map,"${output_dir}/program.map" \
    "$@" -o "${output_dir}/program.elf"

if [[ -n "$("${tool_prefix}nm" -u "${output_dir}/program.elf")" ]]; then
    "${tool_prefix}nm" -u "${output_dir}/program.elf"
    echo "FAIL benchmark image has unresolved symbols"
    exit 1
fi

if (( ddr_bytes > 0 )); then
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.text.init "${output_dir}/program.elf" "${output_dir}/imem.vhex"
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.host --only-section=.data --only-section=.rodata \
        --only-section=.srodata --only-section=.sdata \
        "${output_dir}/program.elf" "${output_dir}/dmem.vhex"
else
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.text "${output_dir}/program.elf" "${output_dir}/imem.vhex"
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.host --only-section=.data \
        "${output_dir}/program.elf" "${output_dir}/dmem.vhex"
fi
python3 scripts/verilator/verilog_hex_to_mem.py \
    "${output_dir}/imem.vhex" "${output_dir}/imem.hex" \
    --word-bytes "${imem_word_bytes}" --depth "${imem_depth}" --base "${imem_base}"
python3 scripts/verilator/verilog_hex_to_mem.py \
    "${output_dir}/dmem.vhex" "${output_dir}/dmem.hex" \
    --word-bytes "${dmem_word_bytes}" --depth "${dmem_depth}" --base "${dmem_base}"
if (( ddr_bytes > 0 )); then
    "${tool_prefix}objcopy" -O verilog --verilog-data-width 1 \
        --only-section=.text "${output_dir}/program.elf" "${output_dir}/ddr.vhex"
    python3 scripts/verilator/verilog_hex_to_mem.py \
        "${output_dir}/ddr.vhex" "${output_dir}/ddr.hex" \
        --word-bytes "${dmem_word_bytes}" --depth "$((ddr_bytes / dmem_word_bytes))" --base "${ddr_base}"
fi
"${tool_prefix}objdump" -d "${output_dir}/program.elf" >"${output_dir}/program.dump"
"${tool_prefix}size" "${output_dir}/program.elf"
