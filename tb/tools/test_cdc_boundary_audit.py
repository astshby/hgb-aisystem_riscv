#!/usr/bin/env python3
"""Exercise native-audit Tcl with a small named sequential-netlist fixture."""
import json
import ctypes
import ctypes.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'scripts/pango')]
from benchmark_config import configuration
from prepare_cdc_audit import specification, generate, bind


def fixture(spec, missing=False, wrong_domain=False, wrong_second=False):
    pins = []
    domains = {(d, k): [] for d in spec['clocks'] for k in ('clock', 'data', 'output')}

    def register(path, clock):
        for kind, suffix in (('clock', 'CLK'), ('data', 'D'), ('output', 'Q')):
            name = path + '/' + suffix
            pins.append(name)
            domains[clock, kind].append(name)

    for domain in spec['clocks']:
        register(f'ordinary/{domain}', domain)
    changed = False
    for f in spec['fifos']:
        if f['prunable']:
            continue
        base = f['path'].replace('.', '/')
        for direction, src, dst in (('write', f['src'], f['dst']), ('read', f['dst'], f['src'])):
            for bit in range(f['bits']):
                register(f'{base}/{direction}_gray_q[{bit}]', src)
                if not changed and (missing or wrong_domain):
                    if wrong_domain:
                        register(f'{base}/{direction}_sync1_q[{bit}]', src)
                    changed = True
                else:
                    register(f'{base}/{direction}_sync1_q[{bit}]', dst)
                register(f'{base}/{direction}_sync2_q[{bit}]', dst)
        if not f['constant_payload']:
            register(f'{base}/payload[0][0]', f['src'])
    for level in spec['levels']:
        for bit in level['bits']:
            register(f'{level["path"].replace(".", "/")}/{level["signal"]}[{bit}]', level['dst'])
        for bit in level['second_bits']:
            register(f'{level["path"].replace(".", "/")}/{level["second_signal"]}[{bit}]',
                     level['src'] if wrong_second else level['dst'])
    lines = ['set fixture_pins {' + ' '.join('{' + p + '}' for p in pins) + '}']
    for (domain, kind), names in domains.items():
        lines.append(f'set fixture_domain({spec["clocks"][domain]},{kind}_pins) {{' +
                     ' '.join('{t:' + n + '}' for n in names) + '}')
    return '\n'.join(lines) + r'''
proc get_pins {args} {
    global fixture_pins
    set pattern [lindex $args end]; set result {}
    foreach name $fixture_pins {
        if {[regexp -- $pattern $name]} {lappend result t:$name}
    }
    return $result
}
proc all_registers {args} {
    global fixture_domain
    return $fixture_domain([lindex $args 1],[string trimleft [lindex $args 2] -])
}
'''


class CdcAuditTests(unittest.TestCase):
    def test_success_and_missing_bit_or_wrong_domain(self):
        for platform in ('soc_tcm', 'soc_ddr', 'soc_ddr_yolo'):
            config = configuration('soc_ddr' if platform == 'soc_ddr_yolo' else platform)
            if platform == 'soc_ddr_yolo':
                config = dict(config, domains=[*config['domains'], 'npu'], npu_enable=1,
                              periods_ps=dict(config['periods_ps'], npu=10000))
            spec = specification(config)
            audit, _ = generate(spec)
            for missing, wrong, second in ((False, False, False), (True, False, False),
                                           (False, True, False), (False, False, True)):
                with self.subTest(platform=platform, missing=missing, wrong=wrong, second=second):
                    with tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary)
                        script = root / 'audit.tcl'
                        script.write_text(fixture(spec, missing, wrong, second) + audit)
                        result = subprocess.run([sys.executable, __file__, '--tcl-fixture', str(script)],
                                                text=True, capture_output=True)
                        self.assertEqual(result.returncode == 0, not (missing or wrong or second), result.stderr)
                        if result.returncode:
                            self.assertNotIn('CDC_AUDIT_PASS', result.stdout)
                            continue
                        (root / 'spec.json').write_text(json.dumps(spec))
                        log = root / 'audit.log'; log.write_text(result.stdout)
                        bind(root, log)
                        fdc = (root / 'bound_cdc.fdc').read_text()
                        self.assertNotIn('set_false_path', fdc)
                        self.assertNotIn('sync2_q', fdc)
                        self.assertNotIn('g_cpu_master\\[0\\][./]u_cdc[./]u_aw', fdc)
                        self.assertIn('set_max_skew', fdc)
                        lcf = (root / 'bound_sync.lcf').read_text()
                        self.assertIn('irq_sync2_q', lcf)
                        self.assertNotIn('gray_q', lcf)

    def test_incomplete_native_log_does_not_publish(self):
        spec = specification(configuration('soc_ddr'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'spec.json').write_text(json.dumps(spec))
            log = root / 'audit.log'; log.write_text('CDC_AUDIT_PASS\n')
            with self.assertRaisesRegex(ValueError, 'coverage'):
                bind(root, log)
            self.assertFalse((root / 'bound_cdc.fdc').exists())


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--tcl-fixture':
        # WSL提供libtcl8.6但没有tclsh入口，直接调用同一解释器；不安装系统软件。
        tcl = ctypes.CDLL(ctypes.util.find_library('tcl8.6'))
        tcl.Tcl_CreateInterp.restype = ctypes.c_void_p
        tcl.Tcl_Init.argtypes = [ctypes.c_void_p]
        tcl.Tcl_EvalFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        tcl.Tcl_GetStringResult.argtypes = [ctypes.c_void_p]
        tcl.Tcl_GetStringResult.restype = ctypes.c_char_p
        tcl.Tcl_DeleteInterp.argtypes = [ctypes.c_void_p]
        interp = tcl.Tcl_CreateInterp()
        result = tcl.Tcl_Init(interp)
        if result == 0:
            result = tcl.Tcl_EvalFile(interp, str(Path(sys.argv[2]).resolve()).encode())
        if result:
            print(tcl.Tcl_GetStringResult(interp).decode(), file=sys.stderr)
        tcl.Tcl_DeleteInterp(interp)
        raise SystemExit(result)
    else:
        unittest.main()
