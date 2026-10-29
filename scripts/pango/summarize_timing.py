#!/usr/bin/env python3
"""Verify a completed PDS timing run and summarize its original reports, not board status."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

if __package__:
    from .prepare_project import verify_staged_manifest
else:
    from prepare_project import verify_staged_manifest


def table(db, name):
    selected = ET.parse(db / f"{name}.db").getroot().find("table")
    headers = [node.text for node in selected.find("column_headers").findall("data")]
    return [dict(zip(headers, [node.text for node in row.findall("data")]))
            for row in selected.findall("row")]


def completed_actions(impl, placement_log=None, route_command="route", place_command=None):
    placement = impl if placement_log is None else placement_log
    pattern = (re.escape(place_command) if place_command is not None else
               r"place(?: -mode fast| -logic_optimize_lut6d FALSE(?: -logic_optimize_lut_cascade FALSE)?)?")
    placements = re.findall(r"^Executing : (" + pattern + r") successfully\.$", placement, re.M)
    if not placements:
        raise ValueError("incomplete implementation action: place")
    if '$hgb_threads' in route_command or route_command == 'route':
        route_pattern = (r'route(?: -route_mode normal(?: -number_of_router_thread [0-9]+)?)?'
                         if route_command == 'route' else
                         re.escape(route_command).replace(re.escape('$hgb_threads'), r'[0-9]+'))
        routes = re.findall(r'^Executing : (' + route_pattern + r') successfully\.$', impl, re.M)
        if not routes:
            raise ValueError('incomplete implementation action: route')
        route_command = routes[-1]
    actions = ["dev_map -force_to_run", placements[-1], route_command, "route_optimize"]
    for index, action in enumerate(actions):
        evidence = placement if index < 2 else impl
        if not re.search(r"^Executing : " + re.escape(action) + r" successfully\.$", evidence, re.M):
            raise ValueError(f"incomplete implementation action: {action}")
    # 只接受原命令或已核验的扩展路径数选项；不能仅凭启动行或任意子串认定完成。
    reports = re.findall(
        r"^Executing : (report_timing(?: -max_path [1-9][0-9]* -nworst [1-9][0-9]*)?) successfully\.$",
        impl, re.M)
    if not reports:
        raise ValueError("incomplete implementation action: report_timing")
    return actions + [reports[-1]]


def placement_reuse(root, impl):
    """Bind a resumed standard route to its immutable, fully verified donor placement."""
    proof_file = root / "placement-reuse.json"
    if not proof_file.exists():
        return None, None, "route"
    proof = json.loads(proof_file.read_text())
    source = Path(proof["source_project"]).resolve()
    manifest = json.loads((root / "manifest.json").read_text())
    hashes = proof["copied_files_sha256"]
    database = proof["placement_database"]
    required = set(manifest["files"]) | {
        "manifest.json", database, "init-both-summary.json",
        "prj_tasks/syn_1/synthesize/pango_200hp_top.snr",
        "prj_tasks/syn_1/synthesize/pango_200hp_top_syn.vm",
        "prj_tasks/pnr_1/place_route/run_place.log",
    }
    if not required <= hashes.keys() or proof["route_mode"] != "normal":
        raise ValueError("incomplete or nonstandard placement reuse proof")
    for name, expected in hashes.items():
        for base in (source, root):
            path = (base / name).resolve()
            path.relative_to(base.resolve())
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError(f"placement reuse hash mismatch: {path}")
    verify_staged_manifest(source, json.loads((source / "manifest.json").read_text()))
    verify_staged_manifest(root, manifest)
    logs = [Path(proof[key]) for key in ("source_implementation_log", "copied_implementation_log")]
    for path in logs:
        if hashlib.sha256(path.read_bytes()).hexdigest() != proof["source_implementation_log_sha256"]:
            raise ValueError("placement reuse source log hash mismatch")
    placement = logs[1].read_text()
    placed = re.findall(r"^Executing : (place[^\r\n]*) successfully\.$", placement, re.M)
    if not placed or placed[-1] != "place":
        raise ValueError("placement reuse requires a final default standard place")
    for action in ("dev_map -force_to_run", "place"):
        if not re.search(r"^Executing : " + re.escape(action) + r" successfully\.$", placement, re.M):
            raise ValueError(f"placement reuse lacks standard {action} completion")
    threads = proof["route_threads"]
    if type(threads) is not int or not 1 <= threads <= 64:
        raise ValueError("invalid placement reuse thread count")
    prefix = f"route -force_to_run -route_mode normal -number_of_router_thread {threads} -input_place_db_file "
    commands = re.findall(r"^Executing : (" + re.escape(prefix) + r"[^\r\n]+) successfully\.$", impl, re.M)
    if len(commands) != 1:
        raise ValueError("resumed standard route not completed exactly once")
    spelling = commands[0][len(prefix):].strip()
    if spelling[:1] in ('"', "{"):
        spelling = spelling[1:-1]
    # Windows PDS 的日志在 WSL 中读取；不把盘符路径解释成相对路径。
    input_path = Path(spelling)
    if not input_path.is_absolute() and re.match(r"^[A-Za-z]:[/\\]", spelling):
        input_path = Path("/mnt") / spelling[0].lower() / spelling[3:].replace("\\", "/")
    if input_path.resolve() != (root / database).resolve():
        raise ValueError("resumed route used a different placement database")
    return proof, placement, commands[0]


def setup_paths(db):
    selected = ET.parse(db / "report_timing_slow_path_setup.db").getroot().find("table")
    headers = [node.text for node in selected.find("column_headers").findall("data")]
    paths = []
    for row in selected.findall("row"):
        path = dict(zip(headers, [node.text for node in row.findall("data")]))
        arrival = row.find("general_container/table_container/table")
        path["logical_resources"] = [] if arrival is None else [
            item.findall("data")[-1].text for item in arrival.findall("row")
            if item.findall("data") and item.findall("data")[-1].text]
        paths.append(path)
    if not paths:
        raise ValueError("missing slow setup paths")
    return paths


def summarize(root, impl_log):
    manifest = json.loads((root / "manifest.json").read_text())
    configuration = verify_staged_manifest(root, manifest)
    syn = root / "prj_tasks/syn_1/synthesize/pango_200hp_top.snr"
    syn_text = syn.read_text()
    patterns = {"lut": r"Total LUTs:\s*(\d+)", "ff": r"Total Registers:\s*(\d+)",
                "latch": r"Total Latches:\s*(\d+)", "bram36k": r"Total DRMs\s*=\s*([\d.]+)",
                "dsp_apm": r"Total APMs\s*=\s*([\d.]+)", "io": r"Total I/O ports\s*=\s*(\d+)"}
    synthesis = {key: int(float(re.search(pattern, syn_text)[1]))
                 for key, pattern in patterns.items()}
    if synthesis["latch"] or synthesis["bram36k"] < 32 or synthesis["dsp_apm"] == 0:
        raise ValueError(f"unexpected TCM/DSP/latch mapping: {synthesis}")

    # WSL 中断可能截断外层 stdout；PDS 工程自身的 run.log 也可作为原始完成证据。
    # 必须保留每个实际动作的成功标记，不能把“进程消失”当成实现完成。
    impl = impl_log.read_text(errors="replace")
    reuse, placement, route_command = placement_reuse(root, impl)
    strategy = None
    place_command = None
    if (root / "strategy.json").exists():
        if reuse is not None:
            raise ValueError("performance experiment cannot reuse a different placement strategy")
        if __package__:
            from .prepare_performance_strategy import verify_strategy
        else:
            from prepare_performance_strategy import verify_strategy
        strategy = verify_strategy(root)
        place_command, route_command = strategy['place'], strategy['route']
    actions = completed_actions(impl, placement, route_command, place_command)
    resource_log = impl if "Device Utilization Summary" in impl else placement
    if resource_log is None or "Device Utilization Summary" not in resource_log:
        raise ValueError("missing implementation resource report")
    resource = resource_log.rsplit("Device Utilization Summary", 1)[1]

    def used(label):
        matches = re.findall(r"^\|\s*" + re.escape(label) + r"\s*\|\s*(\d+)", resource, re.M)
        if not matches:
            raise ValueError(f"missing resource row: {label}")
        return sum(map(int, matches))

    physical = {"lut": used("+ LUT"), "ff": used("+ FF"), "bram36k": used("+ DRM36K"),
                "dsp_apm": used("+ APM"), "io": used("IO")}
    db = root / "prj_tasks/pnr_1/report_timing/report_db"
    names = ["report_timing_fmax", "check_timing_summary"]
    names += [f"report_timing_{corner}_{check}" for corner in ("slow", "fast")
              for check in ("setup", "hold", "recovery", "removal", "mpw", "skew")]
    timing = {name: table(db, name) for name in names}
    paths = setup_paths(db)
    worst = min(paths, key=lambda path: float(path["Slack"]))
    unrouted = int(re.findall(r"Unrouted nets at iteration[^:]*:\s*(\d+)", impl)[-1])
    if unrouted:
        raise ValueError(f"implementation has {unrouted} unrouted nets")
    tracked = [syn, root / "manifest.json", root / "board_ddr.fdc", impl_log,
               root / "prj_tasks/syn_1/synthesize/pango_200hp_top_syn.vm",
               root / "prj_tasks/pnr_1/report_timing/pango_200hp_top.rtr",
               root / "init-both-summary.json"]
    if reuse is not None:
        tracked += [root / "placement-reuse.json", root / reuse["placement_database"],
                    Path(reuse["source_implementation_log"]), Path(reuse["copied_implementation_log"])]
    return {"xlen": manifest["xlen"],
            "configuration": configuration,
            "staged_files_verified": len(manifest["files"]),
            "synthesis": synthesis, "physical": physical, "timing": timing,
            "resource_report_source": str(impl_log) if resource_log == impl else reuse["copied_implementation_log"],
            "placement_reuse": reuse,
            "strategy": strategy,
            "implementation_actions": actions,
            "worst_slow_setup_path": worst, "slow_setup_paths": paths,
            "route_nets": int(re.search(r"Total route nets size:\s*(\d+)", impl)[1]),
            "last_unrouted": unrouted,
            "hashes": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked},
            "status": "implementation completed; inspect all STA failures; board not tested"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--implementation-log", type=Path,
                        help="complete original stdout or the native PDS project run.log")
    args = parser.parse_args()
    root = args.project.resolve()
    width = json.loads((root / "manifest.json").read_text())["xlen"]
    log = args.implementation_log or root.parent / f"logs/implementation-rv{width}.log"
    result = summarize(root, log.resolve())
    (root / "timing-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in
                      ("xlen", "configuration", "staged_files_verified", "synthesis", "physical", "last_unrouted")}, indent=2))
    print("Fmax:", result["timing"]["report_timing_fmax"])


if __name__ == "__main__":
    main()
