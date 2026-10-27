#!/usr/bin/env python3
"""Build and replay isolated DDR CoreMark cache/background configurations (no PDS)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DDR_BASE = 0x80000000
DDR_BYTES = 262144
EXPECTED = {
    'performance': {'seedcrc': 0xe9f5, 'crclist': 0xe714, 'crcmatrix': 0x1fd7, 'crcstate': 0x8e3a},
    'validation': {'seedcrc': 0x18f2, 'crclist': 0xe3c1, 'crcmatrix': 0x0747, 'crcstate': 0x8d84},
}
CLOCKS = {0: [5, 5, 5, 5], 1: [5, 6.25, 4, 20], 2: [4, 5, 6.25, 12.5],
          3: [5.882, 4.274, 5.376, 13.514], 4: [5, 5, 4, 20]}
LAYERS = {'cold': (0, 0), 'warm': (1, 0), 'background': (1, 1)}
CORE_FIELDS = ('xlen', 'backend', 'issue_width', 'retire_entries', 'split_issue_queue',
               'integer_queue_entries', 'memory_queue_entries', 'limited_integer_ooo',
               'scheduler_forward_mode', 'predictor_mode', 'ras_enable', 'mul_impl', 'div_impl')
CORE_ENVIRONMENT = ('CORE_BACKEND', 'ISSUE_WIDTH', 'RETIRE_ENTRIES', 'SPLIT_ISSUE_QUEUE',
                    'INTEGER_QUEUE_ENTRIES', 'MEMORY_QUEUE_ENTRIES', 'LIMITED_INTEGER_OOO',
                    'SCHEDULER_FORWARD_MODE', 'PREDICTOR_MODE', 'RAS_ENABLE', 'MUL_IMPL', 'DIV_IMPL',
                    'CORE_ISSUE_WIDTH', 'CORE_RETIRE_ENTRIES', 'CORE_PREDICTOR_MODE', 'CORE_RAS_ENABLE')
CORE_PROFILES = {
    'p0': dict(zip(CORE_FIELDS, (32, 'scoreboard', 2, 16, 0, 8, 4, 0, 0, 0, 0, 0, 1))),
    'p1': dict(zip(CORE_FIELDS, (32, 'scoreboard', 2, 32, 1, 8, 4, 1, 3, 1, 1, 0, 1))),
}


def validate_core_config(config):
    allowed = {'xlen': (32, 64), 'backend': ('scoreboard',), 'issue_width': (2,),
               'retire_entries': (2, 4, 8, 16, 32), 'split_issue_queue': (0, 1),
               'integer_queue_entries': (2, 4, 8, 16), 'memory_queue_entries': (2, 4, 8),
               'limited_integer_ooo': (0, 1), 'scheduler_forward_mode': (0, 1, 2, 3),
               'predictor_mode': (0, 1), 'ras_enable': (0, 1), 'mul_impl': (0, 1, 2), 'div_impl': (0, 1)}
    if set(config) != set(allowed) or any(config[key] not in values for key, values in allowed.items()):
        raise ValueError('invalid or incomplete compiled Core configuration')
    if config['limited_integer_ooo'] and not config['split_issue_queue']:
        raise ValueError('limited integer OoO requires split issue queues')
    return config


def check_core_profile(config, expected):
    if expected is not None and config != CORE_PROFILES[expected]:
        raise ValueError(f'Core configuration does not match explicit {expected} profile')


def optimization():
    value = os.environ.get('OPT', 'O2')
    if value not in ('O2', 'O3', 'Ofast'):
        raise ValueError('OPT must be O2, O3 or Ofast')
    return value


def soc_build_configuration(clock_profile=1, icache_fill_bytes=4):
    if clock_profile not in CLOCKS or icache_fill_bytes not in (4, 8):
        raise ValueError('invalid static SoC clock profile or I-cache install width')
    hz = [(10**12 + round(half * 2000) // 2) // round(half * 2000) for half in CLOCKS[clock_profile]]
    return dict(zip(('clock_profile', 'icache_fill_bytes', 'metrics_schema', 'clock_info_enable',
                     'core_hz', 'sys_hz', 'ddr_hz', 'periph_hz', 'timer_hz'),
                    (clock_profile, icache_fill_bytes, 2, 1, *hz, hz[3])))


def validate_soc_config(config, expected_periods_ps=None):
    if not isinstance(config, dict):
        raise ValueError('invalid compiled SoC configuration')
    expected = soc_build_configuration(config.get('clock_profile'), config.get('icache_fill_bytes'))
    if expected_periods_ps is not None:
        if len(expected_periods_ps) != 4 or any(p <= 0 for p in expected_periods_ps):
            raise ValueError('four positive clock periods required')
        for domain, period in zip(('core', 'sys', 'ddr', 'periph'), expected_periods_ps):
            expected[domain + '_hz'] = (10**12 + period // 2) // period
        expected['timer_hz'] = expected['periph_hz']
    if config != expected:
        raise ValueError('invalid or incomplete compiled SoC configuration')
    return config


def parse_soc_config(text, expected=None, expected_periods_ps=None):
    lines = re.findall(r'^P2_HARDWARE (.*)$', text, re.M)
    if not lines and expected is None:
        return None
    if len(lines) != 1:
        raise ValueError('missing or duplicate compiled P2_HARDWARE configuration')
    pairs = re.findall(r'(\w+)=(\d+)', lines[0])
    config = {key: int(value) for key, value in pairs}
    if len(config) != len(pairs):
        raise ValueError('duplicate compiled SoC parameter')
    validate_soc_config(config, expected_periods_ps)
    if expected is not None and config != expected:
        raise ValueError('compiled SoC configuration differs from build receipt')
    return config


def core_build_configuration():
    # 与 shell 入口共用参数校验和默认值；软件 freeze 不依赖这组硬件参数。
    command = '''source scripts/verilator/p2_core_config.sh
printf '%s\\n' 32 "$core_backend" "$core_issue_width" "$core_retire_entries" \\
 "$core_split_issue_queue" "$core_integer_queue_entries" "$core_memory_queue_entries" \\
 "$core_limited_integer_ooo" "$core_scheduler_forward_mode" "$core_predictor_mode" \\
 "$core_ras_enable" "$MUL_IMPL" "$DIV_IMPL" "$p2_core_build_tag" "${p2_core_flags[@]}"
'''
    fields = subprocess.check_output(['bash', '-euc', command], cwd=ROOT, text=True).splitlines()
    if len(fields) <= len(CORE_FIELDS) + 1:
        raise ValueError('missing shared Core build configuration')
    try:
        config = {key: value if key == 'backend' else int(value)
                  for key, value in zip(CORE_FIELDS, fields)}
    except ValueError as error:
        raise ValueError('malformed shared Core build configuration') from error
    validate_core_config(config)
    flags = fields[len(CORE_FIELDS) + 1:]
    if any(not flag.startswith('-DCORE_') or any(char.isspace() for char in flag) for flag in flags):
        raise ValueError('unexpected shared Core compiler flag')
    return {'core_config': config, 'core_build_tag': fields[len(CORE_FIELDS)], 'core_flags': flags}


def parse_core_config(text, expected=None):
    lines = re.findall(r'^P2_CORE (.*)$', text, re.M)
    if not lines:
        if expected is not None:
            raise ValueError('missing compiled P2_CORE configuration record')
        return None
    if len(lines) != 1:
        raise ValueError('duplicate compiled P2_CORE configuration record')
    pairs = re.findall(r'(\w+)=(\S+)', lines[0])
    if len(pairs) != len(CORE_FIELDS) or len(dict(pairs)) != len(CORE_FIELDS):
        raise ValueError('malformed compiled P2_CORE configuration record')
    try:
        config = {key: value if key == 'backend' else int(value) for key, value in pairs}
    except ValueError as error:
        raise ValueError('non-numeric compiled Core configuration') from error
    validate_core_config(config)
    if expected is not None and config != expected:
        raise ValueError('compiled P2_CORE configuration differs from build receipt')
    return config


def parse_core_statistics(text, expected_core=None):
    result = {}
    for kind in ('SCOREBOARD_STATS', 'SCHEDULER_STATS'):
        lines = re.findall(r'^' + kind + r' (.*)$', text, re.M)
        # 只有有限乱序配置实例化 integer_issue_queue；统一/有序分队列均无此监测器。
        required = expected_core is not None and (kind == 'SCOREBOARD_STATS' or expected_core['limited_integer_ooo'])
        if len(lines) > 1 or (required and not lines):
            raise ValueError(f'missing or duplicate {kind}')
        if not lines:
            continue
        record = json.loads(lines[0])
        if (not isinstance(record, dict) or record.get('window') != 'whole_run' or
                type(record.get('cycles')) is not int or record['cycles'] <= 0 or
                any(type(value) is not int or value < 0 for key, value in record.items() if key != 'window')):
            raise ValueError(f'invalid {kind} whole-run counters')
        result[kind.lower()] = record
    if len(result) == 2 and len({record['cycles'] for record in result.values()}) != 1:
        raise ValueError('Core statistics observation windows disagree')
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, log):
    with Path(log).open('x') as output:
        output.write('$ ' + shlex.join(map(str, command)) + '\n')
        output.flush()
        subprocess.run(command, check=True, stdout=output, stderr=subprocess.STDOUT)


def symbols_from_nm(text):
    symbols = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and re.fullmatch(r'[0-9a-fA-F]+', fields[0]):
            symbols[fields[2]] = int(fields[0], 16)
    return symbols


def validate_layout(symbols):
    for name in ('main', 'iterate', 'static_memblk', 'seed1_volatile', '__bss_start', '__bss_end'):
        if not DDR_BASE <= symbols[name] < DDR_BASE + 0x1c000:
            raise ValueError(f'{name} must reside in the DDR CPU region')
    if symbols['__stack_top'] != DDR_BASE + 0x20000:
        raise ValueError('CPU stack must reside below reserved DMA DDR buffers')
    if symbols.get('p2_platform') != 0x01100110:
        raise ValueError('platform config must be reserved at 0x01100110')
    if symbols['p2_roi_state'] != 0x01100100:
        raise ValueError('ROI symbol does not match the testbench contract')
    for name in ('_start', 'start_time', 'stop_time', 'p2_timer_entry'):
        if not 0x01000000 <= symbols[name] < 0x01010000:
            raise ValueError(f'{name} must reside in ITCM')
    for name in ('tohost', 'sim_console', '__control_stack_top', '__interrupt_stack_top'):
        if not 0x01100000 <= symbols[name] <= 0x01110000:
            raise ValueError(f'{name} must reside in DTCM')
    return {name: hex(symbols[name]) for name in (
        '_start', 'main', 'iterate', 'static_memblk', 'seed1_volatile', '__bss_start',
        '__bss_end', '__stack_limit', '__stack_top', 'tohost', 'sim_console',
        'p2_roi_state', 'p2_platform', '__control_stack_top', '__interrupt_stack_top')}


def sections_from_objdump(text):
    sections = {}
    lines = text.splitlines()
    for index, line in enumerate(lines[:-1]):
        found = re.match(r'\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)', line)
        if found and 'ALLOC' in lines[index + 1]:
            sections[found[1]] = {'bytes': int(found[2], 16), 'address': int(found[3], 16),
                                  'load_address': int(found[4], 16), 'flags': lines[index + 1].strip()}
    return sections


def validate_sections(sections):
    ranges = {'.text.init': (0x01000000, 0x01010000), '.host': (0x01100000, 0x01100100),
              '.p2_roi': (0x01100100, 0x01100104), '.p2_platform': (0x01100110, 0x01100120),
              '.p2_control': (0x01100120, 0x0110e000),
              **{name: (DDR_BASE, DDR_BASE + 0x1c000) for name in ('.text', '.rodata', '.data', '.bss')}}
    if set(sections) != set(ranges):
        raise ValueError('unexpected or missing allocated ELF section')
    for name, (low, high) in ranges.items():
        section = sections[name]
        if not low <= section['address'] < section['address'] + section['bytes'] <= high:
            raise ValueError(f'{name} allocation lies outside its physical region')
        if section['load_address'] != section['address']:
            raise ValueError(f'{name} requires an unimplemented runtime relocation')
    return sections


def parse_metrics(text, half_periods, require_w=False):
    """Keep each observation boundary separate; its latency unit is its own clock."""
    if not re.search(r'^P2_METRICS scope=software_marker enabled=1 latency_units=domain_cycles$', text, re.M):
        raise ValueError('missing software ROI metrics scope')
    domains = dict(zip(('core', 'sys', 'ddr', 'periph'), (2 * p for p in half_periods)))
    required = {
        'latency': {'cpu.if', 'cpu.d0', 'cpu.d1', 'cpu.d0.queue', 'cpu.d1.queue',
                    'dma.engine', 'dma.software',
                    *(f'tcm{bank}.port{port}' for bank in range(2) for port in range(4)),
                    *(f'{cache}.{part}' for cache in ('icache', 'dcache0', 'dcache1')
                      for part in ('refill', 'install_tail')),
                    *(f'{master}.{part}' for master in ('sys.master0', 'sys.master1', 'sys.master2', 'sys.master3', 'ddr.target')
                      for part in ('read', 'write'))},
        'axi': {'sys.master0', 'sys.master1', 'sys.master2', 'sys.master3', 'ddr.target'},
        'cache': {'icache', 'dcache0', 'dcache1'}, 'cache_bank': {'dcache0', 'dcache1'},
        'tcm': {'tcm0', 'tcm1'},
    }
    result = {}
    # 旧模型没有 W 通道分解，保留 None 表示未测，不能补零伪装成无等待。
    w_lines = re.findall(r'^P2_AXI_W .*', text, re.M)
    if require_w or w_lines:
        required['axi_w'] = required['axi']
    for kind, names in required.items():
        records = {}
        for line in re.findall(r'^P2_' + kind.upper() + r' .*', text, re.M):
            fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
            name = fields.pop('name', '')
            domain = fields.pop('domain', 'core')
            if not name or name in records or domain not in domains:
                raise ValueError(f'duplicate or malformed {kind} observation')
            if any(not value.isdecimal() for value in fields.values()):
                raise ValueError(f'non-numeric {kind} observation')
            record = {key: int(value) for key, value in fields.items()}
            if kind == 'latency':
                expected = ('started', 'completed', 'pending', 'first_count', 'first_sum', 'last_sum',
                            'roi_cycles', 'roi_started', 'roi_completed', 'roi_first_count', 'roi_first_sum',
                            'roi_last_sum', 'roi_request_stall', 'roi_response_stall', 'roi_carry_in',
                            'roi_carry_out', 'roi_completed_from_before', 'roi_started_completed',
                            'roi_started_completed_after', 'cohort_last_sum')
                if any(key not in record for key in expected):
                    raise ValueError('incomplete latency observation')
                if record['started'] != record['completed'] + record['pending']:
                    raise ValueError('latency transaction conservation failed')
                if record['roi_started'] + record['roi_carry_in'] != record['roi_completed'] + record['roi_carry_out']:
                    raise ValueError('latency ROI transaction conservation failed')
                record['roi_mean_first_ns'] = (record['roi_first_sum'] * domains[domain] / record['roi_first_count']
                                               if record['roi_first_count'] else None)
                record['roi_mean_last_ns'] = (record['roi_last_sum'] * domains[domain] / record['roi_completed']
                                              if record['roi_completed'] else None)
            elif kind == 'axi_w':
                expected = ('accepted', 'completed', 'pending', 'wbursts', 'peak_pending',
                            'active_cycles', 'source_gap_cycles', 'downstream_stall_cycles', 'transfer_cycles',
                            'first_sum', 'first_max', 'gap_count', 'gap_sum', 'gap_max', 'before_aw',
                            'roi_accepted', 'roi_completed', 'roi_active_cycles', 'roi_source_gap_cycles',
                            'roi_downstream_stall_cycles', 'roi_transfer_cycles', 'roi_first_sum', 'roi_first_max',
                            'roi_gap_count', 'roi_gap_sum', 'roi_gap_max', 'roi_before_aw')
                if any(key not in record for key in expected):
                    raise ValueError('incomplete AXI W observation')
                if (record['accepted'] != record['completed'] + record['pending'] or
                        record['wbursts'] < record['completed'] or record['before_aw'] > record['completed']):
                    raise ValueError('AXI W transaction conservation failed')
                for prefix in ('', 'roi_'):
                    if record[prefix + 'active_cycles'] != sum(record[prefix + item] for item in
                            ('source_gap_cycles', 'downstream_stall_cycles', 'transfer_cycles')):
                        raise ValueError('AXI W active-cycle conservation failed')
                if any(record[key] > record[key[4:]] for key in expected if key.startswith('roi_')):
                    raise ValueError('AXI W ROI count exceeds whole-run count')
                record['roi_mean_first_ns'] = (record['roi_first_sum'] * domains[domain] / record['roi_completed']
                                               if record['roi_completed'] else None)
                record['roi_mean_interbeat_gap_ns'] = (record['roi_gap_sum'] * domains[domain] / record['roi_gap_count']
                                                       if record['roi_gap_count'] else None)
            else:
                expected = {'axi': ('rbeats', 'wbeats', 'wbytes', 'roi_rbeats', 'roi_wbeats', 'roi_wbytes'),
                            'cache': ('hits', 'misses', 'installs', 'install_writes', 'roi_hits', 'roi_misses', 'roi_installs', 'roi_install_writes'),
                            'cache_bank': ('request_stall_cycles', 'response_with_request', 'same_cycle_turnover',
                                           'roi_request_stall_cycles', 'roi_response_with_request', 'roi_same_cycle_turnover'),
                            'tcm': ('conflict_cycles', 'response_blocked_cycles', 'bank_fires',
                                    'roi_conflict_cycles', 'roi_response_blocked_cycles', 'roi_bank_fires')}[kind]
                if any(key not in record for key in expected):
                    raise ValueError(f'incomplete {kind} observation')
            record.update({'domain': domain, 'period_ns': domains[domain]})
            records[name] = record
        if not names.issubset(records):
            raise ValueError(f'missing required {kind} observations: {sorted(names - records.keys())}')
        result[kind] = records
    result.setdefault('axi_w', None)
    result['axi_w_scope'] = ('AW-to-WLAST active cycles; first latency at joined completion; '
                             'interbeat gaps at the later accepted W beat') if w_lines else 'not_measured'
    result['raw'] = re.findall(r'^P2_(?:LATENCY|AXI|AXI_W|CACHE|CACHE_BANK|TCM) .*', text, re.M)
    return result


def parse_result(text, mode, iterations, layer, expected_core=None, expected_soc=None, expected_periods_ps=None):
    if re.search(r'%Fatal|%Error|Assertion failed|TIMEOUT', text):
        raise ValueError('simulator failure')
    if not re.search(r'^PASS p2-coremark-', text, re.M):
        raise ValueError('missing architectural tohost PASS')
    crc = {}
    for field, expected in EXPECTED[mode].items():
        found = re.search(rf'^(?:\[0\])?{field}\s*:\s*0x([0-9a-fA-F]+)', text, re.M)
        if found is None or int(found[1], 16) != expected:
            raise ValueError(f'{field} validation failed')
        crc[field] = hex(expected)
    final = re.search(r'^\[0\]crcfinal\s*:\s*0x([0-9a-fA-F]+)', text, re.M)
    if final is None:
        raise ValueError('missing final CRC')
    crc['crcfinal'] = hex(int(final[1], 16))
    count = re.search(r'^Iterations\s*:\s*(\d+)', text, re.M)
    ticks = re.search(r'^P2_TICKS high=(\d+) low=(\d+)', text, re.M)
    if count is None or int(count[1]) != iterations or ticks is None:
        raise ValueError('missing or incorrect iteration/timing record')
    cycles = (int(ticks[1]) << 32) | int(ticks[2])
    if cycles <= 0:
        raise ValueError('empty timing interval')
    duration_error = 'ERROR! Must execute for at least 10 secs for a valid result!'
    for line in text.splitlines():
        if 'ERROR!' in line and line != duration_error:
            raise ValueError(f'CoreMark error: {line}')
    virtual_short = cycles < 10000000
    if virtual_short and duration_error not in text:
        raise ValueError('short run did not report its duration limitation')
    if not virtual_short and 'Correct operation validated' not in text:
        raise ValueError('missing full vendor validation')
    background = re.search(r'^P2_BACKGROUND irq=(\d+) dma_completed=(\d+) dma_bytes=(\d+) errors=(\d+)', text, re.M)
    if background is None:
        raise ValueError('missing background result')
    irq, completed, transferred, errors = map(int, background.groups())
    if errors or (layer == 'background' and (irq == 0 or completed == 0 or transferred != completed * 16384)):
        raise ValueError('DMA/timer background did not complete correctly')
    roi_lines = re.findall(r'^P2_ROI .*', text, re.M)
    if len(roi_lines) != 1:
        raise ValueError('missing unique testbench ROI record')
    roi = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', roi_lines[0])}
    if roi.get('core_cycles', 0) <= 0 or roi.get('cpu_ddr_ar', 0) <= 0:
        raise ValueError('ROI did not exercise CPU DDR reads')
    if layer == 'background' and any(roi.get(key, 0) <= 0 for key in ('dma_ar', 'dma_aw', 'dma_rbeats', 'dma_wbeats')):
        raise ValueError('ROI did not overlap actual DMA traffic')
    config = re.search(r'^P2_CONFIG warm=(\d+) background=(\d+) cold_prepared=(\d+) iterations=(\d+)', text, re.M)
    warm, busy = LAYERS[layer]
    if config is None or tuple(map(int, config.groups())) != (warm, busy, 1-warm, iterations):
        raise ValueError('software cache/background configuration does not match requested layer')
    clock = re.search(r'^PASS p2-coremark-.* clocks=C([0-4]) core_half_ns=([0-9.]+) sys_half_ns=([0-9.]+) ddr_half_ns=([0-9.]+) periph_half_ns=([0-9.]+)', text, re.M)
    if clock is None:
        raise ValueError('missing complete simulator clock configuration record')
    clock_config = int(clock[1])
    half_periods = [float(value) for value in clock.groups()[1:]]
    expected_halves = CLOCKS[clock_config] if expected_periods_ps is None else [p / 2000 for p in expected_periods_ps]
    if half_periods != expected_halves:
        raise ValueError('simulator periods differ from the named clock configuration')
    irq_roi = re.search(r'^P2_IRQ start=(\d+) stop=(\d+) roi=(\d+)', text, re.M)
    if irq_roi is None:
        raise ValueError('missing IRQ timing snapshots')
    irq_begin, irq_end, irq_interval = map(int, irq_roi.groups())
    if irq_end - irq_begin != irq_interval or (layer == 'background' and irq_interval <= 0):
        raise ValueError('IRQ snapshots do not prove interrupt activity during ROI')
    if layer != 'background' and (irq != 0 or irq_interval != 0 or completed != 0 or transferred != 0 or
            any(roi.get(key, 0) != 0 for key in ('dma_ar', 'dma_aw', 'dma_rbeats', 'dma_wbeats'))):
        raise ValueError('idle M2 contains IRQ or DMA background activity')
    platform = re.search(r'^P2_PLATFORM magic=([0-9a-fA-F]+) version=(\d+) periph_period_ps=(\d+) clock=(\d+)', text, re.M)
    software_platform = re.search(r'^P2_PLATFORM_SW magic=(\d+) version=(\d+) periph_period_ps=(\d+) clock=(\d+)', text, re.M)
    if platform is None or software_platform is None:
        raise ValueError('missing TB/software platform contract')
    platform_values = (int(platform[1], 16), *map(int, platform.groups()[1:]))
    expected_platform = (0x50324346, 1, round(2 * half_periods[3] * 1000), clock_config)
    if platform_values != expected_platform or tuple(map(int, software_platform.groups())) != expected_platform:
        raise ValueError('CPU platform clock input differs from actual TB clock')
    measured_platform = re.search(r'^P2_PLATFORM_CLOCK periph_period_ps=(\d+) measured_period_ps=(\d+) checked_periods=(\d+)', text, re.M)
    if (measured_platform is None or int(measured_platform[1]) != expected_platform[2] or
            int(measured_platform[2]) != expected_platform[2] or int(measured_platform[3]) <= 0):
        raise ValueError('actual peripheral clock edges do not match the platform contract')
    boot_line = re.search(r'^P2_BOOT .*', text, re.M)
    if boot_line is None:
        raise ValueError('missing actual Boot ROM execution record')
    boot = dict(re.findall(r'(\w+)=([0-9a-fA-F]+)', boot_line[0]))
    if (int(boot.get('first_pc', 'ffffffff'), 16) != 0 or int(boot.get('rom_retired', '0')) < 2 or
            any(boot.get(key) != '1' for key in ('itcm_seen', 'ddr_seen', 'order_ok', 'rom_words_ok'))):
        raise ValueError('Boot ROM to ITCM to DDR execution was not observed')
    if any(int(boot.get(key, '0')) <= 0 for key in ('roi_ddr_retired', 'roi_ddr_if', 'roi_ddr_data')):
        raise ValueError('DDR instruction/data execution was not observed inside ROI')
    stack_line = re.search(r'^P2_STACK .*', text, re.M)
    if stack_line is None:
        raise ValueError('missing actual stack placement record')
    stack = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', stack_line[0])}
    if (stack.get('roi_ddr_sp_writes', 0) <= 0 or stack.get('roi_bad_sp_writes', 1) != 0 or
            stack.get('roi_ddr_stack_accesses', 0) <= 0 or stack.get('roi_bad_stack_accesses', 1) != 0):
        raise ValueError('timed stack pointer escaped DDR/TCM reserved ranges')
    cache_line = re.search(r'^P2_CACHE_CONFIG .*', text, re.M)
    if cache_line is None:
        raise ValueError('missing instantiated cache configuration')
    cache = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', cache_line[0])}
    expected_cache = {'icache_bytes': 4096, 'icache_line_bytes': 32, 'icache_ways': 2,
                      'dcache_bytes': 4096, 'dcache_line_bytes': 32, 'dcache_ways': 2, 'dcache_banks': 2}
    if any(cache.get(key) != value for key, value in expected_cache.items()):
        raise ValueError('actual cache size differs from the frozen benchmark contract')
    soc = parse_soc_config(text, expected_soc, expected_periods_ps)
    if soc is not None and (soc['clock_profile'] != clock_config or
                           cache.get('icache_fill_bytes') != soc['icache_fill_bytes']):
        raise ValueError('executed clocks or I-cache install width differ from compiled hardware')
    timer_line = re.search(r'^P2_TIMER .*', text, re.M)
    total_line = re.search(r'^P2_TIMER_TOTAL late_hi=(\d+) late_lo=(\d+)', text, re.M)
    if timer_line is None or total_line is None:
        raise ValueError('missing actual timer schedule record')
    timer = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', timer_line[0])}
    period_ps = expected_platform[2]
    ticks_expected = 2048 if timer.get('mode') == 1 else (timer.get('requested_ps', 0) + period_ps - 1) // period_ps
    if (timer.get('mode') not in (0, 1) or timer.get('interval_ticks') != ticks_expected or
            timer.get('actual_ps') != ticks_expected * period_ps or
            timer.get('quantum_ps') != (0 if timer['mode'] == 1 else ticks_expected * period_ps - timer['requested_ps'])):
        raise ValueError('timer tick conversion or quantization record is incorrect')
    timer['late_total_ticks'] = (int(total_line[1]) << 32) | int(total_line[2])
    if (timer.get('late_events', 0) > irq_interval or
            (layer != 'background' and any(timer.get(key, 0) for key in ('late_events', 'late_max_ticks', 'late_total_ticks', 'skipped')))):
        raise ValueError('timer schedule activity is inconsistent with ROI interrupts')
    simulated_seconds = cycles * (2 * half_periods[0]) / 1e9
    roi_ns = roi.get('sys_cycles', 0) * 2 * half_periods[1]
    if roi_ns <= 0:
        raise ValueError('missing positive system-domain ROI duration')
    return {'metrics': parse_metrics(text, half_periods, require_w=soc is not None),
            'soc_config': soc, 'core_config': parse_core_config(text, expected_core),
            'core_statistics': parse_core_statistics(text, expected_core),
            'platform': {'magic': expected_platform[0], 'version': 1, 'periph_period_ps': period_ps,
                         'measured_period_ps': int(measured_platform[2]), 'checked_periods': int(measured_platform[3])},
            'boot': boot, 'stack': stack, 'cache': cache, 'timer': timer, 'cycles': cycles, 'iterations': iterations, 'crc': crc,
            'diagnostic_coremark_per_cpu_mhz': iterations * 1000000 / cycles,
            'classification': 'short_crc_adaptation' if simulated_seconds < 10 else 'simulation_cycle_measurement',
            'normalized_timer_hz': 1000000, 'vendor_virtual_duration_met': not virtual_short,
            'simulated_duration_seconds': simulated_seconds, 'official_duration_met': simulated_seconds >= 10,
            'official_coremark_result': False,
            'physical_frequency_measured': False,
            'background': {'irq_total': irq, 'irq_roi': irq_interval, 'dma_completed_total': completed,
                           'dma_bytes_total_including_drain': transferred, 'errors': errors,
                           'roi_dma_read_bytes': roi['dma_rbeats'] * 32,
                           'roi_dma_write_bytes': roi['dma_wbeats'] * 32,
                           'roi_dma_write_MB_per_s': roi['dma_wbeats'] * 32 * 1000 / roi_ns},
            'testbench_roi': roi_lines, 'roi_counters': roi, 'clock_config': clock_config,
            'half_periods_ns': half_periods, 'clock_frequencies_mhz': [500 / p for p in half_periods]}


SOFTWARE_SOURCES = [Path(p) for p in (
    'benchmark/bsp/crt0.S', 'benchmark/bsp/runtime.c', 'benchmark/bsp/softarith.c',
    'benchmark/p2/timing.S', 'benchmark/p2/core_portme.c', 'benchmark/coremark/port/ee_printf.c',
    *('benchmark/coremark/vendor/coremark/' + name for name in
      ('core_list_join.c', 'core_main.c', 'core_matrix.c', 'core_state.c', 'core_util.c')))]
SOFTWARE_INPUTS = SOFTWARE_SOURCES + [Path(p) for p in (
    'benchmark/p2/core_portme.h', 'benchmark/p2/npu_background.h', 'benchmark/coremark/port/core_portme.h',
    'benchmark/p2/link_soc_coremark_ddr.ld', 'benchmark/bsp/benchmark_runtime.h',
    'benchmark/coremark/vendor/coremark/coremark.h', 'benchmark/coremark/vendor/coremark/LICENSE.md',
    'scripts/verilator/verilog_hex_to_mem.py', 'scripts/verilator/run_p2_coremark.py')]


def write_json(path, value):
    with Path(path).open('x') as output:
        json.dump(value, output, indent=2)
        output.write('\n')


def copy_sources(paths, destination):
    hashes = {}
    for path in paths:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as output:
            output.write(path.read_bytes())
        hashes[str(path)] = sha(target)
    return hashes


def verify_hashes(base, hashes):
    for name, expected in hashes.items():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('frozen manifest contains a path outside its bundle')
        if not (base / path).is_file() or sha(base / path) != expected:
            raise ValueError('frozen artifact hash mismatch: ' + name)


def build_image(args, layer, mode, tools, frozen):
    output = frozen / f'{"npu_" if getattr(args,"npu",False) else ""}{layer}-{mode}'
    output.mkdir()
    source_root = frozen / 'source'
    warm, background = LAYERS[layer]
    vendor = source_root / 'benchmark/coremark/vendor/coremark'
    elf = output / 'program.elf'
    command = [tools + 'gcc', '-march=rv32im_zicsr', '-mabi=ilp32', '-mcmodel=medany',
        '-mno-relax', '-std=gnu99', '-'+optimization(), '-DHGB_OPT_LEVEL="-'+optimization()+'"', '-g', '-ffreestanding', '-fno-builtin', '-fno-common',
        '-fno-pie', '-fno-tree-loop-distribute-patterns', '-mstrict-align', '-nostdlib', '-nostartfiles',
        '-static', '-no-pie', '-I' + str(source_root / 'benchmark/p2'),
        '-I' + str(source_root / 'benchmark/bsp'), '-I' + str(vendor),
        '-DITERATIONS=' + str(args.iterations), '-DTOTAL_DATA_SIZE=2000', '-D' + mode.upper() + '_RUN=1',
        '-DP2_WARM=' + str(warm), '-DP2_BACKGROUND=' + str(background),
        '-DP2_TIMER_MODE=' + str(int(args.timer_mode == 'legacy')), '-DP2_INTERVAL_PS=' + str(args.irq_period_us * 1000000),
        '-Wl,--build-id=none,--no-relax', '-Wl,-T,' + str(source_root / 'benchmark/p2/link_soc_coremark_ddr.ld'),
        '-Wl,-Map,' + str(output / 'program.map'), *[str(source_root / p) for p in SOFTWARE_SOURCES], '-o', str(elf)]
    if getattr(args, 'npu', False):
        command.insert(1, '-DP2_NPU=1')
    run(command, output / 'build.log')
    if subprocess.check_output([tools + 'nm', '-u', str(elf)], text=True).strip():
        raise ValueError('unresolved ELF symbols')
    nm = subprocess.check_output([tools + 'nm', '-n', str(elf)], text=True)
    (output / 'program.nm').write_text(nm)
    symbols = symbols_from_nm(nm)
    layout = validate_layout(symbols)
    sections_text = subprocess.check_output([tools + 'objdump', '-h', str(elf)], text=True)
    (output / 'sections.txt').write_text(sections_text)
    sections = validate_sections(sections_from_objdump(sections_text))
    for name, base, length, selected in (
        ('imem', 0x01000000, 65536, ['.text.init']),
        ('dmem', 0x01100000, 65536, ['.host', '.p2_roi', '.p2_platform', '.p2_control']),
        ('ddr', DDR_BASE, DDR_BYTES, ['.text', '.rodata', '.data'])):
        vhex = output / (name + '.vhex')
        subprocess.run([tools + 'objcopy', '-O', 'verilog', '--verilog-data-width', '1',
            *['--only-section=' + section for section in selected], str(elf), str(vhex)], check=True)
        subprocess.run([sys.executable, str(source_root / 'scripts/verilator/verilog_hex_to_mem.py'), str(vhex),
            str(output / (name + '.hex')), '--word-bytes', '4', '--depth', str(length // 4), '--base', hex(base)], check=True)
    run([tools + 'objdump', '-d', str(elf)], output / 'program.dump')
    image = {'layer_key': layer, 'layer': 'M2-B' if background else 'M2',
        'cache_state': 'warm' if warm else 'cold', 'mode': mode, 'iterations': args.iterations,
        'warm_protocol': 'one untimed iterate on DTCM control stack; exact input/result restoration; timed algorithm stack in DDR' if warm else None,
        'cold_protocol': 'D-cache FLUSH and FENCE.I on DTCM control stack before timing' if not warm else None,
        'layout': layout, 'sections': sections, 'symbols': symbols,
        'directory': str(output.relative_to(frozen)), 'compile_command': shlex.join(command),
        'image_sha256': {str(p.relative_to(frozen)): sha(p) for p in
                         (elf, output / 'imem.hex', output / 'dmem.hex', output / 'ddr.hex')}}
    write_json(output / 'image.json', image)
    return image


def freeze_images(args):
    frozen = args.freeze
    frozen.mkdir(parents=True, exist_ok=False)
    source_hashes = copy_sources(SOFTWARE_INPUTS, frozen / 'source')
    tools = str(Path(os.environ['RISCV_TOOL_ROOT']) / 'riscv64-unknown-elf-')
    images = [build_image(args, layer, mode, tools, frozen) for layer in args.layers for mode in args.modes]
    for mode in args.modes:
        for suffix in ('imem.hex', 'ddr.hex'):
            signatures = {h for image in images if image['mode'] == mode
                          for path, h in image['image_sha256'].items() if path.endswith('/' + suffix)}
            if len(signatures) != 1:
                raise ValueError('scenario configuration changed the common code or DDR input image')
    if any(sha(path) != digest for path, digest in source_hashes.items()):
        raise ValueError('software changed while freezing images')
    manifest = {'schema': 2, 'iterations': args.iterations, 'timer_mode': args.timer_mode,
        'irq_period_us': args.irq_period_us, 'xlen': 32, 'DDR_BYTES': DDR_BYTES,
        'boot': {'reset_pc': 0, 'rom_words': ['010002b7', '00028067'], 'itcm_entry': '01000000',
                 'rom_role': 'hardware trampoline; DDR and TCM images preloaded by testbench'},
        'cache_mapping': {'cacheable_region': 'DDR only; TCM bypasses caches',
            'icache': {'bytes': 4096, 'line_bytes': 32, 'ways': 2, 'sets': 64, 'index_bits': [10, 5], 'tag_bits': [31, 11]},
            'dcache': {'total_bytes': 4096, 'banks': 2, 'bank_bit': 10, 'bank_bytes': 2048, 'line_bytes': 32,
                       'ways_per_bank': 2, 'sets_per_bank': 32, 'index_bits': [9, 5], 'tag_bits': [31, 10],
                       'write_policy': 'write-back, write-allocate'}},
        'runtime_config': {'address': '01100110', 'words': ['magic 50324346', 'version 1', 'actual periph_period_ps', 'clock config'],
                           'activation': '+P2_PLATFORM', 'static_input_images_mutated': False},
        'dma_source': '80020000', 'dma_destination': '80030000', 'dma_transfer_bytes': 16384,
        'source_sha256': source_hashes, 'images': images,
        'compiler': subprocess.check_output([tools + 'gcc', '--version'], text=True).splitlines()[0],
        'branch': subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
        'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()}
    write_json(frozen / 'freeze.json', manifest)
    with (frozen / 'freeze.sha256').open('x') as output:
        output.write(sha(frozen / 'freeze.json') + '\n')
    print(f'PASS P2_FREEZE images={len(images)} iterations={args.iterations} path={frozen}', flush=True)


def load_frozen(path):
    if (path / 'freeze.sha256').read_text().strip() != sha(path / 'freeze.json'):
        raise ValueError('frozen manifest metadata hash mismatch')
    manifest = json.loads((path / 'freeze.json').read_text())
    if manifest.get('schema') != 2:
        raise ValueError('unsupported frozen image schema')
    verify_hashes(path / 'source', manifest['source_sha256'])
    for image in manifest['images']:
        verify_hashes(path, image['image_sha256'])
        validate_layout(image['symbols'])
        validate_sections(image['sections'])
    return manifest


def rtl_sources():
    return {str(p): sha(p) for pattern in ('vsrc/**/*.sv', 'vsrc/**/*.svh', 'vsrc/**/*.vh', 'third_party/yolo_npu128/**/*.sv',
                                          'tb/soc/*.sv', 'tb/soc/*.svh', 'tb/common/*.sv',
                                          'tb/common/*.svh', 'tb/common/*.vh', 'tb/benchmark/*.sv', 'scripts/*.f',
                                          'scripts/verilator/p2_core_config.sh',
                                          'scripts/verilator/p1_core_config.sh',
                                          'scripts/verilator/core_build_config.sh')
            for p in sorted(Path('.').glob(pattern))}


def load_sim(binary, expected_profile=None):
    receipt = json.loads((binary.parent / 'p2-build.json').read_text())
    if receipt['binary_sha256'] != sha(binary):
        raise ValueError('simulator differs from recorded build')
    verify_hashes(binary.parent / 'source', receipt['source_tree_sha256'])
    if 'core_config' in receipt:
        validate_core_config(receipt['core_config'])
    if receipt.get('schema', 1) >= 3 or 'soc_config' in receipt:
        validate_soc_config(receipt.get('soc_config'))
    check_core_profile(receipt.get('core_config'), expected_profile)
    return receipt


def build_sim(args):
    binary = args.sim
    core = core_build_configuration()
    check_core_profile(core['core_config'], args.expect_core_profile)
    profile = getattr(args, 'clock_profile', None)
    if profile is None:
        clocks = getattr(args, 'clocks', [1])
        if len(clocks) != 1:
            raise ValueError('new simulator requires one static --clock-profile')
        profile = clocks[0]
    soc = soc_build_configuration(profile, getattr(args, 'icache_fill_bytes', None) or 4)
    if binary.exists():
        receipt = load_sim(binary, args.expect_core_profile)
        if receipt['source_tree_sha256'] != rtl_sources():
            raise ValueError('existing simulator uses different sources; select a new --sim directory')
        if any(receipt.get(key) != value for key, value in core.items()):
            raise ValueError('existing simulator uses different Core parameters; select a new --sim directory')
        if receipt.get('soc_config') != soc:
            raise ValueError('existing simulator uses different SoC parameters; select a new --sim directory')
        return receipt
    binary.parent.mkdir(parents=True, exist_ok=False)
    sources = copy_sources([Path(p) for p in rtl_sources()], binary.parent / 'source')
    command = ['verilator', '--binary', '--assert', '--timing', '-Wall', '-Wno-fatal', '-j', '2',
        '-CFLAGS', '-O1', '-DCORE_XLEN=32', *core['core_flags'], '-GDDR_BYTES=262144', '-GDDR_MODEL_BYTES=262144',
        '-GCLOCK_PROFILE=' + str(soc['clock_profile']), '-DSOC_ICACHE_FILL_BYTES=' + str(soc['icache_fill_bytes']),
        '-f', 'scripts/system_files.f', 'tb/common/store_result_monitor.sv', 'tb/soc/axi_system_memory_model.sv',
        'tb/common/scoreboard_metrics.sv', 'tb/benchmark/bind_scoreboard_metrics.sv',
        'tb/common/scoreboard_scheduler_metrics.sv', 'tb/benchmark/bind_scheduler_metrics.sv',
        'tb/soc/spi_flash_model.sv', 'tb/soc/tb_soc_system.sv', '--top-module', 'tb_soc_system', '-Mdir', str(binary.parent)]
    run(command, args.log_root / 'sim-build.log')
    if sources != rtl_sources():
        raise ValueError('RTL changed during simulator construction; select a new build directory')
    if re.search(r'%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))', (args.log_root / 'sim-build.log').read_text()):
        raise ValueError('critical simulator build diagnostic')
    receipt = {'schema': 3, **core, 'soc_config': soc,
               'core_environment': {key: os.environ[key] for key in CORE_ENVIRONMENT if key in os.environ},
               'build_command': shlex.join(command), 'source_tree_sha256': sources, 'binary_sha256': sha(binary),
               'verilator': subprocess.check_output(['verilator', '--version'], text=True).strip(),
               'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
               'branch': subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()}
    write_json(binary.parent / 'p2-build.json', receipt)
    return receipt


def validate_run_selection(result, clock, manifest):
    if (result['clock_config'] != clock or result['timer']['mode'] != int(manifest['timer_mode'] == 'legacy') or
            result['timer']['requested_ps'] != manifest['irq_period_us'] * 1000000):
        raise ValueError('executed platform or schedule differs from frozen selection')


def replay_images(args):
    manifest = load_frozen(args.replay)
    if args.iterations is not None and args.iterations != manifest['iterations']:
        raise ValueError('replay cannot change frozen iterations')
    if args.timer_mode is not None and args.timer_mode != manifest['timer_mode']:
        raise ValueError('replay cannot change frozen timer mode')
    if args.irq_period_us is not None and args.irq_period_us != manifest['irq_period_us']:
        raise ValueError('replay cannot change frozen timer period')
    images = [image for image in manifest['images'] if image['layer_key'] in args.layers and image['mode'] in args.modes]
    if len(images) != len(args.layers) * len(args.modes):
        raise ValueError('requested scenario is absent from frozen bundle')
    args.log_root.mkdir(parents=True, exist_ok=True)
    if (args.log_root / 'results-index.json').exists():
        raise ValueError('result directory is already complete; select a fresh --log-root')
    names = [f"p2-coremark-{image['layer_key']}-{image['mode']}-i{manifest['iterations']}-c{clock}"
             for image in images for clock in args.clocks]
    if any((args.log_root / (name + suffix)).exists() for name in names for suffix in ('.log', '.json')):
        raise ValueError('run would overwrite an existing log or result; select a fresh --log-root')
    receipt = build_sim(args) if args.build_sim else load_sim(args.sim, args.expect_core_profile)
    validate_sim_selection(receipt, args.clocks, args.clock_profile, args.icache_fill_bytes)
    runner_sources = copy_sources([Path('scripts/verilator/run_p2_coremark.py'), Path('tb/scripts/test_p2_coremark.py')],
                                  args.log_root / 'runner-source')
    invocation_branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
    write_json(args.log_root / 'run-inputs.json', {'command': shlex.join(sys.argv), 'freeze_path': str(args.replay),
        'freeze_manifest_sha256': sha(args.replay / 'freeze.json'), 'freeze_manifest': manifest,
        'binary_sha256': receipt['binary_sha256'], 'runner_sha256': sha(Path(__file__)),
        'core_config': receipt.get('core_config'), 'expected_core_profile': args.expect_core_profile,
        'soc_config': receipt.get('soc_config'),
        'runner_source_sha256': runner_sources, 'runner_invocation_branch': invocation_branch})
    results = []
    for image in images:
        image_dir = args.replay / image['directory']
        for clock in args.clocks:
            name = f"p2-coremark-{image['layer_key']}-{image['mode']}-i{manifest['iterations']}-c{clock}"
            log = args.log_root / (name + '.log')
            command = [str(args.sim), '+IMEM=' + str(image_dir / 'imem.hex'), '+DMEM=' + str(image_dir / 'dmem.hex'),
                '+DDR=' + str(image_dir / 'ddr.hex'), '+TOHOST=' + format(image['symbols']['tohost'], 'x'),
                '+CONSOLE=' + format(image['symbols']['sim_console'], 'x'), '+TEST=' + name,
                '+CLOCK_CONFIG=' + str(clock), '+MAX_CYCLES=' + str(args.max_cycles), '+P2_ROI=01100100', '+P2_PLATFORM', '+P2_METRICS']
            run(command, log)
            result = parse_result(log.read_text(), image['mode'], manifest['iterations'], image['layer_key'],
                                  receipt.get('core_config'), receipt.get('soc_config'))
            validate_run_selection(result, clock, manifest)
            result.update({'name': name, 'run_command': shlex.join(command), 'log': str(log), 'log_sha256': sha(log),
                'binary': str(args.sim), 'binary_sha256': receipt['binary_sha256'], 'verilator': receipt['verilator'],
                'sim_build_command': receipt['build_command'], 'source_tree_sha256': receipt['source_tree_sha256'],
                'core_build_tag': receipt.get('core_build_tag'), 'expected_core_profile': args.expect_core_profile,
                'freeze_path': str(args.replay), 'freeze_manifest_sha256': sha(args.replay / 'freeze.json'),
                'frozen_software_commit': manifest['base_commit'], 'frozen_source_sha256': manifest['source_sha256'],
                'frozen_software_branch': manifest['branch'],
                'image': image, 'runner_sha256': sha(Path(__file__)),
                'runner_source_sha256': runner_sources,
                'base_commit': receipt['base_commit'],
                'branch': receipt.get('branch'), 'runner_invocation_branch': invocation_branch})
            path = args.log_root / (name + '.json')
            write_json(path, result)
            results.append(str(path))
            print(f"PASS P2_COREMARK {image['layer_key']} {image['mode']} C{clock} iterations={manifest['iterations']} cycles={result['cycles']} classification={result['classification']}", flush=True)
    verify_hashes(Path('.'), runner_sources)
    write_json(args.log_root / 'results-index.json', results)


def validate_sim_selection(receipt, clocks, clock_profile=None, icache_fill_bytes=None):
    soc = receipt.get('soc_config')
    if soc is None:
        if clock_profile is not None or icache_fill_bytes is not None:
            raise ValueError('old simulator receipt cannot verify explicit SoC hardware parameters')
    elif (any(clock != soc['clock_profile'] for clock in clocks) or
          (clock_profile is not None and clock_profile != soc['clock_profile']) or
          (icache_fill_bytes is not None and icache_fill_bytes != soc['icache_fill_bytes'])):
        raise ValueError('selected clocks or I-cache install width differ from simulator receipt')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--freeze', type=Path, help='Create a new immutable software bundle; never overwrite')
    action.add_argument('--replay', type=Path, help='Verify and run a frozen bundle without recompiling software')
    parser.add_argument('--layers', nargs='+', choices=LAYERS, default=list(LAYERS))
    parser.add_argument('--modes', nargs='+', choices=EXPECTED, default=list(EXPECTED))
    parser.add_argument('--iterations', type=int)
    parser.add_argument('--timer-mode', choices=('realtime', 'legacy'))
    parser.add_argument('--irq-period-us', type=int)
    parser.add_argument('--clocks', nargs='+', type=int, choices=CLOCKS, default=[1])
    parser.add_argument('--sim', type=Path, default=Path('build/p2/measure-optimize-step1/Vtb_soc_system'))
    parser.add_argument('--build-sim', action='store_true')
    parser.add_argument('--clock-profile', type=int, choices=CLOCKS, help='Static hardware clock profile; one binary per profile')
    parser.add_argument('--icache-fill-bytes', type=int, choices=(4, 8), help='Explicit I-cache install width; new builds default to 4')
    parser.add_argument('--expect-core-profile', choices=CORE_PROFILES,
                        help='Require the exact P0/P1 hardware profile; old receipts without one remain replayable when omitted')
    parser.add_argument('--max-cycles', type=int, default=100000000)
    parser.add_argument('--log-root', type=Path, default=Path('logs/p2/measure-optimize-20261022/step1'))
    args = parser.parse_args()
    if args.iterations is not None and args.iterations < 1:
        parser.error('--iterations must be positive')
    if args.irq_period_us is not None and not 1 <= args.irq_period_us <= 4000:
        parser.error('--irq-period-us must be between 1 and 4000')
    os.chdir(ROOT)
    for key, subdir in (('CCACHE_TEMPDIR', 'build/ccache-tmp'), ('CCACHE_DIR', 'build/ccache')):
        os.environ.setdefault(key, str(ROOT / subdir))
        Path(os.environ[key]).mkdir(parents=True, exist_ok=True)
    if args.freeze:
        args.iterations = args.iterations or 2
        args.timer_mode = args.timer_mode or 'realtime'
        args.irq_period_us = args.irq_period_us or 100
        freeze_images(args)
    else:
        replay_images(args)


if __name__ == '__main__':
    main()
