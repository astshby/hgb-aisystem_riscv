#!/usr/bin/env bash
# Module: run_mm3
# Description: Reproducible C-reference, real RTL SoC and same-ELF accelerator comparisons.
set -euo pipefail
if [[ -n "${MM3_PROJECT_ROOT:-}" ]]; then cd "$MM3_PROJECT_ROOT"; else cd "$(dirname "$0")/../.."; fi
# Bash reads scripts incrementally. Freeze the runner before any long simulation starts.
if [[ "${MM3_RUNNER_FROZEN:-0}" != 1 ]]; then
 mkdir -p build/mm3/runners
 snapshot=$(mktemp "$PWD/build/mm3/runners/run-XXXXXXXX.sh")
 cp "$0" "$snapshot"
 export MM3_PROJECT_ROOT="$PWD" MM3_RUNNER_FROZEN=1 MM3_RUNNER_PATH="$snapshot"
 exec bash "$snapshot" "$@"
fi
# Keep compiler cache writes inside the project, including sandboxed rebuilds.
export CCACHE_DIR="${CCACHE_DIR:-$PWD/build/ccache}" CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-$PWD/build/ccache-tmp}"
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
action="${1:-unit}"; xlen="${2:-32}"
[[ "$xlen" =~ ^(32|64)$ ]] || { echo 'XLEN must be 32 or 64' >&2; exit 2; }
lanes="${MM3_MAC_LANES:-$(awk '$2=="MM3_GEMV_LANES"{print $3}' vsrc/soc/mm3/mm3_config.h)}"; cap="${MM3_SIM_SEQ_LEN:-64}"; new="${MM3_SIM_NEW_TOKENS:-2}"
max_cycles="${MM3_MAX_CYCLES:-1000000000000}"; jobs="${JOBS:-4}"
case_jobs="${MM3_CASE_JOBS:-1}"; sim_jobs="${MM3_SIM_PARALLEL:-2}"
[[ "$case_jobs" =~ ^[1-8]$ && "$sim_jobs" =~ ^[12]$ ]] || exit 2
for n in "$lanes" "$cap" "$new" "$max_cycles" "$jobs"; do [[ "$n" =~ ^[0-9]+$ ]] || exit 2; done
((lanes>=1 && lanes<=32 && 32%lanes==0 && cap>=2 && cap<=2048 && new<=64 && jobs>=1)) || exit 2
verilator="${VERILATOR:-verilator}"; command -v "$verilator" >/dev/null || { echo 'Set VERILATOR to a complete Verilator installation (including VERILATOR_ROOT/include).' >&2; exit 2; }
"$verilator" --version
hostcc="${HOST_CC:-gcc}"
# A dedicated build tree contains every relevant CPU and accelerator configuration.
if [[ "${MM3_CORE_PROFILE:-p1}" == p1 ]]; then source scripts/verilator/p1_core_config.sh;
elif [[ "${MM3_CORE_PROFILE}" != environment ]]; then echo "MM3_CORE_PROFILE must be p1 or environment" >&2; exit 2; fi
source scripts/verilator/core_build_config.sh
build="build/mm3/rv${xlen}-${core_build_tag}-l${lanes}-s${cap}-g${new}"
log="logs/mm3/rv${xlen}-${core_build_tag}-l${lanes}-s${cap}-g${new}"
mkdir -p "$build" "$log"
runtime=software/minimind3/c_runtime
sources=("$runtime/src/integer_math.c" "$runtime/src/integer_ops.c")
if [[ "$action" == unit ]]; then
 "$hostcc" -std=c11 -O2 -I"$runtime/include" tb/unit/mm3/fixed_reference.c "${sources[0]}" -o "$build/fixed-reference"
 "$build/fixed-reference" > "$build/fixed.txt"
 "$verilator" --binary --timing --assert -Wall -Wno-fatal -j "$jobs" --top-module tb_mm3_fixed --Mdir "$build/fixed" vsrc/soc/mm3/common/mm3_fixed_pkg.sv vsrc/soc/mm3/common/mm3_fixed_math.sv tb/unit/mm3/tb_mm3_fixed.sv > "$log/fixed-build.log" 2>&1
 "$build/fixed/Vtb_mm3_fixed" +FIXTURE="$build/fixed.txt" | tee "$log/fixed.log"
 "$hostcc" -std=c11 -O2 -I"$runtime/include" tb/unit/mm3/gemv_reference.c "${sources[@]}" -o "$build/gemv-reference"
 "$build/gemv-reference" "$build/gemv.bin"
 "$verilator" --binary --timing --assert -Wall -Wno-fatal -j "$jobs" -DCORE_XLEN="$xlen" --top-module tb_mm3_accel --Mdir "$build/accel" -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/unit/mm3/tb_mm3_accel.sv -GMAC_LANES="$lanes" > "$log/accel-build.log" 2>&1
 "$build/accel/Vtb_mm3_accel" +FIXTURE="$build/gemv.bin" | tee "$log/accel.log"
 "$hostcc" -std=c11 -O2 -I"$runtime/include" tb/unit/mm3/runtime_checks.c "${sources[@]}" "$runtime/src/integer_model.c" "$runtime/src/integer_io.c" "$runtime/src/platform_integer.c" -o "$build/runtime-checks"
 "$build/runtime-checks" "$runtime/assets/model_w8a16_int.bin" "$build/corrupt.bin" 2>&1 | tee "$log/runtime.log"
 exit
fi
[[ "$action" =~ ^(soc|benchmark|model|matrix|layer|full-case|prepare)$ ]] || exit 2
if [[ -n "${RISCV_TOOL_ROOT:-}" ]]; then tool="${RISCV_TOOL_ROOT}/riscv64-unknown-elf-"; else tool=riscv64-unknown-elf-; fi
command -v "${tool}gcc" >/dev/null
model="$runtime/assets/model_w8a16_int.bin"; tokenizer="$runtime/assets/tokenizer.bin"
[[ -f "$model" && -f "$tokenizer" ]] || { echo 'Restore the locked integer/tokenizer assets first.' >&2; exit 2; }
model_bytes=$(stat -c %s "$model"); tokenizer_bytes=$(stat -c %s "$tokenizer")
python3 scripts/verilator/mm3_fixture.py "$model" "$runtime/assets/integer_manifest.json" "$build/mm3_fixture.h"
# 完整裸机运行库使用本地 stdio/string 与 mm3.h；精简整数头不提供 tokenizer/FILE 定义。
"${tool}gcc" -march="rv${xlen}im_zicsr_zifencei" -mabi="$([[ $xlen == 32 ]] && echo ilp32 || echo lp64)" -mcmodel=medany -mno-relax \
 -std=c11 -O3 -g -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common -fno-pie -fno-tree-loop-distribute-patterns -mstrict-align -fno-fast-math -ffp-contract=off \
 -nostdlib -nostartfiles -static -no-pie -DMODEL_EMBED -DMM3_MODEL_BYTES="$model_bytes" -DMM3_TOKENIZER_BYTES="$tokenizer_bytes" -DMAX_SEQ_LEN="$cap" -DMM3_SIM_NEW_TOKENS="$new" \
 -I"$build" -Isoftware/minimind3/baremetal/include -I"$runtime/include" -Ibenchmark/bsp \
 -Wl,--build-id=none,--no-relax,-T,software/minimind3/baremetal/link.ld,-Map,"$build/program.map" \
 -Wl,--defsym,mm3_model_end=$((0x81000000+model_bytes)),--defsym,mm3_tokenizer_end=$((0x85000000+tokenizer_bytes)) \
 benchmark/bsp/crt0.S benchmark/bsp/runtime.c software/minimind3/baremetal/platform.c software/minimind3/baremetal/accel.c software/minimind3/baremetal/main.c \
 "${sources[@]}" "$runtime/src/integer_model.c" "$runtime/src/integer_io.c" "$runtime/src/tokenizer.c" -lgcc -o "$build/program.elf" > "$log/software-build.log" 2>&1
"${tool}size" "$build/program.elf"
"${tool}nm" -u "$build/program.elf" > "$log/unresolved.txt"; [[ ! -s "$log/unresolved.txt" ]]
"${tool}objdump" -d "$build/program.elf" > "$log/program.dump"
if grep -Eq '\b(f(add|sub|mul|div|sqrt|cvt|mv|sgnj|min|max|eq|lt|le|class)\.|fl[wd]\b|fs[wd]\b)|__(add|sub|mul|div|float|fix|extend|trunc).*(sf|df)' "$log/program.dump"; then echo 'FAIL floating-point ELF' >&2; exit 1; fi
"${tool}objcopy" -O verilog --verilog-data-width 1 --only-section=.text "$build/program.elf" "$build/imem.vhex"
python3 scripts/verilator/verilog_hex_to_mem.py "$build/imem.vhex" "$build/imem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01000000
"${tool}objcopy" -O binary --only-section=.data "$build/program.elf" "$build/data.bin"
tohost=$("${tool}nm" -n "$build/program.elf" | awk '$3=="tohost"{print $1}')
console=$("${tool}nm" -n "$build/program.elf" | awk '$3=="sim_console"{print $1}')
"$verilator" --binary --timing --assert -Wall -Wno-fatal -j "$jobs" -CFLAGS -O2 \
 -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-1}" "${core_microarch_flags[@]}" \
 --top-module tb_mm3_soc --Mdir "$build/soc" -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/common/store_result_monitor.sv tb/soc/tb_mm3_soc.sv \
 -GMM3_MAC_LANES="$lanes" -GDMA_WIDE_ENABLE=1 -GDMA_BLOCK_ENABLE=1 -GCACHE_BLOCK_ENABLE=1 > "$log/soc-build.log" 2>&1
# Compare fresh lint diagnostics with exactly the same harness and accelerator disabled.
for enabled in 0 1; do
 "$verilator" --lint-only --timing -Wall -Wno-fatal -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-1}" "${core_microarch_flags[@]}" \
  --top-module tb_mm3_soc -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/common/store_result_monitor.sv tb/soc/tb_mm3_soc.sv \
  -GMM3_ACCEL_ENABLE="$enabled" -GMM3_MAC_LANES="$lanes" -GDMA_WIDE_ENABLE=1 -GDMA_BLOCK_ENABLE=1 -GCACHE_BLOCK_ENABLE=1 > "$log/lint-enable${enabled}.log" 2>&1
done
python3 - "$log/lint-enable0.log" "$log/lint-enable1.log" <<'LINT'
import pathlib,re,sys
def warnings(path):
    lines=pathlib.Path(path).read_text().splitlines()
    # Verilator can choose another signal/column on the same source line as an SCC representative.
    # Preserve both complete logs; compare category, file and line, rather than that arbitrary representative.
    return {m.groups() for s in lines if (m:=re.match(r'%Warning-(LATCH|MULTIDRIVEN|UNOPTFLAT|ALWCOMBORDER): ([^:]+):(\d+):',s))}
old,new=map(warnings,sys.argv[1:])
extra=new-old
if extra: raise SystemExit('FAIL new structural warnings:\n'+'\n'.join(map(str,sorted(extra))))
print(f'PASS MM3_LINT no new structural warning locations; {len(old & new)} baseline locations recorded')
LINT
"$hostcc" -std=c11 -O3 -DMAX_SEQ_LEN="$cap" -DMM3_SIM_NEW_TOKENS="$new" -I"$runtime/include" \
 tb/unit/mm3/host_reference.c "${sources[@]}" "$runtime/src/integer_model.c" "$runtime/src/integer_io.c" "$runtime/src/tokenizer.c" "$runtime/src/platform_integer.c" -o "$build/host-reference"
# Freeze run artifacts and keep each invocation's outputs separate from the compile cache.
cache="$build"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
build="$cache/runs/$run_id"; log="$log/$run_id"
mkdir -p "$build" "$log"
cp "$cache/program.elf" "$cache/imem.hex" "$cache/data.bin" "$cache/mm3_fixture.h" "$build/"
cp scripts/verilator/mm3_report.py "$build/mm3_report.py"
cp "$cache/soc/Vtb_mm3_soc" "$build/simulator"
cp "$cache/host-reference" "$build/host-reference"
cp "${log%/*}"/{software-build.log,soc-build.log,lint-enable0.log,lint-enable1.log,program.dump} "$log/"
export MM3_RISCV_CC="${tool}gcc"
python3 - "$build" "$xlen" "$core_build_tag" "$lanes" "$cap" "$new" "$model" "$tokenizer" <<'META'
import hashlib,json,pathlib,subprocess,sys,zipfile,os
build=pathlib.Path(sys.argv[1])
paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard'],text=True).splitlines()
h=hashlib.sha256()
archive=zipfile.ZipFile(build/'sources.zip','w',zipfile.ZIP_DEFLATED)
for name in sorted(set(paths)):
 p=pathlib.Path(name)
 if p.is_file() and (p.suffix in {'.sv','.v','.c','.h','.ld','.f','.sh','.py','.json'} or p.name=='Makefile'):
  h.update(name.encode()+b'\0'+p.read_bytes());archive.write(p,name)
archive.close()
meta={'riscv_gcc':subprocess.check_output([os.environ['MM3_RISCV_CC'],'--version'],text=True).splitlines()[0],'verilator':subprocess.check_output([os.environ.get('VERILATOR','verilator'),'--version'],text=True).strip(),'commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'source_sha256':h.hexdigest(),
 'xlen':int(sys.argv[2]),'core_config':sys.argv[3],'mac_lanes':int(sys.argv[4]),'sequence_capacity':int(sys.argv[5]),'new_tokens':int(sys.argv[6]),
 'assets':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in sys.argv[7:]},'ddr_model':'axi_block_memory_model:128MiB:deterministic backpressure',
 'elf_sha256':hashlib.sha256((build/'program.elf').read_bytes()).hexdigest()}
(build/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
META
# Freeze assets as well: editing the user's export files cannot change an active run.
cp --reflink=auto "$model" "$build/model_w8a16_int.bin"
cp --reflink=auto "$tokenizer" "$build/tokenizer.bin"
model="$build/model_w8a16_int.bin";tokenizer="$build/tokenizer.bin"
ln -sfn "${log#logs/mm3/}" "logs/mm3/latest-${action}-rv${xlen}"
if [[ "$action" == prepare ]]; then echo "MM3_PREPARED $build $log"; exit 0; fi
run_pair(){
 local mode="$1" index="$2" trace="$3"
 local reference_trace="-"
 [[ "$trace" == 0 ]] || reference_trace="$build/m${mode}-c${index}-reference.trace"
 "$build/host-reference" "$model" "$tokenizer" "$mode" "$index" "$build/m${mode}-c${index}-reference.bin" "$reference_trace"
 local pids=() failed=0
 for backend in 0 1; do
  local name="m${mode}-c${index}-t${trace}-b${backend}"
  stdbuf -oL "$build/simulator" +IMEM="$build/imem.hex" +DATA="$build/data.bin" +MODEL="$model" +TOKENIZER="$tokenizer" \
   +TOHOST="$tohost" +CONSOLE="$console" +BACKEND="$backend" +MODE="$mode" +CASE="$index" +TRACE="$trace" \
   +MAX_CYCLES="$max_cycles" +RESULT="$build/$name.bin" > "$log/$name.log" 2>&1 &
  pids+=("$!")
  if [[ "$sim_jobs" == 1 ]]; then if ! wait "${pids[-1]}"; then failed=1; fi; fi
 done
 for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=1; fi; done
 if [[ "$failed" != 0 ]]; then echo "FAIL MM3 case mode=$mode index=$index trace=$trace; see $log" >&2; return 1; fi
 for backend in 0 1; do grep 'PASS MM3_SOC' "$log/m${mode}-c${index}-t${trace}-b${backend}.log"; done
 python3 "$build/mm3_report.py" "$build" "$log" "$mode" "$index" "$trace"
}
case "$action" in
 soc) run_pair 0 0 0; run_pair 4 0 0
 for fault in 1:3 2:3 3:4 5:4; do
  allocation="${fault%:*}"; expected="${fault#*:}"
  stdbuf -oL "$build/simulator" +IMEM="$build/imem.hex" +DATA="$build/data.bin" +TOHOST="$tohost" +CONSOLE="$console" \
   +BACKEND=1 +MODE=0 +ALLOC_FAIL="$allocation" +EXPECTED_EXIT="$expected" +MAX_CYCLES=2000000 +RESULT="$build/alloc.bin" > "$log/alloc${allocation}.log" 2>&1
  grep 'PASS MM3_EXPECTED_FAILURE' "$log/alloc${allocation}.log"
 done ;;
 matrix) run_pair 1 "${MM3_CASE:-0}" 0 ;;
 layer) run_pair 2 0 0 ;;
 full-case) run_pair 3 "${MM3_CASE:-0}" "${MM3_TRACE:-0}" ;;
 benchmark)
 pids=(); failed=0
 for i in {0..7}; do
  run_pair 1 "$i" 0 & pids+=("$!")
  if (( ${#pids[@]} >= case_jobs )); then
   for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=1; fi; done
   pids=()
  fi
 done
 for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=1; fi; done
 if ! run_pair 2 0 0; then failed=1; fi
 [[ "$failed" == 0 ]] ;;
 model) failed=0;for i in 0 1; do for trace in 0 1; do if ! run_pair 3 "$i" "$trace"; then failed=1; fi; done; done;[[ "$failed" == 0 ]] ;;
esac
