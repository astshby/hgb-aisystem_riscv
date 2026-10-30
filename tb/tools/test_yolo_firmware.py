#!/usr/bin/env python3
"""Production YOLO image/source/HDMI role binding, without PDS execution."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import tempfile
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT),str(ROOT/'scripts/pango'),str(ROOT/'scripts')]
from tb.tools import test_pango_handoff as handoff
from prepare_project import YOLO_INPUTS, inspect_firmware, verify_staged_manifest, sha
from prepare_cdc_audit import specification
from tb.tools.test_measurement_constraints import Tcl


class YoloFirmwareInputsTest(unittest.TestCase):
    def setUp(self):
        self.fixture=handoff.HandoffTests(methodName='runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.repo=self.fixture.repo
        names=('vsrc/cpu/pango_200hp_top.sv','vsrc/cpu/pango_soc_pll.sv',
               'vsrc/cpu/pango_video_pll.sv','vsrc/soc/video/yolo_video.sv',
               'scripts/pango/mes2l676_200hp_video.fdc')
        for name in names:
            target=self.repo/name;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/name,target)
        with (self.repo/'scripts/pango_files.f').open('a') as stream:
            stream.write('vsrc/cpu/pango_soc_pll.sv\nvsrc/cpu/pango_video_pll.sv\nvsrc/soc/video/yolo_video.sv\n')
        for name in YOLO_INPUTS:
            path=self.repo/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('YOLO source identity fixture '+name+'\n')

    def firmware(self, width=32, **config_changes):
        """Two TCM LOAD segments and ISA sections, not an executable benchmark."""
        directory = self.repo / f'build/yolo-input/rv{width}'
        directory.mkdir(parents=True)
        config = dict(xlen=width, memory='tcm', optimization='O3', baud=115200,
                      hdmi=1, application='yolox-tiny-full-network')
        config.update(config_changes)
        sources = {name: sha(self.repo / name) for name in YOLO_INPUTS}
        build_id = hashlib.sha256(json.dumps(dict(config=config, sources=sources),
                                             sort_keys=True).encode()).hexdigest()[:16]
        elf = bytearray(2048)
        elf[:16] = b'\x7fELF' + bytes((1 if width == 32 else 2, 1, 1)) + bytes(9)
        header_size, phsize, shsize = (52, 32, 40) if width == 32 else (64, 56, 64)
        if width == 32:
            struct.pack_into('<HHIIIIIHHHHHH', elf, 16, 2, 243, 1, 0x01000000,
                             header_size, 0x500, 0, header_size, phsize, 2, shsize, 3, 1)
        else:
            struct.pack_into('<HHIQQQIHHHHHH', elf, 16, 2, 243, 1, 0x01000000,
                             header_size, 0x500, 0, header_size, phsize, 2, shsize, 3, 1)
        text = b'\x13\0\0\0\x93\0\x10\0'
        data = build_id.encode() + b'\0identity-fixture'
        for index, (offset, address, payload, flags) in enumerate((
                (0x100, 0x01000000, text, 5), (0x200, 0x01100000, data, 6))):
            if width == 32:
                struct.pack_into('<8I', elf, header_size + index * phsize, 1, offset,
                                 address, address, len(payload), len(payload) + 16, flags, 4)
            else:
                struct.pack_into('<2I6Q', elf, header_size + index * phsize, 1, flags,
                                 offset, address, address, len(payload), len(payload) + 16, 8)
            elf[offset:offset+len(payload)] = payload
        names = b'\0.shstrtab\0.riscv.attributes\0'
        attributes = f'rv{width}i2p1_m2p0_zicsr2p0_zifencei2p0_zmmul1p0'.encode() + b'\0'
        elf[0x300:0x300+len(attributes)] = attributes
        elf[0x400:0x400+len(names)] = names
        for index, name, offset, size in ((1, 1, 0x400, len(names)),
                                          (2, 11, 0x300, len(attributes))):
            struct.pack_into('<10I' if width == 32 else '<2I4Q2I2Q', elf,
                             0x500 + index * shsize, name, 3 if index == 1 else 0x70000003,
                             0, 0, offset, size, 0, 0, 1, 0)
        (directory / 'program.elf').write_bytes(elf)
        for name, payload in (('imem.hex', text), ('dmem.hex', data)):
            raw = payload + bytes(65536-len(payload))
            step = width // 8
            (directory / name).write_text(''.join(
                f'{int.from_bytes(raw[pos:pos+step], "little"):0{width//4}x}\n'
                for pos in range(0, len(raw), step)))
        receipt = dict(config=config, source_sha256=sources, firmware_id=build_id,
                       source_commit='fixture-commit', source_status=[],
                       image_sha256={name: sha(directory / name) for name in
                                     ('program.elf', 'imem.hex', 'dmem.hex')})
        (directory / 'manifest.json').write_text(json.dumps(receipt))
        return directory

    def stage(self,width=32):
        firmware=self.firmware(width)
        out,_=self.fixture.stage(width=width,backend='scoreboard',clock=10,
            extra=('--npu-enable','--video-enable','1','--firmware-role','yolo-interactive',
                   '--firmware-dir',str(firmware),'--synthesis-strategy','timing-v2',
                   '--icache-bytes','16384','--dcache-bytes','8192','--dcache-bank-xor-mask','2'))
        return out,json.loads((out/'manifest.json').read_text())

    def test_both_widths_keep_real_name_and_all_source_hashes(self):
        for width in (32,64):
            out,manifest=self.stage(width)
            verify_staged_manifest(out,manifest)
            self.assertEqual(manifest['firmware_role'],'yolo-interactive')
            self.assertTrue((out/'firmware/program.elf').is_file())
            self.assertFalse((out/'firmware/loader.elf').exists())
            self.assertEqual(set(manifest['firmware']['source_sha256']),set(YOLO_INPUTS))
            self.assertEqual(manifest['firmware']['build_config']['hdmi'],1)
            self.assertEqual(manifest['config']['frequencies_hz']['npu'],92187500)
            self.assertEqual(manifest['config']['frequencies_hz']['video'],148500000)
            self.assertTrue(manifest['config']['npu_enable'])
            self.assertTrue(manifest['config']['video_enable'])
            self.assertIn('-fanout_guide 64',(out/'synthesize.tcl').read_text())
            self.assertIn('-slack_weight 80',(out/'implement_cdc.tcl').read_text())

    def test_production_requires_hdmi_baud_and_full_program(self):
        for changes in (dict(hdmi=0),dict(baud=500000),dict(application='synthetic-convolution')):
            self.doCleanups();self.setUp()
            firmware=self.firmware(**changes)
            with self.assertRaisesRegex(ValueError,'YOLO production firmware'):
                inspect_firmware(firmware,32,'yolo-interactive',self.repo)

    def test_changed_source_is_rejected(self):
        firmware=self.firmware()
        (self.repo/'software/yolo/network.c').write_text('changed')
        with self.assertRaisesRegex(ValueError,'source hash'):
            inspect_firmware(firmware,32,'yolo-interactive',self.repo)

    def test_rehashed_instruction_hex_must_match_elf(self):
        firmware=self.firmware()
        path=firmware/'imem.hex';path.write_text(path.read_text().replace('00000013','00000093',1))
        receipt=json.loads((firmware/'manifest.json').read_text());receipt['image_sha256']['imem.hex']=sha(path)
        (firmware/'manifest.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError,'ELF/HEX bytes'):
            inspect_firmware(firmware,32,'yolo-interactive',self.repo)

    def test_video_inventory_keeps_all_four_fifo_boundaries(self):
        _,manifest=self.stage()
        spec=specification(manifest['config'])
        self.assertEqual(len(spec['fifos']),40)
        video={x['path']:x for x in spec['fifos'] if x['path'].startswith('g_video.')}
        self.assertEqual(len(video),4)
        self.assertEqual(video['g_video.u_video.u_pixels']['bits'],12)
        self.assertEqual(video['g_video.u_video.u_frame_command']['src'],'video')
        self.assertEqual(spec['clocks']['video'],'clk_video')
        self.assertEqual(len(spec['levels']),10)
        self.assertEqual(sum(bool(x.get('gray_source')) for x in spec['levels']),4)

    def test_native_query_uses_existing_synthesis_action(self):
        with tempfile.TemporaryDirectory(prefix='yolo-cdc-query-') as temp:
            root=Path(temp);project=root/'existing.pds';project.write_text('fixture')
            audit=root/'cdc-audit/audit.tcl';audit.parent.mkdir();audit.write_text('puts fixture')
            setup=(f'set ::env(HGB_PDS_PROJECT) {{{project}}}\n'
                   'proc exec {args} {return {PASS memory fixture}}\n'
                   'proc open_project {args} {set ::opened 1}\n'
                   'proc set_option {args} {}\n'
                   'proc get_tasks {args} {return syn_1}\n'
                   'proc get_actions {args} {return synthesis_action}\n'
                   'proc open_design {args} {if {[lindex $args 0] ne "-action" || [lindex $args 1] ne "synthesis_action" || [lindex $args 2] ne "-file"} {error "bad action"}; set ::queried 1}\n'
                   f'source {{{ROOT / "scripts/pango/query_cdc.tcl"}}}\n')
            runtime=Tcl();self.addCleanup(runtime.close)
            runtime.evaluate(setup)
            self.assertEqual(runtime.evaluate('set ::opened'),'1')
            self.assertEqual(runtime.evaluate('set ::queried'),'1')



if __name__=='__main__':
    unittest.main()
