"""Clock normalization and simulation/synthesis pairing regressions."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import tempfile
import json
import os

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'scripts'),str(ROOT/'scripts/pango'),str(ROOT/'scripts/verilator')]
from benchmark_config import CONFIG, configuration, core_record, score
from hardware_config import hardware_configuration
from prepare_benchmark import compile_tcm, constraints
import run_p2_coremark as p2
import run_unified_coremark as unified


class UnifiedCoreMarkTest(unittest.TestCase):
    def test_tcm_fractional_receipts_and_old_integer_logs(self):
        image=dict(mode='performance',iterations=64,scenario='tcm')
        for clock in ('target','main_margin2','yolo_sys'):
            config=configuration('core_tcm',clock)
            core='P2_CORE '+' '.join(f'{k}={v}' for k,v in core_record(config).items())
            checks='\n'.join(f'{k} : 0x{v:x}' for k,v in p2.EXPECTED['performance'].items())
            prefix=f'{core}\n{checks}\nIterations : 64\nTotal ticks : 20000000\n[0]crcfinal : 0x1234\nPASS unified-test\n'
            values=[str(config['periods_ps']['core']),f'{config["periods_ps"]["core"]:.6f}']
            if clock=='target': values.append('10000')
            for period in values:
                text=prefix+f'UNIFIED_TCM core_period_ps={period} itcm_bytes=65536 dtcm_bytes=65536 cache=0 ddr=0\n'
                self.assertEqual(unified.parse_tcm(text,image,config)['cycles'],20000000)
            wrong=str(round(config['periods_ps']['core'])+1)
            text=prefix+f'UNIFIED_TCM core_period_ps={wrong} itcm_bytes=65536 dtcm_bytes=65536 cache=0 ddr=0\n'
            with self.assertRaisesRegex(ValueError,'clock/memory'):
                unified.parse_tcm(text,image,config)

    def test_model_build_jobs_are_explicit_and_positive(self):
        with tempfile.TemporaryDirectory() as directory:
            for width,jobs in ((32,1),(64,3)):
                config=configuration('core_tcm','main_margin2',width)
                output=Path(directory)/f'rv{width}'
                def fake_compile(command,log,cwd,env):
                    log.write_text('')
                    (output/('V'+config['sim_top'])).write_bytes(b'test-model')
                with patch.object(p2,'rtl_sources',return_value={}),patch.object(unified,'run',side_effect=fake_compile) as compile_mock:
                    _,receipt=unified.build(config,output,jobs)
                command=compile_mock.call_args.args[0]
                self.assertEqual(command[command.index('-j')+1],str(jobs))
                self.assertIn(f'-GCORE_PERIOD_PS={config["periods_ps"]["core"]}',command)
                self.assertIn(f'-j {jobs}',receipt['command'])
            invalid=Path(directory)/'invalid'
            with self.assertRaisesRegex(ValueError,'jobs must be positive'):
                unified.build(config,invalid,0)
            self.assertFalse(invalid.exists())

    def test_rt_and_benchmark_use_identical_bank_mapping(self):
        for width in (32,64):
            for mask in (0,1,2,3):
                rt=hardware_configuration('none',width,16384,4096,mask)
                cm=configuration('soc_ddr','target',width,16384,4096,mask)
                self.assertEqual(rt['memory'],cm['memory'])
                self.assertEqual(rt['macros'],cm['macros'])
                self.assertEqual(rt['macros'].get('SOC_DCACHE_BANK_XOR_MASK',0),mask)

    def test_optimization_level_cannot_reuse_other_firmware(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle=Path(directory)
            (bundle/'manifest.json').write_text(json.dumps(dict(iterations=2,modes=['performance'],optimization='O2')))
            with patch.dict(os.environ,SOFTWARE_OPT='O3'):
                with self.assertRaisesRegex(ValueError,'selection differs'):
                    unified.freeze(bundle,2,['performance'])

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
