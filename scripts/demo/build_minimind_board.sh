#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;;64) abi=lp64;;*) exit 2;;esac
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-}"
out="${MM3_DEMO_OUT:?set MM3_DEMO_OUT to a generated output directory}/rv$xlen"
mkdir -p "$out/obj"
flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=c11 -O3 -g -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-tree-loop-distribute-patterns -mstrict-align -fno-fast-math -ffp-contract=off
    -ffunction-sections -fdata-sections -DMAX_SEQ_LEN=64
    -DMM3_MMIO_BASE="${MM3_MMIO_BASE:-0x20010000u}"
    -Isoftware/minimind3/baremetal/include -Isoftware/minimind3/c_runtime/include
    -Isoftware/minimind3/demo -Isoftware/common -Isoftware/common/baremetal)
sources=(software/common/baremetal/{crt0.S,runtime.c}
    software/minimind3/demo/{session,protocol,board}.c software/minimind3/baremetal/accel.c
    software/minimind3/c_runtime/src/{integer_io,tokenizer,integer_math,integer_ops,integer_model}.c)
objects=()
for source in "${sources[@]}";do
    object="$out/obj/${source//\//_}.o";extra=()
    [[ "$source" != software/common/baremetal/runtime.c ]] || extra=(-Dbenchmark_putchar=mm3_unused_sim_putchar)
    "${prefix}gcc" "${flags[@]}" "${extra[@]}" -c "$source" -o "$object"
    objects+=("$object")
done
"${prefix}gcc" "${flags[@]}" -nostdlib -nostartfiles -static -no-pie \
    -Wl,--gc-sections,--build-id=none,--no-relax,-T,software/minimind3/baremetal/link.ld,-Map,"$out/program.map" \
    "${objects[@]}" -lgcc -o "$out/program.elf"
"${prefix}nm" -u "$out/program.elf" > "$out/unresolved.txt"
[[ ! -s "$out/unresolved.txt" ]]
"${prefix}size" "$out/program.elf"
"${prefix}objdump" -d "$out/program.elf" > "$out/program.dump"
"${prefix}objcopy" -O binary --only-section=.text "$out/program.elf" "$out/itcm.bin"
"${prefix}objcopy" -O binary --only-section=.data "$out/program.elf" "$out/ddr-data.bin"
python3 - "$out" "${sources[@]}" software/minimind3/demo/demo.h \
    software/minimind3/c_runtime/include/{integer,mm3}.h software/minimind3/baremetal/platform.c \
    software/minimind3/baremetal/include/{stdio,stdlib,string}.h software/minimind3/baremetal/link.ld \
    software/common/{soc_clocks,soc_capabilities}.h software/common/baremetal/benchmark_runtime.h \
    tb/cache/cache_maintenance.h scripts/demo/build_minimind_board.sh <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
receipt=dict(commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),source_sha256={p:sha(p) for p in sys.argv[2:]},elf_sha256=sha(out/'program.elf'),context=64,layers=8,backend='existing MMIO accelerator',uart_baud=115200,model_address='0x81000000',tokenizer_address='0x85000000',asset_header_address='0x80400000',rtl_simulation='NOT_RUN',board='NOT_RUN',tf_driver='NOT_IMPLEMENTED')
receipt['preload']=[dict(file=name,address=address,bytes=(out/name).stat().st_size,sha256=sha(out/name)) for name,address in [('itcm.bin','0x01000000'),('ddr-data.bin','0x80000000')]]
receipt['entry']='Initialized ITCM and DDR preloads required; not a production Flash/TF boot payload'
(out/'board-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
printf 'PASS MiniMind UART board compile RV%s; no RTL run or board load\n' "$xlen"
