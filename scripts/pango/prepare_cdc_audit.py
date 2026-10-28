#!/usr/bin/env python3
"""Prepare an object/domain audit before applying bounded FIFO CDC constraints.

Run audit.tcl inside the synthesized PDS design. bind() only publishes constraints
after all pointer bits and synchronizer clock domains pass that native audit.
Ordinary logic, second synchronizer stages, PHY paths and resets are not excepted.
"""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re

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
                          constant_payload=path.endswith('u_flash.u_ack')))
    if config.get('npu_enable'):
        for channel in ('aw', 'w', 'ar', 'b', 'r'):
            reverse = channel in ('b', 'r')
            fifos.append(dict(path=f'g_npu.u_target.u_cdc.u_{channel}', bits=3,
                              src='npu' if reverse else 'sys', dst='sys' if reverse else 'npu',
                              prunable=False, constant_payload=False))
    clocks = {d: 'ddrphy_sysclk' if d == 'ddr' else f'clk_{d}' for d in domains}
    levels = [dict(path=root, signal='irq_sync1_q', bits=[0, 1, 2], src='periph', dst='core')]
    if 'ddr' in domains:
        levels += [dict(path=root, signal=signal, bits=[0], src='ddr', dst=dst)
                   for signal, dst in (('ddr_system_online_q', 'sys'), ('ddr_online_q', 'periph'))]
    return dict(schema=1, platform=config['platform'], clocks=clocks,
                periods_ns={d: str(p) for d, p in periods.items()}, fifos=fifos, levels=levels,
                policy='first-stage Gray and stable FIFO payload only; no clock groups or false paths',
                payload_budget='minimum of source/destination period; pointer visibility takes at least two receiving edges',
                hold_policy='datapath_only replaces setup and hold only for the explicitly bounded CDC paths')


PROCEDURES = r'''
proc cdc_names {objects} {
    if {[llength [info commands get_object_name]]} {set objects [get_object_name $objects]}
    set names {}
    foreach object $objects {
        regsub {^[tcp]:} $object {} name
        lappend names $name
    }
    return [lsort -unique $names]
}
proc cdc_query {pattern} {
    set names [cdc_names [get_pins -hierarchical -regexp $pattern]]
    foreach name $names {
        if {![regexp -- $pattern $name]} {error "CDC unexpected object $name for $pattern"}
    }
    return $names
}
proc cdc_domain {names domain kind label} {
    global cdc_domain_pins
    foreach name $names {
        if {[lsearch -exact $cdc_domain_pins($domain,$kind) $name] < 0} {
            error "CDC domain mismatch $label $name expected=$domain/$kind"
        }
    }
}
proc cdc_bits {names pattern bits label} {
    set actual {}
    foreach name $names {
        if {![regexp -- $pattern $name unused bit]} {error "CDC bit name $name"}
        lappend actual $bit
    }
    set expected {}; for {set n 0} {$n < $bits} {incr n} {lappend expected $n}
    if {[lsort -integer $actual] ne $expected} {error "CDC missing/duplicate bits $label $actual expected=$expected"}
}
proc cdc_pointer {label src dst bits patterns} {
    lassign $patterns source_ck source_q first_d first_ck second_d second_ck
    foreach pattern $patterns kind {clock output data clock data clock} domain [list $src $src $dst $dst $dst $dst] {
        set names [cdc_query $pattern]
        cdc_bits $names $pattern $bits $label
        cdc_domain $names $domain $kind $label
        puts "CDC_BOUND $label $domain/$kind $names"
    }
}
'''


def pins(pattern):
    return f'[get_pins -hierarchical -regexp {{{pattern}}}]'


def generate(spec):
    audit = [PROCEDURES]
    constraints = ['# Native-bound FIFO CDC budgets; do not change the clock periods to claim closure.']
    for domain, clock in spec['clocks'].items():
        for kind in ('clock', 'data', 'output'):
            audit += [f'set cdc_domain_pins({domain},{kind}) [cdc_names [all_registers -clock {clock} -{kind}_pins]]',
                      f'if {{![llength $cdc_domain_pins({domain},{kind})]}} {{error "CDC empty domain {domain}/{kind}"}}']
    for index, fifo in enumerate(spec['fifos']):
        path, src, dst, bits = (fifo[k] for k in ('path', 'src', 'dst', 'bits'))
        budget = min(Decimal(spec['periods_ns'][src]), Decimal(spec['periods_ns'][dst]))
        scope = f'^{_path_pattern(path)}[./].*[./](?:CLK|WCLK)$'
        audit.append(f'set cdc_scope [cdc_query {{{scope}}}]')
        audit.append(f'if {{[llength $cdc_scope] == 0 && {int(fifo["prunable"])}}} {{')
        audit.append(f'    puts {{CDC_PRUNED {index} {path}}}\n}} else {{')
        local_constraints = []
        for direction, a, b in (('write', src, dst), ('read', dst, src)):
            patterns = [_register_pattern(path, name, pin) for name, pin in (
                (f'{direction}_gray_q', 'CLK'), (f'{direction}_gray_q', 'Q'),
                (f'{direction}_sync1_q', 'D'), (f'{direction}_sync1_q', 'CLK'),
                (f'{direction}_sync2_q', 'D'), (f'{direction}_sync2_q', 'CLK'))]
            audit.append(f'    cdc_pointer {{{path}/{direction}}} {a} {b} {bits} '
                         '{' + ' '.join('{' + p + '}' for p in patterns) + '}')
            local_constraints += [
                f'set_max_delay {budget} -datapath_only -from {pins(patterns[0])} -to {pins(patterns[2])}',
                f'set_max_skew {budget} -from {pins(patterns[0])} -to {pins(patterns[2])}']
        payload = f'^{_path_pattern(path)}[./]payload[^/]*[./](?:WCLK|CLK)$'
        audit += [f'    set cdc_payload [cdc_query {{{payload}}}]',
                  f'    cdc_domain $cdc_payload {src} clock {{{path}/payload}}',
                  f'    if {{![llength $cdc_payload] && !{int(fifo["constant_payload"])}}} {{error {{CDC missing payload {path}}}}}',
                  f'    puts "CDC_PAYLOAD {index} $cdc_payload"',
                  f'    puts {{CDC_FIFO_PASS {index} {path}}}', '}']
        # Destination data pins exclude the source clock domain explicitly. Read-address,
        # empty/full logic and all second-stage synchronizer paths retain ordinary timing.
        local_constraints.append(f'set_max_delay {budget} -datapath_only -from {pins(payload)} '
                                 f'-to [all_registers -clock {spec["clocks"][dst]} -data_pins]')
        constraints.append(dict(index=index, lines=local_constraints))
    for level in spec['levels']:
        budget = min(Decimal(spec['periods_ns'][level['src']]), Decimal(spec['periods_ns'][level['dst']]))
        for bit in level['bits']:
            p = _register_pattern(level['path'], level['signal'], 'D', bit)
            audit += [f'set cdc_level [cdc_query {{{p}}}]',
                      'if {[llength $cdc_level] != 1} {error "CDC level endpoint count"}',
                      f'cdc_domain $cdc_level {level["dst"]} data {{level {level["signal"]}}}']
            constraints.append(f'set_max_delay {budget} -datapath_only '
                               f'-from [all_registers -clock {spec["clocks"][level["src"]]} -clock_pins] -to {pins(p)}')
    audit += ['puts "CDC_AUDIT_PASS"']
    return '\n'.join(audit) + '\n', constraints


def bind(directory, log):
    text = log.read_text(errors='replace')
    spec = json.loads((directory / 'spec.json').read_text())
    if not re.search(r'^CDC_AUDIT_PASS\s*$', text, re.M):
        raise ValueError('native CDC audit did not complete')
    if re.search(r'^(?:E:|ERROR:|CDC domain mismatch)', text, re.M):
        raise ValueError('native CDC audit contains errors')
    passed = {int(i) for i in re.findall(r'^CDC_FIFO_PASS (\d+) ', text, re.M)}
    pruned = {int(i) for i in re.findall(r'^CDC_PRUNED (\d+) ', text, re.M)}
    if passed & pruned or passed | pruned != set(range(len(spec['fifos']))):
        raise ValueError('native FIFO audit coverage incomplete')
    _, rows = generate(spec)
    lines = []
    for row in rows:
        if isinstance(row, str):
            lines.append(row)
        elif row['index'] in passed:
            payload = re.search(rf'^CDC_PAYLOAD {row["index"]} (.*)$', text, re.M)
            if payload is None:
                raise ValueError('payload binding evidence missing')
            lines += row['lines'] if payload[1].strip() else row['lines'][:-1]
    with (directory / 'bound_cdc.fdc').open('x') as f:
        f.write('\n'.join(lines) + '\n')
    (directory / 'binding.json').write_text(json.dumps(dict(
        log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
        passed_fifos=sorted(passed), pruned_fifos=sorted(pruned),
        status='object/domain binding passed; exception effectiveness and physical CDC timing still require reports'), indent=2)+'\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', type=Path)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--bind-log', type=Path)
    a = p.parse_args()
    if a.bind_log:
        bind(a.output, a.bind_log)
        return
    if a.project is None:
        p.error('--project required to generate an audit')
    manifest_path = a.project / ('application.json' if (a.project / 'application.json').exists() else 'benchmark.json')
    manifest = json.loads(manifest_path.read_text())
    spec = specification(manifest['config'])
    spec['input_manifest'] = manifest_path.name
    spec['input_manifest_sha256'] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    a.output.mkdir(parents=True, exist_ok=False)
    audit, _ = generate(spec)
    (a.output / 'audit.tcl').write_text(audit)
    (a.output / 'spec.json').write_text(json.dumps(spec, indent=2)+'\n')
    print('Prepared native CDC audit; no constraints applied')


if __name__ == '__main__':
    main()
