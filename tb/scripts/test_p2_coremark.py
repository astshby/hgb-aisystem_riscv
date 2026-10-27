#!/usr/bin/env python3
"""Check that P2 reports reject misplaced software, corrupt CRC and absent background load."""
import importlib.util
from pathlib import Path
import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('p2_coremark', ROOT / 'scripts/verilator/run_p2_coremark.py')
p2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p2)


def metrics_log():
    lines = ['P2_METRICS scope=software_marker enabled=1 latency_units=domain_cycles']
    latency_names = ['cpu.if', 'cpu.d0', 'cpu.d1', 'cpu.d0.queue', 'cpu.d1.queue', 'dma.engine', 'dma.software']
    latency_names += [f'tcm{bank}.port{port}' for bank in range(2) for port in range(4)]
    latency_names += [f'{cache}.{part}' for cache in ('icache', 'dcache0', 'dcache1') for part in ('refill', 'install_tail')]
    latency_names += [f'{master}.{part}' for master in ('sys.master0', 'sys.master1', 'sys.master2', 'sys.master3', 'ddr.target') for part in ('read', 'write')]
    for name in latency_names:
        domain = 'ddr' if name.startswith('ddr.') else 'sys' if name.startswith('sys.') or name == 'dma.engine' else 'periph' if name == 'dma.software' else 'core'
        lines.append(f'P2_LATENCY name={name} domain={domain} started=3 completed=3 pending=0 first_count=3 first_sum=30 last_sum=30 roi_cycles=100 roi_started=2 roi_completed=2 roi_first_count=2 roi_first_sum=20 roi_last_sum=20 roi_request_stall=1 roi_response_stall=0 roi_carry_in=0 roi_carry_out=0 roi_completed_from_before=0 roi_started_completed=2 roi_started_completed_after=0 cohort_last_sum=20')
    for name in ('sys.master0', 'sys.master1', 'sys.master2', 'sys.master3', 'ddr.target'):
        domain = 'ddr' if name == 'ddr.target' else 'sys'
        lines.append(f'P2_AXI name={name} domain={domain} rbeats=1 wbeats=0 wbytes=0 roi_rbeats=1 roi_wbeats=0 roi_wbytes=0')
    for name in ('icache', 'dcache0', 'dcache1'):
        lines.append(f'P2_CACHE name={name} hits=1 misses=1 installs=1 install_writes=4 roi_hits=1 roi_misses=1 roi_installs=1 roi_install_writes=4')
    for name in ('dcache0', 'dcache1'):
        lines.append(f'P2_CACHE_BANK name={name} request_stall_cycles=3 response_with_request=1 same_cycle_turnover=0 roi_request_stall_cycles=3 roi_response_with_request=1 roi_same_cycle_turnover=0')
    for name in ('tcm0', 'tcm1'):
        lines.append(f'P2_TCM name={name} conflict_cycles=0 response_blocked_cycles=0 bank_fires=2 roi_conflict_cycles=0 roi_response_blocked_cycles=0 roi_bank_fires=2')
    return '\n'.join(lines) + '\n'


def result_log(cycles=1234567, irq=0, completed=0):
    return f'''Total ticks      : {cycles}
Iterations       : 2
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x1111
ERROR! Must execute for at least 10 secs for a valid result!
Errors detected
P2_PLATFORM magic=50324346 version=1 periph_period_ps=40000 clock=1
P2_PLATFORM_SW magic={0x50324346} version=1 periph_period_ps=40000 clock=1
P2_PLATFORM_CLOCK periph_period_ps=40000 measured_period_ps=40000 checked_periods=100
P2_BOOT first_pc=00000000 rom_retired=2 itcm_seen=1 ddr_seen=1 order_ok=1 rom_words_ok=1 roi_ddr_retired=100000 roi_ddr_if=50000 roi_ddr_data=20000
P2_STACK roi_ddr_sp_writes=1000 roi_tcm_sp_writes=2 roi_bad_sp_writes=0 roi_sp_construction_writes=1 roi_ddr_stack_accesses=2000 roi_tcm_stack_accesses=10 roi_bad_stack_accesses=0
P2_CACHE_CONFIG icache_bytes=4096 icache_line_bytes=32 icache_ways=2 dcache_bytes=4096 dcache_line_bytes=32 dcache_ways=2 dcache_banks=2
P2_TIMER mode=0 requested_ps=100000000 interval_ticks=2500 actual_ps=100000000 quantum_ps=0 late_events={irq} late_max_ticks={10 if irq else 0} skipped=0
P2_TIMER_TOTAL late_hi=0 late_lo={irq * 10}
P2_CONFIG warm=0 background=0 cold_prepared=1 iterations=2
P2_ROI core_cycles={cycles} sys_cycles=1000000 cpu_ddr_ar=120 cpu_ddr_aw=3 dma_ar={9 if completed else 0} dma_aw={9 if completed else 0} dma_rbeats={36 if completed else 0} dma_wbeats={36 if completed else 0} max_cpu_ar_wait=5 max_dma_ar_wait=9
P2_BACKGROUND irq={irq} dma_completed={completed} dma_bytes={completed * 16384} errors=0
P2_IRQ start=0 stop={irq} roi={irq}
P2_CLOCK core_half_ns=5.000000 sys_half_ns=6.250000 ddr_half_ns=4.000000 periph_half_ns=20.000000
P2_TICKS high=0 low={cycles}
PASS p2-coremark-cold-performance-i2-c1 RV32 cycles=1300000 clocks=C1 core_half_ns=5.000000 sys_half_ns=6.250000 ddr_half_ns=4.000000 periph_half_ns=20.000000
''' + metrics_log()


class P2ResultTests(unittest.TestCase):
    def test_short_crc_run_is_labelled(self):
        result = p2.parse_result(result_log(), 'performance', 2, 'cold')
        self.assertEqual(result['classification'], 'short_crc_adaptation')
        self.assertFalse(result['physical_frequency_measured'])

    def test_changed_algorithm_crc_fails_even_when_tohost_passes(self):
        with self.assertRaisesRegex(ValueError, 'crcmatrix'):
            p2.parse_result(result_log().replace('0x1fd7', '0x1234'), 'performance', 2, 'cold')

    def test_different_seed_mode_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'seedcrc'):
            p2.parse_result(result_log(), 'validation', 2, 'cold')

    def test_iteration_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'iteration'):
            p2.parse_result(result_log(), 'performance', 64, 'cold')

    def test_background_needs_irq_and_dma(self):
        for irq, completed in ((0, 2), (3, 0)):
            with self.subTest(irq=irq, completed=completed), self.assertRaisesRegex(ValueError, 'background'):
                p2.parse_result(result_log(irq=irq, completed=completed), 'performance', 2, 'background')

    def test_background_completed_bytes_must_match(self):
        with self.assertRaisesRegex(ValueError, 'background'):
            p2.parse_result(result_log(irq=3, completed=2).replace('dma_bytes=32768', 'dma_bytes=32764'), 'performance', 2, 'background')

    def test_missing_roi_is_rejected(self):
        text = '\n'.join(line for line in result_log().splitlines() if not line.startswith('P2_ROI '))
        with self.assertRaisesRegex(ValueError, 'ROI'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_missing_clock_is_rejected(self):
        text = result_log().replace('core_half_ns=5.000000', 'period_missing=5.000000')
        with self.assertRaisesRegex(ValueError, 'clock'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_background_needs_roi_irq_not_only_total(self):
        text = result_log(irq=3, completed=2).replace('warm=0 background=0 cold_prepared=1', 'warm=1 background=1 cold_prepared=0')
        text = text.replace('P2_IRQ start=0 stop=3 roi=3', 'P2_IRQ start=3 stop=3 roi=0')
        with self.assertRaisesRegex(ValueError, 'interrupt activity'):
            p2.parse_result(text, 'performance', 2, 'background')

    def test_background_needs_roi_dma_not_only_total(self):
        text = result_log(irq=3, completed=2).replace('warm=0 background=0 cold_prepared=1', 'warm=1 background=1 cold_prepared=0')
        text = text.replace('dma_wbeats=36', 'dma_wbeats=0')
        with self.assertRaisesRegex(ValueError, 'overlap actual DMA'):
            p2.parse_result(text, 'performance', 2, 'background')

    def test_wrong_cache_state_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'configuration'):
            p2.parse_result(result_log(), 'performance', 2, 'warm')

    def test_missing_cpu_ddr_activity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'CPU DDR'):
            p2.parse_result(result_log().replace('cpu_ddr_ar=120', 'cpu_ddr_ar=0'), 'performance', 2, 'cold')

    def test_roi_bandwidth_uses_sys_window_not_completed_total(self):
        text = result_log(irq=3, completed=2).replace('warm=0 background=0 cold_prepared=1', 'warm=1 background=1 cold_prepared=0')
        result = p2.parse_result(text, 'performance', 2, 'background')
        self.assertEqual(result['background']['roi_dma_write_bytes'], 1152)
        self.assertEqual(result['background']['dma_bytes_total_including_drain'], 32768)
        self.assertAlmostEqual(result['background']['roi_dma_write_MB_per_s'], 0.09216)

    def test_unknown_coremark_error_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'CoreMark error'):
            p2.parse_result(result_log() + 'ERROR! invalid data size\n', 'performance', 2, 'cold')

    def test_long_run_requires_vendor_validation(self):
        with self.assertRaisesRegex(ValueError, 'full vendor'):
            p2.parse_result(result_log(cycles=25000000), 'performance', 2, 'cold')

    def test_virtual_ten_seconds_is_not_real_ten_seconds(self):
        text = result_log(cycles=10000000)
        text = text.replace('ERROR! Must execute for at least 10 secs for a valid result!',
                            'Correct operation validated. See readme.txt for run and reporting rules.')
        text = text.replace('Errors detected\n', '')
        result = p2.parse_result(text, 'performance', 2, 'cold')
        self.assertTrue(result['vendor_virtual_duration_met'])
        self.assertEqual(result['simulated_duration_seconds'], 0.1)
        self.assertFalse(result['official_duration_met'])
        self.assertFalse(result['official_coremark_result'])
        self.assertEqual(result['classification'], 'short_crc_adaptation')

    def test_idle_m2_rejects_background_activity(self):
        with self.assertRaisesRegex(ValueError, 'idle M2'):
            p2.parse_result(result_log(irq=3, completed=2), 'performance', 2, 'cold')

    def test_assertion_cannot_hide_after_pass(self):
        with self.assertRaisesRegex(ValueError, 'simulator failure'):
            p2.parse_result(result_log() + '%Error: assertion failed\n', 'performance', 2, 'cold')

    def test_missing_architectural_pass_fails(self):
        with self.assertRaisesRegex(ValueError, 'architectural'):
            p2.parse_result(result_log().replace('PASS p2-coremark', 'pending p2-coremark'), 'performance', 2, 'cold')


    def test_wrong_runtime_clock_is_rejected(self):
        text = result_log().replace('P2_PLATFORM_SW magic=1345471302 version=1 periph_period_ps=40000',
                                    'P2_PLATFORM_SW magic=1345471302 version=1 periph_period_ps=10000')
        with self.assertRaisesRegex(ValueError, 'platform clock'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_actual_stack_range_is_checked(self):
        text = result_log().replace('roi_bad_sp_writes=0', 'roi_bad_sp_writes=1')
        with self.assertRaisesRegex(ValueError, 'stack pointer'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_actual_stack_accesses_are_checked_independently_of_pointer_writes(self):
        text = result_log().replace('roi_bad_stack_accesses=0', 'roi_bad_stack_accesses=1')
        with self.assertRaisesRegex(ValueError, 'stack pointer'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_pointer_value_without_ddr_stack_access_is_insufficient(self):
        text = result_log().replace('roi_ddr_stack_accesses=2000', 'roi_ddr_stack_accesses=0')
        with self.assertRaisesRegex(ValueError, 'stack pointer'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_elf_without_actual_ddr_data_is_rejected(self):
        text = result_log().replace('roi_ddr_data=20000', 'roi_ddr_data=0')
        with self.assertRaisesRegex(ValueError, 'DDR instruction/data'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_missing_actual_boot_is_rejected(self):
        text = result_log().replace('rom_words_ok=1', 'rom_words_ok=0')
        with self.assertRaisesRegex(ValueError, 'Boot ROM'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_declared_cache_does_not_override_actual_instance(self):
        text = result_log().replace('dcache_bytes=4096', 'dcache_bytes=8192')
        with self.assertRaisesRegex(ValueError, 'cache size'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_explicit_bank_mapping_must_match_instance(self):
        log = result_log().replace('dcache_banks=2', 'dcache_banks=2 dcache_bank_xor_mask=1')
        expected = {'icache_bytes':4096, 'dcache_bytes':4096, 'dcache_bank_xor_mask':1}
        p2.parse_result(log, 'performance', 2, 'cold', expected_cache=expected)
        with self.assertRaisesRegex(ValueError, 'bank mapping'):
            p2.parse_result(log, 'performance', 2, 'cold')

    def test_explicit_cache_capacity_must_match_both_actual_instances(self):
        text = result_log().replace('icache_bytes=4096', 'icache_bytes=16384').replace('dcache_bytes=4096', 'dcache_bytes=8192')
        expected = dict(icache_bytes=16384, dcache_bytes=8192)
        result = p2.parse_result(text, 'performance', 2, 'cold', expected_cache=expected)
        self.assertEqual(result['cache']['icache_bytes'], 16384)
        with self.assertRaisesRegex(ValueError, 'cache size'):
            p2.parse_result(text.replace('dcache_bytes=8192', 'dcache_bytes=4096'),
                            'performance', 2, 'cold', expected_cache=expected)

    def test_fixed_period_tick_conversion_is_checked(self):
        text = result_log().replace('interval_ticks=2500', 'interval_ticks=2048')
        with self.assertRaisesRegex(ValueError, 'tick conversion'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_actual_clock_edges_must_match_injected_period(self):
        text = result_log().replace('measured_period_ps=40000', 'measured_period_ps=39999')
        with self.assertRaisesRegex(ValueError, 'actual peripheral clock edges'):
            p2.parse_result(text, 'performance', 2, 'cold')

    def test_self_consistent_timer_still_must_match_frozen_period(self):
        result = p2.parse_result(result_log(), 'performance', 2, 'cold')
        with self.assertRaisesRegex(ValueError, 'frozen selection'):
            p2.validate_run_selection(result, 1, {'timer_mode': 'realtime', 'irq_period_us': 200})

    def test_legacy_ticks_are_explicit(self):
        text = result_log().replace('mode=0 requested_ps=100000000 interval_ticks=2500 actual_ps=100000000',
                                    'mode=1 requested_ps=100000000 interval_ticks=2048 actual_ps=81920000')
        result = p2.parse_result(text, 'performance', 2, 'cold')
        self.assertEqual(result['timer']['mode'], 1)
        self.assertEqual(result['timer']['actual_ps'], 81920000)


class MetricsTests(unittest.TestCase):
    def test_domains_keep_their_own_latency_units(self):
        result = p2.parse_metrics(metrics_log(), [5, 6.25, 4, 20])
        self.assertEqual(result['latency']['cpu.if']['roi_mean_last_ns'], 100)
        self.assertEqual(result['latency']['sys.master0.read']['roi_mean_last_ns'], 125)
        self.assertEqual(result['latency']['ddr.target.read']['roi_mean_last_ns'], 80)

    def test_missing_boundary_is_rejected(self):
        text = '\n'.join(line for line in metrics_log().splitlines() if 'name=dcache1.refill ' not in line)
        with self.assertRaisesRegex(ValueError, 'missing required latency'):
            p2.parse_metrics(text, [5, 6.25, 4, 20])

    def test_duplicate_boundary_is_rejected(self):
        text = metrics_log() + metrics_log().splitlines()[1] + '\n'
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            p2.parse_metrics(text, [5, 6.25, 4, 20])

    def test_roi_transaction_conservation_is_checked(self):
        with self.assertRaisesRegex(ValueError, 'ROI transaction conservation'):
            p2.parse_metrics(metrics_log().replace('roi_carry_out=0', 'roi_carry_out=1'), [5, 6.25, 4, 20])

    def test_whole_run_cannot_masquerade_as_software_roi(self):
        with self.assertRaisesRegex(ValueError, 'metrics scope'):
            p2.parse_metrics(metrics_log().replace('scope=software_marker', 'scope=whole_run'), [5, 6.25, 4, 20])


class FrozenArtifactTests(unittest.TestCase):
    def test_saved_binary_replay_uses_its_snapshot_after_rtl_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            binary = base / 'simulator'
            binary.write_bytes(b'frozen simulator')
            (base / 'source').mkdir()
            (base / 'source' / 'rtl.sv').write_text('frozen rtl\n')
            receipt = {'binary_sha256': p2.sha(binary),
                       'source_tree_sha256': {'rtl.sv': p2.sha(base / 'source' / 'rtl.sv')}}
            p2.write_json(base / 'p2-build.json', receipt)
            with patch.object(p2, 'rtl_sources', side_effect=AssertionError('current RTL is intentionally irrelevant')):
                self.assertEqual(p2.load_sim(binary), receipt)

    def test_explicit_p1_rejects_legacy_receipt_without_guessing(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            binary = base / 'simulator'
            binary.write_bytes(b'frozen simulator')
            (base / 'source').mkdir()
            p2.write_json(base / 'p2-build.json', {'binary_sha256': p2.sha(binary), 'source_tree_sha256': {}})
            with patch.dict(os.environ, {'RETIRE_ENTRIES': '32', 'LIMITED_INTEGER_OOO': '1'}):
                self.assertNotIn('core_config', p2.load_sim(binary))
                with self.assertRaisesRegex(ValueError, 'explicit p1'):
                    p2.load_sim(binary, 'p1')

    def test_saved_binary_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            binary = base / 'simulator'
            binary.write_bytes(b'original')
            p2.write_json(base / 'p2-build.json', {'binary_sha256': p2.sha(binary)})
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'simulator differs'):
                p2.load_sim(binary)

    def test_source_changes_outside_frozen_bundle_do_not_change_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'saved.c').write_text('frozen source\n')
            hashes = {'saved.c': p2.sha(base / 'saved.c')}
            p2.verify_hashes(base, hashes)
            (base / 'saved.c').write_text('changed source\n')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                p2.verify_hashes(base, hashes)

    def test_manifest_parent_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'outside'):
                p2.verify_hashes(Path(temporary), {'../outside': 'unused'})

    def test_existing_result_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'result.json'
            p2.write_json(path, {'original': True})
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                p2.write_json(path, {'replacement': True})
            self.assertEqual(original, path.read_bytes())

    def test_existing_run_log_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'run.log'
            path.write_text('original log\n')
            with self.assertRaises(FileExistsError):
                p2.run(['true'], path)
            self.assertEqual(path.read_text(), 'original log\n')

    def test_metadata_edits_break_freeze_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'freeze.json').write_text('{}')
            (base / 'freeze.sha256').write_text(p2.sha(base / 'freeze.json'))
            (base / 'freeze.json').write_text('{"iterations": 64}')
            with self.assertRaisesRegex(ValueError, 'metadata hash'):
                p2.load_frozen(base)


class P2CoreConfigurationTests(unittest.TestCase):
    def helper(self, **environment):
        cleaned = {key: value for key, value in os.environ.items() if key not in p2.CORE_ENVIRONMENT}
        with patch.dict(os.environ, {**cleaned, **environment}, clear=True):
            return p2.core_build_configuration()

    def test_default_p0_remains_an_explicit_control(self):
        record = self.helper()
        self.assertEqual(record['core_config'], p2.CORE_PROFILES['p0'])
        self.assertIn('-DCORE_RETIRE_ENTRIES=16', record['core_flags'])

    def test_p1_all_fields_reach_the_shared_compiler_flags(self):
        record = self.helper(CORE_BACKEND='scoreboard', ISSUE_WIDTH='2', RETIRE_ENTRIES='32',
            SPLIT_ISSUE_QUEUE='1', INTEGER_QUEUE_ENTRIES='8', MEMORY_QUEUE_ENTRIES='4',
            LIMITED_INTEGER_OOO='1', SCHEDULER_FORWARD_MODE='3', PREDICTOR_MODE='1', RAS_ENABLE='1',
            MUL_IMPL='0', DIV_IMPL='1')
        self.assertEqual(record['core_config'], p2.CORE_PROFILES['p1'])
        self.assertEqual(record['core_build_tag'], 'm0d1-p1r1q32i2-scoreboard-s1j8m4-o1-f3')
        for flag in ('-DCORE_RETIRE_ENTRIES=32', '-DCORE_SPLIT_ISSUE_QUEUE=1', '-DCORE_LIMITED_INTEGER_OOO=1',
                     '-DCORE_SCHEDULER_FORWARD_MODE=3', '-DCORE_ISSUE_QUEUE_ENTRIES=8',
                     '-DCORE_MEMORY_QUEUE_ENTRIES=4', '-DCORE_PREDICTOR_MODE=1', '-DCORE_RAS_ENABLE=1'):
            self.assertIn(flag, record['core_flags'])

    def test_shared_validation_rejects_ooo_without_split_queue(self):
        with self.assertRaises(p2.subprocess.CalledProcessError):
            self.helper(LIMITED_INTEGER_OOO='1', SPLIT_ISSUE_QUEUE='0')

    def test_explicit_p1_cannot_fall_back_to_rob16(self):
        with self.assertRaisesRegex(ValueError, 'explicit p1'):
            p2.check_core_profile(p2.CORE_PROFILES['p0'], 'p1')

    def test_actual_compiled_config_must_match_receipt(self):
        p1_line = 'P2_CORE ' + ' '.join(f'{key}={value}' for key, value in p2.CORE_PROFILES['p1'].items()) + '\n'
        self.assertEqual(p2.parse_core_config(p1_line, p2.CORE_PROFILES['p1']), p2.CORE_PROFILES['p1'])
        with self.assertRaisesRegex(ValueError, 'differs from build receipt'):
            p2.parse_core_config(p1_line.replace('retire_entries=32', 'retire_entries=16'), p2.CORE_PROFILES['p1'])
        with self.assertRaisesRegex(ValueError, 'missing compiled'):
            p2.parse_core_config('', p2.CORE_PROFILES['p1'])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            p2.parse_core_config(p1_line + p1_line, p2.CORE_PROFILES['p1'])
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            p2.parse_core_config(p1_line.replace('issue_width=2', 'wrong_width=2'))

    def test_old_logs_keep_unknown_hardware_identity(self):
        self.assertIsNone(p2.parse_core_config('old saved log'))

    def test_core_statistics_keep_overlapping_scheduler_counters(self):
        record = {'window': 'whole_run', 'cycles': 20, 'raw_cycles': 15, 'mdu_resource_cycles': 15}
        text = 'SCHEDULER_STATS ' + json.dumps(record) + '\n'
        self.assertEqual(p2.parse_core_statistics(text)['scheduler_stats'], record)
        with self.assertRaisesRegex(ValueError, 'missing or duplicate'):
            p2.parse_core_statistics(text, p2.CORE_PROFILES['p1'])
        with self.assertRaisesRegex(ValueError, 'missing or duplicate'):
            p2.parse_core_statistics(text + text)

    def test_new_p0_receipt_does_not_require_uninstantiated_split_iq_monitor(self):
        record = {'window': 'whole_run', 'cycles': 20}
        text = 'SCOREBOARD_STATS ' + json.dumps(record) + '\n'
        self.assertEqual(p2.parse_core_statistics(text, p2.CORE_PROFILES['p0'])['scoreboard_stats'], record)
        with self.assertRaisesRegex(ValueError, 'missing or duplicate SCHEDULER_STATS'):
            p2.parse_core_statistics(text, p2.CORE_PROFILES['p1'])

    def test_ordered_split_queue_does_not_require_uninstantiated_integer_iq_monitor(self):
        record = {'window': 'whole_run', 'cycles': 20}
        text = 'SCOREBOARD_STATS ' + json.dumps(record) + '\n'
        config = {**p2.CORE_PROFILES['p0'], 'split_issue_queue': 1}
        self.assertEqual(p2.parse_core_statistics(text, config)['scoreboard_stats'], record)
        with self.assertRaisesRegex(ValueError, 'missing or duplicate SCHEDULER_STATS'):
            p2.parse_core_statistics(text, {**config, 'limited_integer_ooo': 1})

    def test_compilation_helpers_and_passive_binds_are_in_source_receipt(self):
        with patch.object(p2, 'sha', return_value='stub'):
            paths = p2.rtl_sources()
        for path in ('scripts/verilator/p2_core_config.sh', 'scripts/verilator/p1_core_config.sh',
                     'scripts/verilator/core_build_config.sh', 'tb/benchmark/bind_scheduler_metrics.sv'):
            self.assertIn(path, paths)

    def test_build_command_and_receipt_use_p1_configuration(self):
        core = self.helper(CORE_BACKEND='scoreboard', ISSUE_WIDTH='2', RETIRE_ENTRIES='32',
            SPLIT_ISSUE_QUEUE='1', INTEGER_QUEUE_ENTRIES='8', MEMORY_QUEUE_ENTRIES='4',
            LIMITED_INTEGER_OOO='1', SCHEDULER_FORWARD_MODE='3', PREDICTOR_MODE='1', RAS_ENABLE='1')
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            args = SimpleNamespace(sim=base / 'new-sim/Vtb_soc_system', log_root=base,
                                   expect_core_profile='p1')
            commands = []
            def fake_build(command, log):
                commands.append(command)
                log.write_text('no diagnostics\n')
                args.sim.write_bytes(b'new binary')
            with patch.object(p2, 'core_build_configuration', return_value=core), \
                 patch.object(p2, 'rtl_sources', return_value={}), \
                 patch.object(p2, 'copy_sources', return_value={}), \
                 patch.object(p2, 'run', side_effect=fake_build), \
                 patch.object(p2.subprocess, 'check_output', return_value='recorded\n'):
                receipt = p2.build_sim(args)
            self.assertEqual(receipt['core_config'], p2.CORE_PROFILES['p1'])
            self.assertEqual(receipt['core_flags'], core['core_flags'])
            self.assertIn('-DCORE_RETIRE_ENTRIES=32', commands[0])
            self.assertNotIn('-DCORE_RETIRE_ENTRIES=16', commands[0])
            self.assertIn('tb/benchmark/bind_scheduler_metrics.sv', commands[0])


class P2LayoutTests(unittest.TestCase):
    def setUp(self):
        self.symbols = {name: 0x80000100 for name in ('main', 'iterate', 'static_memblk',
            'seed1_volatile', '__bss_start', '__bss_end')}
        self.symbols.update({'__stack_top': 0x80020000, '__stack_limit': 0x8001c000,
            'p2_roi_state': 0x01100100, 'p2_platform': 0x01100110, '_start': 0x01000000, 'start_time': 0x01000100,
            'stop_time': 0x01000140, 'p2_timer_entry': 0x01000180, 'tohost': 0x01100000,
            'sim_console': 0x01100010, '__control_stack_top': 0x01110000,
            '__interrupt_stack_top': 0x0110f000})

    def test_ddr_workload_layout(self):
        self.assertEqual(p2.validate_layout(self.symbols)['__stack_top'], '0x80020000')

    def test_tcm_data_must_not_be_reported_as_m2(self):
        self.symbols['static_memblk'] = 0x01101000
        with self.assertRaisesRegex(ValueError, 'static_memblk'):
            p2.validate_layout(self.symbols)

    def test_tcm_stack_must_not_be_reported_as_m2(self):
        self.symbols['__stack_top'] = 0x01110000
        with self.assertRaisesRegex(ValueError, 'stack'):
            p2.validate_layout(self.symbols)

    def test_wrong_marker_fails(self):
        self.symbols['p2_roi_state'] += 4
        with self.assertRaisesRegex(ValueError, 'ROI'):
            p2.validate_layout(self.symbols)

    def test_readonly_data_outside_ddr_is_rejected(self):
        names = {'.text.init': 0x01000000, '.host': 0x01100000, '.p2_roi': 0x01100100,
                 '.p2_platform': 0x01100110, '.p2_control': 0x01100120,
                 '.text': 0x80000000, '.rodata': 0x01102000, '.data': 0x80002000, '.bss': 0x80003000}
        sections = {name: {'address': address, 'load_address': address, 'bytes': 4} for name, address in names.items()}
        with self.assertRaisesRegex(ValueError, '.rodata allocation'):
            p2.validate_sections(sections)

    def test_orphan_allocated_sections_cannot_escape_checks(self):
        with self.assertRaisesRegex(ValueError, 'unexpected or missing'):
            p2.validate_sections({'.text': {'address': 0x80000000, 'load_address': 0x80000000, 'bytes': 4},
                                  '.orphan': {'address': 0x01102000, 'load_address': 0x01102000, 'bytes': 4}})

    def test_absolute_and_function_symbols_from_nm(self):
        self.assertEqual(p2.symbols_from_nm('80020000 A __stack_top\n80000210 T main\n         U unknown\n'),
                         {'__stack_top': 0x80020000, 'main': 0x80000210})


def write_metrics_log():
    keys = ('accepted completed pending wbursts peak_pending active_cycles source_gap_cycles '
            'downstream_stall_cycles transfer_cycles first_sum first_max gap_count gap_sum gap_max before_aw '
            'roi_accepted roi_completed roi_active_cycles roi_source_gap_cycles roi_downstream_stall_cycles '
            'roi_transfer_cycles roi_first_sum roi_first_max roi_gap_count roi_gap_sum roi_gap_max roi_before_aw').split()
    return ''.join('P2_AXI_W name=' + name + ' domain=' + ('ddr' if name == 'ddr.target' else 'sys') + ' ' +
                   ' '.join(key + '=0' for key in keys) + '\n'
                   for name in ('sys.master0', 'sys.master1', 'sys.master2', 'sys.master3', 'ddr.target'))


class P2SocHardwareTests(unittest.TestCase):
    def test_static_profiles_use_actual_ps_rounded_hz(self):
        self.assertEqual(p2.soc_build_configuration(1)['sys_hz'], 80000000)
        self.assertEqual(p2.soc_build_configuration(4)['sys_hz'], 100000000)
        self.assertEqual(p2.soc_build_configuration(3)['periph_hz'], (10**12 + 13514) // 27028)
        for clock in p2.CLOCKS:
            for fill in (4, 8):
                cfg = p2.soc_build_configuration(clock, fill)
                self.assertEqual(p2.validate_soc_config(cfg), cfg)

    def test_invalid_fill_or_profile_rejected(self):
        for clock, fill in ((5, 4), (1, 16), (None, 4), (1, None)):
            with self.subTest(clock=clock, fill=fill), self.assertRaises(ValueError):
                p2.soc_build_configuration(clock, fill)

    def test_new_hardware_record_and_cache_match(self):
        cfg = p2.soc_build_configuration(1, 8)
        line = 'P2_HARDWARE ' + ' '.join(f'{key}={value}' for key, value in cfg.items()) + '\n'
        text = result_log().replace('icache_bytes=4096', 'icache_fill_bytes=8 icache_bytes=4096') + line + write_metrics_log()
        result = p2.parse_result(text, 'performance', 2, 'cold', expected_soc=cfg)
        self.assertEqual(result['soc_config'], cfg)
        self.assertIsNotNone(result['metrics']['axi_w'])
        with self.assertRaisesRegex(ValueError, 'install width'):
            p2.parse_result(text.replace('icache_fill_bytes=8 icache_bytes', 'icache_fill_bytes=4 icache_bytes'),
                            'performance', 2, 'cold', expected_soc=cfg)

    def test_missing_duplicate_malformed_or_changed_soc_record_rejected(self):
        cfg = p2.soc_build_configuration(1, 4)
        line = 'P2_HARDWARE ' + ' '.join(f'{key}={value}' for key, value in cfg.items()) + '\n'
        for text in ('', line + line, line.replace('sys_hz=80000000', 'sys_hz=100000000'),
                     line.replace('metrics_schema=2', ''), line + 'P2_HARDWARE unknown=1\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                p2.parse_soc_config(text, cfg)
        with self.assertRaisesRegex(ValueError, 'receipt'):
            p2.parse_soc_config(line, p2.soc_build_configuration(1, 8))

    def test_old_receipt_has_unmeasured_w_and_retains_clock_replay(self):
        result = p2.parse_result(result_log(), 'performance', 2, 'cold')
        self.assertIsNone(result['soc_config'])
        self.assertIsNone(result['metrics']['axi_w'])
        self.assertEqual(result['metrics']['axi_w_scope'], 'not_measured')
        p2.validate_sim_selection({}, [0, 1, 2, 3, 4])
        for profile, fill in ((1, None), (None, 4)):
            with self.assertRaisesRegex(ValueError, 'old simulator receipt'):
                p2.validate_sim_selection({}, [1], profile, fill)

    def test_new_receipt_rejects_runtime_clock_or_fill_change(self):
        receipt = {'soc_config': p2.soc_build_configuration(1, 8)}
        p2.validate_sim_selection(receipt, [1], 1, 8)
        for clocks, profile, fill in (([1, 4], None, None), ([1], 4, None), ([1], None, 4)):
            with self.subTest(clocks=clocks, profile=profile, fill=fill), self.assertRaisesRegex(ValueError, 'receipt'):
                p2.validate_sim_selection(receipt, clocks, profile, fill)

    def test_new_metrics_missing_w_or_partial_boundaries_rejected(self):
        with self.assertRaisesRegex(ValueError, 'missing required axi_w'):
            p2.parse_metrics(metrics_log(), [5, 6.25, 4, 20], require_w=True)
        with self.assertRaisesRegex(ValueError, 'missing required axi_w'):
            p2.parse_metrics(metrics_log() + write_metrics_log().replace('name=ddr.target', 'name=wrong.target'), [5, 6.25, 4, 20])

    def test_w_conservation_and_numeric_negative_checks(self):
        for old, new in (('accepted=0', 'accepted=1'), ('active_cycles=0', 'active_cycles=1'),
                         ('roi_first_sum=0', 'roi_first_sum=1'), ('gap_sum=0', 'gap_sum=-1')):
            with self.subTest(new=new), self.assertRaises(ValueError):
                p2.parse_metrics(metrics_log() + write_metrics_log().replace(old, new, 1), [5, 6.25, 4, 20])

    def test_build_soc_parameters_are_explicit(self):
        core = {'core_config': p2.CORE_PROFILES['p1'], 'core_flags': ['-DCORE_RETIRE_ENTRIES=32'], 'core_build_tag': 'p1'}
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            args = SimpleNamespace(sim=base/'sim/Vtb_soc_system', log_root=base, expect_core_profile='p1',
                                   clock_profile=4, icache_fill_bytes=8, clocks=[4])
            commands = []
            def fake_build(command, log):
                commands.append(command); log.write_text('clean\n'); args.sim.write_bytes(b'binary')
            with patch.object(p2, 'core_build_configuration', return_value=core), \
                 patch.object(p2, 'rtl_sources', return_value={}), patch.object(p2, 'copy_sources', return_value={}), \
                 patch.object(p2, 'run', side_effect=fake_build), patch.object(p2.subprocess, 'check_output', return_value='test\n'):
                receipt = p2.build_sim(args)
            self.assertEqual(receipt['schema'], 3)
            self.assertEqual(receipt['soc_config'], p2.soc_build_configuration(4, 8))
            self.assertIn('-GCLOCK_PROFILE=4', commands[0])
            self.assertIn('-DSOC_ICACHE_FILL_BYTES=8', commands[0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
