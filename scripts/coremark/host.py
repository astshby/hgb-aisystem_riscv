#!/usr/bin/env python3
"""Receive UART CoreMark runs or decode a saved transcript using 64-bit ROI cycles."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time

EXPECTED = {
    'performance': {'seedcrc': 0xe9f5, 'crclist': 0xe714, 'crcmatrix': 0x1fd7, 'crcstate': 0x8e3a},
    'validation': {'seedcrc': 0x18f2, 'crclist': 0xe3c1, 'crcmatrix': 0x0747, 'crcstate': 0x8d84},
}
CRC = re.compile(r'^(?:\[0\])?(seedcrc|crclist|crcmatrix|crcstate|crcfinal)\s*:\s*0x([0-9a-fA-F]+)\s*$')
DURATION_ERROR = 'ERROR! Must execute for at least 10 secs for a valid result!'


def fields(line):
    result = {}
    for item in line.split()[1:]:
        if '=' not in item:
            raise ValueError('malformed protocol field: ' + item)
        key, value = item.split('=', 1)
        if key in result or not value:
            raise ValueError('duplicate or empty protocol field: ' + key)
        result[key] = value
    return result


def positive(values, key):
    value = values.get(key, '')
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError('expected positive integer: ' + key)
    return int(value)


class Decoder:
    """One request ends only after DONE and the following READY have both arrived."""
    def __init__(self):
        self.ready = None
        self.request = None
        self.attempt = None
        self.results = []
        self.retry = False
        self.errors = []

    def feed(self, line):
        line = line.strip()
        try:
            self._feed(line)
        except ValueError as error:
            self.errors.append(str(error))

    def _feed(self, line):
        if line.startswith('READY '):
            info = fields(line)
            if info.get('app') != 'coremark':
                raise ValueError('READY is not CoreMark')
            positive(info, 'core_hz')
            if self.request is not None:
                if self.request.get('done') is None:
                    raise ValueError('READY before DONE')
                self.request['next_ready'] = info
                self._finish()
            self.ready = info
        elif line.startswith('CM_BEGIN '):
            info = fields(line)
            if self.ready is None or (self.request is not None and not self.retry):
                raise ValueError('CM_BEGIN without READY or retry')
            if info.get('mode') not in EXPECTED:
                raise ValueError('unknown CoreMark mode')
            positive(info, 'iterations')
            if self.request is None:
                self.request = {'ready': self.ready, 'attempts': [], 'done': None}
            self.attempt = {'begin': info, 'crc': {}, 'vendor_errors': [], 'result': None}
            self.request['attempts'].append(self.attempt)
            self.retry = False
        elif line.startswith('CM_RESULT '):
            if self.attempt is None or self.attempt['result'] is not None:
                raise ValueError('unexpected CM_RESULT')
            info = fields(line)
            for key in ('iterations', 'roi_cycles', 'core_hz'):
                info[key] = positive(info, key)
            if info.get('formal') not in ('0', '1'):
                raise ValueError('formal must be 0 or 1')
            if (info.get('mode') != self.attempt['begin']['mode'] or
                    info['iterations'] != int(self.attempt['begin']['iterations'])):
                raise ValueError('CM_RESULT differs from CM_BEGIN')
            if info['core_hz'] != int(self.ready['core_hz']):
                raise ValueError('CM_RESULT clock differs from READY')
            self.attempt['result'] = info
        elif line.startswith('CM_RETRY '):
            if self.attempt is None or self.attempt['result'] is None:
                raise ValueError('retry without completed measurement')
            self.retry = True
            self.attempt = None
        elif line.startswith('DONE '):
            info = fields(line)
            if self.request is None:
                # Command/platform failures do not contain a benchmark measurement.
                self.request = {'ready': self.ready, 'attempts': [], 'done': None}
            if self.request['done'] is not None:
                raise ValueError('duplicate DONE')
            self.request['done'] = info.get('status', 'missing')
        elif self.attempt is not None and self.attempt['result'] is None:
            crc = CRC.fullmatch(line)
            if crc:
                key, value = crc.groups()
                if key in self.attempt['crc']:
                    raise ValueError('duplicate CRC: ' + key)
                self.attempt['crc'][key] = int(value, 16)
            elif 'ERROR' in line or 'Errors detected' in line:
                self.attempt['vendor_errors'].append(line)

    def _finish(self):
        request = self.request
        problems = []
        for attempt in request['attempts']:
            result = attempt['result']
            if result is None:
                problems.append('missing CM_RESULT')
                continue
            mode = result['mode']
            crc = attempt['crc']
            if any(crc.get(k) != v for k, v in EXPECTED[mode].items()) or 'crcfinal' not in crc:
                problems.append('missing or incorrect CRC')
            vendor_errors = attempt['vendor_errors']
            duration_error = any(DURATION_ERROR in line for line in vendor_errors)
            algorithm_errors = [line for line in vendor_errors
                                if DURATION_ERROR not in line and
                                not (duration_error and line == 'Errors detected')]
            if algorithm_errors:
                problems.append('vendor error: ' + '; '.join(algorithm_errors))
            result['duration_seconds'] = result['roi_cycles'] / result['core_hz']
            result['coremark_per_mhz'] = result['iterations'] * 1_000_000 / result['roi_cycles']
            result['coremark_per_second'] = result['iterations'] * result['core_hz'] / result['roi_cycles']
            result['duration_qualified'] = result['roi_cycles'] >= 10 * result['core_hz']
            if result['formal'] == '1' and (not result['duration_qualified'] or duration_error):
                problems.append('formal flag disagrees with measured duration')
        if not request['attempts']:
            problems.append('no benchmark measurement')
        if request['done'] not in ('completed', 'short'):
            problems.append('DONE status=' + request['done'])
        if request['ready'] != request['next_ready']:
            problems.append('READY configuration changed during request')
        last = request['attempts'][-1]['result'] if request['attempts'] else None
        if request['done'] == 'completed' and (last is None or last['formal'] != '1'):
            problems.append('completed request lacks formal result')
        request['problems'] = problems
        request['valid'] = not problems
        request['official'] = bool(not problems and request['done'] == 'completed' and last and
                                   last['formal'] == '1' and request['ready'].get('test_only') != '1')
        self.results.append(request)
        self.request = None
        self.attempt = None
        self.retry = False

    def report(self):
        errors = list(self.errors)
        if self.request is not None:
            errors.append('incomplete request: DONE and next READY required')
        if not self.results:
            errors.append('no completed requests')
        return {'schema': 1, 'requests': self.results, 'errors': errors,
                'valid': not errors and all(x['valid'] for x in self.results)}


def decode(text):
    decoder = Decoder()
    for line in text.splitlines():
        decoder.feed(line)
    return decoder.report()


def receive(port, baud, mode, repeat, timeout, raw):
    try:
        import serial
    except ImportError as error:
        raise RuntimeError('serial connection requires pyserial; offline --input does not') from error
    decoder = Decoder()
    sent = 0
    deadline = time.monotonic() + timeout
    pending = bytearray()
    with serial.Serial(port, baud, timeout=0.2) as connection, raw.open('wb') as stream:
        # Do not flush input: the initial READY can already be waiting in the adapter.
        while len(decoder.results) < repeat:
            if time.monotonic() >= deadline:
                raise TimeoutError('no complete READY/DONE cycle before timeout; raw UART saved')
            data = connection.read(1024)
            if not data:
                continue
            stream.write(data)
            stream.flush()
            pending.extend(data)
            if len(pending) > 65536:
                raise ValueError('UART line exceeds 64 KiB')
            while b'\n' in pending:
                line, _, pending = pending.partition(b'\n')
                text = line.decode('ascii', errors='replace').rstrip('\r')
                print(text, flush=True)
                decoder.feed(text)
                if decoder.errors:
                    raise ValueError('; '.join(decoder.errors))
                if decoder.results and any(
                        x['attempts'] and x['attempts'][-1]['result'] is not None and
                        x['attempts'][-1]['result']['mode'] != mode for x in decoder.results):
                    raise ValueError('UART result mode differs from requested mode')
                if text.startswith('READY ') and sent < repeat:
                    connection.write(b'V\r' if mode == 'validation' else b'\r')
                    connection.flush()
                    sent += 1
                    deadline = time.monotonic() + timeout
        return decoder.report()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--input', type=Path, help='saved UART transcript')
    source.add_argument('--port', help='serial port, for example COM5 or /dev/ttyUSB0')
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--mode', choices=tuple(EXPECTED), default='performance')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--raw-log', type=Path, default=Path('coremark-uart.log'))
    parser.add_argument('--output', type=Path, default=Path('coremark-results.json'))
    parser.add_argument('--require-formal', action='store_true')
    args = parser.parse_args()
    if args.baud <= 0 or args.repeat <= 0 or args.timeout <= 0:
        parser.error('baud, repeat and timeout must be positive')
    if args.input:
        payload = args.input.read_bytes()
        report = decode(payload.decode('ascii', errors='replace'))
        report['transcript_sha256'] = hashlib.sha256(payload).hexdigest()
    else:
        report = receive(args.port, args.baud, args.mode, args.repeat, args.timeout, args.raw_log)
        report['transcript_sha256'] = hashlib.sha256(args.raw_log.read_bytes()).hexdigest()
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for index, request in enumerate(report['requests'], 1):
        attempts = request['attempts']
        value = attempts[-1]['result'] if attempts else None
        if value:
            print(f"request={index} CoreMark/MHz={value['coremark_per_mhz']:.6f} "
                  f"seconds={value['duration_seconds']:.6f} official={int(request['official'])}")
    if not report['valid'] or (args.require_formal and not all(x['official'] for x in report['requests'])):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
