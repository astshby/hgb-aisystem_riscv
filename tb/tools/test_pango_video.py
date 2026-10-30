#!/usr/bin/env python3
"""Check video pin facts and fresh project staging without invoking PDS."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import test_pango_handoff as handoff
from scripts.pango.prepare_project import verify_staged_manifest


class VideoStagingTests(unittest.TestCase):
    def fixture(self):
        fixture = handoff.HandoffTests(methodName='runTest')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        for name in ('vsrc/cpu/pango_200hp_top.sv','vsrc/cpu/pango_soc_pll.sv','vsrc/cpu/pango_video_pll.sv',
                     'vsrc/soc/video/yolo_video.sv','scripts/pango/mes2l676_200hp_video.fdc'):
            destination = fixture.repo/name
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(REPO/name,destination)
        with (fixture.repo/'scripts/pango_files.f').open('a') as stream:
            stream.write('vsrc/cpu/pango_soc_pll.sv\nvsrc/cpu/pango_video_pll.sv\nvsrc/soc/video/yolo_video.sv\n')
        return fixture

    def test_pin_map_and_rgb_order(self):
        fdc = (REPO/'scripts/pango/mes2l676_200hp_video.fdc').read_text()
        pins = dict(re.findall(r'define_attribute \{p:([^}]+)\} \{PAP_IO_LOC\} \{([^}]+)\}',fdc))
        expected = {'video_ref_clk':'D18','hdmi_pixel_clk':'T24','hdmi_hs':'R20','hdmi_vs':'R21',
                    'hdmi_de':'N19','hdmi_reset_n':'G25','hdmi_scl':'K22','hdmi_sda':'K23'}
        # 独立黄金值按参考 RGB 各字节的低位到高位排列。
        for offset,locations in ((0,'P19 P21 P20 M22 M21 N18 R22 T22'),
                                 (8,'N22 N23 N24 P23 P24 R25 P25 T25'),
                                 (16,'P16 K25 K26 L24 L25 L22 L23 N21')):
            expected.update({f'hdmi_rgb[{offset+i}]':pin for i,pin in enumerate(locations.split())})
        self.assertEqual(pins,expected)
        base = (REPO/'scripts/pango/mes2l676_200hp.fdc').read_text()
        base_pins = set(re.findall(r'\{PAP_IO_LOC\} \{([^}]+)\}',base))
        self.assertFalse(base_pins.intersection(pins.values()))
        self.assertEqual(len(set(pins.values())),len(pins))
        self.assertIn('-multiply_by {11} -divide_by {2}',fdc)
        self.assertNotRegex(fdc,r'(?m)^\s*(set_false_path|set_clock_groups|set_(input|output)_delay)\b')

    def test_yolo_defaults_to_complete_video_candidate(self):
        fixture = self.fixture()
        output,_ = fixture.stage(backend='scoreboard',clock=7,extra=('--npu-enable',))
        manifest = json.loads((output/'manifest.json').read_text())
        verify_staged_manifest(output,manifest)
        self.assertTrue(manifest['video_enable'])
        self.assertEqual(manifest['board_clock_domains_hz']['video'],148500000)
        self.assertEqual(manifest['board_clock_domains_hz']['npu'],100000000)
        self.assertIn('VIDEO_ENABLE 1',(output/'compile.tcl').read_text())
        self.assertIn('add_constraint {board_video.fdc}',(output/'compile.tcl').read_text())
        self.assertEqual(manifest['video_format']['stride_bytes'],7680)

    def test_headless_yolo_explicit_override(self):
        fixture = self.fixture()
        output,_ = fixture.stage(backend='scoreboard',clock=7,extra=('--npu-enable','--video-enable','0'))
        manifest = json.loads((output/'manifest.json').read_text())
        verify_staged_manifest(output,manifest)
        self.assertFalse(manifest['video_enable'])
        self.assertNotIn('video',manifest['board_clock_domains_hz'])
        self.assertFalse((output/'board_video.fdc').exists())
        self.assertIn('VIDEO_ENABLE 0',(output/'compile.tcl').read_text())

    def test_non_npu_default_keeps_old_entry(self):
        fixture = self.fixture()
        output,_ = fixture.stage(backend='scoreboard',clock=6)
        manifest = json.loads((output/'manifest.json').read_text())
        verify_staged_manifest(output,manifest)
        self.assertNotIn('video_enable',manifest)
        self.assertNotIn('VIDEO_ENABLE',(output/'compile.tcl').read_text())
        self.assertFalse((output/'board_video.fdc').exists())

    def test_rehashed_video_clock_or_pin_change_rejected(self):
        for name,old,new in (('board_video.fdc','{D18}','{D19}'),
                             ('vsrc/cpu/pango_video_pll.sv','.STATIC_RATIOF(33)','.STATIC_RATIOF(32)')):
            with self.subTest(file=name):
                fixture = self.fixture()
                output,_ = fixture.stage(backend='scoreboard',clock=7,extra=('--npu-enable',))
                manifest = json.loads((output/'manifest.json').read_text())
                path = output/name
                path.write_text(path.read_text().replace(old,new))
                manifest['files'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaisesRegex(ValueError,'video'):
                    verify_staged_manifest(output,manifest)

    def test_video_requires_independent_scoreboard(self):
        fixture = self.fixture()
        fixture.stage(backend='legacy',clock=0,extra=('--video-enable','1'),success=False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
