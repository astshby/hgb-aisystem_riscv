#!/usr/bin/env python3
"""Pair native synthesis evidence with its runnable CoreMark hardware configuration."""
import argparse
import json
from pathlib import Path
import re

from prepare_benchmark import verify
from prepare_project import timing_input, TIMING_V3_SYNTHESIS
from benchmark_config import sha
from summarize_measurement import read_table, resources, path_family


def summarize(root, native_log=None):
    input_path, manifest, config = timing_input(root)
    manifest_name = input_path.name
    if manifest_name=='application.json':
        from prepare_yolo_application import verify as verify_application
        manifest=verify_application(root)
    elif manifest_name == 'benchmark.json':
        manifest=verify(root)
    syn=root/'prj_tasks/syn_1/synthesize'
    log=Path(native_log) if native_log is not None else root/'native-synthesis.stdout.log'
    text=log.read_text(errors='replace')
    if not re.search(r'^Executing : synthesize[^\r\n]* successfully\.$',text,re.M):
        raise ValueError('missing completed synthesis action')
    selected = manifest.get('synthesis_strategy')
    if selected in ('timing-v2', 'timing-v3'):
        expected = TIMING_V3_SYNTHESIS.replace('-fanout_guide 128', '-fanout_guide 64') if selected == 'timing-v2' else TIMING_V3_SYNTHESIS
        if ('Executing : '+expected+' successfully.') not in text.splitlines():
            raise ValueError(f'configured {selected} synthesis did not complete')
    strategy = None
    if (root/'strategy.json').exists():
        from prepare_performance_strategy import verify_strategy
        strategy = verify_strategy(root, text)
    report=syn/(config['pds_top']+'.snr')
    netlist=syn/(config['pds_top']+'_syn.vm')
    if not netlist.is_file(): raise ValueError('missing synthesized netlist')
    tables={}
    files=[root/manifest_name,report,netlist,log]
    for name in ('resource_utilization','report_timing_fmax','report_timing_clock_summary',
                 'report_timing_setup','report_timing_hold','report_timing_path_setup','check_timing_summary'):
        path=syn/'report_db'/('synthesize_'+name+'.db')
        tables[name]=read_table(path,paths=name=='report_timing_path_setup')
        files.append(path)
    retained={}
    for row in tables['resource_utilization']:
        name=row.get('Module Inst Name','')
        if any(token in name for token in ('g_tcm[','u_icache(','u_dcache(','u_ddr_cdc(','I_ips_ddr_top(','g_npu[','g_npu.','u_npu(')):
            retained[name]={k:v for k,v in row.items() if k in ('LUT','FF','Distributed RAM','APM','DRM','DDR_PHY')}
    worst={}
    same_domain={}
    for row in tables['report_timing_path_setup']:
        family=('benchmark_observer' if 'u_observe' in str(row) else path_family(row))
        if family not in worst or float(row['Slack'])<float(worst[family]['Slack']): worst[family]=row
        clock=row['Launch Clock']
        if clock==row['Capture Clock'] and (clock not in same_domain or float(row['Slack'])<float(same_domain[clock]['Slack'])):
            same_domain[clock]=row
    return dict(config=config,strategy=strategy,status='native synthesis complete; estimated timing, no place/route',
                input_manifest=manifest_name, firmware_role=manifest.get('firmware_role'),
                firmware=manifest.get('firmware'), source_commit=manifest.get('source_commit'),
                resources=resources(report.read_text(errors='replace')),retained_memory_and_ddr=retained,
                estimated_timing=tables,worst_path_by_family=worst,
                worst_same_domain_path=same_domain,
                cross_domain_setup=[r for r in tables['report_timing_setup'] if r['Launch Clock']!=r['Capture Clock']],
                routed_fmax=None,routed_wns=None,unrouted_nets=None,
                hashes={str(p.relative_to(root)) if p.is_relative_to(root) else str(p):sha(p) for p in files})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--native-log', type=Path, help='exact run_phase synthesis log; original default remains supported')
    args=parser.parse_args()
    result=summarize(args.project.resolve(), args.native_log.resolve() if args.native_log else None)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('status','resources','retained_memory_and_ddr')},indent=2))
    print(json.dumps(result['estimated_timing']['report_timing_fmax'],indent=2))


if __name__=='__main__':
    main()
