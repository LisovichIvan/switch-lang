#!/bin/sh
set -eu
project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_directory"
umask 077
configuration=release
sanitizer=
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=debug ;;
        --sanitize=address) sanitizer=address ;;
        --sanitize=thread) sanitizer=thread ;;
        *) printf 'Unknown build option: %s\n' "$argument" >&2; exit 2 ;;
    esac
done
output_directory="$project_directory/.tools/build/$configuration${sanitizer:+-$sanitizer}"
cache_directory="$project_directory/.tools/swift-cache"
export TMPDIR="$project_directory/.tools/tmp"
export CLANG_MODULE_CACHE_PATH="$cache_directory"
export SWIFT_MODULE_CACHE_PATH="$cache_directory"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$project_directory" "$output_directory" "$cache_directory" "$TMPDIR" <<'PY'
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
for target in map(Path, sys.argv[2:]):
    relative = target.relative_to(root)
    current = root
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise SystemExit(f"Build directory must not be a symbolic link: {current}")
        current.mkdir(mode=0o700, exist_ok=True)
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise SystemExit(f"Unsafe build directory: {current}")
for name in ("AtomicSupport.o", "switch-lang"):
    output = Path(sys.argv[2]) / name
    if output.is_symlink():
        raise SystemExit(f"Build output must not be a symbolic link: {output}")
    if output.exists():
        metadata = output.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1 or metadata.st_mode & 0o022:
            raise SystemExit(f"Unsafe build output: {output}")
PY
set -- -swift-version 5 -warnings-as-errors -parse-as-library -module-name SwitchLang -target arm64-apple-macosx11.0 \
    -module-cache-path "$cache_directory" -I Sources/AtomicSupport
if [ "$configuration" = debug ]; then set -- "$@" -Onone -g; else set -- "$@" -O -whole-module-optimization; fi
if [ -n "$sanitizer" ]; then set -- "$@" "-sanitize=$sanitizer"; fi
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=11.0 -std=c11 -Wall -Wextra -Werror -O2 \
    ${sanitizer:+-fsanitize=$sanitizer} -c Sources/AtomicSupport/AtomicSupport.c -o "$output_directory/AtomicSupport.o"
/usr/bin/xcrun swiftc "$@" Sources/SwitchLang/*.swift Tests/*.swift "$output_directory/AtomicSupport.o" \
    -framework AppKit -framework ApplicationServices -framework Carbon -framework IOKit \
    -o "$output_directory/switch-lang"
printf 'Compiled: %s\n' "$output_directory/switch-lang"
