#!/usr/bin/env python3
"""Stage an isolated H0/H1/H2 diagnostic PDS project, without board or Fmax claims."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys

if __package__:
    from . import measurement_constraints
    from .prepare_project import P1_SCOREBOARD_CONFIGURATION, sources
else:
    import measurement_constraints
    from prepare_project import P1_SCOREBOARD_CONFIGURATION, sources

TOP = "pango_measure_top"
EXTRA_SOURCES = tuple(f"vsrc/cpu/pango_measure_{name}.sv" for name in ("scan", "hot", "top"))
LAYERS = {"H0": "Core with registered observable interfaces",
          "H1": "Core, local TCM and caches, synchronous AXI boundaries",
          "H2": "Complete soft SoC to DDR AXI boundary, no DDR controller or PHY"}
REPO = Path(__file__).resolve().parents[2]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


OVERRIDE_KEYS = ("core_retire_entries", "core_split_issue_queue",
                 "core_limited_integer_ooo", "core_scheduler_forward_mode",
                 "core_issue_queue_entries", "core_memory_queue_entries")


def core_configuration(ras_enable=0, overrides=None):
    value = dict(P1_SCOREBOARD_CONFIGURATION, core_ras_enable=ras_enable)
    if overrides:
        value.update(overrides)
    return value


def compile_command(layer, profile, fill_bytes, ras_enable=0, overrides=None):
    if layer not in LAYERS or profile not in measurement_constraints.CLOCKS or fill_bytes not in (4, 8):
        raise ValueError("unsupported diagnostic configuration")
    macros = ["CORE_XLEN=32", "CORE_MUL_IMPL=0", "CORE_DIV_IMPL=1", "CORE_SCOREBOARD=1"]
    macros += [f"{key.upper()}={value}" for key, value in core_configuration(ras_enable, overrides).items()
               if key.startswith("core_") and key != "core_backend"]
    macros += [f"SOC_ICACHE_FILL_BYTES={fill_bytes}"]
    params = [f"MEASURE_LAYER {int(layer[1])}", "DDR_BYTES 536870912",
              "FLASH_BYTES 16777216", "NPU_BYTES 65536"]
    params += [f"{domain.upper()}_CLOCK_HZ {hz}"
               for domain, hz in measurement_constraints.CLOCKS[profile].items()]
    return (f"compile -top_module {TOP} -verilog_standard SystemVerilog "
            f"-compiler_directives {{{' '.join(macros)}}} "
            f"-defined_parameters {{{' '.join(params)}}} -loop_limit 65536")


def scripts(layer, profile, fill_bytes, rtl, ras_enable=0, overrides=None):
    generated = measurement_constraints.generate(int(layer[1]), profile)
    generated["compile.tcl"] = "\n".join([
        "# Diagnostic external-clock design. Never used to program a board.",
        "set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6",
        "set_option max_threads 8",
        *(f"add_design {{{name}}}" for name in rtl),
        "add_constraint {measurement.fdc}", compile_command(layer, profile, fill_bytes, ras_enable, overrides), ""])
    generated["synthesize.tcl"] = (
        "source compile.tcl\n"
        "synthesize -ads -selected_syn_tool_opt 2 -max_path 100 -nworst 3 "
        "-report_logic_level_distribution -report_exception TRUE\n")
    # 当前 pds_shell 不提供 GUI 的 open_dw；对象审计单列，不让未验证命令冒充已执行。
    generated["post_synthesis.tcl"] = "source audit_clock_bindings.tcl\nsource report_domains.tcl\n"
    generated["implement.tcl"] = (REPO / "scripts/pango/implement.tcl").read_text().replace(
        "report_timing\n", "report_timing -report_max_skew -report_exception\n")
    for name in ("memory_guard.ps1", "memory_gate.ps1"):
        generated[name] = (REPO / "scripts/pango" / name).read_text()
    return generated


def source_lists(repo, name="scripts/soc_files.f"):
    yield name
    for line in (repo / name).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line.startswith("-f "):
            yield from source_lists(repo, line[3:].strip())


def verify(root, manifest):
    root = root.resolve()
    config = manifest.get("core_configuration", {})
    ras_enable = config.get("core_ras_enable")
    overrides = {key: config[key] for key in OVERRIDE_KEYS if key in config}
    if (manifest.get("schema") != "pango-layered-measurement-v1" or
            manifest.get("top") != TOP or manifest.get("xlen") != 32 or
            ras_enable not in (0, 1) or
            manifest.get("core_configuration") != core_configuration(ras_enable, overrides) or
            manifest.get("device") != "PG2L200H-6IFBB676"):
        raise ValueError("unsupported diagnostic manifest")
    layer, profile, fill = (manifest[key] for key in ("layer", "clock_profile", "icache_fill_bytes"))
    if manifest.get("clocks_hz") != measurement_constraints.CLOCKS[profile]:
        raise ValueError("clock metadata differs from explicit compile/constraint configuration")
    for name, expected in manifest["files"].items():
        path = (root / name).resolve()
        path.relative_to(root)
        if sha256(path) != expected:
            raise ValueError(f"staged byte mismatch: {name}")
    for name, content in scripts(layer, profile, fill, manifest["rtl"], ras_enable, overrides).items():
        if name not in manifest["files"] or (root / name).read_text() != content:
            raise ValueError(f"unexpected or unhashed generated script: {name}")
    for name in source_lists(REPO):
        if name not in manifest["files"] or (root / name).read_bytes() != (REPO / name).read_bytes():
            raise ValueError(f"source-list contract changed: {name}")
    expected_rtl = list(dict.fromkeys([*(path.relative_to(root).as_posix()
                                       for path in sources(root, "scripts/soc_files.f")), *EXTRA_SOURCES]))
    if manifest["rtl"] != expected_rtl:
        raise ValueError("RTL list differs from staged source-list closure")
    if not set(manifest["rtl"]) <= manifest["files"].keys() or not set(EXTRA_SOURCES) <= set(manifest["rtl"]):
        raise ValueError("missing RTL evidence")
    for name in ("implement.tcl", "memory_gate.ps1", "memory_guard.ps1"):
        if name not in manifest["files"]:
            raise ValueError(f"missing memory/implementation evidence: {name}")
    return {key: manifest[key] for key in ("layer", "clock_profile", "clocks_hz", "icache_fill_bytes",
                                          "source_commit", "source_branch", "source_status")}


def stage(repo, root, layer, profile, fill_bytes, ras_enable=0, overrides=None):
    # 文件清单覆盖实际 staging 字节，包括未提交的新测量壳；git ID 单独记录。
    repo, root = repo.resolve(), root.resolve()
    if root == repo or repo in root.parents or root in repo.parents:
        raise ValueError("output must be separate from the repository")
    if root.exists() and any(root.iterdir()):
        raise ValueError("preserve existing results; output must be empty")
    compile_command(layer, profile, fill_bytes, ras_enable, overrides)
    inputs = list(dict.fromkeys([*sources(repo, "scripts/soc_files.f"),
                                *(repo / name for name in EXTRA_SOURCES)]))
    if any(not path.is_file() for path in inputs):
        raise ValueError("missing diagnostic RTL")
    rtl = [path.relative_to(repo).as_posix() for path in inputs]
    generated = scripts(layer, profile, fill_bytes, rtl, ras_enable, overrides)
    lists = list(dict.fromkeys(source_lists(repo)))
    manifest = dict(schema="pango-layered-measurement-v1", top=TOP, layer=layer,
                    boundary=LAYERS[layer], xlen=32, device="PG2L200H-6IFBB676",
                    core_configuration=core_configuration(ras_enable, overrides), clock_profile=profile,
                    clocks_hz=measurement_constraints.CLOCKS[profile], icache_fill_bytes=fill_bytes,
                    clock_source="diagnostic external ports; no board PLL or DDR PHY",
                    binding_audit="pending separate native DW invocation; never implied by synthesis success",
                    firmware="no fixed image; mutable TCM inputs controlled through scan harness",
                    status="staged inputs only; synthesis, routing and board operation unverified",
                    rtl=rtl, files={})
    for key, cmd in (("source_commit", ["rev-parse", "HEAD"]),
                     ("source_branch", ["branch", "--show-current"]),
                     ("source_status", ["status", "--porcelain"])):
        value = subprocess.check_output(["git", *cmd], cwd=repo, text=True).strip()
        manifest[key] = value.splitlines() if key == "source_status" else value
    root.mkdir(parents=True, exist_ok=True)
    for source, name in zip(inputs, rtl):
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for name in lists:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / name, target)
    for name, content in generated.items():
        (root / name).write_text(content, encoding="utf-8")
    manifest["files"] = {name: sha256(root / name) for name in [*rtl, *lists, *generated]}
    verify(root, manifest)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--layer", required=True, choices=tuple(LAYERS))
    parser.add_argument("--clock-profile", choices=("C1", "C4"), default="C1")
    parser.add_argument("--icache-fill-bytes", type=int, choices=(4, 8), default=4)
    parser.add_argument("--ras-enable", type=int, choices=(0, 1), default=0,
                        help="production profile omits RAS; 1 replays the historical candidate")
    parser.add_argument("--retire-entries", type=int, choices=(16, 32),
                        help="override ROB depth for a frequency/IPC ablation")
    parser.add_argument("--split-issue-queue", type=int, choices=(0, 1),
                        help="override split integer/memory issue queues")
    parser.add_argument("--limited-integer-ooo", type=int, choices=(0, 1),
                        help="override limited integer out-of-order issue")
    parser.add_argument("--scheduler-forward-mode", type=int, choices=(0, 1, 2, 3),
                        help="override scheduler broadcast-forwarding mode")
    parser.add_argument("--integer-queue-entries", type=int, choices=(2, 4, 8, 16),
                        help="override integer issue queue depth")
    parser.add_argument("--memory-queue-entries", type=int, choices=(2, 4, 8),
                        help="override memory issue queue depth")
    args = parser.parse_args()
    native = str(args.output.resolve()) if sys.platform == "win32" else subprocess.check_output(
        ["wslpath", "-w", str(args.output.resolve())], text=True).strip()
    drive = PureWindowsPath(native).drive
    if not drive or drive.startswith("\\\\") or not native.isascii() or any(c in native for c in "{}"):
        parser.error("use a fresh ASCII native Windows directory")
    overrides = {key: value for key, value in (
        ("core_retire_entries", args.retire_entries),
        ("core_split_issue_queue", args.split_issue_queue),
        ("core_limited_integer_ooo", args.limited_integer_ooo),
        ("core_scheduler_forward_mode", args.scheduler_forward_mode),
        ("core_issue_queue_entries", args.integer_queue_entries),
        ("core_memory_queue_entries", args.memory_queue_entries))
        if value is not None}
    effective = core_configuration(args.ras_enable, overrides)
    if effective["core_limited_integer_ooo"] and not effective["core_split_issue_queue"]:
        parser.error("limited integer OOO requires the split issue queue")
    manifest = stage(Path(__file__).resolve().parents[2], args.output,
                     args.layer, args.clock_profile, args.icache_fill_bytes,
                     args.ras_enable, overrides)
    print(f"PASS staging {args.layer}/{args.clock_profile}/fill{args.icache_fill_bytes}: "
          f"{len(manifest['files'])} hashed inputs; no measured timing yet")


if __name__ == "__main__":
    main()
