#!/usr/bin/env python3
"""Runnable Core/SoC/NPU hardware configurations, frozen firmware and explicit clock ratios."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_config import CONFIG, DOMAINS, ROOT, configuration, core_record, score, sha
import run_p2_coremark as p2

TCM_SOURCES = [str(p) for p in p2.SOFTWARE_SOURCES if str(p) not in
               ('benchmark/p2/timing.S', 'benchmark/p2/core_portme.c')]
TCM_SOURCES.insert(3, 'benchmark/coremark/port/core_portme.c')


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n')


def run(command, log, cwd=ROOT, env=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as out:
        out.write(shlex.join(map(str, command)) + '\n')
        out.flush()
        subprocess.run(command, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT, check=True)


def freeze(bundle, iterations, modes):
    if bundle.exists():
        manifest = json.loads((bundle / 'manifest.json').read_text())
        if manifest['iterations'] != iterations or manifest.get('optimization', 'O2') != p2.optimization() or not set(modes).issubset(manifest['modes']):
            raise ValueError('existing firmware selection differs; choose a new bundle')
        p2.verify_hashes(bundle / 'source', manifest['source_sha256'])
        for im in manifest['images']:
            p2.verify_hashes(bundle, im['image_sha256'])
        return manifest
    bundle.mkdir(parents=True)
    inputs = set(p2.SOFTWARE_INPUTS) | {Path(p) for p in TCM_SOURCES} | {
        Path('software/common/baremetal/link_soc.ld'), Path('benchmark/p2/link_soc_coremark_tcm.ld'),
        Path('scripts/verilator/build_baremetal_image.sh')}
    hashes = p2.copy_sources(sorted(inputs), bundle / 'source')
    tools = str(Path(os.environ['RISCV_TOOL_ROOT']) / 'riscv64-unknown-elf-')
    images = []
    for mode in modes:
        for scenario in ('tcm', 'tcm_background'):
            out = bundle / f'{scenario}-{mode}'
            out.mkdir()
            source = bundle / 'source'
            flags = ['-Ibenchmark/coremark/port', '-Ibenchmark/coremark/vendor/coremark',
                     f'-DITERATIONS={iterations}', '-DTOTAL_DATA_SIZE=2000', f'-D{mode.upper()}_RUN=1']
            if scenario == 'tcm':
                command = ['bash', 'scripts/verilator/build_baremetal_image.sh', '32', str(out),
                           *flags, '-DMEM_LOCATION="ITCM code and DTCM static data/stack"', *TCM_SOURCES]
                run(command, out / 'build.log', source, dict(os.environ, SOC='1', SOC_DDR='0'))
            else:
                command = [tools+'gcc', '-march=rv32im_zicsr', '-mabi=ilp32', '-mcmodel=medany',
                    '-mno-relax', '-std=gnu99', '-'+p2.optimization(), '-DHGB_OPT_LEVEL="-'+p2.optimization()+'"', '-g', '-ffreestanding', '-fno-builtin', '-fno-common',
                    '-fno-pie', '-fno-tree-loop-distribute-patterns', '-mstrict-align', '-nostdlib', '-nostartfiles',
                    '-static', '-no-pie', '-Ibenchmark/p2', '-Isoftware/common/baremetal', *flags,
                    '-DP2_TCM=1', '-DP2_WARM=0', '-DP2_BACKGROUND=1', '-DP2_TIMER_MODE=0',
                    '-DP2_INTERVAL_PS=100000000', '-DDMA_SOURCE=0x01108000u', '-DDMA_DESTINATION=0x01008000u',
                    '-Wl,--build-id=none,--no-relax', '-Wl,-T,benchmark/p2/link_soc_coremark_tcm.ld',
                    '-Wl,-Map,'+str(out/'program.map'), *map(str,p2.SOFTWARE_SOURCES), '-o', str(out/'program.elf')]
                run(command, out/'build.log', source)
                for name, base, sections in (
                    ('imem',0x01000000,['.text']),
                    ('dmem',0x01100000,['.host','.p2_roi','.p2_platform','.p2_control','.data'])):
                    subprocess.run([tools+'objcopy','-O','verilog','--verilog-data-width','1',
                        *['--only-section='+s for s in sections],str(out/'program.elf'),str(out/(name+'.vhex'))],check=True)
                    subprocess.run([sys.executable,str(source/'scripts/verilator/verilog_hex_to_mem.py'),
                        str(out/(name+'.vhex')),str(out/(name+'.hex')),'--word-bytes','4','--depth','16384','--base',hex(base)],check=True)
            elf = out/'program.elf'
            nm = subprocess.check_output([tools+'nm','-n',str(elf)],text=True)
            symbols = p2.symbols_from_nm(nm)
            (out/'program.nm').write_text(nm)
            if subprocess.check_output([tools+'nm','-u',str(elf)],text=True).strip():
                raise ValueError('unresolved firmware symbols')
            if not (0x01000000 <= symbols['_start'] < 0x01010000 and
                    0x01100000 <= symbols['__bss_end'] < symbols['__stack_limit'] <= symbols['__stack_top'] <= 0x01110000):
                raise ValueError('TCM image allocation/stack invalid')
            images.append(dict(scenario=scenario,mode=mode,iterations=iterations,directory=out.name,
                symbols=symbols,compile_command=shlex.join(command),
                image_sha256={str(p.relative_to(bundle)):sha(p) for p in (elf,out/'imem.hex',out/'dmem.hex')}))
    args = SimpleNamespace(iterations=iterations,timer_mode='realtime',irq_period_us=100)
    for layer in p2.LAYERS:
        for mode in modes:
            im=p2.build_image(args,layer,mode,tools,bundle)
            im['scenario']=layer
            images.append(im)
    if 'soc_npu' in CONFIG['platforms']:
        args.npu=True
        for mode in modes:
            im=p2.build_image(args,'background',mode,tools,bundle)
            im['scenario']='npu_background'
            images.append(im)
    manifest=dict(schema=1,optimization=p2.optimization(),iterations=iterations,modes=modes,source_sha256=hashes,images=images,
                  compiler=subprocess.check_output([tools+'gcc','--version'],text=True).splitlines()[0])
    write(bundle/'manifest.json',manifest)
    print(f'PASS unified firmware {len(images)} images: {bundle}',flush=True)
    return manifest


def build(config, root):
    top=config['sim_top']
    binary=root/('V'+top)
    sources=p2.rtl_sources()
    sources.update({p:sha(ROOT/p) for p in ('scripts/benchmark_config.py','scripts/benchmark_platforms.json','scripts/hardware_profile.json','scripts/hardware_config.py',
                                           'scripts/verilator/run_unified_coremark.py')})
    if binary.exists():
        receipt=json.loads((root/'build.json').read_text())
        if receipt['config']!=config or receipt['source_sha256']!=sources or receipt['binary_sha256']!=sha(binary):
            raise ValueError(f'stale model: {root}; use a new output directory')
        return binary,receipt
    root.mkdir(parents=True,exist_ok=False)
    p2.copy_sources([Path(p) for p in sources],root/'source')
    command=['verilator','--binary','--assert','--timing','-Wall','-Wno-fatal','-j','2','-CFLAGS','-O1',
             *[f'-D{k}={v}' for k,v in config['macros'].items()],
             '-f','scripts/system_files.f','tb/common/store_result_monitor.sv',
             'tb/common/scoreboard_metrics.sv','tb/benchmark/bind_scoreboard_metrics.sv',
             'tb/common/scoreboard_scheduler_metrics.sv','tb/benchmark/bind_scheduler_metrics.sv']
    periods=config['periods_ps']
    if config['platform']=='core_tcm':
        command += ['vsrc/cpu/pango_measure_hot.sv','vsrc/cpu/benchmark_core_tcm.sv','tb/benchmark/tb_coremark_tcm.sv',
                    f'-GCORE_PERIOD_PS={periods["core"]}']
    else:
        command += ['tb/soc/axi_system_memory_model.sv','tb/soc/spi_flash_model.sv','tb/soc/tb_soc_system.sv',
                    f'-GDDR_BYTES={config["ddr_bytes"]}', f'-GNPU_ENABLE={config.get("npu_enable",0)}',
                    f'-GNPU_PERIOD_PS={config.get("npu_period_ps",10000)}', '-GDDR_MODEL_BYTES=262144', '-GFLASH_BYTES=0',
                    f'-GICACHE_ENABLE={config["cache_enable"]}',f'-GDCACHE_ENABLE={config["cache_enable"]}',
                    '-GCLOCK_HZ=125000000',f'-GUART_DIVISOR={(10**12//periods["periph"]+57600)//115200}',
                    *[f'-G{d.upper()}_PERIOD_PS={periods[d]}' for d in DOMAINS]]
    command += ['--top-module',top,'-Mdir',str(root)]
    env=dict(os.environ,CCACHE_TEMPDIR=str(ROOT/'build/ccache-tmp'),CCACHE_DIR=str(ROOT/'build/ccache'))
    Path(env['CCACHE_TEMPDIR']).mkdir(parents=True,exist_ok=True)
    run(command,root/'build.log',root/'source',env)
    text=(root/'build.log').read_text()
    if re.search(r'%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))',text):
        raise ValueError('critical Verilator diagnostic: '+str(root/'build.log'))
    receipt=dict(config=config,command=shlex.join(command),source_sha256=sources,binary_sha256=sha(binary),
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        source_branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip())
    write(root/'build.json',receipt)
    print(f'PASS build {config["platform"]} {config["clock"]} RV{config["xlen"]}',flush=True)
    return binary,receipt


def parse_tcm(text, image, config):
    if re.search(r'%Error|%Fatal|TIMEOUT|Assertion failed',text) or not re.search(r'^PASS unified-',text,re.M):
        raise ValueError('TCM execution did not retire a successful tohost store')
    p2.parse_core_config(text,core_record(config))
    if config['platform']=='core_tcm':
        period=re.search(r'^UNIFIED_TCM core_period_ps=(\d+) itcm_bytes=65536 dtcm_bytes=65536 cache=0 ddr=0$',text,re.M)
        if not period or int(period[1])!=config['periods_ps']['core']:
            raise ValueError('core TCM clock/memory configuration mismatch')
    else:
        hardware=re.search(r'^P2_HARDWARE (.*)$',text,re.M)
        if not hardware: raise ValueError('missing hardware clocks')
        fields={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',hardware[1])}
        for d in DOMAINS:
            if fields.get(d+'_hz')!=(config['frequencies_hz'][d] or 0):
                raise ValueError('TCM simulation clock differs from receipt: '+d)
    for field,value in p2.EXPECTED[image['mode']].items():
        found=re.search(rf'^(?:\[0\])?{field}\s*:\s*0x([0-9a-fA-F]+)',text,re.M)
        if not found or int(found[1],16)!=value: raise ValueError('invalid '+field)
    count=re.search(r'^Iterations\s*:\s*(\d+)',text,re.M)
    ticks=re.search(r'^Total ticks\s*:\s*(\d+)',text,re.M)
    if not count or int(count[1])!=image['iterations'] or not ticks or int(ticks[1])<=0:
        raise ValueError('invalid iteration/cycle count')
    for line in text.splitlines():
        if 'ERROR!' in line and line!='ERROR! Must execute for at least 10 secs for a valid result!':
            raise ValueError(line)
    final=re.search(r'^\[0\]crcfinal\s*:\s*0x([0-9a-fA-F]+)',text,re.M)
    if not final: raise ValueError('missing final CRC')
    result=dict(cycles=int(ticks[1]),crc=dict(p2.EXPECTED[image['mode']],crcfinal=int(final[1],16)))
    if image['scenario']=='tcm_background':
        bg=re.search(r'^P2_BACKGROUND irq=(\d+) dma_completed=(\d+) dma_bytes=(\d+) errors=(\d+)',text,re.M)
        roi=re.search(r'^P2_ROI .*',text,re.M)
        irq=re.search(r'^P2_IRQ start=(\d+) stop=(\d+) roi=(\d+)',text,re.M)
        if not bg or not roi or not irq: raise ValueError('missing TCM DMA/IRQ activity')
        i,n,b,e=map(int,bg.groups())
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',roi[0])}
        if e or i<=0 or n<=0 or b!=n*16384 or int(irq[3])<=0 or any(counters[k]<=0 for k in ('dma_ar','dma_aw','dma_rbeats','dma_wbeats')):
            raise ValueError('TCM DMA/IRQ failed or did not overlap the measurement')
        if counters['cpu_ddr_ar'] or counters['cpu_ddr_aw']: raise ValueError('TCM run used DDR')
        result['background']=dict(irq=i,completed=n,bytes=b,errors=e,roi=counters)
    return result


def replay(binary, config, bundle, image, output, receipt):
    name=f'{config["platform"]}-{config["clock"]}-{image["scenario"]}-{image["mode"]}'
    log=output/'results'/(name+'.log')
    im=bundle/image['directory']
    ddr=image['scenario'] in (*p2.LAYERS,'npu_background')
    test=('p2-coremark-' if ddr else 'unified-')+name
    command=[str(binary),f'+IMEM={im}/imem.hex',f'+DMEM={im}/dmem.hex',
             f'+TOHOST={image["symbols"]["tohost"]:x}',f'+CONSOLE={image["symbols"]["sim_console"]:x}',
             '+TEST='+test,'+MAX_CYCLES=100000000']
    if ddr: command += [f'+DDR={im}/ddr.hex']
    if ddr or image['scenario']=='tcm_background': command += ['+P2_ROI=01100100','+P2_METRICS','+P2_PLATFORM']
    run(command,log)
    text=log.read_text()
    if config.get('npu_enable') and f'NPU_HARDWARE enabled=1 period_ps={config["npu_period_ps"]}' not in text:
        raise ValueError('missing NPU clock/configuration receipt')
    periods=[config['periods_ps'][d] for d in DOMAINS]
    result=(p2.parse_result(text,image['mode'],image['iterations'],
                           'background' if image['scenario']=='npu_background' else image['scenario'],
                           expected_core=core_record(config),expected_periods_ps=periods)
            if ddr else parse_tcm(text,image,config))
    result.update(score(image['iterations'],result['cycles'],periods[0]))
    if config.get('npu_enable'):
        activity=re.search(r'^NPU_ACTIVITY (.*)$',text,re.M)
        if not activity: raise ValueError('missing NPU activity record')
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',activity[1])}
        result['npu_activity']=counters
        if image['scenario']=='npu_background':
            work=re.search(r'^NPU_BACKGROUND (.*)$',text,re.M)
            if not work: raise ValueError('missing checked NPU outputs')
            values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',work[1])}
            if values.get('errors')!=0 or any(values.get(k,0)<=0 for k in ('roi_tasks','roi_vectors')) or any(counters.get(k,0)<=0 for k in ('roi_cycles','busy','starts','outputs')):
                raise ValueError('NPU did not compute checked results during CoreMark')
            result['npu_workload']=dict(values,shape='4x1 Ci8 Co16 kernel1 resident raw INT32; timer polls outputs; independent DDR DMA')
        elif any(counters.get(k,0) for k in ('busy','starts','outputs')):
            raise ValueError('idle NPU comparison contained compute activity')
    result.update(config=config,scenario=image['scenario'],mode=image['mode'],iterations=image['iterations'],
        image_sha256=image['image_sha256'],command=shlex.join(command),log=str(log),log_sha256=sha(log),
        binary_sha256=receipt['binary_sha256'],source_commit=receipt['source_commit'],source_branch=receipt['source_branch'],
        memory_backend='AXI verification RAM, 256 KiB, deterministic stalls; no controller/PHY' if config['ddr_bytes'] else 'production TCM RTL')
    write(log.with_suffix('.json'),result)
    print(f'PASS {name} cycles={result["cycles"]} CM/MHz={result["coremark_per_core_mhz"]:.6f} CM/s(sim)={result["coremark_per_second_simulated"]:.3f}',flush=True)
    return result


def functional(binary, config, output, receipt):
    name=f'{config["platform"]}-{config["clock"]}-rv{config["xlen"]}'
    image=output/'functional'/name
    image.mkdir(parents=True,exist_ok=True)
    sources=['software/common/baremetal/crt0.S','software/common/baremetal/runtime.c','software/common/baremetal/softarith.c',
             'software/common/smoke.c' if config['platform']=='core_tcm' else 'tb/software/benchmark_platform.c']
    command=['bash','scripts/verilator/build_baremetal_image.sh',str(config['xlen']),str(image),
             f'-DBENCH_DDR={int(bool(config["ddr_bytes"]))}',f'-DBENCH_NPU={config.get("npu_enable",0)}',*sources]
    build_command=shlex.join(command)
    run(command,image/'build.log',env=dict(os.environ,SOC='1',SOC_DDR='0'))
    nm=subprocess.check_output([str(Path(os.environ['RISCV_TOOL_ROOT'])/'riscv64-unknown-elf-nm'),
                                '-n',str(image/'program.elf')],text=True)
    symbols=p2.symbols_from_nm(nm)
    command=[str(binary),f'+IMEM={image}/imem.hex',f'+DMEM={image}/dmem.hex',
             f'+TOHOST={symbols["tohost"]:x}',f'+CONSOLE={symbols["sim_console"]:x}',
             '+TEST=paired-functional','+MAX_CYCLES=3000000']
    run(command,image/'run.log')
    text=(image/'run.log').read_text()
    if not re.search(r'^PASS paired-functional RV'+str(config['xlen'])+r'\b',text,re.M):
        raise ValueError('paired platform functional test failed')
    p2.parse_core_config(text,core_record(config))
    write(image/'result.json',dict(config=config,command=shlex.join(command),
        image_build_command=build_command,source_commit=receipt['source_commit'],source_branch=receipt['source_branch'],
        binary_sha256=receipt['binary_sha256'],image_sha256={p.name:sha(p) for p in image.glob('*.hex')},
        elf_sha256=sha(image/'program.elf'),source_sha256={s:sha(ROOT/s) for s in
            sources + (['software/yolo/npu_workload.h'] if config.get('npu_enable') else [])},
        log_sha256=sha(image/'run.log'),status='PASS'))
    print('PASS paired functional '+name,flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--bundle',type=Path)
    parser.add_argument('--models',type=Path,help='Shared immutable RTL model directory across software optimization levels')
    parser.add_argument('--platforms',nargs='+',choices=CONFIG['platforms'],default=list(CONFIG['platforms']))
    parser.add_argument('--clocks',nargs='+',choices=CONFIG['clock_periods_ps'],default=['target'])
    parser.add_argument('--scenarios',nargs='+',choices=['tcm','tcm_background',*p2.LAYERS,'npu_background'])
    parser.add_argument('--modes',nargs='+',choices=p2.EXPECTED,default=list(p2.EXPECTED))
    parser.add_argument('--iterations',type=int,default=2)
    parser.add_argument('--build-only',action='store_true')
    parser.add_argument('--functional',action='store_true',help='Run boot/TCM/DMA/cache functionality without CoreMark')
    parser.add_argument('--xlen',type=int,choices=(32,64),default=32)
    args=parser.parse_args()
    if args.iterations<=0: parser.error('iterations must be positive')
    if args.build_only and args.functional: parser.error('choose --build-only or --functional')
    if args.xlen==64 and not (args.build_only or args.functional): parser.error('RV64 is functional-only; use --functional')
    os.chdir(ROOT)
    output=args.output.resolve()
    bundle=args.bundle.resolve() if args.bundle else output/'firmware'
    firmware=None if (args.build_only or args.functional) else freeze(bundle,args.iterations,args.modes)
    results=[]
    for platform in args.platforms:
        for clock in args.clocks:
            config=configuration(platform,clock,args.xlen)
            binary,receipt=build(config,(args.models.resolve() if args.models else output/'models')/f'{platform}-{clock}-rv{args.xlen}')
            if args.functional:
                functional(binary,config,output,receipt)
            if firmware:
                for im in firmware['images']:
                    if im['mode'] in args.modes and im['scenario'] in config['scenarios'] and (args.scenarios is None or im['scenario'] in args.scenarios):
                        results.append(replay(binary,config,bundle,im,output,receipt))
    if results:
        write(output/'results'/'summary.json',results)
    print(f'PASS unified CoreMark measured={len(results)}; synthesis and physical timing are separate',flush=True)


if __name__=='__main__':
    main()
