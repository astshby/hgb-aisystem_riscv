#!/usr/bin/env python3
"""Exercise Pango staging with temporary fake inputs; never invoke PDS or Windows."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.pango.prepare_project import (BOARD_CLOCK_PROFILES, BOARD_CLOCK_RATIOS, GENERATED_SCRIPTS,
                                           MEMORY_SCRIPTS, SCOREBOARD_CONFIGURATION,
                                           P1_SCOREBOARD_CONFIGURATION, DEFAULT_SCOREBOARD_CONFIGURATION, board_clock_constraints,
                                           compile_command, verify_independent_board_clocks,
                                           verify_staged_manifest)
from scripts.pango.summarize_timing import summarize


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pango-handoff-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "fake-repo"
        self.ip = self.root / "fake-ip"
        scripts = self.repo / "scripts/pango"
        scripts.mkdir(parents=True)
        for name in ("prepare_project.py", "check_ip_dq.py", "implement.tcl", "mes2l676_200hp.fdc") + MEMORY_SCRIPTS:
            shutil.copyfile(REPO / "scripts/pango" / name, scripts / name)
        (self.repo / "vsrc").mkdir()
        (self.repo / "vsrc/fixture.sv").write_text("module fixture; endmodule\n")
        (self.repo / "vsrc/cpu").mkdir()
        (self.repo / "vsrc/soc").mkdir()
        (self.repo / "vsrc/cpu/pango_200hp_top.sv").write_text(
            "// Offline topology fixture, not elaborated RTL.\n"
            "module pango_200hp_top #(\n"
            "    parameter int unsigned SOC_PROFILE = 0,\n"
            "    parameter int unsigned BOARD_CLOCK_PROFILE = 0,\n"
            "    parameter int unsigned ICACHE_BYTES = 4096,\n"
            "    parameter int unsigned DCACHE_BYTES = 4096,\n"
            "    parameter bit DUMMY = 1'b0\n"
            ");\n"
            "logic core_clk, hot_clk, sys_clk, periph_clk;\n"
            "localparam int unsigned HOT_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 : 100000000;\n"
            "localparam int unsigned SYS_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 :\n"
            "    (BOARD_CLOCK_PROFILE == 4 ? 100000000 : 80000000);\n"
            "localparam int unsigned PERIPH_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 : 25000000;\n"
            "generate\n"
            "if (BOARD_CLOCK_PROFILE == 0) begin : g_common_clock\n"
            "    assign hot_clk = core_clk;\n"
            "    assign sys_clk = core_clk;\n"
            "    assign periph_clk = core_clk;\n"
            "end else begin : g_domain_clocks\n"
            "    pango_soc_pll #(.CLOCK_PROFILE(BOARD_CLOCK_PROFILE)) u_soc_pll ();\n"
            "    pango_soc_reset u_reset ();\n"
            "end\n"
            "endgenerate\n"
            "`ifdef CORE_SCOREBOARD\nsoc_system #(.ICACHE_BYTES(ICACHE_BYTES),.DCACHE_BYTES(DCACHE_BYTES),.CLOCK_HZ(125000000),"
            ".CLOCK_INFO_ENABLE(BOARD_CLOCK_PROFILE != 0),.CORE_CLOCK_HZ(HOT_HZ),"
            ".SYS_CLOCK_HZ(SYS_HZ),.PERIPH_CLOCK_HZ(PERIPH_HZ)) u_soc ("
            ".clk_core(hot_clk),.clk_sys(sys_clk),.clk_ddr(core_clk),.clk_periph(periph_clk));\n"
            "`else\nsoc_top #() u_soc ();\n`endif\n"
            "endmodule\n")
        (self.repo / "vsrc/soc/soc_system.sv").write_text("// Offline topology fixture.\n")
        (self.repo / "scripts/pango_files.f").write_text(
            "vsrc/fixture.sv\nvsrc/cpu/pango_200hp_top.sv\nvsrc/soc/soc_system.sv\n")
        (self.ip / "rtl").mkdir(parents=True)
        (self.ip / "pnr").mkdir()
        for name in ("ddr3_test.v", "ddr3_test_ddrphy_top.v", "rtl/fixture.v"):
            (self.ip / name).write_text("// Offline staging fixture, not a DDR controller.\n")
        tree = ET.Element("ip")
        ET.SubElement(ET.SubElement(tree, "header"), "version").text = "1.10"
        params = {"ACTUAL_RATE": "1000", "DFI_CLK_PERIOD": "8000"}
        fdc = (scripts / "mes2l676_200hp.fdc").read_text()
        params.update({f"PAD_DQ{index}": pin for index, pin in re.findall(
            r"\{p:mem_dq\[(\d+)\]\} \{PAP_IO_LOC\} \{(\w+)\}", fdc)})
        for name, value in params.items():
            node = ET.SubElement(tree, "param")
            ET.SubElement(node, "name").text = name
            ET.SubElement(node, "value").text = value
        ET.ElementTree(tree).write(self.ip / "ddr3_test.idf")
        (self.ip / "pnr/ddr_test.fdc").write_text(
            "create_clock -name {ref_clk} -period {20.0}\n"
            "create_generated_clock -name {ddrphy_sysclk} -multiply_by {5} -divide_by {2}\n"
            "create_clock -name {free_clk} -period {10.0}\n"
            "set_clock_groups -asynchronous -group {free_clk}\n")
        for width in (32, 64):
            firmware = self.repo / f"build/loader/rv{width}"
            firmware.mkdir(parents=True)
            # ELF 头和镜像形状合法，但不含可执行程序；只验证交接输入，不冒充固件执行。
            ident = b"\x7fELF" + bytes((1 if width == 32 else 2, 1, 1)) + bytes(9)
            if width == 32:
                header = struct.pack("<HHIIIIIHHHHHH", 2, 243, 1, 0, 0, 0, 0, 52, 0, 0, 0, 0, 0)
            else:
                header = struct.pack("<HHIQQQIHHHHHH", 2, 243, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
            (firmware / "loader.elf").write_bytes(ident + header)
            for name in ("imem.hex", "dmem.hex"):
                (firmware / name).write_text(("0" * (width // 4) + "\n") * (65536 // (width // 8)))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        mock = bin_dir / "wslpath"
        mock.write_text("#!/bin/sh\nprintf '%s\\n' 'X:\\offline-fixture'\n")
        mock.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                        PYTHONDONTWRITEBYTECODE="1")

    def stage(self, width=32, profile="full", local=None, output=None, success=True, backend="legacy", clock=0, extra=()):
        output = output or self.root / f"rv{width}-{profile}-ltcm{local}"
        result = subprocess.run([sys.executable, "-B", str(self.repo / "scripts/pango/prepare_project.py"),
                                 "--xlen", str(width), "--soc-profile", profile,
                                 *(("--local-tcm", str(local)) if local is not None else ()),
                                 *(("--core-backend", backend) if backend is not None else ()),
                                 *(("--board-clock-profile", str(clock)) if clock is not None else ()),
                                 "--output", str(output), "--ip-dir", str(self.ip), *extra],
                                text=True, capture_output=True, env=self.env)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return output, result

    def test_default_entry_selects_measured_core_and_four_clocks(self):
        output, _ = self.stage(backend=None, clock=None)
        manifest = json.loads((output / "manifest.json").read_text())
        configuration = verify_staged_manifest(output, manifest)
        self.assertEqual(configuration["core_backend"], "scoreboard")
        self.assertEqual(configuration["core_retire_entries"], 16)
        self.assertEqual(configuration["board_clock_profile"], 1)
        self.assertEqual(configuration["board_clock_domains_hz"],
                         {"core": 100000000, "sys": 80000000,
                          "ddr": 125000000, "periph": 25000000})

    def test_cache_capacity_is_bound_to_native_compile_and_wrapper(self):
        output, _ = self.stage(backend="scoreboard", clock=1,
                               extra=("--icache-bytes", "16384", "--dcache-bytes", "8192"))
        manifest = json.loads((output / "manifest.json").read_text())
        configuration = verify_staged_manifest(output, manifest)
        self.assertEqual((configuration["icache_bytes"], configuration["dcache_bytes"]), (16384, 8192))
        path = output / "compile.tcl"
        path.write_text(path.read_text().replace("ICACHE_BYTES 16384", "ICACHE_BYTES 8192"))
        manifest["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "compile Tcl parameters"):
            verify_staged_manifest(output, manifest)

    def test_p1_defaults_match_simulation_profile(self):
        # 两种入口独立读取的参数必须一致，避免 FPGA 与仿真只共用 P1 名称。
        result = subprocess.run(["bash", "-c", 'source "$1"; env', "profile-check",
                                 str(REPO / "scripts/verilator/p1_core_config.sh")],
                                text=True, capture_output=True, check=True)
        environment = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        names = {"core_backend": "CORE_BACKEND", "core_issue_width": "ISSUE_WIDTH",
                 "core_retire_entries": "RETIRE_ENTRIES", "core_split_issue_queue": "SPLIT_ISSUE_QUEUE",
                 "core_issue_queue_entries": "INTEGER_QUEUE_ENTRIES", "core_memory_queue_entries": "MEMORY_QUEUE_ENTRIES",
                 "core_limited_integer_ooo": "LIMITED_INTEGER_OOO", "core_scheduler_forward_mode": "SCHEDULER_FORWARD_MODE",
                 "core_predictor_mode": "PREDICTOR_MODE", "core_ras_enable": "RAS_ENABLE"}
        for key, variable in names.items():
            self.assertEqual(str(DEFAULT_SCOREBOARD_CONFIGURATION[key]), environment[variable], variable)
        self.assertEqual(environment["MUL_IMPL"], "0")
        self.assertEqual(environment["DIV_IMPL"], "1")

    def test_scoreboard_native_configuration_and_bank_images(self):
        for width in (32, 64):
            for local in (None, 1):
                with self.subTest(width=width, local=local):
                    firmware = self.repo / f"build/loader/rv{width}"
                    for name in ("imem.hex", "dmem.hex"):
                        (firmware / name).write_text("".join(f"{index:0{width//4}x}\n"
                            for index in range(65536//(width//8))))
                    output, _ = self.stage(width=width, local=local, backend="scoreboard")
                    manifest = json.loads((output / "manifest.json").read_text())
                    configuration = verify_staged_manifest(output, manifest)
                    self.assertEqual(manifest["schema_version"], 8)
                    self.assertEqual(manifest["memory_guard_version"], 1)
                    for name in MEMORY_SCRIPTS:
                        self.assertIn(name, manifest["files"])
                    self.assertEqual(configuration["core_backend"], "scoreboard")
                    self.assertEqual(configuration["core_retire_entries"], 16)
                    self.assertEqual(configuration["core_split_issue_queue"], 1)
                    self.assertEqual(configuration["core_memory_queue_entries"], 4)
                    self.assertEqual(configuration["core_limited_integer_ooo"], 0)
                    self.assertEqual(configuration["core_scheduler_forward_mode"], 3)
                    self.assertEqual(configuration["core_predictor_mode"], 1)
                    self.assertEqual(configuration["core_ras_enable"], 0)
                    self.assertEqual(configuration["core_profile"], "custom")
                    self.assertEqual(configuration["soc_topology"], "soc_system")
                    self.assertEqual(configuration["local_tcm_enable"], 1)
                    self.assertEqual(configuration["board_clock_domains_hz"],
                                     dict.fromkeys(("core", "sys", "ddr", "periph"), 125000000))
                    self.assertEqual(configuration["mtime_clock_domain"], "periph")
                    self.assertEqual(configuration["data_ports"], 2)
                    self.assertEqual(configuration["slow_presence"], "0x7ff3")
                    compile_text = (output / "compile.tcl").read_text()
                    self.assertIn("CORE_SCOREBOARD=1", compile_text)
                    for legacy in ("LOCAL_TCM_ENABLE", "DMA_WIDE_ENABLE",
                                   "CACHE_BLOCK_ENABLE", "DMA_BLOCK_ENABLE"):
                        self.assertNotIn(legacy, compile_text)
                    for name in ("imem.hex", "dmem.hex"):
                        words = (output / "firmware" / name).read_text().split()
                        for bank in range(2):
                            self.assertEqual((output / f"firmware/{name}.bank{bank}").read_text().split(),
                                             words[bank::2])
                    self.verify_cli(output)
                    print(f"PASS offline scoreboard staging RV{width} local={local} native_banks=2")

    def test_memory_guard_is_bound_to_staged_inputs(self):
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        for name in MEMORY_SCRIPTS:
            changed = copy.deepcopy(manifest)
            del changed["files"][name]
            with self.assertRaisesRegex(ValueError, "memory guard not covered"):
                verify_staged_manifest(output, changed)
        (output / "memory_guard.ps1").write_text("throw 'modified guard'\n")
        with self.assertRaises(ValueError):
            verify_staged_manifest(output, manifest)

    def test_scoreboard_rehashed_mismatches_rejected(self):
        output, _ = self.stage(backend="scoreboard")
        manifest = json.loads((output / "manifest.json").read_text())
        path = output / "compile.tcl"
        original = path.read_text()
        for before, after in (("CORE_SCOREBOARD=1", ""), ("CORE_RETIRE_ENTRIES=16", "CORE_RETIRE_ENTRIES=4"),
                              ("CORE_SPLIT_ISSUE_QUEUE=1", "CORE_SPLIT_ISSUE_QUEUE=0"),
                              ("CORE_LOAD_QUEUE_ENTRIES=4", "CORE_LOAD_QUEUE_ENTRIES=1")):
            altered = copy.deepcopy(manifest)
            path.write_text(original.replace(before, after))
            altered["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "compile Tcl parameters"):
                verify_staged_manifest(output, altered)
        path.write_text(original)
        bank_name = "firmware/imem.hex.bank0"
        bank = output / bank_name
        bank.write_text("00000001\n" + bank.read_text().split("\n", 1)[1])
        manifest["files"][bank_name] = hashlib.sha256(bank.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "incorrect TCM interleaving"):
            verify_staged_manifest(output, manifest)

    def test_scheduler_parameters_and_schema4_compatibility(self):
        output, _ = self.stage(backend="scoreboard", extra=("--retire-entries", "16",
            "--integer-queue-entries", "4", "--memory-queue-entries", "2",
            "--predictor-mode", "1", "--ras-enable", "1"))
        manifest = json.loads((output / "manifest.json").read_text())
        configuration = verify_staged_manifest(output, manifest)
        self.assertEqual(configuration["core_issue_queue_entries"], 4)
        self.assertEqual(configuration["core_memory_queue_entries"], 2)
        self.assertEqual(configuration["core_predictor_mode"], 1)
        for key in ("core_retire_entries", "core_split_issue_queue", "core_memory_queue_entries"):
            invalid = copy.deepcopy(manifest)
            invalid[key] = 3
            with self.assertRaisesRegex(ValueError, "scheduler configuration"):
                verify_staged_manifest(output, invalid)
        # 旧 P0 工程仍按原 schema/原编译命令校验，不能推定后来新增参数。
        old = copy.deepcopy(manifest)
        old["schema_version"] = 4
        old.update(SCOREBOARD_CONFIGURATION)
        del old["core_split_issue_queue"], old["core_memory_queue_entries"]
        path = output / "compile.tcl"
        lines = path.read_text().splitlines()
        lines[-1] = compile_command(32, 0, 1, dma_wide=1, cache_block=1, dma_block=1,
                                   core_issue_width=2, scoreboard=True)
        path.write_text("\n".join(lines) + "\n")
        old["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        checked = verify_staged_manifest(output, old)
        self.assertEqual(checked["core_retire_entries"], 16)
        self.assertNotIn("core_split_issue_queue", checked)

    def test_limited_integer_issue_and_schema5_compatibility(self):
        output, _ = self.stage(backend="scoreboard", extra=("--limited-integer-ooo", "1"))
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertEqual(verify_staged_manifest(output, manifest)["core_limited_integer_ooo"], 1)
        for value in (None, True, 2):
            changed = copy.deepcopy(manifest)
            if value is None:
                del changed["core_limited_integer_ooo"]
            else:
                changed["core_limited_integer_ooo"] = value
            with self.assertRaisesRegex(ValueError, "scheduler configuration"):
                verify_staged_manifest(output, changed)
        changed = dict(manifest, core_split_issue_queue=0)
        with self.assertRaisesRegex(ValueError, "requires split"):
            verify_staged_manifest(output, changed)
        old = copy.deepcopy(manifest)
        old["schema_version"] = 5
        del old["core_limited_integer_ooo"], old["core_scheduler_forward_mode"]
        path = output / "compile.tcl"
        path.write_text(compile_command(32, 0, 1, 1, 1, 1, 2, scoreboard=True,
                                        scoreboard_config=old) + "\n")
        old["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertNotIn("core_limited_integer_ooo", verify_staged_manifest(output, old))

    def test_forward_modes_and_schema6_compatibility(self):
        for mode in (0, 1, 2, 3):
            output, _ = self.stage(backend="scoreboard", output=self.root / f"forward-{mode}",
                                   extra=("--scheduler-forward-mode", str(mode)))
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(verify_staged_manifest(output, manifest)["core_scheduler_forward_mode"], mode)
        for value in (None, True, 4):
            changed = copy.deepcopy(manifest)
            if value is None:
                del changed["core_scheduler_forward_mode"]
            else:
                changed["core_scheduler_forward_mode"] = value
            with self.assertRaisesRegex(ValueError, "scheduler configuration"):
                verify_staged_manifest(output, changed)
        old = copy.deepcopy(manifest)
        old["schema_version"] = 6
        del old["core_scheduler_forward_mode"]
        path = output / "compile.tcl"
        path.write_text(compile_command(32, 0, 1, 1, 1, 1, 2, scoreboard=True,
                                        scoreboard_config=old) + "\n")
        old["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertNotIn("core_scheduler_forward_mode", verify_staged_manifest(output, old))

    def test_schema7_final_p1_compatibility(self):
        output, _ = self.stage(backend="scoreboard")
        old = json.loads((output / "manifest.json").read_text())
        old["schema_version"] = 7
        for key in ("soc_topology", "core_profile", "board_clock_domains_hz",
                    "clock_relationship", "mtime_clock_domain"):
            del old[key]
        path = output / "compile.tcl"
        path.write_text(compile_command(32, 0, 1, 1, 1, 1, 2, scoreboard=True,
                                        scoreboard_config=old) + "\n")
        old["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(verify_staged_manifest(output, old)["core_scheduler_forward_mode"], 3)
        self.assertIn("LOCAL_TCM_ENABLE 1", path.read_text())

    def test_schema4_p2_requires_hashed_system_wrapper(self):
        output, _ = self.stage(backend="scoreboard")
        old = json.loads((output / "manifest.json").read_text())
        old.update(SCOREBOARD_CONFIGURATION, schema_version=4)
        path = output / "compile.tcl"
        path.write_text(compile_command(32, 0, 1, 1, 1, 1, 2,
                                        scoreboard=True, soc_system=True) + "\n")
        old["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.assertEqual(verify_staged_manifest(output, old)["core_retire_entries"], 16)
        del old["files"]["vsrc/cpu/pango_200hp_top.sv"]
        with self.assertRaisesRegex(ValueError, "compile Tcl parameters"):
            verify_staged_manifest(output, old)

    def test_system_configuration_mismatches_rejected(self):
        output, _ = self.stage(backend="scoreboard")
        manifest = json.loads((output / "manifest.json").read_text())
        for key, value in (("soc_topology", "soc_top"), ("local_tcm_enable", 0),
                           ("core_profile", "p1"), ("mtime_clock_domain", "core"),
                           ("clock_relationship", "asynchronous"),
                           ("board_clock_domains_hz", dict.fromkeys(("core", "sys", "ddr", "periph"), 85000000))):
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_staged_manifest(output, dict(manifest, **{key: value}))
        altered = copy.deepcopy(manifest)
        del altered["files"]["vsrc/soc/soc_system.sv"]
        with self.assertRaisesRegex(ValueError, "hashed soc_system"):
            verify_staged_manifest(output, altered)
        _, result = self.stage(backend="scoreboard", local=0, success=False)
        self.assertIn("always uses local TCM", result.stderr)

    def test_system_rehashed_clock_wiring_change_rejected(self):
        output, _ = self.stage(backend="scoreboard")
        manifest = json.loads((output / "manifest.json").read_text())
        name = "vsrc/cpu/pango_200hp_top.sv"
        path = output / name
        original = path.read_text()
        for before, after in ((".clk_periph(periph_clk)", ".clk_periph(other_clk)"),
                              (".CLOCK_HZ(125000000)", ".CLOCK_HZ(85000000)")):
            path.write_text(original.replace(before, after))
            manifest["files"][name] = hashlib.sha256(path.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "wrapper"):
                verify_staged_manifest(output, manifest)

    def test_independent_board_clock_topology_and_constraints(self):
        wrapper = (REPO / "vsrc/cpu/pango_200hp_top.sv").read_text()
        for profile in (1, 4):
            verify_independent_board_clocks(wrapper, profile)
        with self.assertRaisesRegex(ValueError, "default to BOARD_CLOCK_PROFILE 0"):
            verify_independent_board_clocks(
                wrapper.replace("BOARD_CLOCK_PROFILE = 0", "BOARD_CLOCK_PROFILE = 1", 1), 1)
        with self.assertRaisesRegex(ValueError, "clk_core wiring changed"):
            verify_independent_board_clocks(
                wrapper.replace(".clk_core(hot_clk),.clk_sys", ".clk_core(core_clk),.clk_sys", 1), 1)
        for profile, sys_ratio in ((1, "-multiply_by {16} -divide_by {25}"),
                                   (4, "-multiply_by {4} -divide_by {5}")):
            text = board_clock_constraints(profile)
            self.assertIn(f"create_generated_clock -name {{clk_core}}", text)
            self.assertIn("-multiply_by {4} -divide_by {5}", text)
            self.assertIn(sys_ratio, text)
            self.assertIn("-name {clk_periph}", text)
            self.assertIn("-multiply_by {1} -divide_by {5}", text)
            self.assertNotIn("set_clock_groups", text)
            self.assertNotIn("set_false_path", text)
            self.assertNotIn("set_max_delay", text)

    def test_compile_command_carries_board_clock_profile(self):
        common = compile_command(32, 0, 1, 1, 1, 1, 2, scoreboard=True,
                                 scoreboard_config=P1_SCOREBOARD_CONFIGURATION, soc_system=True)
        self.assertNotIn("BOARD_CLOCK_PROFILE", common)
        for profile in (1, 4):
            command = compile_command(32, 0, 1, 1, 1, 1, 2, scoreboard=True,
                                      scoreboard_config=P1_SCOREBOARD_CONFIGURATION,
                                      soc_system=True, board_clock_profile=profile)
            self.assertIn(f"BOARD_CLOCK_PROFILE {profile}", command)
            self.assertNotIn("LOCAL_TCM_ENABLE", command)

    def test_c1_c4_board_clock_staging(self):
        for profile in (1, 4):
            with self.subTest(profile=profile):
                output, _ = self.stage(backend="scoreboard", output=self.root / f"board-c{profile}",
                                       extra=("--board-clock-profile", str(profile)))
                manifest = json.loads((output / "manifest.json").read_text())
                configuration = verify_staged_manifest(output, manifest)
                expected = BOARD_CLOCK_PROFILES[profile]
                self.assertEqual(manifest["schema_version"], 9)
                self.assertEqual(configuration["board_clock_profile"], profile)
                self.assertEqual(configuration["clock_profile"], expected["name"])
                self.assertEqual(configuration["board_clock_domains_hz"],
                                 {domain: expected[domain]
                                  for domain in ("core", "sys", "ddr", "periph")})
                self.assertIn(f"BOARD_CLOCK_PROFILE {profile}", (output / "compile.tcl").read_text())
                self.assertIn("add_constraint {board_clocks.fdc}", (output / "compile.tcl").read_text())
                self.verify_cli(output)
                original = (output / "board_clocks.fdc").read_text()
                path = output / "board_clocks.fdc"
                path.write_text(original.replace("-divide_by {5}", "-divide_by {4}", 1))
                manifest["files"]["board_clocks.fdc"] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaisesRegex(ValueError, "independent clock constraints"):
                    verify_staged_manifest(output, dict(manifest))
        self.stage(backend="legacy", success=False,
                   extra=("--board-clock-profile", "1"))
        self.stage(backend="scoreboard", success=False,
                   extra=("--board-clock-profile", "2"))

    def test_custom_profile_cannot_claim_final_p1(self):
        output, _ = self.stage(backend="scoreboard", extra=("--scheduler-forward-mode", "0"))
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertEqual(verify_staged_manifest(output, manifest)["core_profile"], "custom")
        with self.assertRaisesRegex(ValueError, "core profile differs"):
            verify_staged_manifest(output, dict(manifest, core_profile="p1"))

    def verify_cli(self, output, staging=True, success=True):
        command = [sys.executable, "-B", str(REPO / "scripts/pango/verify_synthesis.py"), str(output)]
        if staging:
            command.append("--staging-only")
        result = subprocess.run(command, text=True, capture_output=True, env=self.env)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_eight_staged_configurations(self):
        for width in (32, 64):
            for profile in ("full", "lite"):
                for local in (0, 1):
                    with self.subTest(width=width, profile=profile, local=local):
                        output, _ = self.stage(width, profile, local)
                        manifest = json.loads((output / "manifest.json").read_text())
                        config = verify_staged_manifest(output, manifest)
                        self.assertEqual(manifest["schema_version"], 3)
                        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
                            self.assertEqual(config[key], 1)
                        self.assertEqual(config["soc_profile"], profile)
                        self.assertEqual(config["local_tcm_enable"], local)
                        present = 0x7fff if profile == "full" else 0x727f
                        self.assertEqual(config["soc_presence"], f"0x{present:04x}")
                        self.assertEqual(config["slow_presence"], f"0x{present & (0x7ff3 if local else 0x7fff):04x}")
                        self.assertTrue(set(GENERATED_SCRIPTS) <= manifest["files"].keys())
                        result = self.verify_cli(output)
                        self.assertIn("no synthesis evidence", result.stdout)
                        self.assertFalse((output / "synthesis-summary.json").exists())
                        self.verify_cli(output, staging=False, success=False)
                        print(f"PASS offline staging RV{width} profile={profile} local_tcm={local}")

    def test_invalid_cli_values(self):
        for width, profile, local in ((32, "full", 2), (32, "minimal", 0), (16, "full", 0)):
            with self.subTest(width=width, profile=profile, local=local):
                output, result = self.stage(width, profile, local, success=False)
                self.assertIn("invalid choice", result.stderr)
                self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        output = self.root / "existing"
        output.mkdir()
        marker = output / "user-evidence"
        marker.write_text("keep me")
        _, result = self.stage(output=output, success=False)
        self.assertIn("output must be empty", result.stderr)
        self.assertEqual(marker.read_text(), "keep me")

    def test_wrong_and_truncated_elf_rejected(self):
        firmware = self.repo / "build/loader/rv32/loader.elf"
        firmware.write_bytes((self.repo / "build/loader/rv64/loader.elf").read_bytes())
        for content in (firmware.read_bytes(), b"\x7fELF"):
            with self.subTest(size=len(content)):
                firmware.write_bytes(content)
                output, result = self.stage(success=False)
                self.assertIn("loader ELF width mismatch", result.stderr)
                self.assertFalse(output.exists())

    def test_missing_staged_file_rejected(self):
        (self.repo / "build/loader/rv32/imem.hex").unlink()
        output, result = self.stage(success=False)
        self.assertIn("missing generated IP or production loader", result.stderr)
        self.assertFalse(output.exists())

    def test_invalid_hex_shape_rejected(self):
        (self.repo / "build/loader/rv32/dmem.hex").write_text("00000000\n")
        output, result = self.stage(success=False)
        self.assertIn("invalid production TCM HEX: dmem.hex", result.stderr)
        self.assertFalse(output.exists())

    def test_all_generated_tcl_tampering_rejected(self):
        output, _ = self.stage()
        for name in GENERATED_SCRIPTS:
            with self.subTest(name=name):
                path = output / name
                original = path.read_bytes()
                path.write_bytes(original + b"# changed\n")
                result = self.verify_cli(output, success=False)
                self.assertIn(f"staged byte hash mismatch: {name}", result.stderr)
                path.write_bytes(original)

    def test_rehashed_parameter_change_still_rejected(self):
        output, _ = self.stage()
        path = output / "compile.tcl"
        manifest = json.loads((output / "manifest.json").read_text())
        original = path.read_text()
        for old, new in (("LOCAL_TCM_ENABLE 0", "LOCAL_TCM_ENABLE 1"),
                         ("SOC_PROFILE 0", "SOC_PROFILE 1"), ("CORE_XLEN=32", "CORE_XLEN=64"),
                         ("DMA_WIDE_ENABLE 1", "DMA_WIDE_ENABLE 0"),
                         ("CACHE_BLOCK_ENABLE 1", "CACHE_BLOCK_ENABLE 0"),
                         ("DMA_BLOCK_ENABLE 1", "DMA_BLOCK_ENABLE 0"),
                         ("CORE_ISSUE_WIDTH=1", "CORE_ISSUE_WIDTH=2"),
                         (" CACHE_BLOCK_ENABLE 1", ""), (" DMA_BLOCK_ENABLE 1", ""),
                         (" CORE_ISSUE_WIDTH=1", "")):
            with self.subTest(parameter=old):
                path.write_text(original.replace(old, new))
                manifest["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaisesRegex(ValueError, "compile Tcl parameters differ"):
                    verify_staged_manifest(output, manifest)

    def test_manifest_script_coverage_and_schema_rejected(self):
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        for name in GENERATED_SCRIPTS:
            changed = copy.deepcopy(manifest)
            del changed["files"][name]
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "not covered by manifest"):
                verify_staged_manifest(output, changed)
        for version in (True, 0, 10):
            changed = dict(manifest, schema_version=version)
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "unsupported staging"):
                verify_staged_manifest(output, changed)

    def legacy_manifest(self, schema):
        """Build an exact historical command, not a new command with a relabelled version."""
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        manifest["schema_version"] = schema
        if schema == 1:
            del manifest["dma_wide_enable"]
            del manifest["ddr_data_bits"]
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            del manifest[key]
        path = output / "compile.tcl"
        lines = path.read_text().splitlines()
        lines = [compile_command(32, 0, 0, 1 if schema == 2 else None)
                 if line.startswith("compile") else line for line in lines]
        path.write_text("\n".join(lines) + "\n")
        manifest["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
        (output / "manifest.json").write_text(json.dumps(manifest))
        return output, manifest

    def test_schema_one_keeps_dma_configuration_unknown(self):
        output, manifest = self.legacy_manifest(1)
        config = verify_staged_manifest(output, manifest)
        self.assertEqual(config["dma_wide_enable"], "unknown")
        self.assertEqual(config["ddr_data_bits"], "unknown")
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            self.assertEqual(config[key], "unknown")
        self.assertIn("legacy DMA", config["evidence"])
        self.assertIn('"dma_block_enable": "unknown"', self.verify_cli(output).stdout)

    def test_schema_two_keeps_block_and_issue_configuration_unknown(self):
        output, manifest = self.legacy_manifest(2)
        original = {name: (output / name).read_bytes() for name in GENERATED_SCRIPTS}
        config = verify_staged_manifest(output, manifest)
        self.assertEqual(config["dma_wide_enable"], 1)
        self.assertEqual(config["ddr_data_bits"], 256)
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            self.assertEqual(config[key], "unknown")
        self.assertIn("legacy block/issue", config["evidence"])
        self.assertIn('"core_issue_width": "unknown"', self.verify_cli(output).stdout)
        self.assertEqual(original, {name: (output / name).read_bytes() for name in GENERATED_SCRIPTS})

    def test_legacy_rehashed_new_parameters_are_rejected(self):
        for schema in (1, 2):
            with self.subTest(schema=schema):
                output, manifest = self.legacy_manifest(schema)
                path = output / "compile.tcl"
                original = path.read_text()
                for added in ("CACHE_BLOCK_ENABLE 1", "DMA_BLOCK_ENABLE 1"):
                    path.write_text(original.replace("LOCAL_TCM_ENABLE 0", f"LOCAL_TCM_ENABLE 0 {added}"))
                    manifest["files"]["compile.tcl"] = hashlib.sha256(path.read_bytes()).hexdigest()
                    with self.assertRaisesRegex(ValueError, "compile Tcl parameters differ"):
                        verify_staged_manifest(output, manifest)
                # 显式使用不同临时输出，避免第二个历史版本复用非空候选目录。
                shutil.rmtree(output)

    def test_schema_three_missing_or_invalid_block_issue_metadata_rejected(self):
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            for value in (None, 0, True, "1", 2):
                with self.subTest(key=key, value=value):
                    changed = copy.deepcopy(manifest)
                    if value is None:
                        del changed[key]
                    else:
                        changed[key] = value
                    with self.assertRaisesRegex(ValueError, "block/issue configuration"):
                        verify_staged_manifest(output, changed)

    def test_native_dma_metadata_rejected_if_inconsistent(self):
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        for key, value in (("dma_wide_enable", 0), ("dma_wide_enable", True), ("ddr_data_bits", 64)):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "native DMA"):
                verify_staged_manifest(output, dict(manifest, **{key: value}))

    def test_legacy_configuration_is_explicitly_unknown(self):
        output, _ = self.stage()
        manifest = json.loads((output / "manifest.json").read_text())
        del manifest["schema_version"]
        for name in GENERATED_SCRIPTS:
            del manifest["files"][name]
        for name in ("local_tcm_enable", "slow_presence"):
            del manifest[name]
        (output / "manifest.json").write_text(json.dumps(manifest))
        config = verify_staged_manifest(output, manifest)
        self.assertEqual(config["soc_profile"], "unknown")
        self.assertEqual(config["local_tcm_enable"], "unknown")
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            self.assertEqual(config[key], "unknown")
        self.assertIn("legacy", config["evidence"])
        self.assertIn("legacy", self.verify_cli(output).stdout)
        self.verify_cli(output, staging=False, success=False)

    def test_staging_cannot_replace_timing_evidence(self):
        output, _ = self.stage()
        with self.assertRaises(FileNotFoundError):
            summarize(output, output / "nonexistent-implementation.log")

    def test_timing_summary_configuration_and_route_gate(self):
        output, _ = self.stage(64, "lite", 1)
        synthesis = output / "prj_tasks/syn_1/synthesize"
        timing = output / "prj_tasks/pnr_1/report_timing"
        db = timing / "report_db"
        synthesis.mkdir(parents=True)
        db.mkdir(parents=True)
        (synthesis / "pango_200hp_top.snr").write_text(
            "Total LUTs: 1\nTotal Registers: 1\nTotal Latches: 0\n"
            "Total DRMs = 34\nTotal APMs = 4\nTotal I/O ports = 1\n")
        (synthesis / "pango_200hp_top_syn.vm").write_text("// fixture, not synthesized HDL\n")
        (timing / "pango_200hp_top.rtr").write_text("fixture, not a timing report\n")
        (output / "init-both-summary.json").write_text("{}\n")
        names = ["report_timing_fmax", "check_timing_summary"]
        names += [f"report_timing_{corner}_{check}" for corner in ("slow", "fast")
                  for check in ("setup", "hold", "recovery", "removal", "mpw", "skew")]
        for name in names + ["report_timing_slow_path_setup"]:
            (db / f"{name}.db").write_text(
                "<tables><table><column_headers><data>Slack</data></column_headers>"
                "<row><data>0.0</data></row></table></tables>")
        log = output / "implementation.log"
        actions = ("dev_map -force_to_run", "place", "route", "route_optimize", "report_timing")
        completed = "\n".join(f"Executing : {action} successfully." for action in actions)
        completed += ("\nTotal route nets size: 1\nUnrouted nets at iteration 1: 0\n"
                      "Device Utilization Summary\n| + LUT | 1 |\n| + FF | 1 |\n"
                      "| + DRM36K | 34 |\n| + APM | 4 |\n| IO | 1 |\n")
        log.write_text(completed)
        result = summarize(output, log)
        self.assertEqual(result["configuration"]["soc_profile"], "lite")
        self.assertEqual(result["configuration"]["local_tcm_enable"], 1)
        self.assertEqual(result["configuration"]["slow_presence"], "0x7273")
        for key in ("cache_block_enable", "dma_block_enable", "core_issue_width"):
            self.assertEqual(result["configuration"][key], 1)
        self.assertEqual(result["implementation_actions"][1], "place")
        log.write_text(completed.replace("Unrouted nets at iteration 1: 0", "Unrouted nets at iteration 1: 1"))
        with self.assertRaisesRegex(ValueError, "1 unrouted nets"):
            summarize(output, log)
        log.write_text(completed.replace("Executing : route successfully.", "Executing : route"))
        with self.assertRaisesRegex(ValueError, "incomplete implementation action: route"):
            summarize(output, log)

    def test_original_resource_gate_kept(self):
        output, _ = self.stage()
        report = output / "prj_tasks/syn_1/synthesize/pango_200hp_top.snr"
        report.parent.mkdir(parents=True)
        for bram, dsp, latch, success in ((34, 4, 0, True), (33, 4, 0, False),
                                          (34, 3, 0, False), (34, 4, 1, False)):
            with self.subTest(bram=bram, dsp=dsp, latch=latch):
                report.write_text(f"Total LUTs: 1\nTotal Registers: 1\nTotal Latches: {latch}\n"
                                  f"Total DRMs = {bram}\nTotal APMs = {dsp}\nTotal I/O ports = 1\n")
                self.verify_cli(output, staging=False, success=success)

    def test_scoreboard_width_specific_resource_gate(self):
        for width, drm, apm in ((32, 36, 4), (64, 38, 12)):
            output, _ = self.stage(width=width, backend="scoreboard")
            report = output / "prj_tasks/syn_1/synthesize/pango_200hp_top.snr"
            report.parent.mkdir(parents=True)
            for actual_drm, actual_apm, latch, success in (
                    (drm, apm, 0, True), (drm-2, apm, 0, False),
                    (drm, apm+1, 0, False), (drm, apm, 1, False)):
                with self.subTest(width=width, drm=actual_drm, apm=actual_apm, latch=latch):
                    report.write_text(f"Total LUTs: 1\nTotal Registers: 1\nTotal Latches: {latch}\n"
                                      f"Total DRMs = {actual_drm}\nTotal APMs = {actual_apm}\n"
                                      "Total I/O ports = 1\n")
                    self.verify_cli(output, staging=False, success=success)

    def test_powershell_configuration_contract_static_only(self):
        script = (REPO / "scripts/pango/build.ps1").read_text()
        for fragment in ("[ValidateSet('full','lite')][string]$SocProfile",
                         "[ValidateSet(0,1)][int]$LocalTcmEnable",
                         "'--soc-profile', $SocProfile", "'--local-tcm', \"$LocalTcmEnable\"",
                         "'--staging-only'", "$manifest.soc_profile -cne $SocProfile",
                         "$manifest.local_tcm_enable -ne $LocalTcmEnable",
                         "$manifest.schema_version -ne 3",
                         "$manifest.cache_block_enable -ne 1", "$manifest.dma_block_enable -ne 1",
                         "$manifest.core_issue_width -ne 1",
                         "soc_profile = $manifest.soc_profile",
                         "local_tcm_enable = $manifest.local_tcm_enable",
                         "cache_block_enable = $manifest.cache_block_enable",
                         "dma_block_enable = $manifest.dma_block_enable",
                         "core_issue_width = $manifest.core_issue_width"):
            self.assertIn(fragment, script)
        self.assertLess(script.index("'--staging-only'"), script.index("Write-Output 'RUN native PDS"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
