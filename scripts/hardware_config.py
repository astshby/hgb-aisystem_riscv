"""Shared Core parameters and target clocks for bare-metal and RT-Thread software."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROFILE_PATH=ROOT/'scripts/hardware_profile.json'
PROFILE=json.loads(PROFILE_PATH.read_text())


def cache_memory(icache_bytes=None, dcache_bytes=None):
    memory = dict(PROFILE['memory'])
    for key, value in (('icache_bytes', icache_bytes), ('dcache_bytes', dcache_bytes)):
        if value is not None:
            if type(value) is not int or value < 4096 or value > 65536 or value & (value - 1):
                raise ValueError('cache capacity must be a power of two from 4096 to 65536 bytes')
            memory[key] = value
    return memory


def hardware_configuration(accelerator='none',xlen=32,icache_bytes=None,dcache_bytes=None):
    if accelerator not in ('none','yolo','minimind') or xlen not in (32,64):
        raise ValueError('unsupported hardware selection')
    periods=dict(PROFILE['clock_periods_ps']['target'])
    if accelerator!='none':periods['npu']=10000
    return dict(accelerator=accelerator,xlen=xlen,
                macros=dict(PROFILE['core_macros'],CORE_XLEN=xlen),
                memory=cache_memory(icache_bytes,dcache_bytes),periods_ps=periods,
                frequencies_hz={key:10**12//value for key,value in periods.items()},
                board_clock_profile=PROFILE['native_board_profiles']['target'])
