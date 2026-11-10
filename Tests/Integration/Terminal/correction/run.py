"""Coordinator for the opt-in owned native Terminal fixture; never a shell test."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[4]
FIXTURES = Path(__file__).resolve().parent
APPLICATION = ROOT / 'dist/Switch Lang.app'
REQUIREMENT = 'identifier "local.switch-lang.app" and certificate leaf = H"1e054fc92b09f2c8821a7673a9906177061e828a"'


def run(arguments, timeout=90):
    return subprocess.run(list(map(str, arguments)), cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=timeout)


def state():
    return json.loads(run(['/usr/bin/osascript', '-l', 'JavaScript', FIXTURES / 'state.js'], 15).stdout)


def verify(application):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=' + REQUIREMENT, application])


def private_directory(path):
    metadata = path.lstat()
    if path.is_symlink() or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise RuntimeError('Unsafe diagnostic directory')


def regular_file(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1 or metadata.st_mode & 0o022:
        raise RuntimeError('Unsafe diagnostic file')


def manifest(application):
    private_directory(application)
    result = {}
    for path in sorted(application.rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Unexpected bundle symlink')
        if path.is_file():
            regular_file(path)
            result[str(path.relative_to(application))] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            private_directory(path)
        else:
            raise RuntimeError('Unexpected bundle component')
    return result


def expected_gui(snapshot):
    applications = snapshot['applications']
    if len(applications) != 1:
        raise RuntimeError('Expected exactly one workspace GUI')
    application = applications[0]
    if application['bundlePath'] != str(APPLICATION) or application['executablePath'] != str(APPLICATION / 'Contents/MacOS/switch-lang'):
        raise RuntimeError('Unexpected GUI paths')
    return application


def stop_gui():
    snapshot = state()
    if not snapshot['applications']:
        return
    application = expected_gui(snapshot)
    run(['/usr/bin/osascript', '-l', 'JavaScript', FIXTURES / 'stop-gui.js', str(application['pid']), APPLICATION], 15)
    run(['/usr/bin/python3', '-B', FIXTURES / 'wait-process.py', str(application['pid'])], 15)
    if state()['applications']:
        raise RuntimeError('GUI did not exit; no live bundle replacement')


def save(name, value):
    (ARTIFACTS / name).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def main():
    global ARTIFACTS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owned-fixture', action='store_true', required=True)
    parser.add_argument('--artifact-directory', type=Path, required=True)
    arguments = parser.parse_args()
    ARTIFACTS = arguments.artifact_directory
    if ARTIFACTS.name != 'correction' or ARTIFACTS.parent.parent != ROOT / '.tools':
        raise RuntimeError('Artifacts must be a correction directory inside workspace .tools')
    STAGED = ARTIFACTS / 'staged/Switch Lang.app'
    HELD = ARTIFACTS / 'held/Switch Lang.app'
    ARCHIVED = ARTIFACTS / 'diagnostic-run.app'
    os.umask(0o077)
    if Path.cwd() != ROOT:
        raise RuntimeError('Wrong workspace')
    for path in [ROOT / '.tools', ARTIFACTS.parent, ARTIFACTS, ROOT / 'dist']:
        private_directory(path)
    regular_file(ARTIFACTS / 'source-hashes-before.json')
    for path in [STAGED, HELD, ARCHIVED, ARTIFACTS / 'ready.json', ARTIFACTS / 'result.json', ARTIFACTS / 'restored.json']:
        if path.exists() or path.is_symlink():
            raise RuntimeError('Diagnostic destination already occupied')
    binary = ARTIFACTS / 'probe'
    regular_file(binary)
    run([binary, '--self-test'])
    target = json.loads(run(['/usr/bin/osascript', '-l', 'JavaScript', FIXTURES / 'terminal-pid.js'], 15).stdout)
    target_pid = target['pid']
    if not isinstance(target_pid, int) or target_pid <= 0:
        raise RuntimeError('Invalid Terminal PID')
    before = state()
    if before['applications']:
        expected_gui(before)
    if not all(before['settings'].get(key) is True for key in ['permissionIntroductionHandled', 'accessibilityRegistrationAttempted', 'inputMonitoringRegistrationAttempted']):
        raise RuntimeError('Permission markers changed; no requests permitted')
    verify(APPLICATION)
    original = manifest(APPLICATION)
    save('before.json', before)
    save('original-bundle-hashes.json', original)
    STAGED.parent.mkdir(mode=0o700)
    HELD.parent.mkdir(mode=0o700)
    shutil.copytree(APPLICATION, STAGED)
    shutil.copy2(binary, STAGED / 'Contents/MacOS/switch-lang')
    run(['/usr/bin/python3', '-B', ROOT / 'scripts/sign-app.py', 'sign', STAGED])
    verify(STAGED)
    run([STAGED / 'Contents/MacOS/switch-lang', '--self-test'])
    diagnostic = manifest(STAGED)
    save('diagnostic-bundle-hashes.json', diagnostic)
    if state() != before or manifest(APPLICATION) != original:
        raise RuntimeError('Production state changed during preparation')
    if json.loads(run(['/usr/bin/osascript', '-l', 'JavaScript', FIXTURES / 'terminal-pid.js'], 15).stdout) != target:
        raise RuntimeError('Terminal instance changed during preparation')
    session = str(uuid.uuid4())
    save('session.json', {'session': session})
    deployed = False
    try:
        stop_gui()
        os.rename(APPLICATION, HELD)
        try:
            os.rename(STAGED, APPLICATION)
            deployed = True
        except BaseException:
            os.rename(HELD, APPLICATION)
            raise
        verify(APPLICATION)
        print('Synthetic Terminal test setup deployed; existing shell buffers are not touched.', flush=True)
        run(['/usr/bin/open', '-W', '-n', '-g', APPLICATION, '--args', '--session', session, '--target-pid', target_pid], 90)
        regular_file(ARTIFACTS / 'result.json')
        result = json.loads((ARTIFACTS / 'result.json').read_text())
        if result.get('session') != session:
            raise RuntimeError('Unexpected diagnostic session')
        print('Probe result: ' + str(result.get('reason')), flush=True)
    finally:
        if deployed:
            stop_gui()
            if manifest(APPLICATION) != diagnostic:
                raise RuntimeError('Diagnostic changed; original retained in held directory')
            os.rename(APPLICATION, ARCHIVED)
            os.rename(HELD, APPLICATION)
        elif HELD.exists() and not APPLICATION.exists():
            os.rename(HELD, APPLICATION)
        verify(APPLICATION)
        if manifest(APPLICATION) != original:
            raise RuntimeError('Restored bundle differs')
        if state()['settings'] != before['settings']:
            raise RuntimeError('Settings changed; no blind overwrite')
        # The original bundle and settings are already verified. Restore its
        # prior GUI state before a source-audit failure can interrupt cleanup.
        if before['applications']:
            run(['/usr/bin/open', '-g', APPLICATION], 15)
        previous = json.loads((ARTIFACTS / 'source-hashes-before.json').read_text())
        sources_unchanged = all((ROOT / name).is_file() and
            hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
            for name, digest in previous.items())
        save('restored.json', {'bundleUnchanged': True, 'settingsUnchanged': True,
            'sourceFilesUnchanged': sources_unchanged, 'executableSHA256': original['Contents/MacOS/switch-lang']})
        if not sources_unchanged:
            raise RuntimeError('Production sources or documentation changed; original GUI restored')
        print('Original signed GUI restored; settings and sources unchanged.', flush=True)
    expected = [
        {'scenario': 'terminal-first-prompt-en-ru', 'passed': True, 'returns': 0, 'tabs': 0},
        {'scenario': 'terminal-following-prompt-ru-en', 'passed': True, 'returns': 1, 'tabs': 0},
    ]
    if result.get('reason') != 'completed' or result.get('planned') != 2 or result.get('results') != expected:
        raise RuntimeError('Terminal regression did not complete with 2/2 scenarios passed')
    print('Terminal regression passed: 2/2; original bundle, settings and sources verified.', flush=True)


if __name__ == '__main__':
    main()
