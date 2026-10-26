"""NPU provenance and rejection of mislabeled clock/board configurations."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'scripts'), str(ROOT/'scripts/pango')]
from benchmark_config import configuration
from prepare_project import board_clock_constraints, compile_command, verify_npu_board_clocks


class NpuStagingTest(unittest.TestCase):
    def test_pinned_source_identity(self):
        root = ROOT/'third_party/yolo_npu128'
        manifest = json.loads((root/'manifest.json').read_text())
        self.assertEqual(manifest['commit'], '47ffb558bf35bbe017a136903a7464e93132ea2c')
        self.assertEqual(sum(p.endswith('.sv') for p in manifest['files']), 7)
        for name, expected in manifest['files'].items():
            self.assertEqual(hashlib.sha256((root/name).read_bytes()).hexdigest(), expected, name)

    def test_added_domain_keeps_existing_clock_ratio(self):
        old, new = configuration('soc_ddr'), configuration('soc_npu')
        for domain in old['domains']:
            self.assertEqual(old['frequencies_hz'][domain], new['frequencies_hz'][domain])
        self.assertEqual(new['frequencies_hz']['npu'], 100000000)
        self.assertEqual(new['macros'], old['macros'])
        self.assertIn('npu_background', new['scenarios'])

    def test_npu_sweep_is_not_a_native_clock_claim(self):
        for name, hz in [('npu80',80000000),('npu125',125000000)]:
            config = configuration('soc_npu',name)
            self.assertEqual(config['frequencies_hz']['npu'], hz)
            self.assertIsNone(config['native_board_profile'])

    def test_npu_requires_independent_scoreboard_clock(self):
        with self.assertRaises(ValueError):
            compile_command(32,0,1,npu_enable=True)
        with self.assertRaises(ValueError):
            compile_command(32,0,1,core_issue_width=2,scoreboard=True,soc_system=True,npu_enable=True)
        command = compile_command(32,0,1,core_issue_width=2,scoreboard=True,soc_system=True,
                                  board_clock_profile=1,npu_enable=True)
        self.assertIn('NPU_ENABLE 1',command)

    def test_constraints_time_all_domain_crossings(self):
        plain = board_clock_constraints(1)
        npu = board_clock_constraints(1, True)
        self.assertEqual(plain.count('create_generated_clock'),3)
        self.assertEqual(npu.count('create_generated_clock'),4)
        self.assertIn('u_pll/CLKOUT3',npu)
        self.assertNotIn('set_false_path',npu)
        self.assertNotIn('set_clock_groups',npu)

    def test_wrong_npu_frequency_or_connection_rejected(self):
        verify_npu_board_clocks(ROOT)
        with tempfile.TemporaryDirectory() as name:
            root=Path(name)
            for source in ('pango_200hp_top.sv','pango_soc_pll.sv'):
                path=root/'vsrc/cpu'/source; path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text((ROOT/'vsrc/cpu'/source).read_text())
            pll=root/'vsrc/cpu/pango_soc_pll.sv'
            pll.write_text(pll.read_text().replace('.STATIC_RATIO3(8)', '.STATIC_RATIO3(10)'))
            with self.assertRaises(ValueError): verify_npu_board_clocks(root)


if __name__ == '__main__':
    unittest.main()
