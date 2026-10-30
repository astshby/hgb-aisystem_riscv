#!/usr/bin/env python3
"""Classify native board I/O warnings without inventing delays or STA exceptions."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys


def indexed(name, count):
    return {f"{name}[{index}]" for index in range(count)}


DDR_INPUTS = indexed("mem_dq", 32)
DDR_OUTPUTS = (DDR_INPUTS | indexed("mem_a", 15) | indexed("mem_ba", 3) |
               indexed("mem_dm", 4) | indexed("mem_dqs", 4) | indexed("mem_dqs_n", 4) |
               {"mem_ck", "mem_ck_n", "mem_cas_n", "mem_cke", "mem_cs_n", "mem_odt",
                "mem_ras_n", "mem_rst_n", "mem_we_n"})
ROLE_NOTES = {
    "ddr_ip": "IP-owned source-synchronous interface: retain generated FDC/RCF; external pad/board timing coverage still needs vendor evidence.",
    "differential_clock_negative": "Companion of ref_clk_p through GTP_INBUFDS; not an independent data launch clock.",
    "asynchronous_uart_rx": "UART RX enters sync_bits.meta_q then sync_out; audit only the external first-stage leg and keep stage-to-stage timing.",
    "asynchronous_board_reset": "Asynchronous assertion with domain-synchronous release; keep internal recovery/removal and release paths timed.",
    "asynchronous_uart_tx": "Serial receiver has no shared sampling clock; validate baud/frame and electrical interface, not a fabricated peripheral-clock output delay.",
    "status_led": "Human-visible status with no synchronous external receiver; no external setup/hold budget is claimed.",
    "unclassified": "Unknown board interface: supply its clocking contract and real min/max budget before signoff.",
}


def classify_io_gaps(gaps):
    """Directions are warning classes: a DDR inout can occur in both classes."""
    if not isinstance(gaps, dict):
        raise ValueError("io_delay_gaps must be an object")
    roles = {
        "no_input_delay": {**dict.fromkeys(DDR_INPUTS, "ddr_ip"),
            "ref_clk_n": "differential_clock_negative", "uart_rxd": "asynchronous_uart_rx",
            "board_reset_n": "asynchronous_board_reset"},
        "no_output_delay": {**dict.fromkeys(DDR_OUTPUTS, "ddr_ip"),
            "uart_txd": "asynchronous_uart_tx", "ddr_ready_led": "status_led"},
    }
    entries = []
    counts = {}
    for warning, known in roles.items():
        ports = gaps.get(warning)
        if (not isinstance(ports, list) or any(not isinstance(port, str) for port in ports) or
                len(ports) != len(set(ports))):
            raise ValueError(f"{warning} must be a unique list of port names")
        counts[warning] = len(ports)
        for port in sorted(ports):
            role = known.get(port, "unclassified")
            entries.append(dict(warning=warning, port=port, role=role, note=ROLE_NOTES[role]))
    unknown = [entry for entry in entries if entry["role"] == "unclassified"]
    return dict(status="UNCLASSIFIED_IO_GAPS" if unknown else "CLASSIFIED_NOT_TIMING_CLOSED",
                raw_warning_counts=counts, role_counts=dict(Counter(entry["role"] for entry in entries)),
                unclassified=unknown, entries=entries,
                timing_closure_claim=False, generated_constraints=[],
                pending_checks=[
                    "Prove DDR pad timing and PCB skew coverage using the exact HMIC_S version and board data; internal PHY setup/hold is a separate check.",
                    "Audit native UART RX first-stage binding and stage-to-stage timing; do not blanket-cut meta_q/D or the second synchronizer stage.",
                    "Audit external reset assertion and all internal recovery/removal/release paths independently.",
                ])


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def audit(project, physical_summary):
    project = Path(project).resolve()
    physical_summary = Path(physical_summary).resolve()
    summary = json.loads(physical_summary.read_text())
    if Path(summary["project"]).resolve() != project:
        raise ValueError("physical summary belongs to a different native project")
    manifest_path = project / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if summary.get("source_commit") != manifest.get("source_commit"):
        raise ValueError("physical summary and frozen manifest source commits differ")
    result = classify_io_gaps(summary["io_delay_gaps"])
    constraints = {}
    for name in ("board_ddr.fdc", "board_clocks.fdc", "backend_cdc.scf"):
        path = project / name
        if not path.is_file():
            continue
        commands = Counter()
        with path.open() as stream:
            for line in stream:
                words = line.strip().split(None, 1)
                if words and not words[0].startswith("#"):
                    commands[words[0]] += 1
        constraints[name] = dict(sha256=sha(path), command_counts=dict(commands))
    sources = {}
    for name in ("vsrc/cpu/pango_200hp_top.sv", "vsrc/cpu/pango_soc_reset.sv",
                 "vsrc/soc/peripheral/uart/uart_rx.sv", "vsrc/soc/peripheral/uart/uart_tx.sv",
                 "vsrc/soc/common/sync_bits.sv"):
        path = project / name
        if path.is_file():
            identity = sha(path)
            sources[name] = dict(sha256=identity, matches_manifest=manifest.get("files", {}).get(name) == identity)
    compile_text = (project / "compile.tcl").read_text()
    route_loads = [line.strip() for line in compile_text.splitlines()
                   if line.strip().startswith("add_constraint") and ".rcf" in line]
    result.update(schema_version=1, project=str(project), physical_summary=str(physical_summary),
                  physical_summary_sha256=sha(physical_summary), manifest_sha256=sha(manifest_path),
                  source_commit=manifest.get("source_commit"),
                  board_clock_profile=manifest.get("board_clock_profile"),
                  board_clock_domains_hz=manifest.get("board_clock_domains_hz"),
                  constraint_inputs=constraints, rtl_evidence_sources=sources,
                  ddr_route_constraint_version=manifest.get("ddr_route_constraint_version"),
                  native_rcf_loads=route_loads,
                  route_input_status="LOADED_INPUT_NOT_ROUTE_PROOF" if route_loads else "MISSING_GENERATED_DDR_RCF_INPUT",
                  tool_sha256=sha(__file__))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--physical-summary", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = audit(args.project, args.physical_summary)
        payload = json.dumps(result, indent=2) + "\n"
        if args.output:
            output = args.output.resolve()
            if output == args.project.resolve() or args.project.resolve() in output.parents:
                raise ValueError("audit output must be outside the frozen native project")
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("x") as stream:
                stream.write(payload)
            print(f"{result['status']}: {args.output}")
        else:
            print(payload, end="")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    return 2 if result["unclassified"] else 0


if __name__ == "__main__":
    sys.exit(main())
