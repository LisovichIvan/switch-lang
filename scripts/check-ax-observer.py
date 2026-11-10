#!/usr/bin/env python3
"""Keep AX observer lifecycle on its main-thread resource boundary."""

from pathlib import Path
import re
import sys

OWNER = 'AXObservation.swift'
OPERATIONS = re.compile(r'\bAXObserver(?:Create|AddNotification|RemoveNotification|GetRunLoopSource)\s*\(')


def violations(sources):
    return [name + ': AX observer lifecycle must belong to the main-thread owner'
            for name, source in sources.items()
            if name != OWNER and OPERATIONS.search(source)]


def main():
    directory = Path(__file__).resolve().parents[1] / 'Sources/SwitchLang'
    errors = violations({path.name: path.read_text() for path in directory.glob('*.swift')})
    if errors:
        raise SystemExit('\n'.join(errors))
    print('AX observer lifecycle: centralized main-thread owner.')


if __name__ == '__main__':
    if sys.argv[1:]:
        raise SystemExit('Expected no arguments')
    main()
