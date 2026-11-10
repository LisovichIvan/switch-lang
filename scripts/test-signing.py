#!/usr/bin/env python3
"""Signing tests use unlaunched synthetic apps; never request or reset TCC."""

import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

PROJECT_DIRECTORY = Path(__file__).resolve().parent.parent
specification = importlib.util.spec_from_file_location("sign_app", PROJECT_DIRECTORY / "scripts/sign-app.py")
signing = importlib.util.module_from_spec(specification)
specification.loader.exec_module(signing)


class SigningFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="signing-unit-", dir=PROJECT_DIRECTORY / ".tools/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        (self.project / ".tools").mkdir(mode=0o700)

    def make_store(self):
        store = self.project / ".tools/signing"
        store.mkdir(mode=0o700)
        return store

    def test_missing_identity_fails_before_external_commands(self):
        with mock.patch.object(signing, "run_tool") as external:
            with self.assertRaisesRegex(signing.SigningError, "not initialized"):
                signing.check(self.project)
            external.assert_not_called()

    def test_existing_incomplete_store_is_never_replaced(self):
        store = self.make_store()
        sentinel = store / "keep-existing-identity"
        sentinel.write_bytes(b"unchanged")
        with mock.patch.object(signing, "compile_helper") as compiler:
            with self.assertRaises(signing.SigningError):
                signing.initialize(self.project)
            compiler.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        self.assertFalse((store / "password").exists())

    def test_symlink_and_broad_directory_permissions_are_rejected(self):
        target = self.project / "other"
        target.mkdir(mode=0o700)
        link = self.project / ".tools/signing"
        link.symlink_to(target)
        with self.assertRaises(signing.SigningError):
            signing.signing_store(self.project)
        link.unlink()
        link.mkdir(mode=0o755)
        link.chmod(0o755)
        with self.assertRaises(signing.SigningError):
            signing.signing_store(self.project)

    def test_login_keychain_substring_is_refused_before_creation(self):
        project = self.project / "login.keychain-project"
        project.mkdir()
        (project / ".tools").mkdir(mode=0o700)
        with self.assertRaisesRegex(signing.SigningError, "login.keychain"):
            signing.initialize(project)
        self.assertFalse((project / ".tools/signing").exists())

    def test_private_file_modes_types_and_bounds(self):
        store = self.make_store()
        private = store / "private"
        private.write_bytes(b"synthetic")
        private.chmod(0o600)
        self.assertEqual(signing.check_file(private, 16), b"synthetic")
        self.assertIsNone(signing.check_file(private, 16, read_contents=False))
        with self.assertRaises(signing.SigningError):
            signing.check_file(private, 4)
        private.chmod(0o644)
        with self.assertRaises(signing.SigningError):
            signing.check_file(private, 16)
        private.unlink()
        private.symlink_to(store / "missing")
        with self.assertRaises(signing.SigningError):
            signing.check_file(private, 16)
        private.unlink()
        os.mkfifo(private, 0o600)
        with self.assertRaises(signing.SigningError):
            signing.check_file(private, 16)

    def test_signing_operations_do_not_queue_on_a_busy_store(self):
        store = self.make_store()
        with signing.store_lock(store):
            with self.assertRaisesRegex(signing.SigningError, "active"):
                with signing.store_lock(store):
                    self.fail("A concurrent operation acquired the lock")
        with signing.store_lock(store):
            pass

    def test_signing_failure_or_interruption_still_relocks(self):
        store = self.make_store()
        application = self.project / "synthetic-executable"
        application.write_bytes(b"synthetic")
        for failure in (OSError("synthetic I/O failure"), KeyboardInterrupt(), signing.SigningError("synthetic failure")):
            with self.subTest(failure=type(failure).__name__):
                with mock.patch.object(signing, "signing_store", return_value=store), \
                     mock.patch.object(signing, "check_store_files", return_value="0" * 40), \
                     mock.patch.object(signing, "compile_helper", return_value=Path("synthetic-helper")), \
                     mock.patch.object(signing, "keychain_operation") as keychain, \
                     mock.patch.object(signing, "run_tool", side_effect=failure):
                    with self.assertRaises(type(failure)):
                        signing.sign(self.project, application)
                    self.assertEqual([call.args[1] for call in keychain.call_args_list], ["unlock", "lock"])

    def test_build_rejects_symlinked_staging_or_destination_before_writes(self):
        for relative in ("dist", ".tools/tmp"):
            with self.subTest(directory=relative):
                project = self.project / relative.replace("/", "-").replace(".", "directory")
                scripts = project / "scripts"
                scripts.mkdir(parents=True)
                (project / ".tools").mkdir(mode=0o700)
                shutil.copy2(PROJECT_DIRECTORY / "scripts/build-app.sh", scripts / "build-app.sh")
                (scripts / "sign-app.py").write_text("import sys\nsys.exit(0)\n")
                (project / "packaging").mkdir()
                shutil.copy2(PROJECT_DIRECTORY / "packaging/Info.plist", project / "packaging/Info.plist")
                swift_builder = scripts / "build-swift.sh"
                swift_builder.write_text('#!/bin/sh\nproject=$(dirname "$(dirname "$0")")\n'
                                         'touch "$project/swift-was-called"\n'
                                         'mkdir -p "$project/.tools/build/release"\n'
                                         'printf synthetic > "$project/.tools/build/release/switch-lang"\n')
                swift_builder.chmod(0o700)
                outside = self.project / (project.name + "-outside")
                outside.mkdir(mode=0o700)
                (outside / "keep").write_bytes(b"unchanged")
                (project / relative).symlink_to(outside)
                result = subprocess.run(["/bin/sh", str(scripts / "build-app.sh")], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"symbolic link", result.stderr)
                self.assertFalse((project / "swift-was-called").exists())
                self.assertEqual({path.name for path in outside.iterdir()}, {"keep"})

    def test_build_does_not_compile_or_replace_app_without_identity(self):
        scripts = self.project / "scripts"
        scripts.mkdir()
        for filename in ("build-app.sh", "sign-app.py"):
            shutil.copy2(PROJECT_DIRECTORY / "scripts" / filename, scripts / filename)
        swift_builder = scripts / "build-swift.sh"
        swift_builder.write_text('#!/bin/sh\ntouch "$(dirname "$0")/swift-was-called"\nexit 0\n')
        swift_builder.chmod(0o700)
        application = self.project / "dist/Switch Lang.app"
        application.mkdir(parents=True)
        (application / "keep-existing-bundle").write_bytes(b"unchanged")
        result = subprocess.run(["/bin/sh", str(scripts / "build-app.sh")], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"not initialized", result.stderr)
        self.assertFalse((scripts / "swift-was-called").exists())
        self.assertEqual((application / "keep-existing-bundle").read_bytes(), b"unchanged")

    def test_swift_build_rejects_symlinked_outputs_before_compilation(self):
        for relative in (".tools/build", ".tools/build/release/AtomicSupport.o", ".tools/build/release/switch-lang"):
            with self.subTest(destination=relative):
                project = self.project / relative.replace("/", "-")
                scripts = project / "scripts"
                scripts.mkdir(parents=True)
                (project / ".tools").mkdir(mode=0o700)
                shutil.copy2(PROJECT_DIRECTORY / "scripts/build-swift.sh", scripts / "build-swift.sh")
                outside = self.project / (project.name + "-outside")
                outside.mkdir(mode=0o700)
                (outside / "keep").write_bytes(b"unchanged")
                destination = project / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.symlink_to(outside if relative == ".tools/build" else outside / "keep")
                result = subprocess.run(["/bin/sh", str(scripts / "build-swift.sh")], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"symbolic link", result.stderr)
                self.assertEqual({path.name for path in outside.iterdir()}, {"keep"})
                self.assertEqual((outside / "keep").read_bytes(), b"unchanged")


class SigningIdentityTests(unittest.TestCase):
    """Requires explicit init first. No GUI, permission requests, or input."""

    @classmethod
    def setUpClass(cls):
        cls.identity = signing.check(PROJECT_DIRECTORY)

    def test_fresh_initialization_is_private_and_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="signing-init-", dir=PROJECT_DIRECTORY / ".tools/tmp") as directory:
            project = Path(directory)
            (project / "scripts").mkdir()
            shutil.copy2(PROJECT_DIRECTORY / "scripts/signing-keychain.m", project / "scripts/signing-keychain.m")
            identity = signing.initialize(project)
            store = signing.signing_store(project)
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in store.iterdir()))
            self.assertEqual(identity, signing.initialize(project))

    def test_different_app_versions_share_strong_identity_and_reject_foreign_or_changed_code(self):
        search_before = signing.run_tool(["/usr/bin/security", "list-keychains", "-d", "user"])
        default_before = signing.run_tool(["/usr/bin/security", "default-keychain", "-d", "user"])
        with tempfile.TemporaryDirectory(prefix="signing-integration-", dir=PROJECT_DIRECTORY / ".tools/tmp") as directory:
            applications = []
            hashes = []
            requirements = []
            for version in (1, 2, 3):
                application = Path(directory) / f"Version{version}.app"
                executable = application / "Contents/MacOS/signing-fixture"
                executable.parent.mkdir(parents=True)
                with (application / "Contents/Info.plist").open("wb") as destination:
                    plistlib.dump({"CFBundleIdentifier": signing.BUNDLE_IDENTIFIER,
                                   "CFBundleExecutable": "signing-fixture", "CFBundlePackageType": "APPL",
                                   "CFBundleVersion": str(version)}, destination)
                signing.run_tool(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-x", "c", "-", "-o", str(executable)],
                                 input=f"int main(void) {{ return {version}; }}\n".encode())
                if version < 3:
                    signing.sign(PROJECT_DIRECTORY, application)
                    output = subprocess.run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(application)],
                                            capture_output=True, check=True)
                    lines = (output.stdout + output.stderr).decode().splitlines()
                    requirements.append(next(line.removeprefix("designated => ") for line in lines
                                             if line.startswith("designated => ")))
                    hashes.append(next(line for line in lines if line.startswith("CDHash=")))
                else:
                    signing.run_tool(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                                      signing.BUNDLE_IDENTIFIER, str(application)])
                applications.append(application)
            self.assertNotEqual(hashes[0], hashes[1])
            self.assertEqual(requirements[0], requirements[1])
            self.assertIn(f'certificate leaf = H"{self.identity}"', requirements[0])
            for application, requirement in zip(applications, reversed(requirements)):
                signing.run_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", f"-R={requirement}", str(application)])
            refused = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", f"-R={requirements[0]}",
                                      str(applications[2])], capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            with (applications[1] / "Contents/Info.plist").open("ab") as destination:
                destination.write(b"\n<!-- unsigned change -->\n")
            changed = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                      str(applications[1])], capture_output=True)
            self.assertNotEqual(changed.returncode, 0)
        self.assertTrue(search_before == signing.run_tool(["/usr/bin/security", "list-keychains", "-d", "user"]),
                        "User search list changed")
        self.assertTrue(default_before == signing.run_tool(["/usr/bin/security", "default-keychain", "-d", "user"]),
                        "Default keychain changed")
        store = signing.signing_store(PROJECT_DIRECTORY)
        self.assertEqual(self.identity, signing.initialize(PROJECT_DIRECTORY))
        names = {path.name for path in store.iterdir()}
        self.assertTrue({"password", "certificate.der", "local-signing.keychain-db", "operation.lock"}.issubset(names))
        self.assertFalse(any(path.suffix in (".pem", ".p12") or path.is_dir() for path in store.iterdir()))
        # Security.framework may also retain its own empty .fl* lock file.
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in store.iterdir()))


if __name__ == "__main__":
    unittest.main()
