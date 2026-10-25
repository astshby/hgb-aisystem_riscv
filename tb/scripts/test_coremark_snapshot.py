#!/usr/bin/env python3
"""Focused freeze/replay contract tests; all artifacts and simulator stubs are temporary."""

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="coremark-snapshot-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts/verilator"
        scripts.mkdir(parents=True)
        for name in ("coremark_snapshot.py", "run_coremark.sh"):
            shutil.copyfile(REPO / "scripts/verilator" / name, scripts / name)
        self.helper = scripts / "coremark_snapshot.py"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("COREMARK_", "SOC_")) or key in (
                    "SOC", "STUB_BAD", "PREDICTOR_MODE", "RAS_ENABLE", "RETIRE_ENTRIES",
                    "ISSUE_WIDTH", "CORE_BACKEND", "SPLIT_ISSUE_QUEUE",
                    "INTEGER_QUEUE_ENTRIES", "MEMORY_QUEUE_ENTRIES", "LIMITED_INTEGER_OOO", "SCHEDULER_FORWARD_MODE"):
                self.env.pop(key)
        self.env.update(MUL_IMPL="0", DIV_IMPL="1", RISCV_TOOL_ROOT=str(self.tools))
        self.executable(self.tools / "riscv64-unknown-elf-nm", "print('00004000 B tohost\\n00004008 B sim_console')\n")
        self.executable(self.tools / "riscv64-unknown-elf-readelf",
                        "import pathlib, sys\nxlen = 32 if pathlib.Path(sys.argv[-1]).read_bytes()[4] == 1 else 64\n"
                        "print(f'Tag_RISCV_arch: \"rv{xlen}i2p1_m2p0_zicsr2p0_zmmul1p0\"')\n")
        self.executable(self.root / "simulator", '''import os, pathlib, sys
arguments = dict(arg[1:].split('=', 1) if '=' in arg else (arg[1:], '1') for arg in sys.argv[1:])
image = pathlib.Path(arguments['IMEM'])
text = (image.parent / 'baseline.log').read_text()
bad = os.environ.get('STUB_BAD', '')
if bad == 'iterations': text = text.replace('Iterations       : 24', 'Iterations       : 25')
if bad == 'crc': text = text.replace('0xe714', '0x0000')
if bad == 'mode': text = text.replace('validation run', 'performance run')
if bad == 'fatal': text += '%Error: injected failure\\n'
if bad == 'metrics-partition': text = text.replace('"issue_0": 1000', '"issue_0": 999')
if bad == 'metrics-window': text = text.replace('"cycles": 11010001', '"cycles": 11010002')
if bad == 'metrics-stall': text = text.replace('"no_issue_empty": 1000', '"no_issue_empty": 999')
if bad == 'metrics-negative': text = text.replace('"memory_requests": 10', '"memory_requests": -1')
if bad.startswith('soc-metrics-window-'):
    text = text.replace('cycles=11010000 clocks=', 'cycles=' + bad.rsplit('-', 1)[1] + ' clocks=')
if bad == 'metrics-duplicate':
    text += next(line for line in text.splitlines() if line.startswith('SCOREBOARD_STATS')) + '\\n'
if bad.startswith('short'):
    text = text.replace('Total ticks      : 11000000', 'Total ticks      : 9000000')
    text = text.replace('Total time (secs): 11', 'Total time (secs): 9')
    text = text.replace('Iterations       : 24', 'ERROR! Must execute for at least 10 secs for a valid result!\\nIterations       : 24')
    text = text.replace('Correct operation validated.', 'Errors detected')
    if bad == 'short-crc': text = text.replace('0xe714', '0x0000')
    if bad == 'short-error': text += '[0]ERROR! state crc wrong\\n'
if bad == 'mutate': image.write_text(image.read_text() + '00\\n')
print(text, end='')
''')
        # Replay may build RTL, but neither the image builder nor calibration is reachable.
        (scripts / "build_benchmark_image.sh").write_text("touch software-build-was-called\nexit 99\n")
        (scripts / "build_benchmark_sim.sh").write_text(
            'touch rtl-build-was-called\nmkdir -p "build/verilator/benchmark-rv$1-m0d1"\n'
            'cp simulator "build/verilator/benchmark-rv$1-m0d1/Vtb_benchmark"\n')
        self.make_inputs(32)

    @staticmethod
    def executable(path, source):
        path.write_text("#!/usr/bin/env python3\n" + source)
        path.chmod(0o755)

    def make_inputs(self, xlen):
        (self.root / "input-logs").mkdir(exist_ok=True)
        for mode in ("performance", "validation"):
            directory = self.root / "images" / mode
            directory.mkdir(parents=True, exist_ok=True)
            header = bytearray(64)
            header[:6] = b"\x7fELF" + bytes([1 if xlen == 32 else 2, 1])
            struct.pack_into("<H", header, 18, 243)
            (directory / "program.elf").write_bytes(header)
            (directory / "imem.hex").write_text("00000013\n")
            (directory / "dmem.hex").write_text("00000000\n")
            log = (f"2K {mode} run parameters for coremark.\n"
                   "Total ticks      : 11000000\nTotal time (secs): 11\nIterations       : 24\n"
                   f"Compiler version : test\nCompiler flags   : -O2 -march=rv{xlen}im_zicsr\n"
                   "seedcrc          : 0xe9f5\n[0]crclist       : 0xe714\n[0]crcmatrix     : 0x1fd7\n"
                   "[0]crcstate      : 0x8e3a\n[0]crcfinal      : 0x6c74\nCorrect operation validated.\n"
                   f"PASS coremark-{mode} RV{xlen} cycles=11010000\n")
            (self.root / "input-logs" / f"coremark-{mode}-rv{xlen}-m0d1.log").write_text(log)

    def call(self, command, success=True, **environment):
        result = subprocess.run(command, cwd=self.root, env={**self.env, **environment},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse((self.root / "software-build-was-called").exists())
        return result

    def freeze(self, xlen=32, success=True):
        return self.call([sys.executable, str(self.helper), "freeze", "images", "frozen",
                          "--xlen", str(xlen), "--log-dir", "input-logs", "--max-cycles", "100000000"],
                         success=success)

    def replay(self, xlen=32, success=True, explicit=True, **environment):
        env = {"COREMARK_REPLAY_DIR": str(self.root / "frozen"), **environment}
        if explicit:
            env.update(COREMARK_REPLAY_SIM=str(self.root / "simulator"), COREMARK_REPLAY_SIM_SOURCE="test stub")
        return self.call(["bash", "scripts/verilator/run_coremark.sh", str(xlen)], success=success, **env)

    def soc_inputs(self, xlen=32):
        self.env["SOC"] = "1"
        self.make_inputs(xlen)
        self.executable(self.tools / "riscv64-unknown-elf-nm",
                        "print('01104000 B tohost\\n01104008 B sim_console')\n")
        for mode in ("performance", "validation"):
            logs = self.root / "input-logs"
            shutil.copyfile(logs / f"coremark-{mode}-rv{xlen}-m0d1.log",
                            logs / f"coremark-{mode}-rv{xlen}-m0d1-soc.log")

    def platform_helper(self, local_tcm=False, profile=False, dma_wide=False, cache_block=False, dma_block=False):
        scripts = self.root / "scripts/verilator"
        selection = 'config="${config}-soc"\n'
        if profile:
            selection += ('bench_soc_profile="${SOC_PROFILE:-full}"\n'
                          'config="${config}-p${bench_soc_profile}"\n')
        if local_tcm:
            selection += ('bench_local_tcm_enable="${SOC_LOCAL_TCM_ENABLE:-0}"\n'
                          'config="${config}-ltcm${bench_local_tcm_enable}"\n')
        if dma_wide:
            selection += ('bench_dma_wide_enable="${SOC_DMA_WIDE_ENABLE:-0}"\n'
                          'config="${config}-dw${bench_dma_wide_enable}"\n')
        if cache_block:
            selection += ('bench_cache_block_enable="${SOC_CACHE_BLOCK_ENABLE:-0}"\n'
                          'config="${config}-cb${bench_cache_block_enable}"\n')
        if dma_block:
            selection += ('bench_dma_block_enable="${SOC_DMA_BLOCK_ENABLE:-0}"\n'
                          'config="${config}-db${bench_dma_block_enable}"\n')
        (scripts / "benchmark_platform.sh").write_text(selection)
        (scripts / "build_benchmark_sim.sh").write_text(
            'touch rtl-build-was-called\nconfig=m0d1\nsource scripts/verilator/benchmark_platform.sh\n'
            'mkdir -p "build/verilator/benchmark-rv$1-${config}"\n'
            'cp simulator "build/verilator/benchmark-rv$1-${config}/Vtb_soc_benchmark"\n')

    def test_replay_both_widths_and_modes_without_build_or_calibration(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                self.make_inputs(xlen)
                self.freeze(xlen)
                result = self.replay(xlen)
                self.assertIn(f"PASS CoreMark replay performance RV{xlen}", result.stdout)
                self.assertIn(f"PASS CoreMark replay validation RV{xlen}", result.stdout)
                self.assertNotIn("calibration", result.stdout)
                self.assertFalse((self.root / "rtl-build-was-called").exists())
                shutil.rmtree(self.root / "frozen")

    def test_default_replay_builds_only_rtl(self):
        self.freeze()
        self.replay(explicit=False)
        self.assertTrue((self.root / "rtl-build-was-called").exists())

    def test_scoreboard_metrics_are_validated_and_preserved(self):
        counters = dict(window="whole_run", cycles=11010001,
                        issue_0=1000, issue_1=10000000, issue_2=1009001,
                        retire_0=1000, retire_1=10000000, retire_2=1009001,
                        no_issue_redirect=0, no_issue_empty=1000, no_issue_raw=0, no_issue_lsq=0,
                        no_issue_mdu=0, no_issue_serial=0, no_issue_result=0, no_issue_other=0,
                        dispatch_rob_full=2, dispatch_iq_full=3, dispatch_checkpoint=4,
                        completion_pressure=5, memory_requests=10, memory_responses=10, forwarded_loads=2)
        for log in (self.root / "input-logs").glob("*.log"):
            log.write_text(log.read_text() + "SCOREBOARD_STATS " + json.dumps(counters) + "\n")
        self.freeze()
        self.replay()
        report = json.loads(next((self.root / "logs").glob("*/result.json")).read_text())
        for mode in ("performance", "validation"):
            self.assertEqual(report["modes"][mode]["scoreboard_metrics"], counters)
        for failure in ("partition", "window", "stall", "negative", "duplicate"):
            with self.subTest(failure=failure):
                self.replay(success=False, STUB_BAD="metrics-" + failure)

    def test_four_clock_soc_metadata_survives_freeze_and_replay(self):
        suffix = (" clocks=C1 core_half_ns=5.000000 sys_half_ns=6.250000"
                  " ddr_half_ns=4.000000 periph_half_ns=20.000000 SPI_reads=73")
        for log in (self.root / "input-logs").glob("*.log"):
            log.write_text(log.read_text().replace("cycles=11010000\n", "cycles=11010000" + suffix + "\n"))
        self.freeze()
        self.replay()
        report = json.loads(next((self.root / "logs").glob("*/result.json")).read_text())
        for mode in ("performance", "validation"):
            clocks = report["modes"][mode]["simulation_clocks"]
            self.assertEqual(clocks["configuration"], "C1")
            self.assertEqual(clocks["half_period_ns"], {"core": 5, "sys": 6.25, "ddr": 4, "periph": 20})
            self.assertEqual(clocks["spi_reads"], 73)

    def test_p1_profile_and_p2_topology_replay_the_same_old_images(self):
        self.soc_inputs()
        self.freeze()
        original = (self.root / 'frozen/manifest.json').read_bytes()
        for name in ('benchmark_platform.sh', 'core_build_config.sh'):
            shutil.copyfile(REPO / 'scripts/verilator' / name, self.root / 'scripts/verilator' / name)
        shutil.copyfile(REPO / 'scripts/soc_profile.sh', self.root / 'scripts/soc_profile.sh')
        self.replay(CORE_BACKEND='scoreboard', ISSUE_WIDTH='2', RETIRE_ENTRIES='32',
                    SPLIT_ISSUE_QUEUE='1', INTEGER_QUEUE_ENTRIES='8', MEMORY_QUEUE_ENTRIES='4',
                    LIMITED_INTEGER_OOO='1', SCHEDULER_FORWARD_MODE='3', PREDICTOR_MODE='1', RAS_ENABLE='1',
                    COREMARK_REPLAY_SOC_METRICS='1')
        report = json.loads(next((self.root / 'logs').glob('*/result.json')).read_text())
        parameters = report['rtl_parameters']
        self.assertEqual(parameters['system_bus'], 'axi4')
        self.assertEqual(parameters['retire_entries'], 32)
        self.assertEqual(parameters['limited_integer_ooo'], 1)
        self.assertEqual(parameters['scheduler_forward_mode'], 3)
        self.assertTrue(parameters['actual_unified_dma'])
        self.assertEqual((self.root / 'frozen/manifest.json').read_bytes(), original)
        self.assertTrue(report['soc_memory_observation'])
        for mode in ('performance', 'validation'):
            self.assertIn('+P2_METRICS', report['modes'][mode]['command'])
            self.assertIn('+P2_EXPECT_M1', report['modes'][mode]['command'])
            self.assertNotIn('+P2_PLATFORM', report['modes'][mode]['command'])

    def test_soc_observation_cannot_silently_apply_to_core_only_harness(self):
        self.freeze()
        for setting in ('1', 'yes'):
            self.replay(success=False, COREMARK_REPLAY_SOC_METRICS=setting)

    def test_counter_window_is_runtime_metadata_not_a_new_frozen_image_requirement(self):
        self.freeze()
        manifest = json.loads((self.root / 'frozen/manifest.json').read_text())
        for mode in ('performance', 'validation'):
            self.assertNotIn('core_statistics_counter_offset', manifest['modes'][mode])
        self.replay()
        report = json.loads(next((self.root / 'logs').glob('*/result.json')).read_text())
        self.assertEqual(report['modes']['performance']['core_statistics_counter_offset'], 1)

    def test_four_clock_scoreboard_window_has_its_own_exact_offset(self):
        counters = dict(window='whole_run', cycles=11009999,
                        issue_0=1000, issue_1=10000000, issue_2=1008999,
                        retire_0=1000, retire_1=10000000, retire_2=1008999,
                        no_issue_redirect=0, no_issue_empty=1000, no_issue_raw=0, no_issue_lsq=0,
                        no_issue_mdu=0, no_issue_serial=0, no_issue_result=0, no_issue_other=0,
                        dispatch_rob_full=2, dispatch_iq_full=3, dispatch_checkpoint=4,
                        completion_pressure=5, memory_requests=10, memory_responses=10, forwarded_loads=2)
        suffix = (' clocks=C1 core_half_ns=5.000000 sys_half_ns=6.250000'
                  ' ddr_half_ns=4.000000 periph_half_ns=20.000000 SPI_reads=0')
        for log in (self.root / 'input-logs').glob('*.log'):
            log.write_text(log.read_text().replace('cycles=11010000\n', 'cycles=11010000' + suffix + '\n') +
                           'SCOREBOARD_STATS ' + json.dumps(counters) + '\n')
        self.freeze()
        self.replay()
        report = json.loads(next((self.root / 'logs').glob('*/result.json')).read_text())
        self.assertEqual(report['modes']['performance']['core_statistics_counter_offset'], -1)
        # 改 PASS 窗口而不改计数器，0/+1/-2 均必须拒绝，不能靠容差吞下差异。
        for cycles in (11009999, 11009998, 11010001):
            result = self.replay(success=False, STUB_BAD='soc-metrics-window-' + str(cycles))
            self.assertIn('scoreboard metrics/harness window mismatch', result.stderr)

    def test_scheduler_metrics_survive_freeze_and_replay(self):
        counters = dict(window='whole_run', cycles=11010001, occupied_cycles=11000000,
                        ready_cycles=10000000, full_cycles=20, raw_cycles=500000,
                        raw_alu_cycles=200000, raw_mdu_cycles=300000, raw_load_cycles=300000,
                        mdu_resource_cycles=200, mdu_iq_idle_cycles=100, accepted_cycles=9000000,
                        accepted_operations=10000000, bypass_raw_cycles=300, bypass_mdu_cycles=50)
        for log in (self.root / 'input-logs').glob('*.log'):
            log.write_text(log.read_text() + 'SCHEDULER_STATS ' + json.dumps(counters) + '\n')
        self.freeze()
        self.replay()
        report = json.loads(next((self.root / 'logs').glob('*/result.json')).read_text())
        for mode in ('performance', 'validation'):
            self.assertEqual(report['modes'][mode]['scheduler_metrics'], counters)

    def test_invalid_clock_suffix_does_not_validate_completion(self):
        suffix = (" clocks=C1 core_half_ns=5.000000 sys_half_ns=6.250000"
                  " ddr_half_ns=4.000000 periph_half_ns=20.000000 SPI_reads=0")
        for bad in (suffix.replace("C1", "C9"), suffix.replace("5.000000", "0.000000"), suffix + " garbage"):
            with self.subTest(suffix=bad):
                self.make_inputs(32)
                for log in (self.root / "input-logs").glob("*.log"):
                    log.write_text(log.read_text().replace("cycles=11010000\n", "cycles=11010000" + bad + "\n"))
                self.freeze(success=False)

    def test_freeze_rejects_existing_target_and_missing_mode(self):
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.freeze(success=False)
        self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
        shutil.rmtree(self.root / "frozen")
        (self.root / "images/validation/program.elf").unlink()
        self.freeze(success=False)
        self.assertFalse((self.root / "frozen").exists())

    def test_configuration_mismatch_fails_before_rtl_build(self):
        self.freeze()
        for override in ({"SOC": "1"}, {"DIV_IMPL": "0"}, {"COREMARK_ITERATIONS": "25"}):
            with self.subTest(override=override):
                self.replay(success=False, explicit=False, **override)
                self.assertFalse((self.root / "rtl-build-was-called").exists())
        self.replay(64, success=False, explicit=False)

    def test_hash_tampering_is_rejected(self):
        self.freeze()
        for name in ("program.elf", "imem.hex", "dmem.hex", "baseline.log"):
            with self.subTest(name=name):
                path = self.root / "frozen/performance" / name
                original = path.read_bytes()
                path.write_bytes(original + b"tamper")
                self.replay(success=False, explicit=False)
                self.assertFalse((self.root / "rtl-build-was-called").exists())
                path.write_bytes(original)

    def test_replay_checks_output_and_post_run_hashes(self):
        self.freeze()
        for bad in ("iterations", "crc", "mode", "fatal", "mutate"):
            with self.subTest(bad=bad):
                self.replay(success=False, STUB_BAD=bad)

    def test_short_duration_requires_opt_in_and_exact_crc(self):
        self.freeze()
        self.replay(success=False, STUB_BAD="short")
        result = self.replay(STUB_BAD="short", COREMARK_REPLAY_ALLOW_SHORT="1")
        self.assertEqual(result.stdout.count("SKIP CoreMark"), 2)
        for bad in ("short-crc", "short-error"):
            self.replay(success=False, STUB_BAD=bad, COREMARK_REPLAY_ALLOW_SHORT="1")

    def test_explicit_simulator_requires_provenance(self):
        self.freeze()
        self.call([sys.executable, str(self.helper), "replay", "frozen", "--xlen", "32"], success=False,
                  COREMARK_REPLAY_SIM=str(self.root / "simulator"))

    def test_local_tcm_reuses_old_snapshot_and_records_each_candidate(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                self.soc_inputs(xlen)
                self.platform_helper()
                self.freeze(xlen)
                original = (self.root / "frozen/manifest.json").read_bytes()
                self.platform_helper(local_tcm=True)
                for setting in ("0", "1"):
                    result = self.replay(xlen, explicit=False, SOC_LOCAL_TCM_ENABLE=setting)
                    self.assertIn(f"-soc-ltcm{setting}", result.stdout)
                    reports = list((self.root / "logs").glob(
                        f"coremark-replay-rv{xlen}-m0d1-soc-ltcm{setting}-*/result.json"))
                    self.assertEqual(len(reports), 1)
                    report = json.loads(reports[0].read_text())
                    self.assertEqual(report["rtl_parameters"], {
                        "local_tcm_enable": int(setting), "local_tcm_parameter_supported": True,
                        "core_backend": None, "ddr_model_bytes": None,
                        "soc_clock_hz": None, "uart_divisor": None,
                        "soc_profile": "full", "soc_profile_parameter_supported": False,
                        "dma_wide_enable": 0, "dma_wide_parameter_supported": False,
                        "cache_block_enable": 0, "cache_block_parameter_supported": False,
                        "dma_block_enable": 0, "dma_block_parameter_supported": False,
                        "predictor_mode": None, "predictor_mode_parameter_supported": False,
                        "ras_enable": None, "ras_enable_parameter_supported": False,
                        "retire_entries": None, "retire_entries_parameter_supported": False,
                        "issue_width": None, "issue_width_parameter_supported": False,
                        "split_issue_queue": None, "split_issue_queue_parameter_supported": False,
                        "integer_queue_entries": None, "integer_queue_entries_parameter_supported": False,
                        "memory_queue_entries": None, "memory_queue_entries_parameter_supported": False,
                        "limited_integer_ooo": None, "limited_integer_ooo_parameter_supported": False,
                        "scheduler_forward_mode": None, "scheduler_forward_mode_parameter_supported": False})
                    self.assertNotIn("local_tcm_enable", report["config"])
                    self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
                shutil.rmtree(self.root / "frozen")

    def test_legacy_soc_builder_and_rejected_unavailable_parameter(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        self.replay(explicit=False, success=False, SOC_LOCAL_TCM_ENABLE="1")
        self.assertFalse((self.root / "rtl-build-was-called").exists())
        self.replay(explicit=False, SOC_LOCAL_TCM_ENABLE="0")
        reports = list((self.root / "logs").glob("*/result.json"))
        self.assertFalse(json.loads(reports[0].read_text())["rtl_parameters"]["local_tcm_parameter_supported"])

    def test_invalid_or_core_only_local_tcm_fails_before_rtl_build(self):
        self.freeze()
        for setting in ("1", "2", "", "true", "-1"):
            with self.subTest(setting=setting):
                self.replay(explicit=False, success=False, SOC_LOCAL_TCM_ENABLE=setting)
                self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_freeze_new_hardware_named_logs_does_not_lock_routing(self):
        self.soc_inputs()
        self.platform_helper(local_tcm=True)
        self.env["SOC_LOCAL_TCM_ENABLE"] = "1"
        for mode in ("performance", "validation"):
            logs = self.root / "input-logs"
            shutil.copyfile(logs / f"coremark-{mode}-rv32-m0d1-soc.log",
                            logs / f"coremark-{mode}-rv32-m0d1-soc-ltcm1.log")
        self.freeze()
        manifest = json.loads((self.root / "frozen/manifest.json").read_text())
        self.assertEqual(manifest["freeze_rtl_parameters"]["local_tcm_enable"], 1)
        self.assertNotIn("local_tcm_enable", manifest["config"])
        self.replay(explicit=False, SOC_LOCAL_TCM_ENABLE="0")

    def test_device_profiles_replay_identical_old_images(self):
        for xlen in (32, 64):
            with self.subTest(xlen=xlen):
                self.soc_inputs(xlen)
                self.platform_helper()
                self.freeze(xlen)
                original = (self.root / "frozen/manifest.json").read_bytes()
                self.platform_helper(profile=True)
                for setting in ("full", "lite"):
                    result = self.replay(xlen, explicit=False, SOC_PROFILE=setting)
                    self.assertIn(f"-soc-p{setting}", result.stdout)
                    reports = list((self.root / "logs").glob(
                        f"coremark-replay-rv{xlen}-m0d1-soc-p{setting}-*/result.json"))
                    self.assertEqual(len(reports), 1)
                    report = json.loads(reports[0].read_text())
                    self.assertEqual(report["rtl_parameters"]["soc_profile"], setting)
                    self.assertTrue(report["rtl_parameters"]["soc_profile_parameter_supported"])
                    self.assertNotIn("soc_profile", report["config"])
                    self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
                shutil.rmtree(self.root / "frozen")

    def test_profile_and_local_tcm_are_separate_candidate_dimensions(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        self.platform_helper(local_tcm=True, profile=True)
        for profile in ("full", "lite"):
            for local_tcm in ("0", "1"):
                result = self.replay(explicit=False, SOC_PROFILE=profile, SOC_LOCAL_TCM_ENABLE=local_tcm)
                self.assertIn(f"-soc-p{profile}-ltcm{local_tcm}", result.stdout)
        self.assertEqual(len(list((self.root / "logs").glob("*/result.json"))), 4)

    def test_unavailable_profile_is_rejected_before_build(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        self.replay(explicit=False, success=False, SOC_PROFILE="lite")
        self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_invalid_or_core_only_profile_fails_before_build(self):
        self.freeze()
        for setting in ("lite", "0", "1", "", "reduced"):
            with self.subTest(setting=setting):
                self.replay(explicit=False, success=False, SOC_PROFILE=setting)
                self.assertFalse((self.root / "rtl-build-was-called").exists())

    def core_helper(self, reported=None):
        scripts = self.root / "scripts/verilator"
        source = ('core_predictor_mode="${PREDICTOR_MODE:-0}"\n'
                  'core_ras_enable="${RAS_ENABLE:-0}"\n'
                  'core_retire_entries="${RETIRE_ENTRIES:-4}"\n'
                  'core_issue_width="${ISSUE_WIDTH:-1}"\n')
        if reported:
            for name, value in reported.items():
                source += f'{name}="{value}"\n'
        source += ('config="${config}-p${core_predictor_mode}r${core_ras_enable}'
                   'q${core_retire_entries}i${core_issue_width}"\n')
        (scripts / "benchmark_platform.sh").write_text(source)
        (scripts / "build_benchmark_sim.sh").write_text(
            'touch rtl-build-was-called\nconfig=m0d1\nsource scripts/verilator/benchmark_platform.sh\n'
            'mkdir -p "build/verilator/benchmark-rv$1-${config}"\n'
            'cp simulator "build/verilator/benchmark-rv$1-${config}/Vtb_benchmark"\n')

    def test_core_candidates_share_frozen_software_and_record_rtl_parameters(self):
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.core_helper()
        for mode, ras, entries, width in (("0", "0", "2", "1"), ("1", "0", "4", "2"), ("1", "1", "8", "2"), ("0", "0", "32", "2")):
            result = self.replay(explicit=False, PREDICTOR_MODE=mode, RAS_ENABLE=ras,
                                 RETIRE_ENTRIES=entries, ISSUE_WIDTH=width)
            self.assertIn(f"p{mode}r{ras}q{entries}i{width}", result.stdout)
            report_path = next((self.root / "logs").glob(
                f"coremark-replay-rv32-m0d1-p{mode}r{ras}q{entries}i{width}-*/result.json"))
            report = json.loads(report_path.read_text())
            for key, expected in (("predictor_mode", int(mode)), ("ras_enable", int(ras)),
                                  ("retire_entries", int(entries)), ("issue_width", int(width))):
                self.assertEqual(report["rtl_parameters"][key], expected)
                self.assertTrue(report["rtl_parameters"][f"{key}_parameter_supported"])
                self.assertNotIn(key, report["config"])
            self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)

    def test_split_scheduler_parameters_are_reported_and_validated(self):
        self.freeze()
        self.core_helper({"core_split_issue_queue": "1", "core_integer_queue_entries": "8",
                          "core_memory_queue_entries": "4"})
        self.replay(explicit=False, RETIRE_ENTRIES="32", ISSUE_WIDTH="2",
                    SPLIT_ISSUE_QUEUE="1", INTEGER_QUEUE_ENTRIES="8", MEMORY_QUEUE_ENTRIES="4")
        report = json.loads(next((self.root / "logs").glob('*/result.json')).read_text())
        for key, value in (("split_issue_queue", 1), ("integer_queue_entries", 8), ("memory_queue_entries", 4)):
            self.assertEqual(report["rtl_parameters"][key], value)
        (self.root / "rtl-build-was-called").unlink()
        self.replay(explicit=False, success=False, MEMORY_QUEUE_ENTRIES="2")
        self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_limited_issue_parameter_is_reported_without_changing_images(self):
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.core_helper({"core_limited_integer_ooo": "1"})
        self.replay(explicit=False, LIMITED_INTEGER_OOO="1")
        report = json.loads(next((self.root / "logs").glob('*/result.json')).read_text())
        self.assertEqual(report["rtl_parameters"]["limited_integer_ooo"], 1)
        self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
        (self.root / "rtl-build-was-called").unlink()
        self.replay(explicit=False, success=False, LIMITED_INTEGER_OOO="0")
        self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_forward_modes_are_recorded_with_the_same_frozen_software(self):
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        for mode in ("0", "1", "2", "3"):
            with self.subTest(mode=mode):
                before = set((self.root / "logs").glob('*/result.json')) if (self.root / "logs").exists() else set()
                self.core_helper({"core_scheduler_forward_mode": mode})
                helper = self.root / "scripts/verilator/benchmark_platform.sh"
                helper.write_text(helper.read_text() + f'config="${{config}}-f{mode}"\n')
                self.replay(explicit=False, SCHEDULER_FORWARD_MODE=mode)
                added = set((self.root / "logs").glob('*/result.json')) - before
                self.assertEqual(len(added), 1)
                report = json.loads(added.pop().read_text())
                self.assertEqual(report["rtl_parameters"]["scheduler_forward_mode"], int(mode))
                self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
        (self.root / "rtl-build-was-called").unlink()
        for mode in ("4", "1"):
            self.replay(explicit=False, success=False, SCHEDULER_FORWARD_MODE=mode)
            self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_unreported_core_parameter_is_not_guessed_from_environment(self):
        self.freeze()
        for override in ({"PREDICTOR_MODE": "0"}, {"RAS_ENABLE": "1"}, {"RETIRE_ENTRIES": "4"}, {"ISSUE_WIDTH": "2"}):
            with self.subTest(override=override):
                self.replay(explicit=False, success=False, **override)
                self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_invalid_core_parameters_fail_before_build(self):
        self.freeze()
        self.core_helper()
        for variable in ("PREDICTOR_MODE", "RAS_ENABLE", "RETIRE_ENTRIES", "ISSUE_WIDTH"):
            for value in ("-1", "", "3", "true"):
                with self.subTest(variable=variable, value=value):
                    self.replay(explicit=False, success=False, **{variable: value})
                    self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_core_helper_mismatch_and_malformed_report_are_rejected(self):
        self.freeze()
        self.core_helper({"core_predictor_mode": "0"})
        self.replay(explicit=False, success=False, PREDICTOR_MODE="1")
        self.assertFalse((self.root / "rtl-build-was-called").exists())
        self.core_helper({"core_retire_entries": "3"})
        result = self.replay(explicit=False, success=False)
        self.assertIn("invalid benchmark helper retire_entries", result.stderr)
        self.assertFalse((self.root / "rtl-build-was-called").exists())

    def test_wide_dma_candidates_keep_software_bytes_and_separate_models(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.platform_helper(dma_wide=True)
        for setting in ("0", "1"):
            result = self.replay(explicit=False, SOC_DMA_WIDE_ENABLE=setting)
            self.assertIn(f"-dw{setting}", result.stdout)
            report_path = next((self.root / "logs").glob(
                f"coremark-replay-rv32-m0d1-soc-dw{setting}-*/result.json"))
            report = json.loads(report_path.read_text())
            self.assertEqual(report["rtl_parameters"]["dma_wide_enable"], int(setting))
            self.assertTrue(report["rtl_parameters"]["dma_wide_parameter_supported"])
            self.assertNotIn("dma_wide_enable", report["config"])
            self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)

    def test_unavailable_invalid_and_core_only_wide_dma_are_rejected(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        for setting in ("1", "2", "", "true"):
            with self.subTest(setting=setting):
                self.replay(explicit=False, success=False, SOC_DMA_WIDE_ENABLE=setting)
                self.assertFalse((self.root / "rtl-build-was-called").exists())
        self.env["SOC"] = "0"
        self.replay(explicit=False, success=False, SOC_DMA_WIDE_ENABLE="1")

    def test_cache_block_candidates_keep_frozen_software_and_record_interface(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.replay(explicit=False, success=False, SOC_CACHE_BLOCK_ENABLE="1")
        self.platform_helper(cache_block=True)
        for setting in ("0", "1"):
            self.replay(explicit=False, SOC_CACHE_BLOCK_ENABLE=setting)
            report_path = next((self.root / "logs").glob(f"*soc-cb{setting}-*/result.json"))
            parameters = json.loads(report_path.read_text())["rtl_parameters"]
            self.assertEqual(parameters["cache_block_enable"], int(setting))
            self.assertTrue(parameters["cache_block_parameter_supported"])
        for setting in ("2", "", "true"):
            self.replay(explicit=False, success=False, SOC_CACHE_BLOCK_ENABLE=setting)
        self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
        self.env["SOC"] = "0"
        self.replay(explicit=False, success=False, SOC_CACHE_BLOCK_ENABLE="1")

    def test_dma_block_candidates_keep_frozen_bytes_and_do_not_silently_fallback(self):
        self.soc_inputs()
        self.platform_helper()
        self.freeze()
        original = (self.root / "frozen/manifest.json").read_bytes()
        self.replay(explicit=False, success=False, SOC_DMA_BLOCK_ENABLE="1")
        self.platform_helper(dma_block=True)
        for setting in ("0", "1"):
            self.replay(explicit=False, SOC_DMA_BLOCK_ENABLE=setting)
            report_path = next((self.root / "logs").glob(f"*soc-db{setting}-*/result.json"))
            parameters = json.loads(report_path.read_text())["rtl_parameters"]
            self.assertEqual(parameters["dma_block_enable"], int(setting))
            self.assertTrue(parameters["dma_block_parameter_supported"])
        for setting in ("2", "", "true"):
            self.replay(explicit=False, success=False, SOC_DMA_BLOCK_ENABLE=setting)
        self.assertEqual((self.root / "frozen/manifest.json").read_bytes(), original)
        self.env["SOC"] = "0"
        self.replay(explicit=False, success=False, SOC_DMA_BLOCK_ENABLE="1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
