#!/bin/sh
set -eu
project_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
umask 077
python3 "$project_directory/scripts/sign-app.py" check
python3 - "$project_directory" <<'PY'
import os
from pathlib import Path
import stat
import sys

project = Path(sys.argv[1])
for directory in (project / ".tools/tmp", project / "dist"):
    if directory.is_symlink():
        raise SystemExit(f"Build directory must not be a symbolic link: {directory}")
    directory.mkdir(mode=0o700, exist_ok=True)
    metadata = directory.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise SystemExit(f"Unsafe build directory: {directory}")
PY
if /usr/bin/pgrep -x switch-lang >/dev/null; then
    printf '%s\n' 'Quit Switch Lang before replacing its application bundle.' >&2
    exit 1
fi
"$project_directory/scripts/build-swift.sh"
staging_directory=$(mktemp -d "$project_directory/.tools/tmp/app-build.XXXXXX")
application="$project_directory/dist/Switch Lang.app"
cleanup() {
    if [ -e "$staging_directory/previous.app" ]; then
        if [ ! -e "$application" ]; then
            mv "$staging_directory/previous.app" "$application" || return
        else
            printf 'Previous bundle retained: %s/previous.app\n' "$staging_directory" >&2
            return
        fi
    fi
    rm -rf "$staging_directory"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
staged_application="$staging_directory/Switch Lang.app"
mkdir -p "$staged_application/Contents/MacOS"
cp "$project_directory/.tools/build/release/switch-lang" "$staged_application/Contents/MacOS/switch-lang"
cp "$project_directory/packaging/Info.plist" "$staged_application/Contents/Info.plist"
plutil -lint "$staged_application/Contents/Info.plist"
python3 "$project_directory/scripts/sign-app.py" sign "$staged_application"
# Publish only a completely verified bundle, leaving the previous app on failure.
python3 - "$staged_application" "$application" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

staged, application = map(Path, sys.argv[1:])
if subprocess.run(["/usr/bin/pgrep", "-x", "switch-lang"], capture_output=True).returncode != 1:
    raise SystemExit("Switch Lang started during the build; previous app not replaced")
if application.is_symlink():
    raise SystemExit("Application destination must not be a symbolic link")
previous = staged.parent / "previous.app"
if application.exists():
    os.rename(application, previous)
try:
    os.rename(staged, application)
except OSError:
    if previous.exists():
        os.rename(previous, application)
    raise
if previous.exists():
    shutil.rmtree(previous)
PY
printf 'Built: %s\n' "$application"
