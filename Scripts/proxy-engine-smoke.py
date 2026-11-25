#!/usr/bin/env python3
"""Offline runtime smoke test of the bundled engines, not a production install.

All traffic goes to a temporary local HTTP service through a local VLESS
server. The test uses only OS-assigned loopback ports and private temporary
configuration. No subscription, external network, system proxy or agent.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
ARCH = "arm64" if platform.machine() == "arm64" else "x86_64"
XRAY = ROOT / "Resources" / "Xray" / ARCH / "xray"
MIHOMO = ROOT / "Resources" / "Mihomo" / ARCH / "mihomo"
MARKER = b"harbor-offline-engine-fixture"
ENV = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
ENV["XRAY_LOCATION_ASSET"] = str(XRAY.parent)


class Handler(http.server.BaseHTTPRequestHandler):
    hits = 0
    lock = threading.Lock()

    def do_GET(self):
        with self.lock:
            Handler.hits += 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(MARKER)))
        self.end_headers()
        self.wfile.write(MARKER)

    def log_message(self, *_):
        pass


def free_ports(count):
    # Keep every selected port reserved until all values are distinct.
    with contextlib.ExitStack() as stack:
        sockets = [stack.enter_context(socket.socket()) for _ in range(count)]
        for s in sockets:
            s.bind(("127.0.0.1", 0))
        return [s.getsockname()[1] for s in sockets]


def config(path, data):
    path.write_text(json.dumps(data))
    path.chmod(0o600)
    return path


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def start(stack, args, log, ports):
    output = stack.enter_context(log.open("wb"))
    child = subprocess.Popen([str(x) for x in args], env=ENV,
                             stdin=subprocess.DEVNULL, stdout=output,
                             stderr=subprocess.STDOUT)
    stack.callback(stop, child)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError("Engine exited: " + log.read_text(errors="replace")[-1200:])
        try:
            for p in ports:
                with socket.create_connection(("127.0.0.1", p), timeout=0.2):
                    pass
            return child
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("Engine listener timeout: " + log.name)


def request(port, scheme, target, expected=True):
    result = subprocess.run(
        ["/usr/bin/curl", "--disable", "--silent", "--fail",
         "--noproxy", "", "--proxy", f"{scheme}://127.0.0.1:{port}",
         "--connect-timeout", "3", "--max-time", "10", target],
        env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if expected:
        assert result.returncode == 0 and result.stdout == MARKER, (scheme, result.returncode)
    else:
        assert result.returncode != 0, "Unexpected direct fallback"


def main():
    assert XRAY.is_file() and MIHOMO.is_file(), "Bundled engines missing"
    with tempfile.TemporaryDirectory(prefix="harbor-engine-smoke-") as directory, contextlib.ExitStack() as stack:
        root = Path(directory)
        root.chmod(0o700)
        web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        stack.callback(web.server_close)
        thread = threading.Thread(target=web.serve_forever, daemon=True)
        thread.start()
        stack.callback(web.shutdown)
        remote, xhttp, xsocks, mhttp, msocks = free_ports(5)
        target = f"http://127.0.0.1:{web.server_port}/"
        credential = str(uuid.uuid4())
        server_config = config(root / "server.json", {
            "log": {"loglevel": "warning"},
            "inbounds": [{"listen": "127.0.0.1", "port": remote, "protocol": "vless",
                          "settings": {"clients": [{"id": credential}], "decryption": "none"}}],
            "outbounds": [{"protocol": "freedom"}],
        })
        def server():
            return start(stack, [XRAY, "run", "-config", server_config], root / "server.log", [remote])
        upstream = server()
        xconfig = config(root / "client.json", {
            "log": {"loglevel": "warning"},
            "inbounds": [
                {"listen": "127.0.0.1", "port": xhttp, "protocol": "http"},
                {"listen": "127.0.0.1", "port": xsocks, "protocol": "socks", "settings": {"udp": True}}],
            "outbounds": [{"tag": "proxy", "protocol": "vless",
                           "settings": {"vnext": [{"address": "127.0.0.1", "port": remote,
                                                   "users": [{"id": credential, "encryption": "none"}]}]}}],
        })
        start(stack, [XRAY, "run", "-config", xconfig], root / "xray.log", [xhttp, xsocks])
        mconfig = config(root / "mihomo.json", {
            "port": mhttp, "socks-port": msocks, "bind-address": "127.0.0.1",
            "allow-lan": False, "mode": "rule", "log-level": "warning",
            "proxies": [{"name": "fixture", "type": "vless", "server": "127.0.0.1", "port": remote,
                         "uuid": credential, "tls": False, "udp": True, "network": "tcp"}],
            "rules": ["MATCH,fixture"],
        })
        start(stack, [MIHOMO, "-d", root, "-f", mconfig], root / "mihomo.log", [mhttp, msocks])
        routes = [(xhttp, "http"), (xsocks, "socks5h"), (mhttp, "http"), (msocks, "socks5h")]
        for port, scheme in routes:
            request(port, scheme, target)
        print("PASS: real Xray and Mihomo HTTP/SOCKS5 through controlled local VLESS server", flush=True)
        stop(upstream)
        with Handler.lock:
            before = Handler.hits
        for port, scheme in routes:
            request(port, scheme, target, expected=False)
        with Handler.lock:
            assert Handler.hits == before, "Unexpected traffic reached the HTTP target"
        print("PASS: upstream termination fails closed for all four proxy paths", flush=True)
        upstream = server()
        for port, scheme in routes:
            request(port, scheme, target)
        print("PASS: same upstream address restored; all four paths recover", flush=True)
    print("PASS: all fixture engines terminated and temporary configuration removed", flush=True)


if __name__ == "__main__":
    main()
