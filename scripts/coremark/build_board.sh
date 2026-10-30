#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'XLEN must be 32 or 64' >&2; exit 2;; esac
prefix="${CROSS_COMPILE:-${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}/riscv64-unknown-elf-}"
opt="${SOFTWARE_OPT:-O3}"
[[ "$opt" =~ ^(O2|O3|Ofast)$ ]] || { echo 'unsupported SOFTWARE_OPT' >&2; exit 2; }
baud="${COREMARK_BOARD_BAUD:-115200}"
iterations="${COREMARK_BOARD_TEST_ITERATIONS:-0}"
[[ "$baud" =~ ^[0-9]+$ && "$iterations" =~ ^[0-9]+$ ]] || exit 2
(( baud > 0 && baud <= 15000000 && iterations <= 2147483647 )) || exit 2
out="${COREMARK_BOARD_OUT:-build/coremark-board/rv${xlen}-${opt}-i${iterations}-b${baud}}"
mkdir -p "$out/obj"

sources=(
    software/coremark-board/startup.S
    software/coremark-board/main.c
    software/coremark-board/platform.c
    software/coremark-board/port.c
    software/common/baremetal/runtime.c
    software/common/baremetal/softarith.c
    benchmark/coremark/port/ee_printf.c
    benchmark/coremark/vendor/coremark/core_main.c
    benchmark/coremark/vendor/coremark/core_list_join.c
    benchmark/coremark/vendor/coremark/core_matrix.c
    benchmark/coremark/vendor/coremark/core_state.c
    benchmark/coremark/vendor/coremark/core_util.c
)
inputs=("${sources[@]}" software/coremark-board/board.h software/common/soc_clocks.h
    software/common/soc_capabilities.h software/common/baremetal/benchmark_runtime.h
    software/common/baremetal/link_soc.ld benchmark/coremark/port/core_portme.h
    benchmark/coremark/vendor/coremark/coremark.h scripts/coremark/build_board.sh)
python3 - "$out" "$xlen" "$opt" "$baud" "$iterations" "${prefix}gcc" "${inputs[@]}" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);width,opt,baud,iterations=sys.argv[2:6]
config=dict(xlen=int(width),optimization=opt,baud=int(baud),test_iterations=int(iterations),
            memory='tcm',formal_minimum_seconds=10,target_seconds=12,
            compiler=subprocess.check_output([sys.argv[6],'--version'],text=True).splitlines()[0])
sources={name:hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in sys.argv[7:]}
identity=hashlib.sha256(json.dumps(dict(config=config,sources=sources),sort_keys=True).encode()).hexdigest()
receipt=dict(config=config,source_sha256=sources,firmware_id=identity[:16],
             source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
             source_status=subprocess.check_output(['git','status','--short'],text=True))
(out/'build-id.h').write_text('#define HGB_BOARD_BUILD_ID "'+identity[:16]+'"\n')
(out/'manifest.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY

flags=(-march="rv${xlen}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax
    -std=gnu99 "-$opt" -g -ffreestanding -fno-builtin -fno-common -fno-pie
    -fno-stack-protector -fno-tree-loop-distribute-patterns -mstrict-align
    -ffunction-sections -fdata-sections -DHGB_OPT_LEVEL=\"-$opt\"
    -DHGB_BOARD_BAUD="$baud" -DHGB_BOARD_SIM_ITERATIONS="$iterations"
    -DPERFORMANCE_RUN=1 -DTOTAL_DATA_SIZE=2000 '-DMEM_LOCATION="ITCM code; DTCM data/stack"'
    -include "$out/build-id.h" -Isoftware/coremark-board -Isoftware/common
    -Isoftware/common/baremetal -Ibenchmark/coremark/port -Ibenchmark/coremark/vendor/coremark)
objects=()
for source in "${sources[@]}"; do
    object="$out/obj/${source//\//_}.o"
    extra=()
    case "$source" in
        */vendor/coremark/core_main.c) extra=(-Dmain=coremark_run);;
        software/common/baremetal/runtime.c)
            # 保留稳定的周期读取与内存函数，仅此对象重命名不用的仿真输出。
            extra=(-Dbenchmark_putchar=hgb_unused_sim_putchar);;
        software/coremark-board/*.c) extra=(-Wall -Wextra -Werror);;
    esac
    "${prefix}gcc" "${flags[@]}" "${extra[@]}" -c "$source" -o "$object"
    objects+=("$object")
done
"${prefix}gcc" "${flags[@]}" -nostdlib -nostartfiles -static -no-pie \
    -Wl,--build-id=none,--no-relax,--gc-sections,-T,software/common/baremetal/link_soc.ld \
    -Wl,-Map,"$out/program.map" "${objects[@]}" -o "$out/program.elf"
[[ -z "$("${prefix}nm" -u "$out/program.elf")" ]] || { echo 'unresolved symbols' >&2; exit 1; }
"${prefix}nm" -n "$out/program.elf" > "$out/program.nm"
"${prefix}objdump" -d "$out/program.elf" > "$out/program.dump"
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.text "$out/program.elf" "$out/imem.vhex"
"${prefix}objcopy" -O verilog --verilog-data-width 1 --only-section=.host --only-section=.data "$out/program.elf" "$out/dmem.vhex"
for name in imem dmem; do
    base=0x01000000
    [[ "$name" == imem ]] || base=0x01100000
    python3 scripts/verilator/verilog_hex_to_mem.py "$out/$name.vhex" "$out/$name.hex" \
        --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base "$base"
done
python3 - "$out" <<'PY'
import hashlib,json,sys
from pathlib import Path
out=Path(sys.argv[1]);path=out/'manifest.json';receipt=json.loads(path.read_text())
receipt['image_sha256']={name:hashlib.sha256((out/name).read_bytes()).hexdigest()
                         for name in ('program.elf','imem.hex','dmem.hex')}
receipt['entry']='TCM initialized firmware; not an HGB1 loader payload'
path.write_text(json.dumps(receipt,indent=2)+'\n')
PY
"${prefix}size" "$out/program.elf"
echo "PASS board CoreMark build RV$xlen test_iterations=$iterations baud=$baud: $out"
