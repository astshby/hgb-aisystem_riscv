"""Shared Core parameters and target clocks for bare-metal and RT-Thread software."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROFILE_PATH=ROOT/'scripts/hardware_profile.json'
PROFILE=json.loads(PROFILE_PATH.read_text())


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


def hardware_configuration(accelerator='none',xlen=32,icache_bytes=None,dcache_bytes=None,bank_xor_mask=0):
    if accelerator not in ('none','yolo','minimind') or xlen not in (32,64):
        raise ValueError('unsupported hardware selection')
    periods=dict(PROFILE['clock_periods_ps']['target'])
    if accelerator!='none':periods['npu']=10000
    # 只有 YOLO 走 C5 板级时钟；其余软件与测量工程保持 target(C1)。仿真时钟仍是
    # target 的 100/80/125/25 MHz，YOLO 应用验证的周期数与板级 90/100 MHz 无关。
    board_profile = PROFILE['native_board_profiles'].get(
        'yolo' if accelerator == 'yolo' else 'target')
    result = dict(accelerator=accelerator,xlen=xlen,
                macros=dict(PROFILE['core_macros'],CORE_XLEN=xlen),
                memory=cache_memory(icache_bytes,dcache_bytes,bank_xor_mask),periods_ps=periods,
                frequencies_hz={key:10**12//value for key,value in periods.items()},
                board_clock_profile=board_profile)
    if bank_xor_mask:
        result['macros']['SOC_DCACHE_BANK_XOR_MASK'] = bank_xor_mask
    return result
