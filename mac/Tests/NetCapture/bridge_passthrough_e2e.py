"""End-to-end check of when a handshake failure stops counting (docs/packet-capture/TLS-FINGERPRINT.md §7.2), on the
real bundled engine and the bridge in this checkout:

  python3 -I mac/Tests/NetCapture/bridge_passthrough_e2e.py <mac/Vendor/mitmproxy.noindex or Baobox.app/Contents/Helpers>/mitmproxy.app/Contents/MacOS/mitmdump

A local HTTPS origin (self-signed, made with openssl in a temporary folder) sits behind the engine on 127.0.0.1:19660/19661.
Two clients send the same ClientHello (same fingerprint) and differ only in whether they trust Baobox's certificate --
the same kind of client before and after the certificate is installed. Needs openssl and Python 3 on the machine.
Prints one line per check and "E2E OK" / "E2E FAILED".
"""
import json, os, socket, ssl, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
MITM = sys.argv[1]
BRIDGE = os.path.join(HERE, "..", "..", "Sources", "Resources", "NetCapture", "baobox_bridge.py")
PROXY, ORIGIN = 19660, 19661
E = tempfile.mkdtemp(prefix="baobox-e2e-")
os.makedirs(E + "/conf")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", E + "/origin.key",
                "-out", E + "/origin.pem", "-days", "2", "-subj", "/CN=origin.test",
                "-addext", "subjectAltName=DNS:host1.test,DNS:host2.test,DNS:host3.test"],
               check=True, capture_output=True)

# ---- origin: HTTPS on 127.0.0.1:ORIGIN, self-signed for host1..3.test ----
octx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); octx.load_cert_chain(E + "/origin.pem", E + "/origin.key")
osock = socket.socket(); osock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); osock.bind(("127.0.0.1", ORIGIN)); osock.listen(50)
def serve():
    while True:
        c, _ = osock.accept()
        def one(c):
            try:
                s = octx.wrap_socket(c, server_side=True); s.recv(4096)
                s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"); s.close()
            except Exception:
                c.close()
        threading.Thread(target=one, args=(c,), daemon=True).start()
threading.Thread(target=serve, daemon=True).start()

# ---- engine ----
engine = subprocess.Popen([MITM, "--mode", "regular@127.0.0.1:%d" % PROXY, "--set", "confdir=" + E + "/conf",
                           "--set", "ssl_insecure=true", "-q", "-s", BRIDGE],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
events = []
def read():
    for line in engine.stdout:
        start = line.find("{")
        if start < 0: continue
        try: events.append(json.loads(line[start:]))
        except ValueError: pass
threading.Thread(target=read, daemon=True).start()
for _ in range(400):
    if any(e.get("event") == "running" for e in events): break
    time.sleep(0.1)
else:
    engine.kill(); print("engine did not start", events[:5], engine.stderr.read()[:2000], flush=True); sys.exit(2)
print("engine up", flush=True)
CA = E + "/conf/mitmproxy-ca-cert.pem"

def ctx(trust_baobox):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)   # same ClientHello either way: only the trust store differs
    c.load_verify_locations(E + "/origin.pem")
    if trust_baobox: c.load_verify_locations(CA)
    return c
UNTRUSTED, TRUSTED = ctx(False), ctx(True)

def visit(context, host):
    """'decrypted' (Baobox's certificate), 'passthrough' (the origin's own), or 'failed' (handshake refused)."""
    s = socket.create_connection(("127.0.0.1", PROXY), timeout=5)
    s.sendall(("CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n" % (ORIGIN, ORIGIN)).encode())
    head = b""
    while b"\r\n\r\n" not in head: head += s.recv(1)
    try:
        t = context.wrap_socket(s, server_hostname=host)
    except ssl.SSLError:
        s.close(); time.sleep(0.3); return "failed"
    issuer = dict(x[0] for x in t.getpeercert()["issuer"]).get("commonName", "")
    t.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % host).encode())
    try:
        while t.recv(4096): pass
    except Exception: pass
    t.close(); time.sleep(0.3)
    return "passthrough" if issuer == "origin.test" else "decrypted"

def tls_rows(host):
    return sum(1 for e in events if e.get("event") == "tls" and e.get("host") == host)

def send(cmd):
    engine.stdin.write(json.dumps(cmd) + "\n"); engine.stdin.flush(); time.sleep(0.3)

results = []
def check(name, got, want):
    ok = got == want; results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + "  got=%r want=%r" % (got, want), flush=True)

# 7.2-1: the incident. Untrusted first -> recorded; then trusted (same fingerprint) succeeds elsewhere -> host1 decrypts again.
check("untrusted host1: handshake refused", visit(UNTRUSTED, "host1.test"), "failed")
check("untrusted host1 again: passed through", visit(UNTRUSTED, "host1.test"), "passthrough")
check("trusted host1 before any success: still passed through (old behaviour)", visit(TRUSTED, "host1.test"), "passthrough")
check("one 'not decrypted' row for host1 so far", tls_rows("host1.test"), 1)
check("trusted host2: decrypted (first success of this fingerprint)", visit(TRUSTED, "host2.test"), "decrypted")
check("trusted host1 after that success: decrypted again", visit(TRUSTED, "host1.test"), "decrypted")
# once per run: a failure recorded after the first success stays
check("untrusted host3 (like iCloud): refused", visit(UNTRUSTED, "host3.test"), "failed")
check("trusted host2 succeeds again", visit(TRUSTED, "host2.test"), "decrypted")
check("host3 stays passed through (cleared only once)", visit(UNTRUSTED, "host3.test"), "passthrough")
check("one row for host3", tls_rows("host3.test"), 1)
# 7.2-2: forget_reported
send({"cmd": "forget_reported", "device": "10.9.9.9"})
visit(UNTRUSTED, "host3.test")
check("forget_reported for another device: no new row", tls_rows("host3.test"), 1)
send({"cmd": "forget_reported"})
check("after forget_reported: still passed through", visit(UNTRUSTED, "host3.test"), "passthrough")
check("after forget_reported: the row is reported again", tls_rows("host3.test"), 2)
send({"cmd": "forget_reported", "device": "127.0.0.1"})
visit(UNTRUSTED, "host3.test")
check("forget_reported for this device: reported again", tls_rows("host3.test"), 3)
# 7.2-3: retry_decrypt
send({"cmd": "retry_decrypt", "device": "10.9.9.9", "host": "host3.test"})
check("retry for another device: still passed through", visit(TRUSTED, "host3.test"), "passthrough")
send({"cmd": "retry_decrypt", "device": "127.0.0.1", "host": "host3.test"})
check("retry for this device: trusted client decrypted", visit(TRUSTED, "host3.test"), "decrypted")
send({"cmd": "retry_decrypt", "device": "127.0.0.1", "host": "host3.test"})
before = tls_rows("host3.test")
check("retry, still untrusted: refused once more", visit(UNTRUSTED, "host3.test"), "failed")
check("... and a new row", tls_rows("host3.test"), before + 1)
check("... then passed through again", visit(UNTRUSTED, "host3.test"), "passthrough")

engine.stdin.write(json.dumps({"cmd": "shutdown"}) + "\n"); engine.stdin.flush()
try: engine.wait(5)
except subprocess.TimeoutExpired: engine.kill()
print("E2E OK (%d checks)" % len(results) if all(results) else "E2E FAILED")
