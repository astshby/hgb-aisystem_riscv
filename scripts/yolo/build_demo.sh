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
# 自动卷积回归源码及默认 main 保持原样，只对本对象改名供 UART 命令调用。
"${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-gcc" \
    -march="$march" -mabi="$abi" -mcmodel=medany -mno-relax -std=gnu99 "-$opt" \
    -g -ffreestanding -fno-builtin -fno-common -fno-pie -mstrict-align \
    -fno-tree-loop-distribute-patterns -Wall -Wextra -Werror \
    -Dmain=yolo_operator_selftest -c software/yolo/main.c -o "$output/operator.o"
SOC=1 SOC_DDR=0 bash scripts/verilator/build_baremetal_image.sh "$xlen" "$output" \
    -Wall -Wextra -Werror -fno-fast-math -ffp-contract=off -fstack-usage \
    -DYOLO_DEMO_HDMI="$hdmi" \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    software/common/baremetal/crt0.S software/common/baremetal/runtime.c \
    software/common/baremetal/softarith.c "$output/operator.o" \
    software/yolo/demo_protocol.c software/yolo/conv_schedule.c software/yolo/demo_main.c \
    software/yolo/network.c software/yolo/network_service.c software/yolo/network_pool.c \
    software/yolo/video_service.c software/yolo/demo_libc.c \
    "${math_libraries[@]}"

# all 保留独立的仿真构建收据，不冒用 yolo 分支的生产 PDS 身份。
python3 - "$output" "$xlen" <<'PY'
import hashlib,json,os,re,subprocess,sys
from pathlib import Path
out=Path(sys.argv[1]);width=int(sys.argv[2]);sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
prefix=str(Path(os.environ['RISCV_TOOL_ROOT'])/'riscv64-unknown-elf-')
dump=subprocess.check_output([prefix+'objdump','-d','-M','no-aliases',str(out/'program.elf')],text=True)
count=0
for line in dump.splitlines():
    match=re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s+(\S+)',line)
    if not match:continue
    if len(match[1])!=8 or int(match[1],16)&3!=3:raise ValueError('compressed instruction: '+line)
    if int(match[1],16)&127 in (7,39,67,71,75,79,83) or re.search(r'\b(frm|fflags|fcsr)\b',line):
        raise ValueError('floating instruction or CSR: '+line)
    count+=1
sources=list(Path('software/yolo').glob('*.c'))+list(Path('software/yolo').glob('*.h'))
sources+=list(Path('software/common/baremetal').glob('*'))
sources+=[Path('software/common/soc_clocks.h'),Path('software/common/soc_capabilities.h'),Path('scripts/yolo/build_demo.sh')]
receipt=dict(role='yolo-interactive-simulation',xlen=width,
    source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    source_sha256={str(p):sha(p) for p in sources if p.is_file()},
    image_sha256={name:sha(out/name) for name in ('program.elf','imem.hex','dmem.hex')},
    integer_instructions=count,compressed_instructions=0,floating_instructions=0,
    scope='all simulation firmware; not a production PDS input')
(out/'manifest.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS all YOLO firmware RV'+str(width)+' ISA and image SHA')
PY
