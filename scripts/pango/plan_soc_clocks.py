#!/usr/bin/env python3
"""Generate isolated clock-only SoC candidates without starting PDS or editing board files."""
import argparse
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import json
from pathlib import Path
import re
try:
    from .prepare_project import verify_default_board_clocks
except ImportError:
    from prepare_project import verify_default_board_clocks


REPO = Path(__file__).resolve().parents[2]
DOMAINS = ("core", "sys", "ddr", "periph")
BOARD_HZ = 125_000_000
SOURCES = (
    "vsrc/cpu/pango_200hp_top.sv",
    "vsrc/cpu/pango_soc_pll.sv",
    "vsrc/cpu/pango_soc_reset.sv",
    "vsrc/soc/soc_system.sv",
    "vsrc/soc/common/async_fifo.sv",
    "vsrc/soc/common/soc_reset_controller.sv",
    "vsrc/soc/bus/axi_clock_bridge.sv",
    "vsrc/soc/bus/axil_clock_bridge.sv",
    "vsrc/soc/bus/mmio_bus.sv",
    "vsrc/soc/peripheral/timer/machine_timer.sv",
    "vsrc/soc/dma/dma_command_cdc.sv",
    "vsrc/soc/cache/cache_command_cdc.sv",
    "vsrc/soc/flash/flash_axi_target.sv",
    "tb/soc/tb_soc_system.sv",
    "scripts/pango/mes2l676_200hp.fdc",
    "ip/pango/mes2l676_200hp_ddr3.idf",
)


def without_comments(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)


def require(text, pattern, description):
    if not re.search(pattern, without_comments(text), re.S):
        raise ValueError(f"clock topology changed: {description}")


def check_topology(source):
    """Fail closed on the exact portable/board connection contracts used by this planner."""
    board = source["vsrc/cpu/pango_200hp_top.sv"]
    soc = source["vsrc/soc/soc_system.sv"]
    verify_default_board_clocks(board)
    require(board, r"pll_lock\s*&&\s*phy_pll_lock\s*&&\s*ddr_init_done",
            "board profile 0 reset still waits for DDR calibration")
    require(board, r"pango_soc_reset\s+u_reset", "independent boot supervisor")
    require(board, r"\.resetn\(ddr_reset_n\)", "coordinated DDR controller reset")
    for instance in ("u_core", "u_memory", "u_maintenance", "u_ram"):
        require(soc, rf"\b{instance}\s*\(\s*\.clk\s*\(\s*clk_core\s*\)",
                f"{instance} must remain in the shared Core/TCM/Cache domain")
    for instance, src, dst in (
        ("u_cdc", "core", "sys"), ("u_tcm_cdc", "sys", "core"),
        ("g_ddr.u_ddr_cdc", "sys", "ddr"), ("u_periph_cdc", "sys", "periph"),
    ):
        leaf = instance.rsplit('.', 1)[-1]
        require(soc, rf"\b{leaf}\s*\([^;]*\.s_clk\s*\(clk_{src}\)[^;]*"
                rf"\.m_clk\s*\(clk_{dst}\)", f"{instance} {src}->{dst}")
    require(soc, r"genvar\s+m\s*=\s*0\s*;\s*m\s*<\s*2", "two CPU AXI masters")
    require(soc, r"u_peripherals\s*\(\s*\.clk\s*\(clk_periph\)", "peripheral timebase")
    require(source["vsrc/soc/peripheral/timer/machine_timer.sv"],
            r"time_d\s*=\s*time_q\s*\+\s*64'd1", "mtime increments every peripheral cycle")
    for name in ("axi_clock_bridge", "axil_clock_bridge"):
        bridge = source[f"vsrc/soc/bus/{name}.sv"]
        require(bridge, r"parameter\s+int\s+DEPTH\s*=\s*8", f"{name} depth")
        for channel in ("aw", "w", "b", "ar", "r"):
            require(bridge, rf"async_fifo\s*#\([^;]*\.DEPTH\(DEPTH\)\)\s+u_{channel}\s*\(",
                    f"{name} {channel} FIFO")
    for filename, instances in (
        ("vsrc/soc/dma/dma_command_cdc.sv", ("u_command", "u_result")),
        ("vsrc/soc/cache/cache_command_cdc.sv", ("u_command", "u_status")),
        ("vsrc/soc/flash/flash_axi_target.sv", ("u_config", "u_ack")),
    ):
        for instance in instances:
            require(source[filename], rf"async_fifo\s*#\([^;]*\.DEPTH\(2\)\)\s+{instance}\s*\(",
                    f"{filename} {instance} depth")
    fifo = source["vsrc/soc/common/async_fifo.sv"]
    for first, second in (("read_sync1_q", "read_sync2_q"), ("write_sync1_q", "write_sync2_q")):
        require(fifo, rf"{second}\s*<=\s*{first}\s*;", "two-stage Gray synchronizer")
    require(fifo, r'ASYNC_REG\s*=\s*"TRUE"', "Gray synchronizer attribute")
    reset = source["vsrc/soc/common/soc_reset_controller.sv"]
    require(reset, r"posedge\s+clocks\[d\]\s+or\s+posedge\s+reset_async", "common async reset")
    require(reset, r"release_q\s*<=\s*\{release_q\[1:0\],\s*1'b0\}", "synchronous reset release")


def clock_profiles(testbench):
    """Read exact ps-rounded C0-C4 clocks from the existing simulator driver."""
    profiles = {}
    for domain, offset in (("sys", 1700), ("ddr", 2300), ("periph", 3100)):
        require(testbench, rf"if\(clock_config!=0\)\s*#{offset}ps;\s*forever\s*#\({domain}_half\)",
                f"testbench {domain} phase offset")
    body = re.search(r"case\(CLOCK_PROFILE\)(.*?)endfunction", testbench, re.S)
    if body is None:
        raise ValueError("missing testbench clock profiles")
    common = re.search(r"0:\s*return\s+(\d+);", body[1])
    if common is None:
        raise ValueError("incomplete testbench C0")
    profiles['C0'] = {d: Decimal(common[1])/1000 for d in DOMAINS}
    for index in range(1,5):
        block = re.search(rf"\b{index}:\s*case\(domain_index\)(.*?)endcase", body[1], re.S)
        if block is None:
            raise ValueError(f"missing testbench C{index}")
        values = {}
        for selector, value in re.findall(r"([0-3,]+|default):\s*return\s+(\d+);",block[1]):
            for d in ([3] if selector=='default' else map(int,selector.split(','))):
                values[DOMAINS[d]] = Decimal(value)/1000
        if set(values)!=set(DOMAINS):
            raise ValueError(f"incomplete testbench C{index}")
        profiles[f'C{index}'] = values
    # This is a requested portable-clock candidate; no claim about PLL legal settings.
    profiles["floor85"] = {
        d: (Decimal(1_000_000_000) / hz).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
        for d, hz in zip(DOMAINS, map(Decimal, (85_000_000, 100_000_000, 125_000_000, 25_000_000)))
    }
    for periods in profiles.values():
        if any(p <= 0 for p in periods.values()):
            raise ValueError("clock period must be positive")
    return profiles


def cdc_boundaries(periods):
    """List every FIFO and its two Gray crossings; physical pins remain unresolved."""
    fifos = []

    def add(path, src, dst, depth):
        fifos.append({
            "rtl_instance": path, "source_domain": src, "destination_domain": dst,
            "depth": depth, "pointer_bits": depth.bit_length(),
            "gray_physical_budget_ns": str(min(periods[src], periods[dst])),
            "gray_crossings": [
                {"from": "write_gray_q", "to": "write_sync1_q", "source_domain": src},
                {"from": "read_gray_q", "to": "read_sync1_q", "source_domain": dst},
            ],
            "binding_status": "unresolved synthesized Q/D pins; no exception emitted",
        })

    for instance, src, dst in (
        ("g_cpu_master[0].u_cdc", "core", "sys"),
        ("g_cpu_master[1].u_cdc", "core", "sys"),
        ("u_tcm_cdc", "sys", "core"), ("g_ddr.u_ddr_cdc", "sys", "ddr"),
        ("u_periph_cdc", "sys", "periph"),
    ):
        for channel in ("aw", "w", "ar", "b", "r"):
            reverse = channel in ("b", "r")
            add(f"{instance}.u_{channel}", dst if reverse else src, src if reverse else dst, 8)
    for instance, src, dst in (
        ("u_dma.u_command", "periph", "sys"), ("u_dma.u_result", "sys", "periph"),
        ("u_maintenance_cdc.u_command", "periph", "core"),
        ("u_maintenance_cdc.u_status", "core", "periph"),
        ("u_flash.u_config", "periph", "sys"), ("u_flash.u_ack", "sys", "periph"),
    ):
        add(instance, src, dst, 2)
    return fifos


def build_plan(repo, profile, target="soc_system"):
    if target != "soc_system":
        raise ValueError("board generated-clock pins and CDC physical constraints remain unbound; "
                         "portable port-clock candidates cannot be applied to pango_200hp_top")
    source = {name: (repo / name).read_text() for name in SOURCES}
    check_topology(source)
    profiles = clock_profiles(source["tb/soc/tb_soc_system.sv"])
    if profile not in profiles:
        raise ValueError(f"unknown profile: {profile}")
    periods = profiles[profile]
    clocks = {}
    phase_offsets = dict(zip(DOMAINS, (0, 1700, 2300, 3100)))
    for domain, period in periods.items():
        hz = Decimal(1_000_000_000) / period
        clocks[domain] = {
            "port": f"clk_{domain}", "period_ns": str(period), "frequency_hz": float(hz),
            "testbench_start_offset_ps": (1 + (phase_offsets[domain] if profile != "C0" else 0))
            if profile != "floor85" else None,
        }
    periph_hz = Decimal(str(clocks["periph"]["frequency_hz"]))
    divisor = int((periph_hz / 115200).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    report = {
        "schema_version": 1, "profile": profile, "top": target,
        "status": "offline clock-only candidate; PDS, synthesis, STA and PLL generation not run",
        "physical_timing_pass": False, "clocks": clocks,
        "constraint_scope": "soc_system four top-level inputs only; not board_ddr.fdc",
        "constraint_phase": "zero-phase clock definitions; simulator startup offsets recorded separately",
        "board": {"reference_hz": BOARD_HZ, "ddr_user_hz": BOARD_HZ,
                  "domain_sources": dict.fromkeys(DOMAINS, "DDR IP core_clk"),
                  "default_profile": 0, "reset_waits_for_ddr": True, "candidate_applied": False,
                  "rtl_candidate_profiles": [1, 4],
                  "candidate_reset": "independent boot; lock/ready/heartbeat loss resets all domains and DDR IP",
                  "pll_candidate": {"primitive": "GTP_GPLL", "reference_hz": 125000000,
                                    "idiv": 5, "mdiv": 4, "feedback_div": 8,
                                    "pfd_hz": 25000000, "vco_hz": 800000000,
                                    "output_div_c1": [8, 10, 32], "output_div_c4": [8, 8, 32],
                                    "dedicated_buffers": 3, "site_and_route_verified": False,
                                    "clock_relationship": "core/sys/periph share GPLL; DDR IP shares reference, phase pending"}},
        "local_hot_path": {"members": ["Core", "TCM", "I-cache", "D-cache"], "domain": "core",
                           "core_memory_split": "future candidate, not implemented"},
        "timebases": {"mcycle_domain": "core", "mtime_domain": "periph",
                      "mtime_hz": clocks["periph"]["frequency_hz"],
                      "uart_divisor_for_115200": divisor,
                      "uart_resulting_baud": float(periph_hz / divisor),
                      "discovery": "ABI bit 8 advertises versioned core/sys/ddr/periph/timer fields; legacy +0x04 retained"},
        "fifo_boundaries": cdc_boundaries(periods),
        "level_crossings": [
            {"signal": "device_pending", "from": "periph", "to": "core", "first_stage": "irq_sync1_q"},
            {"signal": "ddr_ready", "from": "ddr", "to": "sys", "first_stage": "ddr_system_online_q[0]"},
            {"signal": "ddr_ready", "from": "ddr", "to": "periph", "first_stage": "ddr_online_q[0]"},
        ],
        "reset": "common asynchronous assertion, three destination-clock edges to release; no one-sided FIFO reset",
        "physical_todo": [
            "Validate the extra GPLL and three global buffers against DDR IP resources and device placement sites.",
            "Bind generated-clock output pins and establish actual phase relationships before choosing clock exceptions.",
            "Bind Gray source Q to first-stage D pins; verify max delay and bus skew within the listed conservative budget.",
            "Keep first-to-second synchronizer stage paths timed; review CDC payload storage/read paths separately.",
            "Resolve reset recovery/removal, asynchronous input synchronization and missing board I/O delays.",
            "Validate reference watchdog and coordinated DDR reset recovery/removal on physical clocks.",
            "Validate each domain with standard PDS later; simulation periods are not achieved Fmax.",
        ],
        "source_sha256": {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in SOURCES},
        "generator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    lines = ["# Offline soc_system port-clock candidate. NOT a Pango board constraint file.",
             "# Clock definitions only; no path exceptions, I/O constraints or CDC physical binding.",
             "# Zero-phase definitions; simulation startup offsets are in clock-plan.json."]
    for domain, period in periods.items():
        lines.append(f"create_clock -name {{clk_{domain}}} [get_ports {{clk_{domain}}}] -period {{{period}}}")
    return report, "\n".join(lines) + "\n"


def write_plan(repo, output, profile, target="soc_system"):
    output = output.resolve()
    # Artifacts stay under ignored build/; never modify a staged or board project.
    build_root = (repo / "build").resolve()
    if build_root not in output.parents:
        raise ValueError("output must be a new isolated directory below repository build/")
    if output.exists() and any(output.iterdir()):
        raise ValueError("output directory must be empty; preserve earlier candidates")
    report, constraints = build_plan(repo, profile, target)
    report["command"] = ["python3", "scripts/pango/plan_soc_clocks.py", "--profile", profile,
                         "--target", target, "--output", output.relative_to(repo).as_posix()]
    output.mkdir(parents=True, exist_ok=True)
    (output / "soc_system_clocks.fdc").write_text(constraints)
    report["constraint_sha256"] = hashlib.sha256(constraints.encode()).hexdigest()
    (output / "clock-plan.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("C0", "C1", "C2", "C3", "C4", "floor85"), required=True)
    parser.add_argument("--target", choices=("soc_system", "pango_200hp_top"), default="soc_system")
    parser.add_argument("--output", type=Path, required=True, help="new directory under build/")
    args = parser.parse_args()
    try:
        report = write_plan(REPO, args.output, args.profile, args.target)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    print(f"PASS offline clock plan {args.profile}: {len(report['fifo_boundaries'])} FIFO boundaries; PDS not run")


if __name__ == "__main__":
    main()
