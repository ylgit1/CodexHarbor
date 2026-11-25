#!/usr/bin/env python3
"""Temporary signed launchd/XPC fixture. Never installs the production job."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / ".build" / "debug" / "HarborProxyIPCFixture"


def run(args, timeout=15, check=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr[-800:]}")
    return result


def main():
    if not FIXTURE.is_file():
        raise RuntimeError("Build HarborProxyIPCFixture in debug configuration first")
    identity = os.environ.get("CODEX_HARBOR_SIGN_IDENTITY")
    keychain_args = []
    keychain = os.environ.get("CODEX_HARBOR_SIGN_KEYCHAIN")
    if keychain:
        if not identity or not Path(keychain).is_file():
            raise RuntimeError("Explicit signing keychain requires a file and identity")
        keychain_args = ["--keychain", keychain]
    profile = Path(os.environ.get("CODEX_HARBOR_SIGNING_PROFILE",
        str(Path.home() / "Library/Application Support/CodexHarbor/CodeSigning/profile.json")))
    if not identity and profile.is_file():
        run(["/usr/bin/swift", "-suppress-warnings", ROOT / "Scripts/unlock-local-signing.swift", profile], timeout=60)
        # Only the non-secret identity and keychain path are consumed here.
        values = json.loads(profile.read_text())
        identity = values["identity"]
        keychain = values["keychainPath"]
        keychain_args = ["--keychain", keychain]
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning",
                      *([keychain] if keychain else [])]).stdout
    matches = re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "([^"]+)"', identities, re.M)
    if not identity:
        local = [item for item in matches if item[1] == "Codex Harbor Local Code Signing"]
        if len(local) == 1:
            identity = local[0][0]
        elif len(matches) == 1:
            identity = matches[0][0]
        else:
            raise RuntimeError("Select a single persistent signing identity; no ad-hoc fallback")
    if identity == "-":
        raise RuntimeError("Persistent signing identity required")
    domain = f"gui/{os.getuid()}"
    if run(["/bin/launchctl", "print", domain], check=False).returncode != 0:
        domain = f"user/{os.getuid()}"
    label = "com.codexharbor.proxy-ipc-test." + str(uuid.uuid4())
    service = domain + "/" + label

    with tempfile.TemporaryDirectory(prefix="harbor-ipc-test-") as directory:
        root = Path(directory)
        root.chmod(0o700)
        server, client, wrong, adhoc = [root / name for name in ["server", "client", "wrong", "adhoc"]]
        for path, signer, identifier in [
            (server, identity, "com.codexharbor.proxy-agent"),
            (client, identity, "com.codexharbor.app"),
            (wrong, identity, "com.codexharbor.proxy-ipc-test.wrong"),
            (adhoc, "-", "com.codexharbor.app"),
        ]:
            shutil.copy2(FIXTURE, path)
            run(["/usr/bin/codesign", "--force", "--sign", signer,
                 *(keychain_args if signer != "-" else []), "--identifier", identifier, path], timeout=30)
            run(["/usr/bin/codesign", "--verify", "--strict", path])
        for port in range(28000, 28999, 2):
            try:
                with socket.socket() as a, socket.socket() as b:
                    a.bind(("127.0.0.1", port))
                    b.bind(("127.0.0.1", port + 1))
                break
            except OSError:
                continue
        else:
            raise RuntimeError("No isolated port pair")
        marker = root / "proxy-agent-active"
        plist = root / "fixture.plist"
        plist.write_bytes(plistlib.dumps({
            "Label": label,
            "ProgramArguments": [str(server), "server", label, str(root)],
            "MachServices": {label: True},
            "KeepAlive": {"PathState": {str(marker): True}},
            "RunAtLoad": False, "ProcessType": "Background", "ThrottleInterval": 1,
            "StandardOutPath": str(root / "stdout.log"),
            "StandardErrorPath": str(root / "stderr.log"),
        }))

        def rpc(binary, command, expected=True):
            result = run([binary, "client", label, root, command, str(port)], timeout=12, check=False)
            if expected:
                if result.returncode:
                    raise RuntimeError(f"Authenticated RPC failed: {result.returncode} {result.stdout[-400:]} {result.stderr[-400:]}")
                return json.loads(result.stdout)
            # macOS can terminate a peer that fails an XPC signing requirement
            # with SIGTRAP instead of returning an ordinary RPC error.
            # The caller also checks that the service remained unchanged.
            assert result.returncode in (2, 3, -signal.SIGTRAP), f"Unexpected rejection result: {result.returncode}"
            assert not result.stdout.lstrip().startswith("{"), "Rejected peer received a successful snapshot"
            print("Rejected fixture client status=" + str(result.returncode), flush=True)

        def pid():
            info = run(["/bin/launchctl", "print", service], check=False)
            found = re.search(r"^\s*pid = (\d+)\s*$", info.stdout, re.M)
            return int(found.group(1)) if found else None

        def listening():
            for p in [port, port + 1]:
                try:
                    with socket.create_connection(("127.0.0.1", p), timeout=0.3):
                        pass
                except OSError:
                    return False
            return True

        registered = False
        try:
            run(["/bin/launchctl", "bootstrap", domain, plist])
            registered = True
            snapshot = rpc(client, "open")
            assert snapshot["gateways"][0]["port"] == port and snapshot["gateways"][0]["ready"]
            assert marker.is_file() and listening()
            old_pid = pid()
            assert old_pid is not None
            print("PASS: signed mutual XPC, journal and fixed listener creation", flush=True)
            rpc(wrong, "stop", expected=False)
            assert rpc(client, "inspect")["gateways"][0]["ready"] and listening() and marker.is_file()
            rpc(adhoc, "stop", expected=False)
            assert rpc(client, "inspect")["gateways"][0]["ready"] and listening() and marker.is_file()
            print("PASS: wrong signing identifier and ad-hoc client cannot stop fixture", flush=True)
            # Exact temporary job label only, never the production job.
            run(["/bin/launchctl", "kill", "SIGKILL", service])
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                new_pid = pid()
                if new_pid and new_pid != old_pid and listening():
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("Fixture launchd restart timed out")
            snapshot = rpc(client, "inspect")
            assert snapshot["gateways"][0]["ready"]
            assert not snapshot["gateways"][0]["healthy"]
            assert snapshot["gateways"][0].get("routingBackendID") is None
            print("PASS: launchd restarted killed fixture, signed XPC reconnected, fixed ports restored fail-closed", flush=True)
            snapshot = rpc(client, "stop")
            assert not snapshot["gateways"] and not marker.exists()
            print("PASS: explicit stop removed listener ownership and keepalive marker", flush=True)
        finally:
            if registered:
                run(["/bin/launchctl", "bootout", service], check=False)
            info = run(["/bin/launchctl", "print", service], check=False)
            if info.returncode == 0:
                raise RuntimeError("Temporary job still registered: " + service)
        print("PASS: temporary LaunchAgent unloaded; production job untouched", flush=True)


if __name__ == "__main__":
    main()
