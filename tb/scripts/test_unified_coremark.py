"""Clock normalization and simulation/synthesis pairing regressions."""
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'scripts'),str(ROOT/'scripts/pango'),str(ROOT/'scripts/verilator')]
from benchmark_config import CONFIG, configuration, score
from prepare_benchmark import compile_tcm, constraints
import run_p2_coremark as p2


class UnifiedCoreMarkTest(unittest.TestCase):
    def test_three_platform_domains(self):
        self.assertEqual(configuration('core_tcm')['domains'],['core'])
        self.assertEqual(configuration('soc_tcm')['domains'],['core','sys','periph'])
        self.assertEqual(configuration('soc_ddr')['domains'],['core','sys','ddr','periph'])
        self.assertIsNone(configuration('soc_tcm')['frequencies_hz']['ddr'])

    def test_absolute_frequency_does_not_change_cycle_normalization(self):
        a=score(64,24000000,10000)
        b=score(64,24000000,12500)
        self.assertEqual(a['coremark_per_core_mhz'],b['coremark_per_core_mhz'])
        self.assertAlmostEqual(b['coremark_per_second_simulated']/a['coremark_per_second_simulated'],0.8)
        self.assertFalse(a['official_coremark_result'])

    def test_external_wait_in_core_cycles_reduces_both_scores(self):
        a=score(64,24000000,10000)
        b=score(64,25000000,10000)
        self.assertLess(b['coremark_per_core_mhz'],a['coremark_per_core_mhz'])
        self.assertLess(b['coremark_per_second_simulated'],a['coremark_per_second_simulated'])

    def test_single_domain_sweeps(self):
        target=CONFIG['clock_periods_ps']['target']
        for name,domain in (('core80','core'),('sys100','sys'),('ddr100','ddr'),('periph50','periph')):
            changed=[d for d in target if CONFIG['clock_periods_ps'][name][d]!=target[d]]
            self.assertEqual(changed,[domain])

    def test_tcm_compile_has_same_core_and_real_images(self):
        for name in ('core_tcm','soc_tcm'):
            c=configuration(name)
            command=compile_tcm(c)
            for key,value in c['macros'].items(): self.assertIn(f'{key}={value}',command)
            self.assertIn('ITCM_INIT_FILE "firmware/imem.hex"',command)
            self.assertIn('ONCHIP_SOC '+str(int(name=='soc_tcm')),command)
            fdc=constraints(c)
            self.assertNotIn('clk_ddr',fdc)
            self.assertNotIn('false_path',fdc)
            self.assertNotIn('clock_groups',fdc)

    def test_simulation_only_ratios_not_mislabeled_native_board_profiles(self):
        for name in ('core80','ddr100','periph50'):
            self.assertIsNone(configuration('soc_ddr',name)['native_board_profile'])
        self.assertEqual(configuration('soc_ddr','target')['native_board_profile'],1)

    def test_actual_clock_metadata_must_match_explicit_sweep(self):
        periods=list(CONFIG['clock_periods_ps']['periph50'].values())
        hardware=p2.soc_build_configuration()
        with self.assertRaises(ValueError): p2.validate_soc_config(hardware,periods)
        hardware.update(periph_hz=50000000,timer_hz=50000000)
        self.assertEqual(p2.validate_soc_config(hardware,periods),hardware)
        with self.assertRaises(ValueError): p2.validate_soc_config(hardware)


if __name__=='__main__':
    unittest.main()
