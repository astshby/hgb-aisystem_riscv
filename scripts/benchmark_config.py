"""One configuration source for runnable CoreMark models and native PDS staging."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / 'scripts/benchmark_platforms.json'
from hardware_config import PROFILE, PROFILE_PATH, cache_memory, clock_periods
CONFIG = dict(PROFILE, **json.loads(CONFIG_PATH.read_text()))
DOMAINS = ('core', 'sys', 'ddr', 'periph')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def configuration(platform, clock='target', xlen=32, icache_bytes=None, dcache_bytes=None, bank_xor_mask=0):
    if xlen not in (32, 64):
        raise ValueError('XLEN must be 32 or 64')
    result = dict(CONFIG['platforms'][platform])
    memory = cache_memory(icache_bytes, dcache_bytes, bank_xor_mask)
    identity = sha(CONFIG_PATH) + sha(PROFILE_PATH)
    if memory != CONFIG['memory']:
        identity += json.dumps(memory, sort_keys=True)
    periods = clock_periods(clock, bool(result.get('npu_enable')))
    if result.get('npu_enable'):
        result['npu_period_ps'] = periods.get('npu', result['npu_period_ps'])
        periods['npu'] = result['npu_period_ps']
    result.update(platform=platform, clock=clock, xlen=xlen,
                  macros=dict(CONFIG['core_macros'], CORE_XLEN=xlen),
                  memory=memory, periods_ps=periods,
                  frequencies_hz={d: round(10**12 / periods[d]) if d in result['domains'] else None for d in (*DOMAINS, *(['npu'] if result.get('npu_enable') else []))},
                  config_sha256=hashlib.sha256(identity.encode()).hexdigest(),
                  native_board_profile=CONFIG['native_board_profiles'].get(clock),
                  timing_status='unvalidated_target')
    if bank_xor_mask:
        result['macros']['SOC_DCACHE_BANK_XOR_MASK'] = bank_xor_mask
    return result


def core_record(config):
    m = config['macros']
    names = dict(xlen='CORE_XLEN', issue_width='CORE_ISSUE_WIDTH', retire_entries='CORE_RETIRE_ENTRIES',
                 split_issue_queue='CORE_SPLIT_ISSUE_QUEUE', integer_queue_entries='CORE_ISSUE_QUEUE_ENTRIES',
                 memory_queue_entries='CORE_MEMORY_QUEUE_ENTRIES', limited_integer_ooo='CORE_LIMITED_INTEGER_OOO',
                 scheduler_forward_mode='CORE_SCHEDULER_FORWARD_MODE', predictor_mode='CORE_PREDICTOR_MODE',
                 ras_enable='CORE_RAS_ENABLE', mul_impl='CORE_MUL_IMPL', div_impl='CORE_DIV_IMPL')
    return dict(backend='scoreboard', **{key: m[value] for key, value in names.items()})


def score(iterations, cycles, core_period_ps):
    if iterations <= 0 or cycles <= 0 or core_period_ps <= 0:
        raise ValueError('positive iteration count, cycles and period required')
    seconds = cycles * core_period_ps / 10**12
    return dict(coremark_per_core_mhz=iterations * 10**6 / cycles,
                coremark_per_second_simulated=iterations / seconds,
                simulated_seconds=seconds, official_coremark_result=False,
                physical_frequency_measured=False)
