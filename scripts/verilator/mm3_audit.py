#!/usr/bin/env python3
"""Fail-closed text audits; missing tools/files must never be interpreted as no matches."""
import argparse
import pathlib
import re
import sys

PATTERNS = {
    'no-float': r'\b(f(add|sub|mul|div|sqrt|cvt|mv|sgnj|min|max|eq|lt|le|class)\.|f(madd|msub|nmadd|nmsub)\.|fl[wd]\b|fs[wd]\b)|__(add|sub|mul|div|float|fix|extend|trunc).*(sf|df)',
    'structure': r'%Warning-(LATCH|MULTIDRIVEN|UNOPTFLAT|ALWCOMBORDER)',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=PATTERNS)
    parser.add_argument('files', nargs='+', type=pathlib.Path)
    args = parser.parse_args()
    pattern = re.compile(PATTERNS[args.kind])
    found = False
    try:
        for path in args.files:
            # Do not accept unreadable, missing or undecodable evidence as a clean audit.
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if pattern.search(line):
                    print(f'{path}:{number}:{line}', file=sys.stderr)
                    found = True
    except (OSError, UnicodeError) as error:
        print(f'AUDIT_ERROR {args.kind}: {error}', file=sys.stderr)
        return 2
    if found:
        print(f'AUDIT_FAIL {args.kind}', file=sys.stderr)
        return 1
    print(f'AUDIT_PASS {args.kind} files={len(args.files)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
