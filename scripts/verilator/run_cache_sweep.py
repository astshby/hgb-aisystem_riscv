#!/usr/bin/env python3
"""Measure cache capacities with identical firmware, Core and clock ratios."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_config import ROOT, configuration, sha
import run_unified_coremark as unified


def observations(result):
    caches = result['metrics']['cache']
    def counts(names):
        hits = sum(caches[name]['roi_hits'] for name in names)
        misses = sum(caches[name]['roi_misses'] for name in names)
        return dict(hits=hits, misses=misses, requests=hits+misses,
                    hit_percent=100*hits/(hits+misses) if hits+misses else None)
    return dict(icache=counts(['icache']), dcache=counts(['dcache0','dcache1']),
                icache_refill_busy_cycles=result['metrics']['latency']['icache.refill']['roi_busy_cycles'],
                dcache_bank_wait_cycles={k:v['roi_request_stall_cycles'] for k,v in result['metrics']['cache_bank'].items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--models', type=Path, help='reuse models from an earlier sweep with identical RTL/configuration')
    parser.add_argument('--pairs', nargs='+', default=['4:4','8:4','16:4','32:4','4:8','4:16','4:32'],
                        help='I:D capacities in KiB')
    parser.add_argument('--modes', nargs='+', choices=['performance','validation'], default=['performance'])
    parser.add_argument('--scenarios', nargs='+', choices=['cold','warm','background'], default=['cold','warm','background'])
    parser.add_argument('--iterations', type=int, default=2)
    parser.add_argument('--workers', type=int, choices=[1,2], default=2)
    args = parser.parse_args()
    os.chdir(ROOT)
    output, bundle = args.output.resolve(), args.bundle.resolve()
    models = args.models.resolve() if args.models else output
    driver_sha256 = sha(Path(__file__))
    output.mkdir(parents=True, exist_ok=True)
    firmware = unified.freeze(bundle, args.iterations, args.modes)
    pairs = [tuple(int(v)*1024 for v in pair.split(':')) for pair in args.pairs]
    if any(len(pair)!=2 for pair in pairs) or len(set(pairs))!=len(pairs):
        parser.error('pairs must be unique I:D capacities')
    def measure(pair):
        config = configuration('soc_ddr','target',32,*pair)
        name = f'i{pair[0]//1024}-d{pair[1]//1024}'
        root = output/name
        print(f'CACHE_CONFIGURATION {name}',flush=True)
        binary, receipt = unified.build(config, models/name/'model')
        results = []
        for image in firmware['images']:
            if image['scenario'] not in args.scenarios or image['mode'] not in args.modes:
                continue
            result = unified.replay(binary, config, bundle, image, root, receipt)
            results.append(dict(scenario=image['scenario'],mode=image['mode'],cycles=result['cycles'],
                                coremark_per_mhz=result['coremark_per_core_mhz'],**observations(result)))
        summary = dict(icache_bytes=pair[0],dcache_bytes=pair[1],results=results)
        unified.write(root/'summary.json',summary)
        return summary
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(measure,pairs))
    baselines = {(r['scenario'],r['mode']):r['cycles'] for row in rows
                 if (row['icache_bytes'],row['dcache_bytes'])==(4096,4096) for r in row['results']}
    for row in rows:
        ratios = []
        for result in row['results']:
            baseline = baselines.get((result['scenario'],result['mode']))
            if baseline:
                ratio=baseline/result['cycles'];ratios.append(ratio)
                result['score_gain_percent']=100*(ratio-1)
        if ratios:
            row['equal_scenario_geomean_score_gain_percent']=100*(math.exp(sum(map(math.log,ratios))/len(ratios))-1)
    unified.write(output/'summary.json',dict(command=sys.argv,source_commit=subprocess.check_output(
        ['git','rev-parse','HEAD'],text=True).strip(),driver_sha256=driver_sha256,
        firmware_manifest_sha256=sha(bundle/'manifest.json'),rows=rows))
    print(f'PASS cache capacity sweep configurations={len(rows)} measurements={sum(len(r["results"]) for r in rows)}',flush=True)


if __name__=='__main__':main()
