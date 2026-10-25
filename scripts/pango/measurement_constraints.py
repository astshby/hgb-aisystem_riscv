#!/usr/bin/env python3
"""Diagnostic H0/H1/H2 constraints; generate text only, never launch PDS.

The clocks below are independent external inputs to pango_measure_top.  They do
not certify board PLLs, DDR PHY routing, CDC payload timing, or timing closure.
PDS syntax follows UG990202 sections 3.5.4.9/12/24/26 and UG990004 4.79/106.
"""
from decimal import Decimal
import json
import re


CLOCKS = {
    "C1": {"core": 100_000_000, "sys": 80_000_000, "ddr": 125_000_000, "periph": 25_000_000},
    "C4": {"core": 100_000_000, "sys": 100_000_000, "ddr": 125_000_000, "periph": 25_000_000},
}
DOMAINS = ("core", "sys", "ddr", "periph")
SCAN_INPUTS = ("scan_shift", "scan_update", "scan_capture", "scan_din")
SOC = "g_soc.u_soc"
PRUNABLE_FIFOS = tuple(f"{SOC}.g_cpu_master[0].u_cdc.u_{channel}" for channel in ("aw", "w", "b"))


def _number(value):
    return format(Decimal(value).normalize(), "f")


def _path_pattern(path):
    # PDS 的 generate 层次可用点或斜线表示；不接受任意跨层通配。
    return "[./]".join(re.escape(part) for part in path.split("."))


def _register_pattern(path, signal, pin, bit=None):
    index = "([0-9]+)" if bit is None else f"({bit})"
    # 只接受 RTL 位寄存器及已知 opit 包装。复制/改名必须按新综合网表另行审查。
    return (f"^{_path_pattern(path)}[./]{re.escape(signal)}\\[{index}\\]"
            rf"(?:[./]opit_[0-9]+(?:_inv)?)?[./]{pin}$")


def _pins(pattern):
    return f"[get_pins -hierarchical -regexp {{{pattern}}}]"


def _ports(name):
    return f"[get_ports -regexp {{^{re.escape(name)}$}}]"


def _fifo_inventory(periods):
    entries = []

    def add(path, src, dst, depth):
        crossings = []
        for direction, source, destination in (("write", src, dst), ("read", dst, src)):
            crossings.append({
                "direction": direction, "source_domain": source, "destination_domain": destination,
                "source_q": _register_pattern(path, f"{direction}_gray_q", "Q"),
                "source_clock": _register_pattern(path, f"{direction}_gray_q", "CLK"),
                "first_d": _register_pattern(path, f"{direction}_sync1_q", "D"),
                "first_clock": _register_pattern(path, f"{direction}_sync1_q", "CLK"),
                "second_d": _register_pattern(path, f"{direction}_sync2_q", "D"),
                "second_clock": _register_pattern(path, f"{direction}_sync2_q", "CLK"),
            })
        entries.append({"path": path, "pointer_bits": depth.bit_length(),
                        "scope_clock_pattern": f"^{_path_pattern(path)}[./].*[./]CLK$",
                        "budget_ns": _number(min(periods[src], periods[dst])),
                        "allow_whole_fifo_pruned": path in PRUNABLE_FIFOS,
                        "crossings": crossings})

    for instance, src, dst in (
        ("g_cpu_master[0].u_cdc", "core", "sys"),
        ("g_cpu_master[1].u_cdc", "core", "sys"),
        ("u_tcm_cdc", "sys", "core"), ("g_ddr.u_ddr_cdc", "sys", "ddr"),
        ("u_periph_cdc", "sys", "periph"),
    ):
        for channel in ("aw", "w", "ar", "b", "r"):
            reverse = channel in ("b", "r")
            add(f"{SOC}.{instance}.u_{channel}", dst if reverse else src, src if reverse else dst, 8)
    for instance, src, dst in (
        ("u_dma.u_command", "periph", "sys"), ("u_dma.u_result", "sys", "periph"),
        ("u_maintenance_cdc.u_command", "periph", "core"),
        ("u_maintenance_cdc.u_status", "core", "periph"),
        ("u_flash.u_config", "periph", "sys"), ("u_flash.u_ack", "sys", "periph"),
    ):
        add(f"{SOC}.{instance}", src, dst, 2)
    return entries


def _specification(layer, profile):
    if type(layer) is not int or layer not in (0, 1, 2):
        raise ValueError("measurement layer must be integer 0, 1 or 2; H3 board PLLs are separate")
    if profile not in CLOCKS:
        raise ValueError("measurement profile must be C1 or C4")
    active = DOMAINS if layer == 2 else ("core",)
    periods = {d: Decimal(1_000_000_000) / CLOCKS[profile][d] for d in DOMAINS}
    resets = []
    for domain in active:
        index = DOMAINS.index(domain)
        roots = [f"u_reset.g_domain[{index}]"]
        if layer == 2:
            roots.append(f"{SOC}.u_reset.g_domain[{index}]")
        resets.append({"domain": domain, "roots": roots,
                       "chains": [{pin: _register_pattern(root, "release_q", pin)
                                   for pin in ("D", "CLK", "(?:P|C)")}
                                  for root in roots]})
    levels = []
    if layer == 2:
        for name, src, dst, first, second, bits, bit0, bit1 in (
            ("irq", "periph", "core", "irq_sync1_q", "irq_sync2_q", 3, None, None),
            ("ddr_system_ready", "ddr", "sys", "ddr_system_online_q", "ddr_system_online_q", 1, 0, 1),
            ("ddr_periph_ready", "ddr", "periph", "ddr_online_q", "ddr_online_q", 1, 0, 1),
        ):
            levels.append({"name": name, "source_domain": src, "destination_domain": dst,
                           "bits": bits, "first_indices": list(range(bits)) if bit0 is None else [bit0],
                           "second_indices": list(range(bits)) if bit1 is None else [bit1],
                           "first_d": _register_pattern(SOC, first, "D", bit0),
                           "first_clock": _register_pattern(SOC, first, "CLK", bit0),
                           "second_d": _register_pattern(SOC, second, "D", bit1),
                           "second_clock": _register_pattern(SOC, second, "CLK", bit1)})
    return {
        "schema_version": 2, "top": "pango_measure_top", "layer": layer, "profile": profile,
        "clock_source": "independent diagnostic input clocks; H3 board PLLs are not represented",
        "active_domains": list(active), "clock_hz": {d: CLOCKS[profile][d] for d in active},
        "period_ns": {d: _number(periods[d]) for d in active},
        "io_assumptions_ns": {"input_min": "0", "input_max": "1", "output_min": "0", "output_max": "1"},
        "clock_uncertainty_ns": {"setup": "0.2", "hold": "0.05"},
        "inactive_scan_bits": [DOMAINS.index(d) for d in DOMAINS if d not in active],
        "inactive_ports_reason": "H0/H1 unused domain inputs have no endpoints; corresponding scan outputs are constant zero",
        "reset_chains": resets, "fifos": _fifo_inventory(periods) if layer == 2 else [],
        "level_crossings": levels,
        "pruning_rule": "only IF0 AW/W/B; both pointer sources and both synchronizer stages must all be absent",
        "payload_policy": "FIFO payload paths retain ordinary timing checks; no payload false path or timing-closure claim",
        "audit_scope": "exact object/bit/domain binding, not connectivity or analog metastability proof",
        "constraints_mode": "conservative_external_clocks_io; all internal paths remain timed",
        "exceptions_loaded": False,
        "proposed_exception_file": "proposed_cdc.fdc",
        "exception_activation_requires": "native compile/synthesis/map object evidence and review; never add the proposal automatically",
        "pds_execution": "not run by this generator", "physical_timing_pass": False,
    }


def _fdc(spec):
    lines = ["# H0/H1/H2 diagnostic clocks and scan timing assumptions; no board PLL claim.",
             "# Conservative resource/same-domain diagnosis: no internal timing exception is loaded.",
             "# Reset, CDC, scan and FIFO payload paths all retain ordinary timing checks.",
             "# proposed_cdc.fdc is unbound evidence only; do not add_constraint it."]
    for domain in spec["active_domains"]:
        period = spec["period_ns"][domain]
        lines += [f"create_clock -name {{clk_{domain}}} -period {period} "
                  f"-waveform {{0 {_number(Decimal(period) / 2)}}} [get_ports {{clk_{domain}}}]",
                  f"set_clock_uncertainty -setup 0.2 [get_clocks {{clk_{domain}}}]",
                  f"set_clock_uncertainty -hold 0.05 [get_clocks {{clk_{domain}}}]"]
        index = DOMAINS.index(domain)
        for name in SCAN_INPUTS:
            port = _ports(f"{name}[{index}]")
            lines += [f"set_input_delay -clock [get_clocks {{clk_{domain}}}] -min 0 {port}",
                      f"set_input_delay -clock [get_clocks {{clk_{domain}}}] -max 1 {port}"]
        port = _ports(f"scan_dout[{index}]")
        lines += [f"set_output_delay -clock [get_clocks {{clk_{domain}}}] -min 0 {port}",
                  f"set_output_delay -clock [get_clocks {{clk_{domain}}}] -max 1 {port}"]
    lines += ["# Reset input is modeled for coverage; no recovery/removal exception is loaded.",
              "set_input_delay -clock [get_clocks {clk_core}] -min 0 [get_ports {reset_async}]",
              "set_input_delay -clock [get_clocks {clk_core}] -max 1 [get_ports {reset_async}]"]
    return "\n".join(lines) + "\n"


def _proposed_exceptions(spec):
    # 原生 compile DB 尚未确认内部对象命名。保留方案文本，不导入任何测量工程。
    lines = ["# UNBOUND PROPOSAL ONLY. Not loaded by the diagnostic measurement flow.",
             "# Native compile/synthesis/map object names and exception effectiveness need review first.",
             "# PDS UG990202: datapath_only max-delay and max-skew override first-stage false paths.",
             "# Keep scan, synchronizer later stages and FIFO payload paths normally timed."]
    for reset in spec["reset_chains"]:
        for chain in reset["chains"]:
            lines.append(f"set_false_path -from [get_ports {{reset_async}}] -to {_pins(chain['(?:P|C)'])}")
    for fifo in spec["fifos"]:
        lines.append(f"# {fifo['path']}; require post-synthesis binding audit.")
        for cross in fifo["crossings"]:
            first = _pins(cross["first_d"])
            source = _pins(cross["source_q"])
            lines += [f"set_false_path -from {source} -to {first}",
                      f"set_max_delay {fifo['budget_ns']} -datapath_only -from {source} -to {first}",
                      f"set_max_skew {fifo['budget_ns']} -from {_pins(cross['source_clock'])} -to {first}"]
    for level in spec["level_crossings"]:
        lines.append(f"set_false_path -from [get_clocks {{clk_{level['source_domain']}}}] "
                     f"-to {_pins(level['first_d'])}")
    return "\n".join(lines) + "\n"


def _discovery(spec):
    queries = ["get_cells -hierarchical *release_q*", "get_pins -hierarchical *release_q*",
               "get_clocks *", "all_clocks"]
    for domain in spec["active_domains"]:
        queries.append(f"all_registers -clock clk_{domain} -async_pins")
    if spec["layer"] == 2:
        queries += ["get_cells -hierarchical *u_ddr_cdc*u_ar*write_gray_q*",
                    "get_pins -hierarchical *u_ddr_cdc*u_ar*write_gray_q*",
                    "get_pins -hierarchical *u_ddr_cdc*u_ar*write_sync1_q*",
                    "get_pins -hierarchical *irq_sync*", "get_pins -hierarchical *ddr_online_q*"]
    rows = " ".join("{" + query + "}" for query in queries)
    return ("# Read-only DW object discovery. No exception, flow action or database mutation.\n"
            "# Invoke with open_dw -action compile|synthesize -shell_mode -file <this file> -serial_execution.\n"
            'puts "S4_OBJECT_DISCOVERY_BEGIN"\n'
            'puts "S4_API [info commands get_*]"\n'
            f"foreach query {{{rows}}} {{\n"
            '    puts "S4_QUERY $query"\n'
            "    if {[catch {uplevel #0 $query} result]} {\n"
            '        puts "S4_QUERY_ERROR $result"\n'
            "    } else {\n"
            '        puts "S4_QUERY_RESULT [lrange $result 0 95]"\n'
            "    }\n}\n"
            'puts "S4_OBJECT_DISCOVERY_END"\n')


_AUDIT_PROCEDURES = r'''# Execute inside open_dw -action synthesize -shell_mode; no flow command here.
# Unsupported collection representations fail instead of being mistaken for one match.
foreach command {get_ports get_pins get_clocks all_clocks all_registers} {
    if {[llength [info commands $command]] != 1} { error "missing PDS query command $command" }
}
proc hgb_names {objects label} {
    if {[llength [info commands get_object_name]] == 1} {
        set objects [get_object_name $objects]
    }
    if {[catch {llength $objects}]} { error "unsupported collection for $label" }
    set names {}
    foreach name $objects {
        if {![regexp {^[A-Za-z_][A-Za-z0-9_./:\[\]-]*$} $name]} {
            error "unsupported object name for $label: $name"
        }
        if {[lsearch -exact $names $name] >= 0} { error "duplicate object for $label: $name" }
        lappend names $name
    }
    return $names
}
proc hgb_query {pattern} {
    set names [hgb_names [get_pins -hierarchical -regexp $pattern] $pattern]
    foreach name $names {
        if {![regexp -- $pattern $name]} { error "query returned unrelated object: $name" }
    }
    return $names
}
proc hgb_exact {objects expected label} {
    set names [hgb_names $objects $label]
    if {[lsort $names] ne [lsort $expected]} { error "$label: expected $expected; got $names" }
    return $names
}
proc hgb_bits {names pattern expected label} {
    set bits {}
    foreach name $names {
        if {![regexp -- $pattern $name unused bit]} { error "$label has unrecognized bit: $name" }
        lappend bits $bit
    }
    if {[lsort -integer $bits] ne [lsort -integer $expected]} {
        error "$label: expected bits $expected; got $bits"
    }
}
proc hgb_domain {names domain kind label} {
    global hgb_domain_objects
    foreach name $names {
        if {[lsearch -exact $hgb_domain_objects($domain,$kind) $name] < 0} {
            error "$label: $name does not belong to clk_$domain $kind"
        }
    }
}
proc hgb_audit_fifo {path bits prunable scope_clock_pattern rows} {
    set resolved {}; set total 0
    foreach row $rows {
        lassign $row direction src dst source_q source_ck first_d first_ck second_d second_ck
        set matches {}
        foreach pattern [list $source_q $source_ck $first_d $first_ck $second_d $second_ck] {
            set names [hgb_query $pattern]
            incr total [llength $names]
            lappend matches $names
        }
        lappend resolved $matches
    }
    if {$total == 0 && $prunable} {
        if {[llength [hgb_query $scope_clock_pattern]] != 0} {
            error "$path has residual registers; unknown aliases cannot count as whole-FIFO pruning"
        }
        puts "MEASUREMENT_FIFO_PRUNED $path reason=instruction_master_has_no_write_channel"
        return
    }
    set expected {}; for {set bit 0} {$bit < $bits} {incr bit} { lappend expected $bit }
    foreach row $rows matches $resolved {
        lassign $row direction src dst source_q source_ck first_d first_ck second_d second_ck
        foreach pattern [list $source_q $source_ck $first_d $first_ck $second_d $second_ck] names $matches {
            hgb_bits $names $pattern $expected "$path $direction"
            puts "MEASUREMENT_BIND $path $direction $pattern $names"
        }
        hgb_domain [lindex $matches 0] $src output "$path source Q"
        hgb_domain [lindex $matches 1] $src clock "$path source CLK"
        hgb_domain [lindex $matches 2] $dst data "$path first D"
        hgb_domain [lindex $matches 3] $dst clock "$path first CLK"
        hgb_domain [lindex $matches 4] $dst data "$path second D"
        hgb_domain [lindex $matches 5] $dst clock "$path second CLK"
    }
}
proc hgb_audit_reset {domain chains} {
    set present 0
    foreach chain $chains {
        lassign $chain data_pat clock_pat async_pat
        set data [hgb_query $data_pat]; set clock [hgb_query $clock_pat]; set async [hgb_query $async_pat]
        if {[llength $data] + [llength $clock] + [llength $async] == 0} { continue }
        foreach pattern $chain names [list $data $clock $async] {
            hgb_bits $names $pattern {0 1 2} "reset $domain"
        }
        hgb_domain $data $domain data "reset D"
        hgb_domain $clock $domain clock "reset CLK"
        hgb_domain $async $domain async "reset asynchronous control"
        puts "MEASUREMENT_RESET_BIND $domain $data $async"
        incr present
    }
    if {$present == 0} { error "no complete reset release chain for $domain" }
}
'''


def _audit(spec):
    lines = [_AUDIT_PROCEDURES, "set ::hgb_measurement_bindings_pass 0"]
    clocks = " ".join(f"clk_{d}" for d in spec["active_domains"])
    lines.append(f"hgb_exact [all_clocks] {{{clocks}}} {{active diagnostic clocks}}")
    lines.append("hgb_exact [get_ports {reset_async}] {reset_async} {reset port}")
    for domain in spec["active_domains"]:
        lines += [f"hgb_exact [get_clocks {{clk_{domain}}}] {{clk_{domain}}} {{clock {domain}}}",
                  f"hgb_exact [get_ports {{clk_{domain}}}] {{clk_{domain}}} {{clock port {domain}}}"]
        for name in (*SCAN_INPUTS, "scan_dout"):
            port = f"{name}[{DOMAINS.index(domain)}]"
            lines.append(f"hgb_exact {_ports(port)} {{{port}}} {{scan port {port}}}")
        for kind, option in (("clock", "clock_pins"), ("data", "data_pins"),
                             ("output", "output_pins"), ("async", "async_pins")):
            lines += [f"set hgb_domain_objects({domain},{kind}) "
                      f"[hgb_names [all_registers -clock clk_{domain} -{option}] {{{domain} {kind}}}]",
                      f"if {{[llength $hgb_domain_objects({domain},{kind})] == 0}} "
                      f"{{ error {{no clk_{domain} {kind} register endpoints}} }}"]
    # 未被列入任一活动域的寄存器也必须阻断，不能只核对已知 CDC 名字。
    lines.append("set hgb_covered_clock_pins {}")
    for domain in spec["active_domains"]:
        lines.append(f"set hgb_covered_clock_pins [concat $hgb_covered_clock_pins $hgb_domain_objects({domain},clock)]")
    lines += ["set hgb_all_clock_pins [hgb_names [all_registers -clock_pins] {all sequential clock pins}]",
              "if {[lsort -unique $hgb_covered_clock_pins] ne [lsort -unique $hgb_all_clock_pins]} {",
              '    error "sequential clock endpoints exist outside the declared diagnostic domains"', "}"]
    for reset in spec["reset_chains"]:
        rows = " ".join("{" + " ".join("{" + c[k] + "}" for k in ("D", "CLK", "(?:P|C)")) + "}"
                        for c in reset["chains"])
        lines.append(f"hgb_audit_reset {reset['domain']} {{{rows}}}")
    for fifo in spec["fifos"]:
        rows = []
        for cross in fifo["crossings"]:
            values = [cross[key] for key in ("direction", "source_domain", "destination_domain", "source_q",
                                             "source_clock", "first_d", "first_clock", "second_d", "second_clock")]
            rows.append("{" + " ".join("{" + value + "}" for value in values) + "}")
        lines.append(f"hgb_audit_fifo {{{fifo['path']}}} {fifo['pointer_bits']} "
                     f"{int(fifo['allow_whole_fifo_pruned'])} {{{fifo['scope_clock_pattern']}}} {{{' '.join(rows)}}}")
    for level in spec["level_crossings"]:
        for key, kind, indices in (("first_d", "data", "first_indices"), ("first_clock", "clock", "first_indices"),
                                   ("second_d", "data", "second_indices"), ("second_clock", "clock", "second_indices")):
            pattern = level[key]
            expected = " ".join(map(str, level[indices]))
            lines += [f"set hgb_level [hgb_query {{{pattern}}}]",
                      f"hgb_bits $hgb_level {{{pattern}}} {{{expected}}} {{{level['name']} {key}}}",
                      f"hgb_domain $hgb_level {level['destination_domain']} {kind} {{{level['name']} {key}}}",
                      f"puts \"MEASUREMENT_LEVEL_BIND {level['name']} {key} $hgb_level\""]
    lines += ["set ::hgb_measurement_bindings_pass 1",
              f'puts "MEASUREMENT_BINDINGS_PASS H{spec["layer"]} {spec["profile"]} object_binding_only"',
              '# FIFO payload paths remain normally timed; PASS above does not assert timing or CDC signoff.']
    return "\n".join(lines) + "\n"


def _reports(spec):
    lines = ["# Run in the same synthesis DW after audit_clock_bindings.tcl.",
             "if {![info exists ::hgb_measurement_bindings_pass] || !$::hgb_measurement_bindings_pass} {",
             '    error "clock binding audit must pass before per-domain reports"', "}",
             "# Archive the PDS report artifacts for each marked call; output filename behavior is tool-owned."]
    for source in spec["active_domains"]:
        for destination in spec["active_domains"]:
            label = f"{source}_to_{destination}"
            lines += [f'puts "MEASUREMENT_PATH_BEGIN {label}"',
                      f"report_path_timing -phase post_syn -from [get_clocks {{clk_{source}}}] "
                      f"-to [get_clocks {{clk_{destination}}}] -report_logic_level_distribution",
                      f'puts "MEASUREMENT_PATH_END {label}"']
    lines += ["# After physical implementation also run:",
              "# report_timing -report_max_skew -report_exception",
              "# Inspect first-to-second stage timing and max-delay/skew exception coverage explicitly."]
    return "\n".join(lines) + "\n"


def generate(layer: int, profile: str = "C1") -> dict[str, str]:
    """Return deterministic staging artifacts for the fixed diagnostic RTL contract.

    The caller owns file placement, input/source hashes and PDS execution.  The
    generated audit deliberately stops on unrecognized synthesis aliases rather
    than guessing which register is a synchronizer.  A stopped audit does not
    invalidate already collected synthesis resource measurements.
    """
    spec = _specification(layer, profile)
    proposed = _proposed_exceptions(spec)
    kinds = ("set_false_path", "set_max_delay", "set_max_skew")
    spec["pending_exception_commands"] = {kind: sum(line.startswith(kind + " ")
                                                    for line in proposed.splitlines()) for kind in kinds}
    spec["pending_exception_count"] = sum(spec["pending_exception_commands"].values())
    return {"measurement.fdc": _fdc(spec), "audit_clock_bindings.tcl": _audit(spec),
            "report_domains.tcl": _reports(spec),
            "proposed_cdc.fdc": proposed, "discover_clock_objects.tcl": _discovery(spec),
            "binding-spec.json": json.dumps(spec, indent=2, sort_keys=True) + "\n"}
