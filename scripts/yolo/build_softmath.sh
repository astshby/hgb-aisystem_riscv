#!/usr/bin/env bash
# Module: yolo_softmath_build
# Description: Rebuild the small GCC/newlib software-float dependency set as pure RV64IM; no installed library is linked.
set -euo pipefail
source_root="${RISCV_GNU_SOURCE_ROOT:?set RISCV_GNU_SOURCE_ROOT to the existing riscv-gnu-toolchain source tree}"
gcc_build="${RISCV_GCC_BUILD_ROOT:-$source_root/build-gcc-newlib-stage2}"
prefix="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}/riscv64-unknown-elf-"
output="${1:-build/yolo/softmath-rv64im}"
mkdir -p "$output"
source_root="$(realpath "$source_root")"
gcc_build="$(realpath "$gcc_build")"
output="$(realpath "$output")"
base_flags=(-march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -mno-relax -mstrict-align
    -O2 -ffreestanding -fno-builtin -fno-common -fno-pie -fno-stack-protector
    -fno-fast-math -ffp-contract=off -ffunction-sections -fdata-sections)
soft_include=(-I"$source_root/gcc/libgcc/soft-fp" -I"$source_root/gcc/libgcc/config/riscv"
    -I"$source_root/gcc/include")
libgcc_include=(-I"$gcc_build/gcc" -I"$gcc_build/riscv64-unknown-elf/libgcc"
    -I"$source_root/gcc/gcc" -I"$source_root/gcc/libgcc" -I"$source_root/gcc/include")
math_include=(-I"$source_root/newlib/newlib/libm/common")
[[ -f "$gcc_build/gcc/tconfig.h" && -f "$gcc_build/riscv64-unknown-elf/libgcc/libgcc_tm.h" ]]
[[ "$("${prefix}gcc" -dumpfullversion)" == "$(cat "$source_root/gcc/gcc/BASE-VER")" ]] || {
    echo 'installed compiler and GCC source versions differ' >&2; exit 2;
}
"${prefix}gcc" -print-multi-lib > "$output/installed-multilib.txt"
"${prefix}nm" -A "$("${prefix}gcc" -march=rv64imac -mabi=lp64 -print-libgcc-file-name)" > "$output/installed-soft-symbols.txt"
: > "$output/commands.jsonl"
objects=()
compile() {
    local source="$1" name="$2"; shift 2
    local command=("${prefix}gcc" "${base_flags[@]}" "$@" -MD -MF "$output/$name.d" -c "$source" -o "$output/$name.o")
    python3 - "$output/commands.jsonl" "${command[@]}" <<'PY'
import json,sys
with open(sys.argv[1],'a') as stream: stream.write(json.dumps(sys.argv[2:])+'\n')
PY
    "${command[@]}"
    objects+=("$output/$name.o")
}
for name in addsf3 subsf3 mulsf3 divsf3 negsf2 eqsf2 gesf2 lesf2 unordsf2 \
    fixsfsi fixunssfsi floatsisf floatunsisf fixsfdi fixunssfdi floatdisf floatundisf \
    divdf3 gedf2 extendsfdf2 truncdfsf2; do
    compile "$source_root/gcc/libgcc/soft-fp/$name.c" "$name" "${soft_include[@]}"
done
# RV64的L_clzsi2模板产生__clzdi2；表来自同一GCC libgcc2原实现。
compile "$source_root/gcc/libgcc/libgcc2.c" clzsi2 "${libgcc_include[@]}" -Dinhibit_libc -DIN_GCC -DIN_LIBGCC2 -DL_clzsi2
compile "$source_root/gcc/libgcc/libgcc2.c" clz_table "${libgcc_include[@]}" -Dinhibit_libc -DIN_GCC -DIN_LIBGCC2 -DL_clz
for name in ef_exp wf_exp ef_sqrt wf_sqrt sf_fabs sf_floor; do
    compile "$source_root/newlib/newlib/libm/math/$name.c" "$name" "${math_include[@]}"
done
for name in sf_finite math_errf s_fmax sf_fmax sf_fmin s_fpclassify sf_fpclassify; do
    compile "$source_root/newlib/newlib/libm/common/$name.c" "$name" "${math_include[@]}"
done
rm -f "$output/libyolo_softmath.a"
"${prefix}ar" rcsD "$output/libyolo_softmath.a" "${objects[@]}"
"${prefix}objdump" -dr -M no-aliases "$output/libyolo_softmath.a" > "$output/disassembly.txt"
"${prefix}readelf" -h -A "$output/libyolo_softmath.a" > "$output/elf-attributes.txt"
"${prefix}nm" -A "$output/libyolo_softmath.a" > "$output/symbols.txt"
python3 - "$output" "$source_root" "$gcc_build" "${prefix}gcc" "$0" <<'PY'
import hashlib,json,re,subprocess,sys
from pathlib import Path
output,source_root,gcc_build=map(Path,sys.argv[1:4]);compiler=sys.argv[4]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
instructions=0
for line in (output/'disassembly.txt').read_text().splitlines():
    match=re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s+(\S+)',line)
    if not match:continue
    value=match.group(1)
    if len(value)!=8 or int(value,16)&3!=3:raise ValueError('non-32-bit instruction: '+line)
    if int(value,16)&127 in (7,39,67,71,75,79,83):raise ValueError('floating-point instruction: '+line)
    if re.search(r'\b(frm|fflags|fcsr)\b',line):raise ValueError('floating-point CSR instruction: '+line)
    instructions+=1
flags=re.findall(r'Flags:\s+(0x[0-9a-f]+)',(output/'elf-attributes.txt').read_text())
if not flags or any(int(flag,16)&7 for flag in flags):raise ValueError('RVC or floating-point ABI flag present')
commands=[json.loads(line) for line in (output/'commands.jsonl').read_text().splitlines()]
defined,undefined=set(),set()
for line in (output/'symbols.txt').read_text().splitlines():
    fields=line.split()
    if len(fields)<2:continue
    if fields[-2]=='U':undefined.add(fields[-1])
    elif fields[-2] in ('T','D','B','R','W','V'):defined.add(fields[-1])
required=sorted(undefined-defined)
if required!=['__errno']:raise ValueError('unexpected application dependency: '+repr(required))
dependencies=set()
for file in output.glob('*.d'):
    dependencies.update(Path(x) for x in file.read_text().replace('\\\n',' ').split(':',1)[1].split())
receipt=dict(status='BUILD_AND_ISA_AUDIT_PASS',march='rv64im_zicsr',abi='lp64',optimization='O2',
    source_root=str(source_root),gcc_build_root=str(gcc_build),compiler=subprocess.check_output([compiler,'--version'],text=True).splitlines()[0],
    gcc_source_version=(source_root/'gcc/gcc/BASE-VER').read_text().strip(),
    source_revisions={name:subprocess.check_output(['git','-C',str(source_root/name),'rev-parse','HEAD'],text=True).strip() for name in ('gcc','newlib')},
    commands=commands,source_sha256={str(p):sha(p) for p in sorted(dependencies)},
    archive_sha256=sha(output/'libyolo_softmath.a'),object_count=len(commands),instruction_count=instructions,
    compressed_instructions=0,floating_instructions=0,elf_flags=flags,
    build_script_sha256=sha(Path(sys.argv[5])),required_application_symbols=required,
    not_run=['numeric execution','RV64 RTL simulation'])
(output/'manifest.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PASS pure RV64IM software math:',len(commands),'objects,',instructions,'32-bit integer instructions')
PY
