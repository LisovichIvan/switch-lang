#!/bin/sh
set -eu
project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_directory"
export PYTHONDONTWRITEBYTECODE=1
/usr/bin/python3 -B scripts/check-ax-reads.py --self-test
/usr/bin/python3 -B scripts/check-ax-reads.py
/usr/bin/python3 -B scripts/check-ax-observer.py
/usr/bin/xcrun swift-format lint --strict --recursive Sources/SwitchLang Tests
/bin/sh -n scripts/build-swift.sh
/bin/sh -n scripts/build-app.sh
/usr/bin/plutil -lint packaging/Info.plist
./scripts/build-swift.sh --debug
.tools/build/debug/switch-lang --self-test
printf '%s\n' 'Swift core/settings/keyboard/runtime/worker self-tests passed.'
.tools/build/debug/switch-lang --test-logging
/usr/bin/python3 -B scripts/test-signing.py -v
