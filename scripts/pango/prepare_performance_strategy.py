#!/usr/bin/env python3
"""Clone frozen paired inputs into a fresh, explicit PDS performance experiment.

The original compile, firmware and clock constraints remain byte-identical.
The strategy is a measured candidate, not a promise of higher Fmax or less area.
Options follow local PDS 2025.2 UG990004 sections 4.92, 4.112 and 4.142.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


SYNTHESIS = ('synthesize -ads -selected_syn_tool_opt 2 -resource_sharing false '
             '-fanout_guide 128 -retiming -max_path 100 -nworst 3 '
             '-report_logic_level_distribution -report_exception TRUE')
PLACEMENT = 'place -mode normal -optimize_gp_recovery TRUE -logic_optimize_lut6d FALSE'
ROUTE = 'route -route_mode normal -slack_weight 90 -optimize_routing_recovery TRUE'


def scripts(synthesis, implementation):
    standard = ('synthesize -ads -selected_syn_tool_opt 2 -max_path 100 -nworst 3 '
                '-report_logic_level_distribution -report_exception TRUE')
    if synthesis.splitlines().count(standard) != 1:
        raise ValueError('unsupported paired synthesis entry')
    standard_route = 'route -route_mode normal'
    place = 'place' if 'place' in implementation.splitlines() else PLACEMENT
    route = standard_route if standard_route in implementation.splitlines() else ROUTE
    if implementation.splitlines().count(place) != 1 or implementation.splitlines().count(route) != 1:
        raise ValueError('unsupported implementation entry')
    return (synthesis.replace(standard, SYNTHESIS).replace('set_option max_threads 1', 'set_option max_threads 8'),
            implementation.replace('\n'+place+'\n', '\n'+PLACEMENT+'\n').replace('\n'+route+'\n', '\n'+ROUTE+'\n'))


def stage(source, output):
    from prepare_benchmark import verify
    if (source/'application.json').exists():
        raise ValueError('main stages no-accelerator benchmarks; use baseline-yolo for application projects')
    manifest = verify(source)
    manifest_name = 'benchmark.json'
    if output.exists():
        raise ValueError('performance experiment needs a new directory')
    # Gray sources, both synchronizer stages and the FIFO module must retain their
    # RTL retiming protection before this global retiming experiment is generated.
    fifo = (source / 'vsrc/soc/common/async_fifo.sv').read_text()
    if 'PAP_ASYNC_REG' not in fifo or 'syn_allow_retiming = 0' not in fifo or 'syn_preserve = 1' not in fifo:
        raise ValueError('paired RTL lacks the reviewed CDC protection')
    output.mkdir(parents=True)
    for name in [*manifest['files'], manifest_name]:
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    synthesis, implementation = scripts((source / 'benchmark_synthesize.tcl').read_text(),
                                         (source / 'implement.tcl').read_text())
    (output / 'performance_synthesize.tcl').write_text(synthesis)
    (output / 'performance_implement.tcl').write_text(implementation)
    strategy = dict(name='timing-v3', synthesis=SYNTHESIS, place=PLACEMENT, route=ROUTE,
                    threads=8,
                    clocks='unchanged from paired standard project',
                    input_manifest=manifest_name, input_manifest_sha256=sha(output / manifest_name),
                    source_project=source.name,
                    files={name: sha(output/name) for name in
                           ('performance_synthesize.tcl', 'performance_implement.tcl')},
                    cdc_constraints='not applied; requires native object binding and exception verification',
                    status='prepared; no PDS execution or physical timing claim')
    (output / 'strategy.json').write_text(json.dumps(strategy, indent=2)+'\n')
    verify(output)
    print(f'PASS frozen performance strategy: {output}')


def verify_strategy(root, synthesis_log=None):
    strategy = json.loads((root / 'strategy.json').read_text())
    # 历史v2报告仍按当时的64/80核验，不用新参数重写旧测量口径。
    expected = dict(synthesis=SYNTHESIS, place=PLACEMENT, route=ROUTE)
    if strategy['name'] == 'timing-v2':
        expected['synthesis'] = SYNTHESIS.replace('-fanout_guide 128', '-fanout_guide 64')
        expected['route'] = ROUTE.replace('-slack_weight 90', '-slack_weight 80')
    if strategy['name'] not in ('timing-v2', 'timing-v3') or any(strategy[k] != v for k, v in expected.items()):
        raise ValueError('unknown performance strategy')
    manifest_name = strategy.get('input_manifest', 'benchmark.json')
    if manifest_name not in ('benchmark.json', 'application.json'):
        raise ValueError('unknown paired manifest')
    digest = strategy.get('input_manifest_sha256', strategy.get('benchmark_manifest_sha256'))
    if sha(root / manifest_name) != digest:
        raise ValueError('performance benchmark configuration changed')
    for name, digest in strategy['files'].items():
        if sha(root/name) != digest:
            raise ValueError('performance script changed: '+name)
    if synthesis_log is not None and f'Executing : {expected["synthesis"]} successfully.' not in synthesis_log.splitlines():
        raise ValueError('performance synthesis command did not complete')
    return strategy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    stage(args.source.resolve(), args.output.resolve())


if __name__ == '__main__':
    main()
