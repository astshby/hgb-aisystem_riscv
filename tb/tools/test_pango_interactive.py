#!/usr/bin/env python3
"""Check role-aware native inputs with synthetic ELF/HEX; never launch PDS."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts'), str(ROOT / 'scripts/pango')]
from tb.tools import test_pango_handoff as handoff_fixture
from scripts.pango.prepare_project import (COREMARK_INPUTS, TIMING_V3_SYNTHESIS,
    inspect_firmware, project_configuration, sha, synthesis_commands, timing_input,
    verify_staged_manifest)
from scripts.pango.prepare_cdc_audit import publish_native_binding, specification
from scripts.pango import summarize_benchmark


class InteractiveInputsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = handoff_fixture.HandoffTests(methodName='test_default_entry_selects_measured_core_and_four_clocks')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.repo = self.fixture.repo
        shutil.copyfile(ROOT / 'vsrc/cpu/pango_200hp_top.sv',
                        self.repo / 'vsrc/cpu/pango_200hp_top.sv')
        for name in COREMARK_INPUTS:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('offline source identity fixture: ' + name + '\n')

    def firmware(self, width=32, **config_changes):
        """Two TCM LOAD segments and ISA sections, not an executable benchmark."""
        directory = self.repo / f'build/interactive/rv{width}'
        directory.mkdir(parents=True)
        config = dict(xlen=width, memory='tcm', optimization='O3', baud=115200,
                      test_iterations=0, formal_minimum_seconds=10, target_seconds=12)
        config.update(config_changes)
        sources = {name: sha(self.repo / name) for name in COREMARK_INPUTS}
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

    def inspect(self, directory, width=32):
        return inspect_firmware(directory, width, 'coremark-interactive', self.repo)

    def stage(self, width=32):
        directory = self.firmware(width)
        output, result = self.fixture.stage(width=width, backend='scoreboard', clock=6,
            extra=('--firmware-dir', str(directory), '--firmware-role', 'coremark-interactive',
                   '--synthesis-strategy', 'timing-v3', '--icache-bytes', '16384',
                   '--dcache-bytes', '8192', '--dcache-bank-xor-mask', '2'))
        return output, json.loads((output / 'manifest.json').read_text()), result

    def rehash_image(self, directory, name):
        path = directory / 'manifest.json'
        receipt = json.loads(path.read_text())
        receipt['image_sha256'][name] = sha(directory / name)
        path.write_text(json.dumps(receipt))

    def test_both_widths_keep_program_and_banked_identity(self):
        for width in (32, 64):
            with self.subTest(width=width):
                output, manifest, _ = self.stage(width)
                verify_staged_manifest(output, manifest)
                self.assertEqual(manifest['firmware_role'], 'coremark-interactive')
                self.assertTrue((output / 'firmware/program.elf').exists())
                self.assertFalse((output / 'firmware/loader.elf').exists())
                self.assertEqual(len(manifest['firmware']['source_sha256']), 20)
                self.assertEqual(manifest['firmware']['entry'], 0x01000000)
                self.assertEqual(manifest['firmware']['build_config']['test_iterations'], 0)
                for name in ('imem.hex', 'dmem.hex'):
                    words = (output / 'firmware' / name).read_text().split()
                    self.assertEqual((output / f'firmware/{name}.bank1').read_text().split(), words[1::2])
                self.assertEqual((output / 'synthesize.tcl').read_text(), synthesis_commands('timing-v3'))
                _, _, config = timing_input(output)
                self.assertEqual(config['frequencies_hz'], dict(core=100000000, sys=100000000,
                                                               ddr=125000000, periph=60000000))
                self.assertEqual(config['memory']['icache_bytes'], 16384)
                self.assertEqual(config['memory']['dcache_bytes'], 8192)
                self.assertEqual(config['memory']['dcache_bank_xor_mask'], 2)
                self.assertEqual(specification(config)['clocks']['ddr'], 'ddrphy_sysclk')

    def test_short_demo_is_not_a_production_image(self):
        with self.assertRaisesRegex(ValueError, 'test_iterations=0'):
            self.inspect(self.firmware(test_iterations=2))

    def test_mismatched_xlen_rejected(self):
        with self.assertRaisesRegex(ValueError, 'width/machine'):
            self.inspect(self.firmware(64))

    def test_source_and_image_mutations_rejected(self):
        directory = self.firmware()
        source = self.repo / COREMARK_INPUTS[0]
        original = source.read_bytes()
        source.write_bytes(original + b'changed')
        with self.assertRaisesRegex(ValueError, 'source hash differs'):
            self.inspect(directory)
        source.write_bytes(original)
        path = directory / 'imem.hex'
        path.write_text(path.read_text().replace('00000013', '00000093', 1))
        with self.assertRaisesRegex(ValueError, 'build/image identity'):
            self.inspect(directory)
        self.rehash_image(directory, 'imem.hex')
        with self.assertRaisesRegex(ValueError, 'ELF/HEX'):
            self.inspect(directory)

    def test_incomplete_sources_rejected(self):
        directory = self.firmware()
        path = directory / 'manifest.json'
        receipt = json.loads(path.read_text())
        receipt['source_sha256'].pop(COREMARK_INPUTS[0])
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, '20-source'):
            self.inspect(directory)

    def test_entry_and_unsupported_isa_rejected_even_after_rehash(self):
        directory = self.firmware()
        path = directory / 'program.elf'
        original = path.read_bytes()
        changed = bytearray(original)
        struct.pack_into('<I', changed, 24, 0)
        path.write_bytes(changed)
        self.rehash_image(directory, 'program.elf')
        with self.assertRaisesRegex(ValueError, 'entry/ISA'):
            self.inspect(directory)
        path.write_bytes(original.replace(b'm2p0', b'c2p0'))
        self.rehash_image(directory, 'program.elf')
        with self.assertRaisesRegex(ValueError, 'unsupported ISA'):
            self.inspect(directory)

    def test_out_of_tcm_load_rejected(self):
        directory = self.firmware()
        path = directory / 'program.elf'
        data = bytearray(path.read_bytes())
        struct.pack_into('<I', data, 52 + 8, 0x80000000)
        path.write_bytes(data)
        self.rehash_image(directory, 'program.elf')
        with self.assertRaisesRegex(ValueError, 'outside TCM'):
            self.inspect(directory)

    def test_hardware_metadata_cannot_drift(self):
        output, manifest, _ = self.stage()
        manifest['config']['frequencies_hz']['core'] = 90000000
        with self.assertRaisesRegex(ValueError, 'hardware binding'):
            verify_staged_manifest(output, manifest)

    def test_rehashed_bank_still_requires_correct_interleave(self):
        output, manifest, _ = self.stage()
        path = output / 'firmware/imem.hex.bank0'
        path.write_text(path.read_text().replace('00000013', '00000093', 1))
        manifest['files']['firmware/imem.hex.bank0'] = sha(path)
        with self.assertRaisesRegex(ValueError, 'TCM interleaving'):
            verify_staged_manifest(output, manifest)

    def test_interactive_role_requires_explicit_directory(self):
        _, result = self.fixture.stage(backend='scoreboard', clock=6, success=False,
            extra=('--firmware-role', 'coremark-interactive'))
        self.assertIn('requires --firmware-dir', result.stderr)

    def test_native_summary_rejects_incomplete_timing_strategy(self):
        output, _, _ = self.stage()
        native_log = self.fixture.root / 'outside-native.log'
        native_log.write_text('Executing : synthesize -ads -selected_syn_tool_opt 2 successfully.\n')
        with self.assertRaisesRegex(ValueError, 'timing-v3'):
            summarize_benchmark.summarize(output, native_log)

    def test_native_summary_preserves_firmware_and_external_log(self):
        output, manifest, _ = self.stage()
        native_log = self.fixture.root / 'outside-native.log'
        native_log.write_text('Executing : '+TIMING_V3_SYNTHESIS+' successfully.\n')
        syn = output / 'prj_tasks/syn_1/synthesize'
        (syn / 'report_db').mkdir(parents=True)
        (syn / 'pango_200hp_top_syn.vm').write_text('module fixture; endmodule\n')
        (syn / 'pango_200hp_top.snr').write_text('offline report fixture')
        for name in ('resource_utilization', 'report_timing_fmax', 'report_timing_clock_summary',
                     'report_timing_setup', 'report_timing_hold', 'report_timing_path_setup', 'check_timing_summary'):
            (syn / f'report_db/synthesize_{name}.db').write_text('<tables/>')
        with patch.object(summarize_benchmark, 'read_table', return_value=[]), \
                patch.object(summarize_benchmark, 'resources', return_value={'LUT': 123}):
            result = summarize_benchmark.summarize(output, native_log)
        self.assertEqual(result['firmware'], manifest['firmware'])
        self.assertEqual(result['config'], manifest['config'])
        self.assertEqual(result['input_manifest'], 'manifest.json')
        self.assertEqual(result['hashes'][str(native_log)], sha(native_log))
        self.assertIsNone(result['routed_fmax'])

    def test_native_binding_receipt_binds_all_physical_inputs(self):
        output, manifest, _ = self.stage()
        directory = output / 'cdc-audit'
        directory.mkdir()
        constraints = 'set_max_delay 10 -datapath_only -from {t:src/Q} -to {t:dst/D}\nset_max_skew 6 -from {t:a/Q} -to {t:b/D}\n'
        (directory / 'bound_cdc.fdc').write_text(constraints)
        (directory / 'bound_sync.lcf').write_text('define_attribute {i:dst} {PAP_ASYNC_REG} {TRUE}\n')
        (directory / 'binding.json').write_text('{"verified":true}\n')
        config = project_configuration(manifest)
        spec = dict(input_manifest='manifest.json', input_manifest_sha256=sha(output / 'manifest.json'))
        names = [f'prj_tasks/syn_1/synthesize/{config["pds_top"]}_syn.vm'] + [
            'prj_tasks/syn_1/synthesize/report_db/synthesize_'+name+'.db' for name in (
                'report_timing_clock_summary', 'report_timing_path_setup', 'report_clock_network')]
        for name in names:
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('offline native input: ' + name)
        result = dict(log_sha256='0'*64, passed_fifos=['fifo'], synchronizer_registers=['dst'])
        publish_native_binding(output, directory, spec, result, config)
        receipt = json.loads((output / 'cdc-scope-receipt.json').read_text())
        self.assertEqual((receipt['fifos'], receipt['synchronizer_registers'],
                          receipt['max_delay_commands'], receipt['max_skew_commands']), (1, 1, 1, 1))
        for name, digest in receipt['files'].items():
            self.assertEqual(sha(output / name), digest)
        self.assertEqual((output / 'backend_cdc.scf').read_text(), constraints)
        with self.assertRaises(FileExistsError):
            publish_native_binding(output, directory, spec, result, config)


if __name__ == '__main__':
    unittest.main()
