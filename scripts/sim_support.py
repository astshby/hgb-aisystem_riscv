"""Shared firmware options, source snapshots and ELF symbols for functional simulators."""
import hashlib
import os
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def optimization():
    value=os.environ.get('SOFTWARE_OPT','O3')
    if value not in ('O2','O3','Ofast'):
        raise ValueError('SOFTWARE_OPT must be O2, O3 or Ofast')
    return value


def rtl_sources():
    patterns=('vsrc/**/*.sv','vsrc/**/*.svh','vsrc/**/*.vh','third_party/**/*.sv',
              'tb/soc/*.sv','tb/soc/*.svh','tb/common/*.sv','tb/common/*.svh','tb/common/*.vh',
              'scripts/*.f','scripts/verilator/*core_config.sh','scripts/verilator/core_build_config.sh')
    return {str(p):sha(p) for pattern in patterns for p in sorted(Path('.').glob(pattern))}


def copy_sources(paths,destination):
    hashes={}
    for path in paths:
        target=destination/path
        target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as output:output.write(path.read_bytes())
        hashes[str(path)]=sha(target)
    return hashes


def symbols_from_nm(text):
    result={}
    for line in text.splitlines():
        fields=line.split()
        if len(fields)==3 and re.fullmatch(r'[0-9a-fA-F]+',fields[0]):
            result[fields[2]]=int(fields[0],16)
    return result
