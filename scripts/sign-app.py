#!/usr/bin/env python3
"""Workspace-only signing. Never creates identities implicitly during a build."""

import argparse
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import tempfile

PROJECT_DIRECTORY = Path(__file__).resolve().parent.parent
BUNDLE_IDENTIFIER = "local.switch-lang.app"
CERTIFICATE_CONFIGURATION = b"""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Switch Lang Local Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
"""


class SigningError(Exception):
    pass


def run_tool(arguments, **options):
    options.setdefault("umask", 0o077)
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=90, **options)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SigningError(f"{Path(arguments[0]).name}: {type(error).__name__}") from error
    if result.returncode:
        # Passwords are file-descriptor input, never arguments or command output.
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise SigningError(f"{Path(arguments[0]).name} failed ({result.returncode}): {detail}")
    return result.stdout


def check_directory(path, private):
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise SigningError("Local signing is not initialized. Run: python3 scripts/sign-app.py init") from error
    forbidden = 0o077 if private else 0o022
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & forbidden):
        raise SigningError(f"Unsafe signing directory: {path}")


def check_file(path, maximum_size, read_contents=True):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as error:
        raise SigningError(f"Missing or unsafe signing file: {path.name}") from error
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or not 0 < metadata.st_size <= maximum_size):
            raise SigningError(f"Unsafe signing file: {path.name}")
        return source.read(maximum_size + 1) if read_contents else None


def signing_store(project_directory):
    tools = project_directory / ".tools"
    check_directory(tools, private=False)
    store = tools / "signing"
    # Apple's legacy keychain creation treats this substring as a login keychain.
    if "/login.keychain" in str(store):
        raise SigningError("Workspace path must not contain /login.keychain")
    check_directory(store, private=True)
    return store


def check_store_files(store):
    password = check_file(store / "password", 64)
    if len(password) != 64 or any(character not in b"0123456789abcdef" for character in password):
        raise SigningError("Invalid local signing password file; identity was not regenerated")
    certificate = check_file(store / "certificate.der", 16384)
    check_file(store / "local-signing.keychain-db", 16 * 1024 * 1024, read_contents=False)
    run_tool(["/usr/bin/openssl", "x509", "-inform", "DER", "-in",
              str(store / "certificate.der"), "-checkend", "0", "-noout"])
    return hashlib.sha1(certificate).hexdigest()


@contextlib.contextmanager
def store_lock(store):
    descriptor = os.open(store / "operation.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1
                or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise SigningError("Unsafe local signing lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SigningError("Another local signing operation is active") from error
        yield
    finally:
        os.close(descriptor)


def compile_helper(project_directory):
    tools = project_directory / ".tools"
    check_directory(tools, private=False)
    with tempfile.TemporaryDirectory(prefix="signing-helper-", dir=tools) as directory:
        temporary = Path(directory) / "signing-keychain"
        run_tool(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=11.0",
                  "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
                  str(project_directory / "scripts/signing-keychain.m"),
                  "-framework", "Foundation", "-framework", "Security", "-o", str(temporary)],
                 env={**os.environ, "TMPDIR": str(directory)})
        helper = tools / "signing-keychain"
        os.replace(temporary, helper)
    return helper


def keychain_operation(helper, operation, store, *arguments):
    run_tool([str(helper), operation, str(store), *map(str, arguments)])
    # Security.framework can create auxiliary lock files with explicit 0644,
    # ignoring the child's umask. Keep every generated regular file private.
    for path in store.iterdir():
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            check_directory(path, private=True)
            continue
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            metadata = os.fstat(descriptor)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1):
                raise SigningError("Unsafe generated keychain file")
            os.fchmod(descriptor, 0o600)
        finally:
            os.close(descriptor)


def initialize(project_directory):
    tools = project_directory / ".tools"
    tools.mkdir(exist_ok=True)
    check_directory(tools, private=False)
    store = tools / "signing"
    if "/login.keychain" in str(store):
        raise SigningError("Workspace path must not contain /login.keychain")
    if store.exists() or store.is_symlink():
        # Existing or incomplete identities are never silently overwritten.
        return check(project_directory)
    helper = compile_helper(project_directory)
    store.mkdir(mode=0o700)
    with store_lock(store):
        descriptor = os.open(store / "password", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        with os.fdopen(descriptor, "w") as destination:
            destination.write(secrets.token_hex(32))
        with tempfile.TemporaryDirectory(prefix="import-", dir=store) as directory:
            temporary = Path(directory)
            tool_environment = {**os.environ, "TMPDIR": str(temporary), "RANDFILE": str(temporary / "random-seed")}
            with (store / "password").open("rb") as password:
                run_tool(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                          "-sha256", "-days", "3650", "-config", "/dev/stdin",
                          "-keyout", str(temporary / "key.pem"), "-out", str(temporary / "certificate.pem"),
                          "-passout", f"fd:{password.fileno()}"],
                         input=CERTIFICATE_CONFIGURATION, pass_fds=(password.fileno(),), env=tool_environment)
            with (store / "password").open("rb") as password_in, (store / "password").open("rb") as password_out:
                run_tool(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(temporary / "key.pem"),
                          "-in", str(temporary / "certificate.pem"), "-out", str(temporary / "identity.p12"),
                          "-passin", f"fd:{password_in.fileno()}", "-passout", f"fd:{password_out.fileno()}"],
                         pass_fds=(password_in.fileno(), password_out.fileno()), env=tool_environment)
            certificate = run_tool(["/usr/bin/openssl", "x509", "-in", str(temporary / "certificate.pem"),
                                    "-outform", "DER"])
            descriptor = os.open(store / "certificate.der", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
            with os.fdopen(descriptor, "wb") as destination:
                destination.write(certificate)
            keychain_operation(helper, "create", store, temporary)
        identity = check_store_files(store)
    print(f"Created permanent local signing identity: {identity}")
    return identity


def check(project_directory):
    store = signing_store(project_directory)
    with store_lock(store):
        identity = check_store_files(store)
        helper = compile_helper(project_directory)
        keychain_operation(helper, "check", store)
    return identity


def requirement_for(identity):
    return f'identifier "{BUNDLE_IDENTIFIER}" and certificate leaf = H"{identity}"'


def sign(project_directory, application):
    application = application.resolve(strict=True)
    if not application.is_relative_to(project_directory.resolve()):
        raise SigningError("Signing target must stay inside this workspace")
    store = signing_store(project_directory)
    with store_lock(store):
        identity = check_store_files(store)
        helper = compile_helper(project_directory)
        failure = None
        try:
            keychain_operation(helper, "unlock", store)
            run_tool(["/usr/bin/codesign", "--force", "--timestamp=none", "--keychain",
                      str(store / "local-signing.keychain-db"), "--identifier", BUNDLE_IDENTIFIER,
                      f"-r=designated => {requirement_for(identity)}", "--sign", identity, str(application)])
            run_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                      f"-R={requirement_for(identity)}", str(application)])
        except BaseException as error:
            # Re-lock even on interruption; re-raise the original failure below.
            failure = error
        try:
            keychain_operation(helper, "lock", store)
        except (SigningError, OSError) as error:
            if failure is None:
                raise
            print(f"Additionally, keychain relock failed: {error}", file=sys.stderr)
        if failure is not None:
            raise failure
    print(f"Signed with permanent local identity: {identity}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "check", "sign"))
    parser.add_argument("application", nargs="?", type=Path)
    arguments = parser.parse_args()
    if (arguments.action == "sign") != (arguments.application is not None):
        parser.error("only sign requires an application path")
    try:
        if arguments.action == "init":
            initialize(PROJECT_DIRECTORY)
        elif arguments.action == "check":
            identity = check(PROJECT_DIRECTORY)
            print(f"Permanent local signing identity ready: {identity}")
        else:
            sign(PROJECT_DIRECTORY, arguments.application)
    except (SigningError, OSError) as error:
        print(f"Local signing failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
