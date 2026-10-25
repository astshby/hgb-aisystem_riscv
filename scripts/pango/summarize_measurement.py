#!/usr/bin/env python3
"""Collect layered PDS synthesis evidence; never call an estimated clock a routed Fmax."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

if __package__:
    from .prepare_measurement import TOP, sha256, verify
else:
    from prepare_measurement import TOP, sha256, verify


def read_table(path, paths=False):
    table = ET.parse(path).getroot().find("table")
    headers = [node.text for node in table.find("column_headers").findall("data")]
    result = []

    def visit(node, ancestors):
        values = [item.text or "" for item in node.findall("data")]
        if len(values) != len(headers):
            raise ValueError(f"malformed row in {path.name}")
        row = dict(zip(headers, values))
        row["hierarchy"] = [*ancestors, values[0]]
        if paths:
            arrival = node.find("general_container/table_container/table")
            row["logical_resources"] = [] if arrival is None else [
                item.findall("data")[-1].text for item in arrival.findall("row")
                if item.findall("data") and item.findall("data")[-1].text]
        result.append(row)
        for child in node.findall("row"):
            visit(child, row["hierarchy"])

    for row in table.findall("row"):
        visit(row, [])
    return result


def path_family(row):
    names = " ".join([row.get("Start Point", ""), row.get("End Point", ""),
                      *row.get("logical_resources", [])])
    if "u_scan" in names or "g_scan_" in names or "scan_" in names:
        return "scan_harness_or_boundary"
    if any(token in names for token in ("sync1", "gray", "u_cdc", "cdc_")):
        return "cdc_or_synchronizer"
    if "u_core" in names:
        if any(token in names for token in ("u_memory", "u_tcm", "g_tcm", "u_icache", "u_dcache")):
            return "core_local_memory_boundary"
        return "core"
    if any(token in names for token in ("u_memory", "u_tcm", "g_tcm", "u_icache", "u_dcache")):
        return "local_memory"
    if "u_dma" in names:
        return "dma"
    if any(token in names for token in ("fabric", "u_periph", "u_sys", "u_axi")):
        return "system_or_peripheral"
    return "other_inspect_raw_path"


def resources(text):
    patterns = {"lut": r"Total LUTs:\s*(\d+)", "ff": r"Total Registers:\s*(\d+)",
                "latch": r"Total Latches:\s*(\d+)", "drm36k": r"Total DRMs\s*=\s*([\d.]+)",
                "apm": r"Total APMs\s*=\s*([\d.]+)", "io": r"Total I/O ports\s*=\s*(\d+)"}
    found = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match is None:
            raise ValueError(f"missing synthesis resource {key}")
        found[key] = float(match[1]) if key in ("drm36k", "apm") else int(match[1])
    return found


def summarize(root, synthesis_log):
    manifest = json.loads((root / "manifest.json").read_text())
    configuration = verify(root, manifest)
    log = synthesis_log.read_text(errors="replace")
    actions = re.findall(r"^Executing : (synthesize[^\r\n]*) successfully\.$", log, re.M)
    if not actions:
        raise ValueError("missing successful synthesis completion marker")
    syn = root / "prj_tasks/syn_1/synthesize"
    db = syn / "report_db"
    report = syn / f"{TOP}.snr"
    netlist = syn / f"{TOP}_syn.vm"
    if not netlist.is_file():
        raise ValueError("missing actual mapped netlist")
    counts = resources(report.read_text(errors="replace"))
    tables = {}
    for name in ("resource_utilization", "report_timing_clock_summary", "report_timing_fmax",
                 "report_timing_setup", "report_timing_hold", "check_timing_summary",
                 "report_timing_path_setup"):
        path = db / f"synthesize_{name}.db"
        tables[name] = read_table(path, paths=name.endswith("path_setup"))
    families = {}
    for row in tables["report_timing_path_setup"]:
        family = path_family(row)
        row["family"] = family
        if family not in families or float(row["Slack"]) < float(families[family]["Slack"]):
            families[family] = row
    entities = tables["resource_utilization"]
    core_entities = [row for row in entities if row.get("Module Inst Name", "").startswith("u_core(")
                     or ".u_core(" in row.get("Module Inst Name", "")]
    harness_entities = [row for row in entities if "u_scan(" in row.get("Module Inst Name", "")]
    errors = []
    if counts["latch"]:
        errors.append("latches inferred")
    if counts["apm"] != 4:
        errors.append("RV32 DSP mapping differs from four APMs; inspect retention/configuration")
    if not core_entities or not harness_entities:
        errors.append("missing named Core or scan entity resource evidence")
    if manifest["layer"] != "H0" and counts["drm36k"] < 32:
        errors.append("less than 128 KiB local TCM mapped capacity; inspect memory retention")
    # 初次特征化只列实测实体；接口保活必须结合网表绑定和定向测试再审核。
    marker = (f"MEASUREMENT_BINDINGS_PASS {manifest['layer']} {manifest['clock_profile']} "
              "object_binding_only")
    binding_complete = re.search(r"^" + re.escape(marker) + r"$", log, re.M) is not None
    tracked = [root / "manifest.json", report, netlist, synthesis_log,
               *(db / f"synthesize_{name}.db" for name in tables)]
    return dict(status="synthesis measured; estimated timing only; no routed Fmax or board result",
                configuration=configuration, synthesis_actions=actions, resources=counts,
                structural_issues=errors, binding_audit_complete=binding_complete,
                core_entities=core_entities, harness_entities=harness_entities,
                estimated_timing=tables, worst_reported_path_by_family=families,
                reported_path_counts=dict(Counter(row["family"] for row in tables["report_timing_path_setup"])),
                routed_fmax_mhz=None, routed_wns_ns=None, unrouted_nets=None,
                hashes={path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path): sha256(path)
                        for path in tracked})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--synthesis-log", required=True, type=Path)
    args = parser.parse_args()
    result = summarize(args.project.resolve(), args.synthesis_log.resolve())
    output = args.project / "measurement-summary.json"
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in
                      ("status", "configuration", "resources", "structural_issues", "binding_audit_complete")}, indent=2))


if __name__ == "__main__":
    main()
