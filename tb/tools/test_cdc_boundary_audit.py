#!/usr/bin/env python3
"""Check native-log parsing, synthesized clock tracing and CDC fault rejection."""
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'scripts/pango')]
from benchmark_config import configuration
from netlist_clock_audit import ClockNetlist
from prepare_cdc_audit import specification, generate, parse_native_queries, audit_objects, read_clock_sources

PRESERVE = '(* PAP_PRESERVE="TRUE", PAP_ASYNC_REG="TRUE", PAP_ALLOW_RETIMING="FALSE" *)'


def fixture(spec, fault=None, include_prunable=False):
    pins, cells, crossings = set(), [], []
    changed = False

    def register(name, domain, protected=True):
        name = name.replace('.', '/')
        cells.append(f'{PRESERVE if protected else ""} GTP_DFF_C #(.INIT(1\'b0)) \\{name} '
                     f'(.CLK(clk_{domain}), .D(1\'b0), .Q(q));')
        for pin in ('CLK', 'D', 'Q'):
            pins.add(name + '/' + pin)

    for f in spec['fifos']:
        if f['prunable'] and not include_prunable:
            continue
        for direction, src, dst in (('write', f['src'], f['dst']), ('read', f['dst'], f['src'])):
            for bit in range(f['bits']):
                register(f'{f["path"]}/{direction}_gray_q[{bit}]', src)
                first = f'{f["path"]}/{direction}_sync1_q[{bit}]'
                if not changed and fault in ('missing', 'wrong_first', 'unprotected'):
                    changed = True
                    if fault != 'missing':
                        register(first, src if fault == 'wrong_first' else dst, fault != 'unprotected')
                else:
                    register(first, dst)
                register(f'{f["path"]}/{direction}_sync2_q[{bit}]',
                         src if fault == 'wrong_second' else dst)
        if not f['constant_payload']:
            register(f'{f["path"]}/payload[0][0]', f['dst'] if fault == 'payload_clock' else f['src'])
            register(f'{f["path"]}/consumer_q', f['dst'])
            crossings.append(dict(source=f'{f["path"]}/payload[0][0]/CLK'.replace('.', '/'),
                                  destination=f'{f["path"]}/consumer_q/D'.replace('.', '/'),
                                  source_clock=spec['clocks'][f['src']], destination_clock=spec['clocks'][f['dst']]))
    for level in spec['levels']:
        for signal, bits in ((level['signal'], level['bits']), (level['second_signal'], level['second_bits'])):
            for bit in bits:
                register(f'{level["path"]}/{signal}[{bit}]', level['dst'])
        for bit in level['bits']:
            source = f'{level["path"]}/{level["signal"]}_source{bit}'
            register(source, level['src'])
            crossings.append(dict(source=(source+'/CLK').replace('.', '/'),
                                  destination=f'{level["path"]}/{level["signal"]}[{bit}]/D'.replace('.', '/'),
                                  source_clock=spec['clocks'][level['src']], destination_clock=spec['clocks'][level['dst']]))
    if fault == 'unknown_fifo':
        register('unreviewed/write_gray_q[0]', 'core')
    header = ', '.join('input clk_' + d for d in spec['clocks'])
    vm = 'module top (' + header + ');\n' + '\n'.join(cells) + '\nendmodule\n'
    clocks = [dict(**{'Clock Name': clock, 'Period': spec['periods_ns'][domain],
                     'Targets': '{ clk_' + domain + ' }'}) for domain, clock in spec['clocks'].items()]
    sources = {d: sorted({r['source'] for r in crossings if r['source_clock'] == spec['clocks'][d] and '_source' in r['source']}) for d in spec['clocks']}
    return vm, clocks, pins, sources


def native_log(spec, names):
    lines = []
    for index, group in generate(spec, names)[1].items():
        command = 'get_pins {' + ' '.join(group) + '}'
        lines += [f'CDC_QUERY {index}', 'Executing : ' + command,
                  'Executing : ' + command + ' successfully.']
    return '\n'.join(lines + ['CDC_QUERY_COMPLETE']) + '\n'



class CdcAuditTests(unittest.TestCase):
    def specs(self):
        for platform in ('soc_tcm', 'soc_ddr', 'soc_ddr_yolo'):
            config = configuration('soc_ddr' if platform.endswith('yolo') else platform)
            if platform.endswith('yolo'):
                config = dict(config, domains=[*config['domains'], 'npu'], npu_enable=1,
                              periods_ps=dict(config['periods_ps'], npu=10000))
            yield specification(config)

    def test_three_platforms_and_functional_faults(self):
        for spec in self.specs():
            for fault in (None, 'missing', 'wrong_first', 'wrong_second', 'unprotected', 'payload_clock', 'unknown_fifo'):
                with self.subTest(platform=spec['platform'], fault=fault):
                    vm, clocks, names, crossings = fixture(spec, fault)
                    netlist = ClockNetlist(vm, 'top', clocks, spec)
                    if fault:
                        with self.assertRaises(ValueError):
                            audit_objects(spec, names, netlist, crossings)
                    else:
                        result, fdc = audit_objects(spec, names, netlist, crossings)
                        self.assertEqual(parse_native_queries(native_log(spec, result['pins']), spec, result['pins']), set(result['pins']))
                        self.assertNotIn('set_false_path', fdc)
                        self.assertNotIn('set_clock_groups', fdc)
                        self.assertIn('-through', fdc)
                        self.assertNotIn('sync2_q', fdc)
                        self.assertIn('set_max_skew', fdc)
                        self.assertIn('irq_sync2_q', ' '.join(result['synchronizer_registers']))
                        self.assertEqual(len(result['passed_fifos']) + len(result['pruned_fifos']), len(spec['fifos']))

    def test_native_log_errors_counts_and_deferred_handles(self):
        spec = next(self.specs())
        vm, clocks, names, crossings = fixture(spec)
        result, _ = audit_objects(spec, names, ClockNetlist(vm, 'top', clocks, spec), crossings)
        names = result['pins']
        log = native_log(spec, names)
        corrupt = [log.replace('CDC_QUERY_COMPLETE', ''), log + '\nE: query failed\n',
                   log + '\nC: Timing-4003: Pin not found\n',
                   log.replace(' successfully.', ' BROKEN successfully.', 1),
                   log.replace('Executing : get_pins {', 'Executing : get_pins {@tcicmdresult ')]
        for text in corrupt:
            with self.subTest(text=text[-100:]), self.assertRaises(ValueError):
                parse_native_queries(text, spec, names)

    def test_native_clock_tree_tracks_generated_clocks_and_scope(self):
        spec = next(self.specs())
        xml = """<tables><table><row><data>ref (50.00MHZ)</data>
+<row><data>clk_periph (25.00MHZ)</data><row><data>periph_a/CLK (1.0)</data></row>
+<row><data>clk_core (100.00MHZ)</data><row><data>core_a/CLK (2.0)</data></row></row>
+<row><data>periph_b/CLK (1.2)</data></row></row></row></table></tables>""".replace('\n+', '\n')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'clock.db'
            path.write_text(xml)
            sources = read_clock_sources(path, spec)
            self.assertEqual(sources['periph'], ['periph_a/CLK', 'periph_b/CLK'])
            self.assertEqual(sources['core'], ['core_a/CLK'])
            path.write_text(xml.replace('clk_periph', 'unknown'))
            with self.assertRaises(ValueError):
                read_clock_sources(path, spec)

    def test_clock_trace_uses_wiring_and_distinguishes_equal_period_domains(self):
        spec = dict(clocks={'core': 'clk_core', 'sys': 'clk_sys'}, periods_ns={'core': '10', 'sys': '10'})
        vm = r'''
module child(input misleading_sys_name);
 (* PAP_PRESERVE="TRUE", PAP_ALLOW_RETIMING="FALSE" *) GTP_DFF_C \q[0]  (.CLK(misleading_sys_name),.D(1'b0),.Q());
endmodule
module top(input ref);
 wire a, b, buffered;
 GTP_GPLL pll (.CLKIN1(ref),.CLKOUT0(a),.CLKOUT1(b));
 GTP_CLKBUFG buffer (.CLKIN(a),.CLKOUT(buffered));
 child u_child (.misleading_sys_name(buffered));
endmodule
'''
        clocks = [{'Clock Name': 'clk_core', 'Period': '10', 'Targets': '{ pll/CLKOUT0 }'},
                  {'Clock Name': 'clk_sys', 'Period': '10', 'Targets': '{ pll/CLKOUT1 }'}]
        n = ClockNetlist(vm, 'top', clocks, spec)
        self.assertEqual(n.domain('u_child/q[0]/D')[0], 'core')
        other = ClockNetlist(vm.replace('.CLKIN(a)', '.CLKIN(b)'), 'top', clocks, spec)
        self.assertEqual(other.domain('u_child/q[0]/D')[0], 'sys')
        with self.assertRaises(ValueError):
            ClockNetlist(vm, 'top', [dict(clocks[0], Period='9'), clocks[1]], spec)
        gated = ClockNetlist(vm.replace('GTP_CLKBUFG buffer (.CLKIN(a),.CLKOUT(buffered));',
                                       'GTP_LUT2 gate (.I0(a),.Z(buffered));'), 'top', clocks, spec)
        with self.assertRaises(ValueError):
            gated.domain('u_child/q[0]/CLK')

    def test_native_vm_name_collision_requires_matching_output(self):
        spec = dict(clocks={'core': 'clk_core'}, periods_ns={'core': '10'})
        clocks = [{'Clock Name': 'clk_core', 'Period': '10', 'Targets': '{ clk }'}]
        vm = '''module top(input clk);
 GTP_DFF active_q_vname (.CLK(clk),.D(1'b0),.Q(active_q));
endmodule
'''
        netlist = ClockNetlist(vm, 'top', clocks, spec)
        self.assertEqual(netlist.domain('active_q/D')[0], 'core')
        self.assertEqual(netlist.native_aliases, {'active_q': 'active_q_vname'})
        with self.assertRaises(ValueError):
            ClockNetlist(vm.replace('.Q(active_q)', '.Q(unrelated)'), 'top', clocks, spec).domain('active_q/D')

    def test_only_known_unused_receivers_may_be_completely_pruned(self):
        spec = next(self.specs())
        vm, clocks, names, crossings = fixture(spec, include_prunable=True)
        for fifo in (next(f for f in spec['fifos'] if f['prunable']),
                     next(f for f in spec['fifos'] if not f['prunable'])):
            prefix = fifo['path'].replace('.', '/') + '/read_sync'
            for partial in (False, True):
                def removed(name):
                    return name.startswith(prefix) and (not partial or 'sync1_q[0]' in name)
                reduced_names = {name for name in names if not removed(name)}
                reduced_vm = '\n'.join(line for line in vm.splitlines()
                                       if not any(removed(n) and ('\\' + n.rsplit('/', 1)[0] + ' ') in line
                                                  for n in names))
                netlist = ClockNetlist(reduced_vm, 'top', clocks, spec)
                with self.subTest(fifo=fifo['path'], partial=partial):
                    if fifo['prunable'] and not partial:
                        result, fdc = audit_objects(spec, reduced_names, netlist, crossings)
                        self.assertIn(fifo['path'] + '/read', result['pruned_receivers'])
                        self.assertNotIn(prefix, fdc)
                    else:
                        with self.assertRaises(ValueError):
                            audit_objects(spec, reduced_names, netlist, crossings)

    def test_hierarchical_output_and_encrypted_clock_witness(self):
        spec = dict(clocks={'ddr': 'ddrphy_sysclk'}, periods_ns={'ddr': '8'})
        vm = '''
(* PAP_HIER="hard" *)module pll_wrapper(input ref, output clock);
 GTP_GPLL u_pll (.CLKIN1(ref),.CLKOUT0(clock));
endmodule
module top(input ref);
 wire buffered, pll_clock;
 pll_wrapper pll (.ref(ref),.clock(pll_clock));
 GTP_CLKBUFG buffer (.CLKIN(pll_clock),.CLKOUT(buffered));
 GTP_DFF_C q (.CLK(buffered),.D(1'b0),.Q());
endmodule
'''
        rows = [{'Clock Name': 'ddrphy_sysclk', 'Period': '8', 'Targets': '{ pll/u_pll/CLKOUT0 }'}]
        self.assertEqual(ClockNetlist(vm, 'top', rows, spec).domain('q/CLK')[0], 'ddr')
        encrypted = vm.replace(' GTP_GPLL u_pll (.CLKIN1(ref),.CLKOUT0(clock));',
                               '`pragma protect begin_protected\n`pragma protect end_protected')
        with self.assertRaises(ValueError):
            ClockNetlist(encrypted, 'top', rows, spec).domain('q/CLK')
        witness = {'Launch Clock': 'ddrphy_sysclk', 'Capture Clock': 'ddrphy_sysclk',
                   'Start Point': 'q/CLK', 'logical_resources': [
                       'pll/u_pll/CLKOUT0', 'pll_clock', 'buffer/CLKIN',
                       'buffer/CLKOUT', 'buffered', 'q/CLK', 'unrelated_data_net']}
        netlist = ClockNetlist(encrypted, 'top', rows, spec, {'ddrphy_sysclk': witness})
        self.assertEqual(netlist.domain('q/CLK')[0], 'ddr')
        self.assertNotIn('unrelated_data_net', netlist.reported_clock_nets)
        with self.assertRaises(ValueError):
            ClockNetlist(encrypted, 'top', rows, spec,
                         {'ddrphy_sysclk': dict(witness, **{'Capture Clock': 'clk_sys'})})
        unrelated = dict(witness, logical_resources=['unrelated_pll/CLKOUT0', 'buffered', 'q/CLK'])
        with self.assertRaises(ValueError):
            ClockNetlist(encrypted, 'top', rows, spec, {'ddrphy_sysclk': unrelated}).domain('q/CLK')


if __name__ == '__main__':
    unittest.main()
