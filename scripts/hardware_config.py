"""Shared Core parameters and target clocks for bare-metal and RT-Thread software."""
import json
from fractions import Fraction
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROFILE_PATH=ROOT/'scripts/hardware_profile.json'
PROFILE=json.loads(PROFILE_PATH.read_text())


def clock_periods(clock, npu_enable=False):
    """Keep rational PLL periods until the simulator or FDC converts units."""
    periods = dict(PROFILE['clock_periods_ps'][clock])
    pll = PROFILE.get('pll_profiles', {}).get(clock)
    if pll:
        vco = Fraction(pll['reference_hz'] * pll['multiply'] * pll['feedback_div'], pll['input_div'])
        for domain, divider in pll['output_div'].items():
            if domain != 'npu' or npu_enable:
                periods[domain] = float(Fraction(10**12) * divider / vco)
        if not npu_enable:
            periods.pop('npu', None)
    elif npu_enable:
        # 历史档未声明 NPU 时沿用100 MHz；显式 npu80/npu125 不再被覆盖。
        periods.setdefault('npu', 10000)
    return periods


def cache_memory(icache_bytes=None, dcache_bytes=None, bank_xor_mask=0):
    memory = dict(PROFILE['memory'])
    for key, value in (('icache_bytes', icache_bytes), ('dcache_bytes', dcache_bytes)):
        if value is not None:
            if type(value) is not int or value < 4096 or value > 65536 or value & (value - 1):
                raise ValueError('cache capacity must be a power of two from 4096 to 65536 bytes')
            memory[key] = value
    if type(bank_xor_mask) is not int or bank_xor_mask not in (0, 1, 2, 3):
        raise ValueError('bank XOR mask must be 0, 1, 2 or 3')
    if bank_xor_mask:
        memory['dcache_bank_xor_mask'] = bank_xor_mask
    return memory


def hardware_configuration(accelerator='none',xlen=32,icache_bytes=None,dcache_bytes=None,bank_xor_mask=0,clock=None):
    if accelerator not in ('none','yolo','minimind') or xlen not in (32,64):
        raise ValueError('unsupported hardware selection')
    clock = clock or PROFILE['application_clocks'][accelerator]
    periods=clock_periods(clock, accelerator!='none')
    # 应用和板级使用同一档，periods_ps 保留分数周期；整数 Hz 元数据四舍五入。
    board_profile = PROFILE['native_board_profiles'].get(clock)
    result = dict(accelerator=accelerator,xlen=xlen,clock=clock,
                macros=dict(PROFILE['core_macros'],CORE_XLEN=xlen),
                memory=cache_memory(icache_bytes,dcache_bytes,bank_xor_mask),periods_ps=periods,
                frequencies_hz={key:round(10**12/value) for key,value in periods.items()},
                board_clock_profile=board_profile)
    if bank_xor_mask:
        result['macros']['SOC_DCACHE_BANK_XOR_MASK'] = bank_xor_mask
    return result
