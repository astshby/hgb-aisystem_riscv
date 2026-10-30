#!/usr/bin/env bash
# Module: yolo_vendored_softmath_build
# Description: Build pure RV64IM software math from the source-controlled GCC/Newlib subset.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT}/riscv64-unknown-elf-"
output="${1:-build/yolo/softmath-rv64im}"
vendor=software/yolo/vendor/softmath
gcc_vendor="$vendor/gcc"
math_vendor="$vendor/newlib/newlib/libm"
mkdir -p "$output"
python3 - "$vendor" <<'PY'
import hashlib,json,sys
from pathlib import Path
base=Path(sys.argv[1]); manifest=json.loads((base/'manifest.json').read_text())
for name,expected in manifest['files'].items():
    if hashlib.sha256((base/name).read_bytes()).hexdigest()!=expected:
        raise ValueError('softmath source SHA mismatch: '+name)
PY
flags=(-march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -mno-relax -mstrict-align
    -O2 -ffreestanding -fno-builtin -fno-common -fno-pie -fno-stack-protector
    -fno-fast-math -ffp-contract=off -ffunction-sections -fdata-sections)
objects=()
compile() {
    local source="$1" name="$2"; shift 2
    "${prefix}gcc" "${flags[@]}" "$@" -MMD -MF "$output/$name.d" -c "$source" -o "$output/$name.o"
    objects+=("$output/$name.o")
}
for name in addsf3 subsf3 mulsf3 divsf3 negsf2 eqsf2 gesf2 lesf2 unordsf2 \
    fixsfsi fixunssfsi floatsisf floatunsisf fixsfdi fixunssfdi floatdisf floatundisf \
    divdf3 gedf2 extendsfdf2 truncdfsf2; do
    compile "$gcc_vendor/soft-fp/$name.c" "$name" -I"$gcc_vendor/soft-fp" \
        -I"$gcc_vendor/libgcc/config/riscv" -I"$gcc_vendor/include"
done
compile software/yolo/soft_clz.c soft_clz
for name in ef_exp wf_exp ef_sqrt wf_sqrt sf_fabs sf_floor; do
    compile "$math_vendor/math/$name.c" "$name" -I"$math_vendor/common"
done
for name in sf_finite math_errf s_fmax sf_fmax sf_fmin s_fpclassify sf_fpclassify; do
    compile "$math_vendor/common/$name.c" "$name" -I"$math_vendor/common"
done
rm -f "$output/libyolo_softmath.a"
"${prefix}ar" rcsD "$output/libyolo_softmath.a" "${objects[@]}"
"${prefix}objdump" -dr -M no-aliases "$output/libyolo_softmath.a" > "$output/disassembly.txt"
"${prefix}readelf" -h -A "$output/libyolo_softmath.a" > "$output/elf-attributes.txt"
"${prefix}nm" -A "$output/libyolo_softmath.a" > "$output/symbols.txt"
python3 - "$output" "$vendor" "${prefix}gcc" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
output,vendor=map(Path,sys.argv[1:3]);count=0
for line in (output/'disassembly.txt').read_text().splitlines():
    m=re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s+(\S+)',line)
    if not m: continue
    if len(m[1])!=8 or int(m[1],16)&3!=3: raise ValueError('compressed instruction: '+line)
    if int(m[1],16)&127 in (7,39,67,71,75,79,83) or re.search(r'\b(frm|fflags|fcsr)\b',line):
        raise ValueError('floating instruction or CSR: '+line)
    count+=1
flags=re.findall(r'Flags:\s+(0x[0-9a-f]+)',(output/'elf-attributes.txt').read_text())
if not flags or any(int(x,16)&7 for x in flags):raise ValueError('unsupported library ABI')
report=dict(status='BUILD_AND_ISA_AUDIT_PASS',march='rv64im_zicsr',abi='lp64',
    source_manifest_sha256=hashlib.sha256((vendor/'manifest.json').read_bytes()).hexdigest(),
    archive_sha256=hashlib.sha256((output/'libyolo_softmath.a').read_bytes()).hexdigest(),
    compiler=subprocess.check_output([sys.argv[3],'--version'],text=True).splitlines()[0],
    instruction_count=count,compressed_instructions=0,floating_instructions=0)
(output/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS vendored RV64IM softmath:',count,'integer instructions')
PY
