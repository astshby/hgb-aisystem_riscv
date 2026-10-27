"""Shared Core parameters and target clocks for bare-metal and RT-Thread software."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROFILE_PATH=ROOT/'scripts/hardware_profile.json'
PROFILE=json.loads(PROFILE_PATH.read_text())


def hardware_configuration(accelerator='none',xlen=32):
    if accelerator not in ('none','yolo','minimind') or xlen not in (32,64):
        raise ValueError('unsupported hardware selection')
    periods=dict(PROFILE['clock_periods_ps']['target'])
    if accelerator!='none':periods['npu']=10000
    return dict(accelerator=accelerator,xlen=xlen,
                macros=dict(PROFILE['core_macros'],CORE_XLEN=xlen),
                memory=dict(PROFILE['memory']),periods_ps=periods,
                frequencies_hz={key:10**12//value for key,value in periods.items()},
                board_clock_profile=PROFILE['native_board_profiles']['target'])
