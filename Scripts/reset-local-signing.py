#!/usr/bin/env python3
"""Rotate only CodexHarbor's local signing identity, preserving old keys.

The active profile is changed atomically only after a real signing probe.
Secrets are never printed, passed in process arguments, or stored in the repo.
The new certificate is trusted in the user domain for code signing only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import uuid

SCRIPTS = Path(__file__).resolve().parent
ROOT = Path.home() / "Library/Application Support/CodexHarbor/CodeSigning"
PROFILE = ROOT / "profile.json"
SECURITY = "/usr/bin/security"
SWIFT = "/usr/bin/swift"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"


class Failure(Exception):
    pass


def execute(args, *, timeout=45, data=None, quiet=False):
    # Never include command arguments or child output in secret-handling errors.
    try:
        result = subprocess.run([str(a) for a in args], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Failure(f"{Path(args[0]).name} timed out") from None
    if result.returncode:
        if quiet:
            raise Failure(f"{Path(args[0]).name} failed ({result.returncode})")
        raise Failure(f"{Path(args[0]).name} failed ({result.returncode}): "
                      + result.stderr.decode(errors="replace")[-500:])
    return result.stdout


def private(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Failure("Unsafe permissions or ownership: " + path.name)
    if not directory and info.st_nlink != 1:
        raise Failure("Unexpected hard link: " + path.name)


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def atomic_profile(data, expected):
    if PROFILE.exists():
        private(PROFILE)
        if PROFILE.read_bytes() != expected:
            raise Failure("Active profile changed concurrently")
    elif expected is not None:
        raise Failure("Active profile disappeared")
    temp = ROOT / (".profile-" + str(uuid.uuid4()))
    try:
        write_private(temp, data)
        os.replace(temp, PROFILE)
        fd = os.open(ROOT, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        temp.unlink(missing_ok=True)


def generation_path(name):
    if not name.startswith("generation-"):
        raise Failure("Invalid generation name")
    try:
        uuid.UUID(name[len("generation-"):])
    except ValueError:
        raise Failure("Invalid generation UUID") from None
    path = ROOT / name
    private(path, directory=True)
    return path


def configure_partition(generation):
    # security's interactive input is captured and discarded, not logged.
    # The password is never in argv. Only this newly-created keychain is
    # targeted, and the ACL is limited to Apple signing-tool partitions.
    password_path = generation / "keychain.password"
    private(password_path)
    password = password_path.read_text()
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", password):
        raise Failure("Unexpected new-generation password format")
    path = str(generation / "signing.keychain-db")
    if any(c in path for c in '"\\\n\r'):
        raise Failure("Unexpected keychain path")
    command = f'set-key-partition-list -S apple-tool:,apple: -s -t private -k "{password}" "{path}"\n'
    execute([SECURITY, "-i"], data=command.encode(), timeout=30, quiet=True)


def create(generation, original):
    previous = generation / "previous-profile.json"
    if original is not None:
        write_private(previous, original)
    write_private(generation / "keychain.password", secrets.token_urlsafe(32).encode())
    write_private(generation / "import.password", secrets.token_urlsafe(32).encode())
    cfg = generation / "certificate.cnf"
    write_private(cfg, (
        "[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = extensions\n"
        "[dn]\nCN = Codex Harbor Local Code Signing " + generation.name[-8:] + "\n"
        "[extensions]\nbasicConstraints = critical,CA:FALSE\n"
        "keyUsage = critical,digitalSignature\nextendedKeyUsage = codeSigning\n"
        "subjectKeyIdentifier = hash\n"
    ).encode())
    key = generation / "temporary-private.pem"
    cert = generation / "certificate.pem"
    p12 = generation / "identity.p12"
    try:
        execute([OPENSSL, "req", "-x509", "-newkey", "rsa:3072", "-nodes",
                 "-days", "3650", "-sha256", "-config", cfg, "-keyout", key, "-out", cert],
                timeout=60, quiet=True)
        key.chmod(0o600)
        execute([OPENSSL, "pkcs12", "-export", "-inkey", key, "-in", cert,
                 "-out", p12, "-passout", "file:" + str(generation / "import.password")],
                quiet=True)
        p12.chmod(0o600)
        execute([SWIFT, "-suppress-warnings", SCRIPTS / "create-local-signing-keychain.swift", generation], timeout=60)
    finally:
        # Never retain plaintext key material or transient PKCS#12.
        for path in (key, p12, generation / "import.password", cfg):
            path.unlink(missing_ok=True)
    keychain = generation / "signing.keychain-db"
    private(keychain)
    der = execute([OPENSSL, "x509", "-in", cert, "-outform", "DER"])
    identity = hashlib.sha1(der).hexdigest().upper()
    candidate = {"identity": identity, "keychainPath": str(keychain),
                 "passwordPath": str(generation / "keychain.password")}
    write_private(generation / "profile.json", (json.dumps(candidate, indent=2) + "\n").encode())
    print("New keychain created; original keychain and active profile retained", flush=True)


def verify_and_activate(generation):
    candidate_path = generation / "profile.json"
    private(candidate_path)
    data = candidate_path.read_bytes()
    candidate = json.loads(data)
    keychain = generation / "signing.keychain-db"
    if candidate["keychainPath"] != str(keychain) or candidate["passwordPath"] != str(generation / "keychain.password"):
        raise Failure("Unexpected candidate paths")
    original_path = generation / "previous-profile.json"
    original = original_path.read_bytes() if original_path.exists() else None
    if PROFILE.exists() and PROFILE.read_bytes() == data:
        print("Generation already active; verifying again", flush=True)
        original = data
    # Force a real locked-keychain recovery before trusting this generation.
    execute([SECURITY, "lock-keychain", keychain])
    execute([SWIFT, "-suppress-warnings", SCRIPTS / "unlock-local-signing.swift", candidate_path], timeout=60)
    configure_partition(generation)
    # Partition-list configuration must not invalidate the saved unlock secret.
    execute([SECURITY, "lock-keychain", keychain])
    execute([SWIFT, "-suppress-warnings", SCRIPTS / "unlock-local-signing.swift", candidate_path], timeout=60)
    identity = candidate["identity"]
    identities = execute([SECURITY, "find-identity", "-v", "-p", "codesigning", keychain]).decode()
    if identity not in identities:
        print("New certificate requires user-domain code-signing trust", flush=True)
        # No admin/system trust store and no SSL or arbitrary-purpose trust.
        execute([SECURITY, "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                 "-k", keychain, generation / "certificate.pem"], timeout=60)
    identities = execute([SECURITY, "find-identity", "-v", "-p", "codesigning", keychain]).decode()
    if identity not in identities:
        raise Failure("New identity is not valid for code signing; active profile unchanged")
    # Real signing probe, never sign the installed application.
    probe = generation / ("signing-probe-" + str(uuid.uuid4()))
    try:
        shutil.copyfile("/usr/bin/true", probe)
        probe.chmod(0o700)
        execute([CODESIGN, "--force", "--sign", identity, "--keychain", keychain,
                 "--identifier", "com.codexharbor.signing-probe", probe], timeout=30)
        execute([CODESIGN, "--verify", "--strict",
                 f'-R=identifier "com.codexharbor.signing-probe" and certificate leaf = H"{identity}"', probe])
    finally:
        probe.unlink(missing_ok=True)
    atomic_profile(data, original)
    print("PASS: persistent signature, exact certificate and identifier verified", flush=True)
    print("ACTIVE_GENERATION=" + generation.name, flush=True)
    print("Old profile backed up in previous-profile.json; old keys remain in place", flush=True)


def verify_active_binaries():
    private(PROFILE)
    candidate = json.loads(PROFILE.read_bytes())
    keychain = Path(candidate["keychainPath"])
    generation = generation_path(keychain.parent.name)
    if keychain != generation / "signing.keychain-db" or candidate["passwordPath"] != str(generation / "keychain.password"):
        raise Failure("Unexpected active keychain path")
    private(keychain)
    private(generation / "keychain.password")
    # Check the stored password actually unlocks the new keychain, rather
    # than relying on a previously unlocked session. Never lock old keys.
    execute([SECURITY, "lock-keychain", keychain])
    execute([SWIFT, "-suppress-warnings", SCRIPTS / "unlock-local-signing.swift", PROFILE], timeout=60)
    print("PASS: saved password unlocks the active generation after locking", flush=True)
    identity = candidate["identity"]
    binaries = {
        "CodexHarbor": "com.codexharbor.app",
        "HarborChatGPTAgent": "com.codexharbor.agent",
        "HarborUsageCardAgent": "com.codexharbor.usage-card-agent",
        "HarborProxyAgent": "com.codexharbor.proxy-agent",
    }
    import tempfile
    with tempfile.TemporaryDirectory(prefix="signing-verification-", dir=generation) as directory:
        for binary, identifier in binaries.items():
            source = SCRIPTS.parent / ".build" / "debug" / binary
            if not source.is_file():
                raise Failure("Build debug target first: " + binary)
            target = Path(directory) / binary
            shutil.copyfile(source, target)
            target.chmod(0o700)
            execute([CODESIGN, "--force", "--sign", identity, "--keychain", keychain,
                     "--identifier", identifier, target], timeout=60)
            execute([CODESIGN, "--verify", "--strict",
                     f'-R=identifier "{identifier}" and certificate leaf = H"{identity}"', target])
            print("PASS: " + binary + " signed and verified with active identity", flush=True)
    print("All four isolated binaries verified; installed app untouched", flush=True)


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--resume", metavar="GENERATION", help="Retry verification of an existing staged generation")
    modes.add_argument("--verify-active", action="store_true", help="Lock/unlock the active generation and sign four debug binary copies")
    args = parser.parse_args()
    os.umask(0o077)
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    private(ROOT, directory=True)
    if PROFILE.exists():
        private(PROFILE)
    lock = ROOT / ".rotation.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise Failure("Another rotation is in progress; inspect the lock before retrying") from None
    generation = None
    try:
        if args.verify_active:
            verify_active_binaries()
            return
        if args.resume:
            generation = generation_path(args.resume)
        else:
            original = PROFILE.read_bytes() if PROFILE.exists() else None
            generation = ROOT / ("generation-" + str(uuid.uuid4()))
            generation.mkdir(mode=0o700)
            print("STAGED_GENERATION=" + generation.name, flush=True)
            create(generation, original)
        verify_and_activate(generation)
    except Exception:
        if generation is not None:
            print("Staged generation retained: " + generation.name, flush=True)
        raise
    finally:
        lock.rmdir()


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print("Signing rotation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print("Signing rotation stopped: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
