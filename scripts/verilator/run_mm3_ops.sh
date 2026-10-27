#!/usr/bin/env bash
# Module: run_mm3_ops
# Description: Static checks are separate from all numerical references and simulations.
set -euo pipefail
if [[ -n "${MM3_OPS_PROJECT_ROOT:-}" ]]; then cd "$MM3_OPS_PROJECT_ROOT"; else cd "$(dirname "$0")/../.."; fi
# Bash reads incrementally; preserve the exact runner throughout long simulations.
if [[ "${MM3_OPS_RUNNER_FROZEN:-0}" != 1 ]]; then
 mkdir -p build/mm3-ops/runners
 snapshot=$(mktemp "$PWD/build/mm3-ops/runners/run-XXXXXXXX.sh")
 cp "$0" "$snapshot"
 export MM3_OPS_PROJECT_ROOT="$PWD" MM3_OPS_RUNNER_FROZEN=1
 exec bash "$snapshot" "$@"
fi
action="${1:-static}";xlen="${2:-32}";op="${OP:-rmsnorm}";jobs="${JOBS:-4}";trace="${TRACE:-0}"
[[ "$trace" == 0 || "$trace" == 1 ]] || exit 2
trace_flags=();[[ "$trace" == 0 ]] || trace_flags=(--trace)
[[ "$xlen" =~ ^(32|64)$ && "$jobs" =~ ^[1-9][0-9]*$ ]] || exit 2
python3 scripts/verilator/mm3_config.py
read -r hash cap lanes timeout ddr < <(python3 - <<'CFG'
import json
m=json.load(open('build/mm3-ops/config/config.json'));c=m['config'];print(m['sha256'][:16],c['MM3_SEQ_CAP'],c['MM3_GEMV_LANES'],c['MM3_TIMEOUT_CYCLES'],c['MM3_DDR_BYTES'])
CFG
)
build="build/mm3-ops/$hash";logs="logs/mm3-ops/$hash";runtime=software/minimind3/c_runtime;ops=software/minimind3/operators
mkdir -p "$build" "$logs"
export CCACHE_DIR="${CCACHE_DIR:-$PWD/build/ccache}" CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-$PWD/build/ccache-tmp}"
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
cc="${HOST_CC:-gcc}";verilator="${VERILATOR:-verilator}"
if [[ -n "${RISCV_TOOL_ROOT:-}" ]];then tool="$RISCV_TOOL_ROOT/riscv64-unknown-elf-";else tool=riscv64-unknown-elf-;fi
csources=("$ops/mm3_ops.c" "$runtime/src/integer_math.c" "$runtime/src/integer_ops.c" "$runtime/src/integer_model.c" "$runtime/src/integer_io.c")
cflags=(-std=c11 -"${SOFTWARE_OPT:-O3}" -Wall -Wextra -Werror -Wno-misleading-indentation -I"$runtime/include" -I"$ops")
compile_host(){
 "$cc" "${cflags[@]}" "$ops/mm3_reference_main.c" "${csources[@]}" "$runtime/src/platform_integer.c" -o "$build/reference" > "$logs/host-build.log" 2>&1
 "$cc" "${cflags[@]}" -c "$ops/mm3_driver.c" -o "$build/host-driver.o" >> "$logs/host-build.log" 2>&1
}
compile_cpu(){
 local width="$1";local abi=ilp32;[[ "$width" == 32 ]] || abi=lp64
 "${tool}gcc" "${cflags[@]}" -march="rv${width}im_zicsr_zifencei" -mabi="$abi" -mcmodel=medany -mno-relax \
  -ffreestanding -fno-builtin -fno-common -fno-pie -ffunction-sections -fdata-sections -fno-tree-loop-distribute-patterns -mstrict-align -nostdlib -nostartfiles -static -no-pie \
  -Isoftware/minimind3/baremetal/include -Isoftware/common/baremetal -Wl,--gc-sections,--build-id=none,--no-relax,-T,software/minimind3/baremetal/link.ld,-Map,"$build/layer-rv$width.map" \
  software/common/baremetal/crt0.S software/common/baremetal/runtime.c software/minimind3/baremetal/platform.c "$ops/mm3_layer_main.c" "$ops/mm3_driver.c" "${csources[@]}" -lgcc -o "$build/layer-rv$width.elf" > "$logs/cpu-rv$width-build.log" 2>&1
 "${tool}objdump" -d "$build/layer-rv$width.elf" > "$logs/cpu-rv$width.dump"
 "${tool}nm" -u "$build/layer-rv$width.elf" > "$logs/cpu-rv$width-unresolved.txt";[[ ! -s "$logs/cpu-rv$width-unresolved.txt" ]]
 python3 scripts/verilator/mm3_audit.py no-float "$logs/cpu-rv$width.dump"
 "${tool}gcc" "${cflags[@]}" -march="rv${width}im_zicsr_zifencei" -mabi="$abi" -ffreestanding -Isoftware/minimind3/baremetal/include -c "$ops/mm3_ops.c" -o "$build/operators-rv$width.o" >> "$logs/cpu-rv$width-build.log" 2>&1
 "${tool}objdump" -d "$build/operators-rv$width.o" > "$logs/operators-rv$width.dump"
 "${tool}nm" -u "$build/operators-rv$width.o" > "$logs/operators-rv$width-unresolved.txt"
 python3 scripts/verilator/mm3_audit.py no-float "$logs/operators-rv$width.dump" "$logs/operators-rv$width-unresolved.txt"
 "${tool}size" "$build/layer-rv$width.elf"
}
load_profile(){ source scripts/verilator/p1_core_config.sh;source scripts/verilator/core_build_config.sh; }
need_verilator(){ command -v "$verilator" >/dev/null || { echo 'Set VERILATOR/VERILATOR_ROOT to a complete installation.' >&2;exit 2;}; }
static_check(){
 python3 - <<'FILES'
from pathlib import Path
ops=Path('scripts/mm3_files.f').read_text().splitlines()
soc=Path('scripts/soc_files.f').read_text().splitlines()
if [p for p in soc if p.startswith('vsrc/soc/mm3/')]!=ops:raise SystemExit('MM3 file list ordering mismatch')
FILES
 python3 scripts/verilator/mm3_config.py --check
 bash -n scripts/verilator/run_mm3_ops.sh scripts/verilator/run_mm3.sh
 python3 -m py_compile scripts/verilator/mm3_audit.py scripts/verilator/mm3_config.py scripts/verilator/mm3_integer_reference.py scripts/verilator/mm3_fixture_ops.py scripts/verilator/mm3_compare_ops.py
 compile_host;compile_cpu 32;compile_cpu 64;need_verilator;load_profile
 for width in 32 64;do
  "$verilator" --lint-only --timing --assert -Wall -Wno-fatal -DCORE_XLEN="$width" -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/unit/mm3/tb_mm3_accel.sv --top-module tb_mm3_accel > "$logs/lint-legacy-unit-rv$width.log" 2>&1
  "$verilator" --lint-only --timing --assert -Wall -Wno-fatal -DCORE_XLEN="$width" -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/unit/mm3/tb_mm3_program.sv --top-module tb_mm3_program > "$logs/lint-program-rv$width.log" 2>&1
  python3 scripts/verilator/mm3_audit.py structure "$logs/lint-program-rv$width.log"
  for enabled in 0 1;do
   "$verilator" --lint-only --timing --assert -Wall -Wno-fatal -DCORE_XLEN="$width" -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 "${core_microarch_flags[@]}" -f scripts/soc_files.f tb/common/store_result_monitor.sv tb/soc/axi_system_memory_model.sv tb/soc/spi_flash_model.sv tb/soc/tb_soc_system.sv tb/soc/tb_mm3_system.sv --top-module tb_mm3_system -GOP_PROGRAM=1 -GMM3_ACCEL_ENABLE="$enabled" > "$logs/lint-soc-rv$width-enable$enabled.log" 2>&1
  done
 done
 python3 - "$logs" "$build" "${tool}gcc" <<'CHECK'
import pathlib,re,json,sys,subprocess,hashlib,os,datetime
p,b=map(pathlib.Path,sys.argv[1:3]);summaries={}
def warnings(f):return set(re.findall(r'%Warning-(LATCH|MULTIDRIVEN|UNOPTFLAT|ALWCOMBORDER): ([^:]+):(\d+):',f.read_text()))
for w in (32,64):
 old=warnings(p/f'lint-soc-rv{w}-enable0.log');new=warnings(p/f'lint-soc-rv{w}-enable1.log')
 if new-old:raise SystemExit('FAIL new structural warning locations: '+str(new-old))
 summaries[str(w)]={'baseline_structural_warnings':len(old),'new_structural_warnings':0,'elf_sha256':hashlib.sha256((b/f'layer-rv{w}.elf').read_bytes()).hexdigest()}
report={'scope':'STATIC ONLY: no simulator, numerical reference, synthesis or board run executed','status':'pass','commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'config':json.load(open('build/mm3-ops/config/config.json')),'widths':summaries}
report['tools']={name:subprocess.check_output([exe,*args],text=True).splitlines()[0] for name,exe,args in [('host_cc',os.environ.get('HOST_CC','gcc'),['--version']),('riscv_cc',sys.argv[3],['--version']),('python','python3',['--version']),('verilator',os.environ.get('VERILATOR','verilator'),['--version'])]}
report['dirty']=bool(subprocess.check_output(['git','status','--porcelain'],text=True))
report['checked_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard'],text=True).splitlines()
report['source_sha256']={f:hashlib.sha256(pathlib.Path(f).read_bytes()).hexdigest() for f in sorted(set(paths)) if pathlib.Path(f).is_file() and (f.startswith(('vsrc/soc/mm3/','software/minimind3/operators/','scripts/verilator/mm3_','scripts/verilator/run_mm3','tb/unit/mm3/','tb/soc/tb_mm3')) or f in ('Makefile','scripts/soc_files.f','scripts/mm3_files.f','vsrc/soc/soc_top.sv'))}
(p/'static-report.json').write_text(json.dumps(report,indent=2)+'\n');print('STATIC_CHECK_PASS; functional simulation remains unexecuted')
CHECK
}
reference(){
 local kind="$1";fixture="$build/fixtures/$kind";mkdir -p "$fixture"
 python3 scripts/verilator/mm3_fixture_ops.py --case "$kind" --out "$fixture" "${trace_flags[@]}"
 local c_trace_args=()
 if [[ "$trace" == 1 ]];then mkdir -p "$fixture/c-trace";c_trace_args=("$fixture/c-trace");fi
 "$build/reference" "$fixture/image.bin" "$fixture/commands.bin" "$fixture/ranges.bin" "$fixture/c-result.bin" "${c_trace_args[@]}" > "$fixture/c-reference.log"
 python3 scripts/verilator/mm3_compare_ops.py "$fixture" "$fixture/c-result.bin" --label C
}
run_case(){
 local kind="$1" route="$2";reference "$kind";need_verilator
 local run="$build/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$-$kind-$route";mkdir -p "$run"
 cp "$fixture"/{image.bin,commands.bin,ranges.bin,control.bin,expected.bin,fixture.json,c-reference.log,c-result.report.json} "$run/"
 local trace_args=()
 if [[ "$trace" == 1 ]];then
  mkdir -p "$run/trace";cp "$fixture"/expected-op-*.bin "$run/";cp -r "$fixture/c-trace" "$run/c-trace"
  trace_args=(+TRACE_PREFIX="$run/trace")
 fi
 "$verilator" --version > "$run/tool-versions.txt"
 "$cc" --version >> "$run/tool-versions.txt"
 python3 --version >> "$run/tool-versions.txt"
 git rev-parse HEAD > "$run/source-commit.txt";cp build/mm3-ops/config/config.json "$run/config.json"
 git diff --binary > "$run/source-tracked.patch"
 python3 - "$run" "$action" "$xlen" "$op" "$trace" "$jobs" <<'REPRO'
import hashlib,json,pathlib,subprocess,sys
r=pathlib.Path(sys.argv[1]);files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard'],text=True).splitlines()
files=sorted(set(p for p in files if p.startswith(('vsrc/soc/mm3/','software/minimind3/operators/','scripts/verilator/mm3_','scripts/verilator/run_mm3','tb/unit/mm3/','tb/soc/tb_mm3')) or p in ('Makefile','scripts/soc_files.f','scripts/mm3_files.f','vsrc/soc/soc_top.sv')))
meta={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in files if pathlib.Path(p).is_file()}
(r/'source-sha256.json').write_text(json.dumps(meta,indent=2)+'\n')
(r/'invocation.txt').write_text(f'OP={sys.argv[4]} TRACE={sys.argv[5]} JOBS={sys.argv[6]} bash scripts/verilator/run_mm3_ops.sh {sys.argv[2]} {sys.argv[3]}\n')
REPRO
 if [[ "$route" == independent ]];then
  "$verilator" --binary --timing --assert -Wall -Wno-fatal -j "$jobs" -CFLAGS -O2 -DCORE_XLEN="$xlen" -f scripts/soc_files.f tb/soc/axi_block_memory_model.sv tb/unit/mm3/tb_mm3_program.sv --top-module tb_mm3_program --Mdir "$build/sim-rv$xlen" > "$logs/sim-rv$xlen-build.log" 2>&1
  "$build/sim-rv$xlen/Vtb_mm3_program" +IMAGE="$run/image.bin" +COMMANDS="$run/commands.bin" +RANGES="$run/ranges.bin" +CONTROL="$run/control.bin" +RESULT="$run/actual.bin" "${trace_args[@]}" > "$run/simulation.log" 2>&1
 else
  compile_cpu "$xlen";load_profile
  "${tool}gcc" --version >> "$run/tool-versions.txt"
  "${tool}objcopy" -O verilog --verilog-data-width 1 --only-section=.text "$build/layer-rv$xlen.elf" "$run/imem.vhex"
  python3 scripts/verilator/verilog_hex_to_mem.py "$run/imem.vhex" "$run/imem.hex" --word-bytes "$((xlen/8))" --depth "$((65536/(xlen/8)))" --base 0x01000000
  "${tool}objcopy" -O binary --only-section=.data "$build/layer-rv$xlen.elf" "$run/data.bin"
  tohost=$("${tool}nm" -n "$build/layer-rv$xlen.elf" | awk '$3=="tohost"{print $1}');console=$("${tool}nm" -n "$build/layer-rv$xlen.elf" | awk '$3=="sim_console"{print $1}')
  "$verilator" --binary --timing --assert -Wall -Wno-fatal -j "$jobs" -CFLAGS -O2 -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL=0 -DCORE_DIV_IMPL=1 "${core_microarch_flags[@]}" -f scripts/soc_files.f tb/common/store_result_monitor.sv tb/soc/axi_system_memory_model.sv tb/soc/spi_flash_model.sv tb/soc/tb_soc_system.sv tb/soc/tb_mm3_system.sv --top-module tb_mm3_system -GOP_PROGRAM=1 --Mdir "$build/soc-rv$xlen" > "$logs/soc-rv$xlen-build.log" 2>&1
  printf "@0\n0\n" > "$run/dmem.hex"
  stdbuf -oL "$build/soc-rv$xlen/Vtb_mm3_system" +DMEM="$run/dmem.hex" +IMEM="$run/imem.hex" +DATA="$run/data.bin" +TOHOST="$tohost" +CONSOLE="$console" +IMAGE="$run/image.bin" +COMMANDS="$run/commands.bin" +RANGES="$run/ranges.bin" +CONTROL="$run/control.bin" +MAX_CYCLES="$timeout" +RESULT="$run/actual.bin" "${trace_args[@]}" > "$run/simulation.log" 2>&1
 fi
 if [[ "$route" == soc ]];then cp "$build/layer-rv$xlen.elf" "$run/";fi
 python3 scripts/verilator/mm3_compare_ops.py "$run" "$run/actual.bin" --label "$route-rv$xlen"
 grep '^PASS' "$run/simulation.log";ln -sfn "$PWD/$run" "logs/mm3-ops/latest-$kind-$route-rv$xlen"
}
case "$action" in
 config) : ;;
 static)static_check;;
 ref)compile_host;reference layer;;
 op)compile_host;if [[ "$op" == all ]];then for kind in add mul rmsnorm rope softmax swiglu gemm kv;do run_case "$kind" independent;done;else [[ "$op" =~ ^(add|ew_add|mul|ew_mul|rmsnorm|norm|rope|softmax|swiglu|gemm|kv|kv_cache)$ ]] || exit 2;run_case "$op" independent;fi;;
 attn)compile_host;run_case attention independent;;
 layer)compile_host;run_case layer independent;;
 soc)compile_host;run_case layer soc;;
 *)echo "unknown action $action" >&2;exit 2;;
esac
