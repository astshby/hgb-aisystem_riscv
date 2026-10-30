#!/usr/bin/env python3
"""Compare native timing before/after bounded CDC constraints, without changing clocks."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def rows(directory, name):
    table = ET.parse(directory / f'synthesize_{name}.db').getroot().find('table')
    headers = [d.text for d in table.find('column_headers')]
    return [dict(zip(headers, [d.text for d in row.findall('data')])) for row in table.findall('row')]


def same_domain(values):
    return {(r['Launch Clock'], r['Capture Clock']): r for r in values
            if r['Launch Clock'] == r['Capture Clock']}


def verify(before, after, spec, log):
    errors = re.findall(r'^(?:E:|ERROR:).*|^.*(?:SDC-2040|STA-301[235]|Timing-4003|CommandTiming-0057):.*', log, re.M)
    if errors or 'CDC_TIMING_REPORT_DONE' not in log:
        raise ValueError('native constraint diagnostics or incomplete timing run: ' + str(errors[:3]))
    result = dict(same_domain={}, functional_crossings=[])
    for name in ('report_timing_clock_summary', 'report_timing_fmax'):
        if rows(before, name) != rows(after, name):
            raise ValueError('clock definitions or same-domain Fmax changed: ' + name)
    for kind in ('setup', 'hold'):
        old, new = rows(before, 'report_timing_' + kind), rows(after, 'report_timing_' + kind)
        if same_domain(old) != same_domain(new):
            raise ValueError('same-domain timing/endpoints changed: ' + kind)
        result['same_domain'][kind] = list(same_domain(new).values())
        for r in rows(after, 'report_timing_path_' + kind):
            if r['Launch Clock'] == r['Capture Clock'] and r.get('Exception'):
                raise ValueError('same-domain path has an exception: ' + str(r))
            if re.search(r'/(?:write|read|irq)_sync2_q', r['End Point']) and r.get('Exception'):
                raise ValueError('second synchronizer stage was excepted: ' + str(r))
    clocks = set(spec['clocks'].values())
    for row in rows(after, 'report_timing_setup'):
        if row['Launch Clock'] != row['Capture Clock'] and {row['Launch Clock'], row['Capture Clock']} <= clocks:
            if float(row['WNS(ns)']) < 0:
                raise ValueError('bounded functional CDC setup still fails: ' + str(row))
            result['functional_crossings'].append(row)
    if not result['functional_crossings']:
        raise ValueError('no functional cross-domain timing reported')
    exceptions = [r for r in rows(after, 'report_timing_path_setup') if r.get('Exception')]
    if not any('MaxDelay' in r['Exception'] for r in exceptions):
        raise ValueError('no bounded path exception appears in the native report')
    result['reported_exception_paths'] = len(exceptions)
    result['status'] = 'PASS bounded CDC setup; same-domain clocks, Fmax, setup/hold and endpoint counts unchanged'
    result['limits'] = 'pre-route evidence; max-skew and physical timing require implementation reports'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'spec', 'log', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.before, args.after, json.loads(args.spec.read_text()), args.log.read_text(errors='replace'))
    result['files_sha256'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in [args.spec, args.log, *args.before.glob('*.db'), *args.after.glob('*.db')]}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(result['status'])


if __name__ == '__main__':
    main()
