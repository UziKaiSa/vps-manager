"""Exercise the generated relay with real nginx and controlled TLS origins.

Run on Linux with VPS_TLS_TEST_DIR pointing inside a registered private task
directory. No system configuration or public service ports are changed.
"""
import base64
import hashlib
import http.client
import http.server
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "vps-manager.sh"


def function(name):
    source = SCRIPT.read_text()
    start = re.search(r"(?m)^" + re.escape(name) + r"\(\) \{", source).start()
    following = re.search(r"(?m)^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{", source[start + len(name) + 4:])
    end = start + len(name) + 4 + following.start() if following else len(source)
    return source[start:end]


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@unittest.skipUnless(shutil.which("nginx") and shutil.which("openssl") and os.environ.get("VPS_TLS_TEST_DIR"),
                     "requires nginx, openssl and an explicitly owned test directory")
class RelayTLS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ["VPS_TLS_TEST_DIR"]).resolve()
        cls.root.mkdir(parents=True, mode=0o700, exist_ok=False)
        cls.nginx = shutil.which("nginx")
        cls.cases = []
        cls.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                    "-keyout", "ca.key", "-out", "ca.pem", "-subj", "/CN=Relay fixture CA",
                    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        for name, dns in [("good", "relay.test"), ("wrong-name", "wrong.test")]:
            cls.openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", name + ".key",
                        "-out", name + ".csr", "-subj", "/CN=" + dns)
            (cls.root / (name + ".ext")).write_text("subjectAltName=DNS:" + dns + "\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n")
            cls.openssl("x509", "-req", "-in", name + ".csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                        "-CAcreateserial", "-days", "2", "-out", name + ".pem", "-extfile", name + ".ext")
        cls.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                    "-keyout", "other-ca.key", "-out", "other-ca.pem", "-subj", "/CN=Unrelated CA",
                    "-addext", "basicConstraints=critical,CA:TRUE")

    @classmethod
    def openssl(cls, *args):
        subprocess.run(["openssl", *args], cwd=cls.root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def generate(self, case, ca, port, fail_ca=False):
        case.mkdir(mode=0o700)
        (case / "logs").mkdir()
        cfg = case / "relay.conf"
        if fail_ca:
            cfg.write_text("existing configuration must remain intact")
        q = shlex.quote
        shell = "\n".join([
            "set -eu", "umask 077", "WORK_DIR=" + q(str(case)), "KOMARI_ACCESS_CONFIG=" + q(str(cfg)),
            "KOMARI_ACCESS_LISTEN_PORT=" + str(port), function("komari_write_access_proxy"),
            "komari_access_ca_bundle() { " + ("return 1" if fail_ca else "printf '%s\\n' " + q(str(ca))) + "; }",
            "ensure_work_dir() { :; }", "ip() { printf 'default fixture\\n'; }", "log() { :; }", "warn() { :; }",
            "nginx() { " + q(self.nginx) + " -p " + q(str(case) + "/") + ' "$@"; }',
            "komari_write_access_proxy relay.test fixture-id fixture-secret",
        ])
        result = subprocess.run(["bash", "-c", shell], capture_output=True)
        if fail_ca:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cfg.read_text(), "existing configuration must remain intact")
            return
        self.assertEqual(result.returncode, 0, "generated nginx syntax failed")
        self.assertEqual(cfg.stat().st_mode & 0o777, 0o600)
        return cfg

    def check_origin(self, label, cert, trusted_ca, expected):
        received = []

        class Origin(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                received.append(self.headers.get("CF-Access-Client-Id") == "fixture-id" and
                                self.headers.get("CF-Access-Client-Secret") == "fixture-secret")
                if self.headers.get("Upgrade", "").lower() == "websocket":
                    key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                    self.send_response(101)
                    self.send_header("Upgrade", "websocket")
                    self.send_header("Connection", "Upgrade")
                    self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
                    self.end_headers()
                    self.wfile.write(b"\x81\x09TLS_WS_OK")
                    self.wfile.flush()
                    return
                body = b"TLS_HTTP_OK"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root / (cert + ".pem"), self.root / (cert + ".key"))
        origin.socket = context.wrap_socket(origin.socket, server_side=True)
        thread = threading.Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        port = available_port()
        case = self.root / label
        cfg = self.generate(case, self.root / trusted_ca, port)
        text = cfg.read_text().replace("pid /run/vps-manager-komari-access.pid;", "pid " + str(case / "nginx.pid") + ";")
        text = text.replace("error_log /dev/null emerg;", "error_log " + str(case / "error.log") + " info;")
        # Test-only dial target: keep the generated SNI/name verification intact.
        text = text.replace("set $komari_upstream https://relay.test;", "set $komari_upstream https://127.0.0.1:" + str(origin.server_port) + ";")
        cfg.write_text(text)
        process = subprocess.Popen([self.nginx, "-p", str(case) + "/", "-c", str(cfg), "-g", "daemon off;"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 4
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), .1):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        self.fail("isolated nginx readiness failed")
                    time.sleep(.05)
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/api/clients/report")
            response = conn.getresponse()
            self.assertEqual(response.status, expected)
            body = response.read()
            conn.close()
            if expected == 200:
                self.assertEqual(body, b"TLS_HTTP_OK")
                self.assertEqual(received, [True])
                with socket.create_connection(("127.0.0.1", port), 5) as sock:
                    sock.sendall(b"GET /api/clients/v2/rpc HTTP/1.1\r\nHost: relay.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
                    wire = b""
                    while b"TLS_WS_OK" not in wire:
                        part = sock.recv(4096)
                        if not part:
                            break
                        wire += part
                    self.assertIn(b"101 Switching Protocols", wire)
                    self.assertIn(b"TLS_WS_OK", wire)
                self.assertEqual(received, [True, True])
            else:
                self.assertEqual(received, [])
                error = (case / "error.log").read_text()
                self.assertTrue("certificate verify error" in error or "certificate does not match" in error)
            self.cases.append({"case": label, "status": expected, "passed": True})
        finally:
            process.terminate()
            process.wait(timeout=5)
            origin.shutdown()
            origin.server_close()
            thread.join(timeout=2)

    def test_valid_chain_and_websocket(self):
        self.check_origin("valid-chain", "good", "ca.pem", 200)

    def test_untrusted_chain_rejected(self):
        self.check_origin("untrusted-chain", "good", "other-ca.pem", 502)

    def test_wrong_hostname_rejected(self):
        self.check_origin("wrong-hostname", "wrong-name", "ca.pem", 502)

    def test_missing_ca_preserves_existing_config(self):
        self.generate(self.root / "missing-ca", None, available_port(), fail_ca=True)


if __name__ == "__main__":
    os.umask(0o077)
    unittest.main()
