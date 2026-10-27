#!/usr/bin/env python3
"""Offline diagnostic staging contract tests; never invoke PDS or board tools."""
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.pango import prepare_measurement as measurement
from scripts.pango import prepare_project as board
from scripts.pango import summarize_measurement as summary


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class MeasurementStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pango-measure-test-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        # 用真实源清单测试依赖闭包；RTL内容只作不可执行的 staging fixture。
        lists = set()

        def copy_list(name):
            if name in lists:
                return
            lists.add(name)
            text = (REPO / name).read_text()
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
            for line in text.splitlines():
                line = line.split("#", 1)[0].strip()
                if line.startswith("-f "):
                    copy_list(line[3:].strip())
                elif line and not line.startswith("-"):
                    path = self.repo / line
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("// Offline staging bytes; not elaborated hardware.\n")

        copy_list("scripts/soc_files.f")
        self.source_lists = lists
        for name in measurement.EXTRA_SOURCES:
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// Mutable diagnostic fixture.\n")
        (self.repo / "scripts/pango").mkdir(parents=True, exist_ok=True)
        for name in ("implement.tcl", "memory_gate.ps1", "memory_guard.ps1"):
            shutil.copyfile(REPO / "scripts/pango" / name, self.repo / "scripts/pango" / name)
        # 新stager还绑定脚本自身身份时，fixture使用当前真实工具字节。
        for path in (REPO / "scripts/pango").glob("*measurement*.py"):
            shutil.copyfile(path, self.repo / "scripts/pango" / path.name)
        self.output = self.base / "output"

        def git_output(command, **kwargs):
            self.assertEqual(command[0], "git")
            self.assertEqual(kwargs["cwd"], self.repo)
            values = {("rev-parse", "HEAD"): "0123456789abcdef\n",
                      ("branch", "--show-current"): "test/measurement\n",
                      ("status", "--porcelain"): "?? vsrc/cpu/pango_measure_top.sv\n"}
            return values[tuple(command[1:])]

        patcher = mock.patch.object(measurement.subprocess, "check_output", side_effect=git_output)
        patcher.start()
        self.addCleanup(patcher.stop)

    def stage(self, layer="H2", profile="C1", fill=4, output=None, ras_enable=0):
        return measurement.stage(self.repo, output or self.output, layer, profile, fill, ras_enable)

    def test_ras_ablation_preserves_other_core_parameters(self):
        manifest = self.stage(layer="H0", ras_enable=0)
        expected = dict(measurement.P1_SCOREBOARD_CONFIGURATION, core_ras_enable=0)
        self.assertEqual(manifest["core_configuration"], expected)
        command = (self.output / "compile.tcl").read_text()
        self.assertIn("CORE_RAS_ENABLE=0", command)
        self.assertNotIn("CORE_RAS_ENABLE=1", command)
        measurement.verify(self.output, manifest)
        manifest["core_configuration"]["core_ras_enable"] = 1
        with self.assertRaises(ValueError):
            measurement.verify(self.output, manifest)

    def changed_file(self, manifest, name, text):
        result = copy.deepcopy(manifest)
        path = self.output / name
        path.write_text(text)
        result["files"][name] = digest(path)
        return result

    def test_explicit_p1_layer_clock_and_fill_matrix(self):
        expected_macros = {
            "CORE_XLEN": 32, "CORE_MUL_IMPL": 0, "CORE_DIV_IMPL": 1,
            "CORE_SCOREBOARD": 1, "CORE_ISSUE_WIDTH": 2, "CORE_RETIRE_ENTRIES": 32,
            "CORE_ISSUE_QUEUE_ENTRIES": 8, "CORE_LOAD_QUEUE_ENTRIES": 4,
            "CORE_STORE_QUEUE_ENTRIES": 4, "CORE_BRANCH_CHECKPOINTS": 4,
            "CORE_PREDICTOR_MODE": 1, "CORE_RAS_ENABLE": 0,
            "CORE_SPLIT_ISSUE_QUEUE": 1, "CORE_MEMORY_QUEUE_ENTRIES": 4,
            "CORE_LIMITED_INTEGER_OOO": 1, "CORE_SCHEDULER_FORWARD_MODE": 3,
        }
        for layer in ("H0", "H1", "H2"):
            for profile, sys_hz in (("C1", 80000000), ("C4", 100000000)):
                for fill in (4, 8):
                    with self.subTest(layer=layer, profile=profile, fill=fill):
                        command = measurement.compile_command(layer, profile, fill)
                        tokens = re.findall(r"\b([A-Z][A-Z0-9_]*)=(\d+)\b", command)
                        self.assertEqual(len(tokens), len(dict(tokens)))
                        self.assertEqual({k: int(v) for k, v in tokens},
                                         dict(expected_macros, SOC_ICACHE_FILL_BYTES=fill))
                        params = re.search(r"-defined_parameters \{([^}]+)\}", command)[1].split()
                        self.assertEqual(dict(zip(params[::2], map(int, params[1::2]))), {
                            "MEASURE_LAYER": int(layer[1]), "DDR_BYTES": 536870912,
                            "FLASH_BYTES": 16777216, "NPU_BYTES": 65536,
                            "CORE_CLOCK_HZ": 100000000, "SYS_CLOCK_HZ": sys_hz,
                            "DDR_CLOCK_HZ": 125000000, "PERIPH_CLOCK_HZ": 25000000})
                        self.assertIn("-top_module pango_measure_top", command)

    def test_reject_bad_configuration_before_writing(self):
        for args in (("H3", "C1", 4), ("H2", "C0", 4), ("H1", "C2", 8),
                     ("H0", "C1", 16), ("H2", "C4", 0)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.stage(*args)
            self.assertFalse(self.output.exists())

    def test_stage_all_layers_and_profiles_with_verifiable_inputs(self):
        for layer in ("H0", "H1", "H2"):
            for profile in ("C1", "C4"):
                output = self.base / f"{layer}-{profile}"
                with self.subTest(layer=layer, profile=profile):
                    manifest = self.stage(layer, profile, 8, output)
                    saved = json.loads((output / "manifest.json").read_text())
                    self.assertEqual(saved, manifest)
                    checked = measurement.verify(output, saved)
                    self.assertEqual(checked["icache_fill_bytes"], 8)
                    self.assertEqual(checked["clock_profile"], profile)
                    self.assertEqual(checked["layer"], layer)
                    self.assertEqual(saved["source_status"], ["?? vsrc/cpu/pango_measure_top.sv"])
                    self.assertEqual(saved["core_configuration"]["core_retire_entries"], 32)
                    self.assertIn("no board PLL or DDR PHY", saved["clock_source"])
                    self.assertNotIn("pango_200hp_top", (output / "compile.tcl").read_text())
                    constraint_files = {"measurement.fdc", "audit_clock_bindings.tcl",
                                        "report_domains.tcl", "binding-spec.json",
                                        "proposed_cdc.fdc", "discover_clock_objects.tcl"}
                    self.assertTrue(constraint_files <= saved["files"].keys())
                    compile_text = (output / "compile.tcl").read_text()
                    self.assertEqual(re.findall(r"^add_constraint (.+)$", compile_text, re.M),
                                     ["{measurement.fdc}"])
                    fdc = (output / "measurement.fdc").read_text()
                    self.assertNotRegex(fdc, r"\b(get_pins|get_cells|all_registers)\b")
                    self.assertNotRegex(fdc, r"(?m)^(set_false_path|set_max_delay|set_max_skew|"
                                            r"set_clock_groups|source)\b")
                    spec = json.loads((output / "binding-spec.json").read_text())
                    self.assertEqual(spec["schema_version"], 2)
                    self.assertIs(spec["exceptions_loaded"], False)
                    self.assertEqual(spec["pending_exception_count"], 197 if layer == "H2" else 1)
                    self.assertEqual(spec["proposed_exception_file"], "proposed_cdc.fdc")
                    self.assertIn("all internal paths remain timed", spec["constraints_mode"])
                    # 综合入口只调用原生支持的步骤；未执行的对象审计不能冒充验收证据。
                    synth_lines = [line for line in (output / "synthesize.tcl").read_text().splitlines()
                                   if line and not line.startswith("#")]
                    self.assertEqual(len(synth_lines), 2)
                    self.assertEqual(synth_lines[0], "source compile.tcl")
                    self.assertTrue(synth_lines[1].startswith("synthesize -ads "))
                    for name, expected in saved["files"].items():
                        self.assertEqual(digest(output / name), expected, name)
                    self.assertTrue(self.source_lists <= saved["files"].keys())

    def test_actual_dirty_source_bytes_and_shared_constants_preserved(self):
        source = self.repo / measurement.EXTRA_SOURCES[0]
        source.write_text(source.read_text() + "// intentional uncommitted fixture edit\n")
        configuration = copy.deepcopy(board.P1_SCOREBOARD_CONFIGURATION)
        before = {str(p.relative_to(self.repo)): digest(p) for p in self.repo.rglob("*") if p.is_file()}
        manifest = self.stage()
        self.assertEqual(manifest["files"][measurement.EXTRA_SOURCES[0]], digest(source))
        self.assertEqual((self.output / measurement.EXTRA_SOURCES[0]).read_bytes(), source.read_bytes())
        self.assertEqual(board.P1_SCOREBOARD_CONFIGURATION, configuration)
        self.assertEqual(before, {str(p.relative_to(self.repo)): digest(p)
                                  for p in self.repo.rglob("*") if p.is_file()})

    def test_nonempty_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "earlier-route.log"
        sentinel.write_text("preserve previous evidence\n")
        with self.assertRaisesRegex(ValueError, "empty|preserve"):
            self.stage()
        self.assertEqual(sentinel.read_text(), "preserve previous evidence\n")
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_completed_output_cannot_be_reused(self):
        self.stage()
        before = {str(p.relative_to(self.output)): digest(p) for p in self.output.rglob("*") if p.is_file()}
        with self.assertRaises(ValueError):
            self.stage(fill=8)
        self.assertEqual(before, {str(p.relative_to(self.output)): digest(p)
                                  for p in self.output.rglob("*") if p.is_file()})

    def test_existing_empty_output_allowed(self):
        self.output.mkdir()
        measurement.verify(self.output, self.stage())

    def test_repository_and_ancestor_outputs_rejected(self):
        for output in (self.repo, self.repo / "build/new-measurement", self.base):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "separate"):
                self.stage(output=output)

    def test_output_symlink_into_repository_rejected(self):
        alias = self.base / "alias"
        alias.symlink_to(self.repo, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "separate"):
            self.stage(output=alias / "candidate")

    def test_missing_rtl_rejected_before_output(self):
        source = next(board.sources(self.repo, "scripts/soc_files.f"))
        source.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_missing_measurement_shell_rejected(self):
        (self.repo / measurement.EXTRA_SOURCES[-1]).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_modified_rtl_hash_rejected(self):
        manifest = self.stage()
        (self.output / measurement.EXTRA_SOURCES[0]).write_text("changed after staging\n")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            measurement.verify(self.output, manifest)

    def test_modified_constraint_hash_rejected(self):
        manifest = self.stage()
        (self.output / "measurement.fdc").write_text("# removed clocks\n")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            measurement.verify(self.output, manifest)

    def test_rehashed_compile_parameter_changes_rejected(self):
        manifest = self.stage(fill=8)
        original = (self.output / "compile.tcl").read_text()
        replacements = (("CORE_RETIRE_ENTRIES=32", "CORE_RETIRE_ENTRIES=16"),
                        ("CORE_LIMITED_INTEGER_OOO=1", "CORE_LIMITED_INTEGER_OOO=0"),
                        ("CORE_SCHEDULER_FORWARD_MODE=3", "CORE_SCHEDULER_FORWARD_MODE=0"),
                        ("SOC_ICACHE_FILL_BYTES=8", "SOC_ICACHE_FILL_BYTES=4"),
                        ("MEASURE_LAYER 2", "MEASURE_LAYER 0"),
                        ("SYS_CLOCK_HZ 80000000", "SYS_CLOCK_HZ 100000000"))
        for before, after in replacements:
            with self.subTest(before=before):
                self.assertIn(before, original)
                changed = self.changed_file(manifest, "compile.tcl", original.replace(before, after))
                with self.assertRaises(ValueError):
                    measurement.verify(self.output, changed)

    def test_changed_manifest_parameters_rejected(self):
        manifest = self.stage()
        for field, value in (("layer", "H1"), ("clock_profile", "C4"),
                             ("icache_fill_bytes", 8), ("xlen", 64),
                             ("top", "pango_200hp_top"), ("device", "other-device")):
            changed = copy.deepcopy(manifest)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                measurement.verify(self.output, changed)
        changed = copy.deepcopy(manifest)
        changed["core_configuration"]["core_retire_entries"] = 16
        with self.assertRaises(ValueError):
            measurement.verify(self.output, changed)

    def test_rehashed_constraint_changes_rejected(self):
        manifest = self.stage()
        changes = {"measurement.fdc": "# clocks removed\n",
                   "compile.tcl": (self.output / "compile.tcl").read_text() +
                                  "add_constraint {proposed_cdc.fdc}\n",
                   "synthesize.tcl": (self.output / "synthesize.tcl").read_text() +
                                     "source proposed_cdc.fdc\n",
                   "binding-spec.json": json.dumps({"schema_version": 2, "exceptions_loaded": True})}
        for name, text in changes.items():
            original = (self.output / name).read_text()
            with self.subTest(name=name):
                changed = self.changed_file(manifest, name, text)
                with self.assertRaises(ValueError):
                    measurement.verify(self.output, changed)
            (self.output / name).write_text(original)

    def test_rehashed_implementation_and_memory_bypass_rejected(self):
        manifest = self.stage()
        for name in ("implement.tcl", "memory_gate.ps1", "memory_guard.ps1"):
            original = (self.output / name).read_text()
            with self.subTest(name=name):
                changed = self.changed_file(manifest, name, "# skip safety checks and route\n")
                with self.assertRaises(ValueError):
                    measurement.verify(self.output, changed)
            (self.output / name).write_text(original)

    def test_missing_generated_or_rtl_hash_rejected(self):
        manifest = self.stage()
        for name in ("compile.tcl", "measurement.fdc", "proposed_cdc.fdc", "binding-spec.json",
                     "discover_clock_objects.tcl", "implement.tcl", "memory_gate.ps1",
                     "memory_guard.ps1", measurement.EXTRA_SOURCES[0]):
            changed = copy.deepcopy(manifest)
            del changed["files"][name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                measurement.verify(self.output, changed)

    def test_rehashed_source_list_change_rejected(self):
        manifest = self.stage()
        for name in self.source_lists:
            original = (self.output / name).read_text()
            with self.subTest(name=name):
                changed = self.changed_file(manifest, name, original + "# edited source contract\n")
                with self.assertRaises(ValueError):
                    measurement.verify(self.output, changed)
            (self.output / name).write_text(original)

    def test_rehashed_source_omission_and_compile_rewrite_rejected(self):
        manifest = self.stage()
        removed = next(name for name in manifest["rtl"] if name not in measurement.EXTRA_SOURCES)
        changed = copy.deepcopy(manifest)
        changed["rtl"].remove(removed)
        del changed["files"][removed]
        (self.output / removed).unlink()
        # 即使同时重写Tcl及其hash，也不能把不完整输入描述为同一个硬件层次。
        for name, text in measurement.scripts("H2", "C1", 4, changed["rtl"]).items():
            (self.output / name).write_text(text)
            changed["files"][name] = digest(self.output / name)
        with self.assertRaises((ValueError, FileNotFoundError)):
            measurement.verify(self.output, changed)

    def test_manifest_cannot_escape_staging_directory(self):
        manifest = self.stage()
        outside = self.base / "outside.sv"
        outside.write_text("outside evidence\n")
        changed = copy.deepcopy(manifest)
        changed["files"]["../outside.sv"] = digest(outside)
        with self.assertRaises(ValueError):
            measurement.verify(self.output, changed)

    def test_symlinked_evidence_outside_directory_rejected(self):
        manifest = self.stage()
        name = measurement.EXTRA_SOURCES[0]
        path = self.output / name
        outside = self.base / "outside.sv"
        outside.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            measurement.verify(self.output, manifest)

    def test_legacy_schema8_board_contract_is_separate(self):
        before = copy.deepcopy(board.P1_SCOREBOARD_CONFIGURATION)
        command = board.compile_command(32, 0, 1, core_issue_width=2, scoreboard=True,
                                        scoreboard_config=before, soc_system=True)
        self.stage()
        self.assertEqual(command, board.compile_command(32, 0, 1, core_issue_width=2, scoreboard=True,
                                                       scoreboard_config=before, soc_system=True))
        self.assertIn("-top_module pango_200hp_top", command)
        self.assertNotIn("MEASURE_LAYER", command)
        self.assertNotIn("SOC_ICACHE_FILL_BYTES", command)
        self.assertEqual(board.BOARD_CLOCK_DOMAINS, dict.fromkeys(("core", "sys", "ddr", "periph"), 125000000))
        board.verify_default_board_clocks((REPO / "vsrc/cpu/pango_200hp_top.sv").read_text())

    def test_cli_requires_native_ascii_windows_directory(self):
        argv = ["prepare_measurement.py", "--output", str(self.output), "--layer", "H2"]
        for native in (r"\\server\share\test", "/tmp/test", "X:\\测试", "X:\\unsafe{path}"):
            with self.subTest(native=native), mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(sys, "platform", "linux"), \
                    mock.patch.object(measurement.subprocess, "check_output", return_value=native), \
                    mock.patch.object(measurement, "stage") as stage, \
                    mock.patch.object(sys, "stderr", io.StringIO()):
                with self.assertRaises(SystemExit):
                    measurement.main()
                stage.assert_not_called()

    def test_cli_explicit_selection_reaches_stager_without_pds(self):
        argv = ["prepare_measurement.py", "--output", str(self.output), "--layer", "H1",
                "--clock-profile", "C4", "--icache-fill-bytes", "8", "--ras-enable", "0"]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "platform", "linux"), \
                mock.patch.object(measurement.subprocess, "check_output", return_value="X:\\offline"), \
                mock.patch.object(measurement, "stage", return_value={"files": {}}) as stage, \
                mock.patch.object(sys, "stdout", io.StringIO()) as output:
            measurement.main()
            stage.assert_called_once_with(REPO, self.output, "H1", "C4", 8, 0, {})
            self.assertIn("no measured timing yet", output.getvalue())


class MeasurementSummaryTests(unittest.TestCase):
    """Synthetic report fixtures exercise interpretation, never claim an actual PDS run."""
    RESOURCE_TEXT = ("Total LUTs: 12000\nTotal Registers: 17000\nTotal Latches: 0\n"
                     "Total DRMs = 32\nTotal APMs = 4\nTotal I/O ports = 20\n")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="pango-measure-summary-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.syn = self.root / "prj_tasks/syn_1/synthesize"
        self.db = self.syn / "report_db"
        self.db.mkdir(parents=True)
        (self.root / "manifest.json").write_text(json.dumps({"layer": "H2", "clock_profile": "C1"}))
        (self.syn / f"{summary.TOP}.snr").write_text(self.RESOURCE_TEXT)
        (self.syn / f"{summary.TOP}_syn.vm").write_text("// Synthetic parser fixture, not a mapped design.\n")
        self.log = self.root / "synthesis.log"
        self.log.write_text("Executing : synthesize -ads successfully.\n"
                            "MEASUREMENT_BINDINGS_PASS H2 C1 object_binding_only\n")
        self.table("resource_utilization", ["Module Inst Name", "LUTs"],
                   [["u_core(scoreboard_core)", "9000"], ["u_scan(pango_measure_scan)", "1200"]])
        self.table("report_timing_path_setup", ["Start Point", "End Point", "Slack"],
                   [["u_core/a", "u_core/b", "-1.0"], ["u_scan/a", "u_core/b", "-2.0"]])
        for name in ("report_timing_clock_summary", "report_timing_fmax", "report_timing_setup",
                     "report_timing_hold", "check_timing_summary"):
            self.table(name, ["Name", "Value"], [["synthetic", "0"]])
        patcher = mock.patch.object(summary, "verify", return_value={"layer": "H2", "clock_profile": "C1"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def table(self, name, headers, rows):
        report = ET.Element("report")
        table = ET.SubElement(report, "table")
        column_headers = ET.SubElement(table, "column_headers")
        for value in headers:
            ET.SubElement(column_headers, "data").text = value
        for values in rows:
            row = ET.SubElement(table, "row")
            for value in values:
                ET.SubElement(row, "data").text = value
        path = self.db / f"synthesize_{name}.db"
        ET.ElementTree(report).write(path, encoding="unicode")
        return path

    def test_resource_fields_are_required(self):
        self.assertEqual(summary.resources(self.RESOURCE_TEXT),
                         {"lut": 12000, "ff": 17000, "latch": 0, "drm36k": 32.0, "apm": 4.0, "io": 20})
        for line in self.RESOURCE_TEXT.splitlines(keepends=True):
            with self.subTest(line=line), self.assertRaisesRegex(ValueError, "missing synthesis resource"):
                summary.resources(self.RESOURCE_TEXT.replace(line, ""))

    def test_synthesis_completion_marker_is_required(self):
        for text in ("", "Executing : synthesize failed.\n", "Starting synthesize\n"):
            self.log.write_text(text)
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "completion marker"):
                summary.summarize(self.root, self.log)

    def test_actual_netlist_is_required(self):
        (self.syn / f"{summary.TOP}_syn.vm").unlink()
        with self.assertRaisesRegex(ValueError, "mapped netlist"):
            summary.summarize(self.root, self.log)

    def test_estimated_timing_never_becomes_routed_frequency(self):
        result = summary.summarize(self.root, self.log)
        self.assertIn("estimated timing only", result["status"])
        self.assertIsNone(result["routed_fmax_mhz"])
        self.assertIsNone(result["routed_wns_ns"])
        self.assertIsNone(result["unrouted_nets"])
        self.assertEqual(result["structural_issues"], [])
        self.assertTrue(result["binding_audit_complete"])
        self.assertEqual(result["worst_reported_path_by_family"]["core"]["Slack"], "-1.0")
        self.assertEqual(result["reported_path_counts"], {"core": 1, "scan_harness_or_boundary": 1})
        for path, expected in result["hashes"].items():
            self.assertEqual(digest(self.root / path), expected)

    def test_missing_binding_audit_remains_incomplete(self):
        self.log.write_text("Executing : synthesize -ads successfully.\n")
        self.assertFalse(summary.summarize(self.root, self.log)["binding_audit_complete"])

    def test_binding_marker_matches_whole_line_and_selected_configuration(self):
        for layer in ("H0", "H1", "H2"):
            for profile in ("C1", "C4"):
                (self.root / "manifest.json").write_text(json.dumps({"layer": layer, "clock_profile": profile}))
                marker = f"MEASUREMENT_BINDINGS_PASS {layer} {profile} object_binding_only"
                alternatives = ((marker, True), ("ERROR expected: " + marker, False),
                                (marker + " FAILED", False),
                                (marker.replace(profile, "C4" if profile == "C1" else "C1"), False),
                                (marker.replace(layer, "H1" if layer == "H0" else "H0"), False))
                for text, expected in alternatives:
                    with self.subTest(layer=layer, profile=profile, text=text):
                        self.log.write_text("Executing : synthesize -ads successfully.\n" + text + "\n")
                        self.assertEqual(summary.summarize(self.root, self.log)["binding_audit_complete"], expected)

    def test_structural_resource_regressions_are_reported(self):
        text = self.RESOURCE_TEXT.replace("Latches: 0", "Latches: 2").replace("DRMs = 32", "DRMs = 4").replace("APMs = 4", "APMs = 0")
        (self.syn / f"{summary.TOP}.snr").write_text(text)
        issues = summary.summarize(self.root, self.log)["structural_issues"]
        self.assertEqual(len(issues), 3)
        self.assertTrue(any("latches" in item for item in issues))
        self.assertTrue(any("APMs" in item for item in issues))
        self.assertTrue(any("TCM" in item for item in issues))

    def test_missing_core_or_harness_entity_is_not_accepted_silently(self):
        self.table("resource_utilization", ["Module Inst Name", "LUTs"], [["unrelated", "9000"]])
        self.assertIn("missing named Core or scan entity resource evidence",
                      summary.summarize(self.root, self.log)["structural_issues"])

    def test_malformed_report_row_is_rejected(self):
        path = self.table("bad", ["Name", "Count"], [["missing-count"]])
        with self.assertRaisesRegex(ValueError, "malformed row"):
            summary.read_table(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
