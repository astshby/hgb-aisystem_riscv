"""Check exact release PLL ratios, runtime clocks and unchanged historical profiles."""
from fractions import Fraction
from pathlib import Path
import hashlib
import json
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts'), str(ROOT / 'scripts/pango')]
from hardware_config import PROFILE, clock_periods, hardware_configuration
from benchmark_config import configuration
from prepare_project import (BOARD_CLOCK_PROFILES, BOARD_CLOCK_RATIOS, BOARD_PLL_PARAMETERS,
                             DEFAULT_SCOREBOARD_CONFIGURATION, board_clock_constraints,
                             board_clock_hz, board_clock_relationship, project_configuration,
                             verify_independent_board_clocks, verify_staged_manifest,
                             synthesis_commands, implementation_commands)
from measurement_constraints import generate
from tb.tools import test_pango_handoff as handoff_fixture


class ReleaseClocksTest(unittest.TestCase):
    def test_exact_native_ratios_and_runtime_integer_hz(self):
        for profile, name in ((9, 'main_margin2'), (10, 'yolo_sys')):
            with self.subTest(profile=profile):
                pll = PROFILE['pll_profiles'][name]
                self.assertEqual(pll, BOARD_PLL_PARAMETERS[profile])
                vco = Fraction(pll['reference_hz'] * pll['multiply'] * pll['feedback_div'], pll['input_div'])
                self.assertTrue(600000000 <= vco <= 1200000000)
                self.assertTrue(10000000 <= Fraction(pll['reference_hz'], pll['input_div']) <= 40000000)
                periods = clock_periods(name, True)
                for domain, divider in pll['output_div'].items():
                    ratio = Fraction(vco, divider * 125000000)
                    self.assertEqual(BOARD_CLOCK_RATIOS[profile][domain], (ratio.numerator, ratio.denominator))
                    self.assertAlmostEqual(periods[domain], float(Fraction(10**12) * divider / vco), places=9)
                    self.assertEqual(board_clock_hz(profile, domain), round(vco / divider))
                self.assertEqual(periods['ddr'], 8000)

    def test_selected_application_clocks_and_explicit_npu_sweeps(self):
        for width in (32, 64):
            main = hardware_configuration('none', width)
            yolo = hardware_configuration('yolo', width)
            self.assertEqual((main['clock'], main['board_clock_profile']), ('main_margin2', 9))
            self.assertEqual((yolo['clock'], yolo['board_clock_profile']), ('yolo_sys', 10))
            self.assertNotIn('npu', main['periods_ps'])
            self.assertEqual(yolo['frequencies_hz']['npu'], 92187500)
            self.assertAlmostEqual(yolo['periods_ps']['npu'], 640000000.0 / 59000.0)
            self.assertEqual(hardware_configuration('yolo', width, clock='npu80')['frequencies_hz']['npu'], 80000000)
            self.assertEqual(hardware_configuration('yolo', width, clock='npu125')['frequencies_hz']['npu'], 125000000)

    def test_board_register_metadata_and_constraints_match(self):
        wrapper = (ROOT / 'vsrc/cpu/pango_200hp_top.sv').read_text()
        for profile, name in ((9, 'main_margin2'), (10, 'yolo_sys')):
            verify_independent_board_clocks(wrapper, profile)
            bad = wrapper.replace('83806818', '83806819', 1)
            with self.assertRaisesRegex(ValueError, 'HOT_HZ'):
                verify_independent_board_clocks(bad, profile)
            fdc = board_clock_constraints(profile, npu_enable=True)
            for domain, (multiply, divide) in BOARD_CLOCK_RATIOS[profile].items():
                line = next(row for row in fdc.splitlines() if f'-name {{clk_{domain}}}' in row)
                self.assertIn(f'-multiply_by {{{multiply}}} -divide_by {{{divide}}}', line)
            self.assertNotIn('set_false_path', fdc)
            self.assertNotIn('set_clock_groups', fdc)
            self.assertIn(str(BOARD_CLOCK_PROFILES[profile]['core']), wrapper)

    def test_native_project_periods_do_not_round_back_from_integer_hz(self):
        for profile, name in ((9, 'main_margin2'), (10, 'yolo_sys')):
            clocks = {d: board_clock_hz(profile, d) for d in ('core', 'sys', 'ddr', 'periph', 'npu')}
            manifest = dict(DEFAULT_SCOREBOARD_CONFIGURATION, schema_version=9, soc_topology='soc_system',
                            board_clock_profile=profile, board_clock_domains_hz=clocks, xlen=32,
                            icache_bytes=16384, dcache_bytes=8192, top='pango_200hp_top')
            native = project_configuration(manifest)
            self.assertEqual(native['clock'], name)
            self.assertEqual(native['periods_ps'], clock_periods(name, True))
            self.assertNotEqual(native['periods_ps']['sys'], 10**12 / clocks['sys'])
            self.assertIn(str(float(Fraction(125000000 * BOARD_PLL_PARAMETERS[profile]['multiply'] *
                                            BOARD_PLL_PARAMETERS[profile]['feedback_div'],
                                            BOARD_PLL_PARAMETERS[profile]['input_div'])) / 1000000),
                          board_clock_relationship(profile))

    def test_layered_benchmarks_use_exact_same_profile(self):
        for width in (32, 64):
            for name in ('main_margin2', 'yolo_sys'):
                for platform in ('core_tcm', 'soc_tcm', 'soc_ddr'):
                    config = configuration(platform, name, width, 16384, 8192, 2)
                    self.assertEqual(config['periods_ps'], clock_periods(name))
                    self.assertEqual(config['native_board_profile'], PROFILE['native_board_profiles'][name])

    def test_diagnostic_constraints_keep_exact_fraction_periods(self):
        for profile, numerator, denominator in (('C9', 720, 71), ('C10', 576, 59)):
            text = generate(2, profile)['measurement.fdc']
            line = next(row for row in text.splitlines() if '-name {clk_sys}' in row)
            period = Fraction(line.split('-period ', 1)[1].split()[0])
            self.assertLess(abs(float(period) - numerator / denominator), 1e-12)

    def test_historical_profiles_and_npu_100_are_preserved(self):
        self.assertEqual(PROFILE['clock_periods_ps']['main60'],
                         dict(core=10000, sys=10000, ddr=8000, periph=1000000 / 60))
        for profile in (1, 4, 5, 6, 7, 8):
            self.assertEqual(board_clock_hz(profile, 'npu'), 100000000)
        self.assertEqual(board_clock_relationship(1), 'independent_gpll_800mhz_vco')
        self.assertEqual(board_clock_relationship(8), 'independent_gpll_900mhz_vco')

    def test_timing_v2_is_independent_of_default_and_v3(self):
        self.assertIn('-fanout_guide 64 -retiming', synthesis_commands('timing-v2'))
        self.assertIn('-fanout_guide 128 -retiming', synthesis_commands('timing-v3'))
        self.assertNotIn('fanout_guide', synthesis_commands())
        for name in ('implement.tcl', 'implement_cdc.tcl'):
            template = (ROOT / 'scripts/pango' / name).read_text()
            self.assertEqual(implementation_commands(template), template)
            self.assertEqual(implementation_commands(template, 'timing-v3'), template)
            v2 = implementation_commands(template, 'timing-v2')
            self.assertIn('-slack_weight 80', v2)
            self.assertNotIn('-slack_weight 90', v2)
            self.assertEqual(v2.replace('-slack_weight 80', '-slack_weight 90'), template)

    def test_both_widths_stage_new_clock_and_64_80_policy(self):
        fixture = handoff_fixture.HandoffTests(methodName='test_default_entry_selects_measured_core_and_four_clocks')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        shutil.copyfile(ROOT / 'vsrc/cpu/pango_200hp_top.sv', fixture.repo / 'vsrc/cpu/pango_200hp_top.sv')
        for width in (32, 64):
            for profile in (9, 10):
                with self.subTest(width=width, profile=profile):
                    output, _ = fixture.stage(width=width, backend='scoreboard', clock=profile,
                                               output=fixture.root / f'release-rv{width}-c{profile}',
                                               extra=('--synthesis-strategy', 'timing-v2'))
                    manifest = json.loads((output / 'manifest.json').read_text())
                    verify_staged_manifest(output, manifest)
                    self.assertEqual(manifest['clock_relationship'], board_clock_relationship(profile))
                    self.assertEqual(project_configuration(manifest)['periods_ps'],
                                     clock_periods('main_margin2' if profile == 9 else 'yolo_sys'))
                    self.assertIn('-fanout_guide 64', (output / 'synthesize.tcl').read_text())
                    for name in ('implement.tcl', 'implement_cdc.tcl'):
                        text = (output / name).read_text()
                        self.assertIn('-slack_weight 80', text)
                        self.assertNotIn('-slack_weight 90', text)
                    path = output / 'implement_cdc.tcl'
                    path.write_text(path.read_text().replace('-slack_weight 80', '-slack_weight 90'))
                    manifest['files']['implement_cdc.tcl'] = hashlib.sha256(path.read_bytes()).hexdigest()
                    with self.assertRaisesRegex(ValueError, 'timing-v2 implementation'):
                        verify_staged_manifest(output, manifest)


if __name__ == '__main__':
    unittest.main()
