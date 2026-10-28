#!/usr/bin/env python3
"""Prepare an object/domain audit before applying bounded FIFO CDC constraints.

Run audit.tcl inside the synthesized PDS design. bind() only publishes constraints
after native pin names and emitted-netlist clock roots have both been checked.
Ordinary logic, second synchronizer stages, PHY paths and resets are not excepted.
"""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from measurement_constraints import _fifo_inventory, _path_pattern, _register_pattern


def specification(config):
    domains = config['domains']
    if config['platform'] == 'core_tcm':
        raise ValueError('Core+TCM has no asynchronous FIFO boundary')
    if config.get('native_board_profile') not in (1, 4):
        raise ValueError('audit supports the documented C1/C4 clock profiles')
    periods = {d: Decimal(config['periods_ps'][d]) / 1000 for d in domains}
    root = 'u_soc' if 'ddr' in domains else 'g_soc.u_soc'
    all_periods = dict(periods, ddr=Decimal(config['periods_ps']['ddr']) / 1000)
    fifos = []
    for fifo in _fifo_inventory(all_periods):
        if any(c['source_domain'] not in domains or c['destination_domain'] not in domains
               for c in fifo['crossings']):
            continue
        path = fifo['path'].replace('g_soc.u_soc', root, 1)
        src, dst = (fifo['crossings'][0][k] for k in ('source_domain', 'destination_domain'))
        fifos.append(dict(path=path, bits=fifo['pointer_bits'], src=src, dst=dst,
                          prunable=fifo['allow_whole_fifo_pruned'],
                          constant_payload=(path.endswith('u_flash.u_ack') or
                              (config.get('cache_enable') == 0 and '.u_maintenance_cdc.' in path))))
    if config.get('npu_enable'):
        for channel in ('aw', 'w', 'ar', 'b', 'r'):
            reverse = channel in ('b', 'r')
            fifos.append(dict(path=f'g_npu.u_target.u_cdc.u_{channel}', bits=3,
                              src='npu' if reverse else 'sys', dst='sys' if reverse else 'npu',
                              prunable=False, constant_payload=False))
    clocks = {d: 'ddrphy_sysclk' if d == 'ddr' else f'clk_{d}' for d in domains}
    levels = [dict(path=root, signal='irq_sync1_q', second_signal='irq_sync2_q',
                   bits=[0, 1, 2], second_bits=[0, 1, 2], src='periph', dst='core')]
    if 'ddr' in domains:
        levels += [dict(path=root, signal=signal, second_signal=signal,
                        bits=[0], second_bits=[1], src='ddr', dst=dst)
                   for signal, dst in (('ddr_system_online_q', 'sys'), ('ddr_online_q', 'periph'))]
    return dict(schema=1, platform=config['platform'], clocks=clocks,
                periods_ns={d: str(p) for d, p in periods.items()}, fifos=fifos, levels=levels,
                policy='first-stage Gray and stable FIFO payload only; no clock groups or false paths',
                payload_budget='minimum of source/destination period; pointer visibility takes at least two receiving edges',
                hold_policy='datapath_only replaces setup and hold only for the explicitly bounded CDC paths')


# PDS name-report output truncates after 1000 objects. Query exact, bounded
# batches from the emitted VM; reject any missing native object before binding.
def generate(spec, names):
    ordered = sorted(names)
    groups = {str(i // 128): ordered[i:i + 128] for i in range(0, len(ordered), 128)}
    lines = ['# Exact native pins, bounded batches; no Tcl iteration over deferred handles.']
    for index, group in groups.items():
        lines += [f'puts "CDC_QUERY {index}"', 'get_pins {' + ' '.join(group) + '}']
    lines.append('puts "CDC_QUERY_COMPLETE"')
    return '\n'.join(lines) + '\n', groups


def parse_native_queries(text, spec, names):
    if not re.search(r'^CDC_QUERY_COMPLETE\s*$', text, re.M):
        raise ValueError('native CDC query did not complete')
    if re.search(r'^(?:E:|ERROR:)|(?:Timing-4003|CommandTiming-0057):', text, re.M):
        raise ValueError('native CDC query contains unresolved objects or errors')
    expected = generate(spec, names)[1]
    complete, current = set(), None
    for line in text.splitlines():
        marker = re.fullmatch(r'CDC_QUERY (\d+)', line)
        if marker:
            current = marker[1]
            if current not in expected or current in complete:
                raise ValueError('duplicate/unexpected native query marker')
            continue
        match = re.fullmatch(r'Executing : get_pins (.*?) successfully\.', line)
        if match:
            objects = match[1].strip().removeprefix('{').removesuffix('}').split()
            if current not in expected or current in complete or objects != expected[current]:
                raise ValueError('native query objects differ from prepared VM objects')
            complete.add(current)
    if complete != set(expected):
        raise ValueError('native query coverage incomplete')
    return set(names)


def object_list(names):
    if not names or any(re.search(r'[\s{}]', name) for name in names):
        raise ValueError('empty or unsupported native object list')
    return '{' + ' '.join('t:' + name for name in names) + '}'


def read_clock_sources(path, spec):
    sources = {domain: set() for domain in spec['clocks']}
    domains = {clock: domain for domain, clock in spec['clocks'].items()}

    def walk(row, clock=None):
        description = row.find('data').text or ''
        match = re.match(r'(\S+) \([0-9.]+MHZ\)', description)
        if match:
            clock = match[1]
        name = description.split(' (', 1)[0]
        if clock in domains and re.search(r'/(?:CLK|WCLK)$', name):
            sources[domains[clock]].add(name)
        for child in row.findall('row'):
            walk(child, clock)

    for row in ET.parse(path).getroot().find('table').findall('row'):
        walk(row)
    for level in spec['levels']:
        if not sources[level['src']]:
            raise ValueError('native clock network has no level-source registers: ' + level['src'])
    return {domain: sorted(pins) for domain, pins in sources.items()}


def audit_objects(spec, names, netlist, clock_sources):
    proofs, syncs, passed, pruned, reviewed_pointer_pins = {}, set(), [], [], set()
    pruned_receivers = []
    constraints = ['# Bound to native pins and traced clock roots; periods remain unchanged.']

    def checked(pattern, domain, bits, label, protected=False):
        regex = re.compile(pattern)
        selected = sorted(name for name in names if regex.fullmatch(name))
        if bits is not None:
            actual = sorted(int(re.fullmatch(pattern, name)[1]) for name in selected)
            if actual != list(bits):
                raise ValueError(f'missing/duplicate bits {label}: {actual}, expected {list(bits)}')
        for name in selected:
            actual, trace = netlist.domain(name)
            if actual != domain:
                raise ValueError(f'clock domain mismatch {name}: {actual}, expected {domain}')
            _, cell, pin = netlist.pin(name)
            if protected:
                flag = "PAP_PRESERVE" if "_gray_q" in name else "PAP_ASYNC_REG"
                if not re.search(flag + r'\s*=\s*"TRUE"', cell.attributes) or not re.search(
                        r'PAP_ALLOW_RETIMING\s*=\s*"FALSE"', cell.attributes):
                    raise ValueError(f'missing native preservation attributes {name}')
            proofs[name] = dict(domain=actual, trace=trace, primitive=cell.kind)
        return selected

    for index, fifo in enumerate(spec['fifos']):
        path, src, dst = (fifo[k] for k in ('path', 'src', 'dst'))
        scope = r'^' + _path_pattern(path) + r'[./]'
        relevant = [name for name in names if re.match(scope, name)]
        if not relevant and fifo['prunable']:
            if any(re.match(scope, name) for name in netlist.cells):
                raise ValueError(f'FIFO exists in VM but is absent from native queries: {path}')
            pruned.append(index)
            continue
        budget = min(Decimal(spec['periods_ns'][src]), Decimal(spec['periods_ns'][dst]))
        for direction, a, b in (('write', src, dst), ('read', dst, src)):
            groups = []
            receiver_patterns = [_register_pattern(path, f'{direction}_sync{stage}_q', pin)
                                 for stage in (1, 2) for pin in ('CLK', 'D')]
            no_receivers = fifo['prunable'] and not any(re.fullmatch(p, n) for p in receiver_patterns for n in names)
            for signal, pin, domain in ((f'{direction}_gray_q', 'CLK', a),
                    (f'{direction}_gray_q', 'Q', a), (f'{direction}_sync1_q', 'D', b),
                    (f'{direction}_sync1_q', 'CLK', b), (f'{direction}_sync2_q', 'D', b),
                    (f'{direction}_sync2_q', 'CLK', b)):
                if no_receivers and 'sync' in signal:
                    continue
                selected = checked(_register_pattern(path, signal, pin), domain,
                                   range(fifo['bits']), f'{path}/{signal}/{pin}', True)
                groups.append(selected)
                reviewed_pointer_pins.update(selected)
                if pin == 'CLK' and 'sync' in signal:
                    syncs.update(name.rsplit('/', 1)[0] for name in selected)
            if no_receivers:
                pruned_receivers.append(path + '/' + direction)
                continue
            constraints += [f'set_max_delay {budget} -datapath_only -from {object_list(groups[0])} -to {object_list(groups[2])}',
                            f'set_max_skew {budget} -from {object_list(groups[0])} -to {object_list(groups[2])}']
        payload = checked(scope + r'payload[^/]*(?:/opit_[0-9]+)?/(?:WCLK|CLK)$', src,
                          None, path + '/payload')
        if not payload and not (fifo['constant_payload'] or fifo['prunable']):
            raise ValueError(f'missing native FIFO payload {path}')
        if payload:
            outputs = []
            for name in payload:
                _, cell, _ = netlist.pin(name)
                outputs += [name.rsplit('/', 1)[0] + '/' + port for port in netlist.scalar_outputs(cell)]
            if not outputs:
                raise ValueError(f'FIFO payload has no connected native output {path}')
            names.update(outputs)
            checked('(?:' + '|'.join(re.escape(n) for n in outputs) + ')', src, None, path + '/outputs')
            # Explicit clocks filter out read-address feedback in the receiving
            # domain; finite data outputs restrict the exception to this FIFO.
            constraints.append(f'set_max_delay {budget} -datapath_only '
                               f'-from [get_clocks {spec["clocks"][src]}] '
                               f'-through {object_list(sorted(outputs))} '
                               f'-to [get_clocks {spec["clocks"][dst]}]')
        passed.append(index)
    pointer_names = {n for n in names if re.search(r'/(?:write|read)_(?:gray|sync[12])_q\[\d+\](?:/opit_\d+(?:_inv)?)?/(?:CLK|D|Q)$', n)}
    # D of Gray and Q of sync stages are native inventory evidence, not exception endpoints.
    required = {n for n in pointer_names if re.search(r'_gray_q\[\d+\](?:/opit_\d+(?:_inv)?)?/(?:CLK|Q)$', n)
                or re.search(r'_sync[12]_q\[\d+\](?:/opit_\d+(?:_inv)?)?/(?:CLK|D)$', n)}
    if required != reviewed_pointer_pins:
        raise ValueError(f'unreviewed native FIFO pointer pins: {sorted(required-reviewed_pointer_pins)[:3]}')
    for level in spec['levels']:
        budget = min(Decimal(spec['periods_ns'][level['src']]), Decimal(spec['periods_ns'][level['dst']]))
        for signal, bits, first in ((level['signal'], level['bits'], True),
                                    (level['second_signal'], level['second_bits'], False)):
            for bit in bits:
                for pin in ('D', 'CLK'):
                    selected = checked(_register_pattern(level['path'], signal, pin, bit),
                                       level['dst'], [bit], signal, True)
                    if pin == 'CLK':
                        syncs.update(name.rsplit('/', 1)[0] for name in selected)
                    elif first:
                        sources = clock_sources[level['src']]
                        # Clock-network membership is native evidence, including
                        # vendor IP registers whose module bodies are encrypted.
                        for name in sources:
                            proofs[name] = dict(domain=level['src'], primitive='native register clock',
                                                trace=[(spec['clocks'][level['src']], 'native clock network')])
                        constraints.append(f'set_max_delay {budget} -datapath_only '
                                           f'-from {object_list(sources)} -to {object_list(selected)}')
    return dict(passed_fifos=passed, pruned_fifos=pruned, pruned_receivers=pruned_receivers, pins=proofs,
                synchronizer_registers=sorted(syncs)), '\n'.join(constraints) + '\n'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_inputs(project, summary_file, spec):
    from netlist_clock_audit import ClockNetlist
    manifest_path = project / spec['input_manifest']
    if sha(manifest_path) != spec['input_manifest_sha256']:
        raise ValueError('staged manifest changed after query preparation')
    config = json.loads(manifest_path.read_text())['config']
    summary = json.loads(summary_file.read_text())
    if summary['config'] != config:
        raise ValueError('timing summary configuration mismatch')
    relative_vm = f'prj_tasks/syn_1/synthesize/{config["pds_top"]}_syn.vm'
    clock_db = 'prj_tasks/syn_1/synthesize/report_db/synthesize_report_timing_clock_summary.db'
    path_db = 'prj_tasks/syn_1/synthesize/report_db/synthesize_report_timing_path_setup.db'
    network_db = 'prj_tasks/syn_1/synthesize/report_db/synthesize_report_clock_network.db'
    for relative in (relative_vm, clock_db, path_db):
        if sha(project / relative) != summary['hashes'][relative]:
            raise ValueError(f'timing summary/native artifact hash mismatch {relative}')
    if sha(project / network_db) != spec['clock_network_sha256']:
        raise ValueError('native clock network changed after query preparation')
    netlist = ClockNetlist((project / relative_vm).read_text(), config['pds_top'],
                          summary['estimated_timing']['report_timing_clock_summary'], spec,
                          summary['worst_same_domain_path'])
    pointer_or_level = re.compile(r'/(?:write|read)_(?:gray|sync[12])_q|/(?:irq_sync[12]|ddr_(?:system_)?online)_q')
    payload = re.compile('^(?:' + '|'.join(_path_pattern(f['path']) for f in spec['fifos']) + r')[./]payload')
    names = {f'{name}/{pin}' for name, (_, cell) in netlist.cells.items()
             if pointer_or_level.search(name) or payload.match(name) for pin in cell.ports}
    clock_sources = read_clock_sources(project / network_db, spec)
    result, constraints = audit_objects(spec, names, netlist, clock_sources)
    result.update(netlist_sha256=sha(project / relative_vm), clock_report_sha256=sha(project / clock_db),
                  path_report_sha256=sha(project / path_db), encrypted_clock_evidence=netlist.clock_evidence,
                  clock_network_sha256=sha(project / network_db),
                  native_to_vm_aliases=netlist.native_aliases,
                  input_manifest_sha256=sha(manifest_path))
    return result, constraints


def bind(directory, log, project, summary_file):
    spec = json.loads((directory / 'spec.json').read_text())
    result, constraints = load_inputs(project, summary_file, spec)
    if generate(spec, result['pins'])[0] != (directory / 'audit.tcl').read_text():
        raise ValueError('prepared query does not match current VM pins')
    parse_native_queries(log.read_text(errors='replace'), spec, result['pins'])
    result.update(log_sha256=sha(log), status='native objects and emitted-netlist clock roots verified; constraint effectiveness and routed timing still pending')
    for name in ('bound_cdc.fdc', 'bound_sync.lcf', 'binding.json'):
        if (directory / name).exists():
            raise FileExistsError(directory / name)
    (directory / 'bound_cdc.fdc').write_text(constraints)
    (directory / 'bound_sync.lcf').write_text(''.join(
        f'define_attribute {{i:{name}}} {{PAP_ASYNC_REG}} {{TRUE}}\n'
        for name in result['synchronizer_registers']))
    (directory / 'binding.json').write_text(json.dumps(result, indent=2)+'\n')
    print(f'PASS native CDC object/clock binding: {len(result["passed_fifos"])} FIFOs, '
          f'{len(result["synchronizer_registers"])} synchronizer registers')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--bind-log', type=Path)
    p.add_argument('--timing-summary', type=Path, required=True)
    a = p.parse_args()
    if a.bind_log:
        if not a.timing_summary:
            p.error('--timing-summary required for native clock-root verification')
        bind(a.output, a.bind_log, a.project, a.timing_summary)
        return
    manifest_path = a.project / ('application.json' if (a.project / 'application.json').exists() else 'benchmark.json')
    manifest = json.loads(manifest_path.read_text())
    spec = specification(manifest['config'])
    spec['schema'] = 3
    spec['input_manifest'] = manifest_path.name
    spec['input_manifest_sha256'] = sha(manifest_path)
    spec['clock_network_sha256'] = sha(a.project / 'prj_tasks/syn_1/synthesize/report_db/synthesize_report_clock_network.db')
    result, _ = load_inputs(a.project, a.timing_summary, spec)
    a.output.mkdir(parents=True, exist_ok=False)
    audit, _ = generate(spec, result['pins'])
    (a.output / 'audit.tcl').write_text(audit)
    (a.output / 'spec.json').write_text(json.dumps(spec, indent=2)+'\n')
    print('Prepared native CDC name queries; no constraints applied')


if __name__ == '__main__':
    main()
