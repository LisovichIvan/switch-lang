#!/usr/bin/env python3
"""Opt-in native Terminal regression. Requires an existing signed app and granted access.

Run explicitly: python3 -B scripts/test-terminal-integration.py --owned-fixture
The coordinator temporarily deploys a diagnostic at the original app path, then
verifies restoration. It never requests access, changes settings, or uses a shell
for synthetic input. This is not a physical/session-input compatibility test.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests/Integration/Terminal"
EXPECTED_RESULTS = [
    {"scenario": "terminal-first-prompt-en-ru", "passed": True, "returns": 0, "tabs": 0},
    {"scenario": "terminal-following-prompt-ru-en", "passed": True, "returns": 1, "tabs": 0},
]


def workspace_directory(path):
    current = ROOT
    for component in path.relative_to(ROOT).parts:
        current = current / component
        if current.is_symlink():
            raise RuntimeError(f"Directory must not be a symbolic link: {current}")
        current.mkdir(mode=0o700, exist_ok=True)
        metadata = current.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o022):
            raise RuntimeError(f"Unsafe workspace directory: {current}")


def source_manifest():
    paths = list(ROOT.glob("*.md")) + [ROOT / ".gitignore"]
    for name in ("Sources", "Tests", "scripts", "packaging"):
        directory = ROOT / name
        if directory.is_symlink():
            raise RuntimeError(f"Source directory must not be a symbolic link: {directory}")
        paths.extend(directory.rglob("*"))
    hashes = {}
    for path in sorted(paths):
        if path.is_symlink():
            raise RuntimeError(f"Source must not be a symbolic link: {path}")
        if path.is_file():
            hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def create_artifacts():
    # Keep the proven native New Command tokenization; do not fall back to a
    # shell (or a user buffer) for paths requiring quoting.
    if not re.fullmatch(r"[/A-Za-z0-9._-]+", str(ROOT)):
        raise RuntimeError("Native fixture requires a workspace path without whitespace or quoting")
    os.umask(0o077)
    for path in (ROOT / ".tools", ROOT / ".tools/tmp", ROOT / ".tools/swift-cache"):
        workspace_directory(path)
    artifacts = Path(tempfile.mkdtemp(prefix="terminal-integration-", dir=ROOT / ".tools"))
    (artifacts / "correction").mkdir(mode=0o700)
    return artifacts


def build(artifacts):
    """Compile only; no signing, app launch, access requests, or settings writes."""
    runtime_source = (ROOT / "Sources/SwitchLang/KeyboardRuntime.swift").read_bytes()
    original_signature = b"func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {"
    nullable_signature = original_signature.replace(b"CGEventTapProxy,", b"CGEventTapProxy?,")
    if runtime_source.count(original_signature) != 1 or nullable_signature in runtime_source:
        raise RuntimeError("Expected exactly one original nonnullable handleEvent signature")
    variant = runtime_source.replace(original_signature, nullable_signature, 1)
    if (variant.replace(nullable_signature, original_signature, 1) != runtime_source
            or variant.split(nullable_signature, 1)[1] != runtime_source.split(original_signature, 1)[1]):
        raise RuntimeError("Diagnostic variant changed the handler body or another source byte")
    generated_runtime = artifacts / "KeyboardRuntime.swift"
    generated_runtime.write_bytes(variant)
    configuration = artifacts / "TerminalIntegrationConfiguration.swift"
    configuration.write_text(
        "enum TerminalIntegrationConfiguration {\n"
        f"  static let directory = {json.dumps(str(artifacts))}\n"
        "}\n", encoding="utf-8")
    environment = {
        **os.environ,
        "TMPDIR": str(ROOT / ".tools/tmp"),
        "CLANG_MODULE_CACHE_PATH": str(ROOT / ".tools/swift-cache"),
        "SWIFT_MODULE_CACHE_PATH": str(ROOT / ".tools/swift-cache"),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    atomic_object = artifacts / "AtomicSupport.o"
    common = [
        "/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", "arm64-apple-macosx11.0", "-warnings-as-errors", "-O",
        "-whole-module-optimization", "-module-cache-path", ROOT / ".tools/swift-cache",
    ]
    sources = [path for path in sorted((ROOT / "Sources/SwitchLang").glob("*.swift"))
               if path.name not in ("Main.swift", "KeyboardRuntime.swift")]
    sources += sorted((ROOT / "Tests").glob("*.swift"))
    sources += [generated_runtime, configuration]
    sources += [FIXTURES / name for name in
                ("ScopedInputAdapter.swift", "TerminalLaunch.swift", "CorrectionMain.swift")]
    commands = [
        ["/usr/bin/xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=11.0",
         "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-c",
         ROOT / "Sources/AtomicSupport/AtomicSupport.c", "-o", atomic_object],
        common + [FIXTURES / "TTYFixture.swift", configuration, "-o", artifacts / "tty-fixture"],
        common + ["-I", ROOT / "Sources/AtomicSupport"] + sources + [atomic_object,
            "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "Carbon",
            "-framework", "IOKit", "-o", artifacts / "correction/probe"],
    ]
    save_json(artifacts / "build-commands.json", [[str(value) for value in command] for command in commands])
    with (artifacts / "build.log").open("w", encoding="utf-8") as log:
        for command in commands:
            subprocess.run(list(map(str, command)), cwd=ROOT, env=environment, check=True,
                           stdout=log, stderr=subprocess.STDOUT, timeout=240)


def verify_completion(artifacts, before):
    correction = artifacts / "correction"
    result = json.loads((correction / "result.json").read_text())
    session = json.loads((correction / "session.json").read_text())
    restored = json.loads((correction / "restored.json").read_text())
    original = json.loads((correction / "original-bundle-hashes.json").read_text())
    if (result.get("reason") != "completed" or result.get("planned") != 2
            or result.get("results") != EXPECTED_RESULTS or result.get("session") != session.get("session")):
        raise RuntimeError("Terminal regression did not complete with 2/2 scenarios passed")
    if (any(restored.get(key) is not True for key in
            ("bundleUnchanged", "settingsUnchanged", "sourceFilesUnchanged"))
            or restored.get("executableSHA256") != original["Contents/MacOS/switch-lang"]):
        raise RuntimeError("Original bundle/settings/source restoration was not verified")
    if source_manifest() != before:
        raise RuntimeError("Workspace source manifest changed during integration")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owned-fixture", action="store_true", required=True,
                        help="Explicitly permit the isolated native Terminal fixture and temporary app swap")
    parser.parse_args()
    artifacts = None
    try:
        artifacts = create_artifacts()
        print(f"Artifacts: {artifacts}", flush=True)
        before = source_manifest()
        save_json(artifacts / "correction/source-hashes-before.json", before)
        if not (ROOT / "dist/Switch Lang.app").is_dir():
            raise RuntimeError("Existing signed dist/Switch Lang.app required; prepare the normal app build first")
        build(artifacts)
        if source_manifest() != before:
            raise RuntimeError("Workspace sources changed during compilation")
        with (artifacts / "correction/run-output.txt").open("w", encoding="utf-8") as log:
            command = [sys.executable, "-B", str(FIXTURES / "correction/run.py"),
                       "--owned-fixture", "--artifact-directory", str(artifacts / "correction")]
            process = subprocess.Popen(
                command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(ROOT / ".tools/tmp")})
            # subprocess.run kills its child on KeyboardInterrupt. Never kill
            # the coordinator while it may be restoring the original bundle.
            while True:
                try:
                    returncode = process.wait()
                    break
                except KeyboardInterrupt:
                    print(f"Interrupted; waiting for coordinator restoration. Artifacts: {artifacts}", file=sys.stderr)
            if returncode:
                raise subprocess.CalledProcessError(returncode, command)
        verify_completion(artifacts, before)
        print(f"PASS: 2/2 Terminal scenarios; original bundle/settings/sources restored. Artifacts: {artifacts}")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        print(f"FAIL: {error}. Artifacts: {artifacts or 'not created'}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
