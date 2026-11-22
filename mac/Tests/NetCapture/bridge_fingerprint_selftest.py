"""Self-test of the bridge's client TLS fingerprint (docs/packet-capture/TLS-FINGERPRINT.md §3.1, §4.2).

The bridge only runs inside the bundled mitmproxy, so this runs there too (it imports the real
Resources/NetCapture/baobox_bridge.py and mitmproxy's own ClientHello parser):

  <Baobox.app or mac/Vendor/mitmproxy.noindex>/mitmproxy.app/Contents/MacOS/mitmdump -q --set server=false \
      -s mac/Tests/NetCapture/bridge_fingerprint_selftest.py

Prints one line per check and "SELFTEST OK" / "SELFTEST FAILED", then exits.
"""
import hashlib
import importlib.util
import os
import struct

from mitmproxy import ctx

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "baobox_bridge_under_test", os.path.join(HERE, "..", "..", "Sources", "Resources", "NetCapture", "baobox_bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def sni(name):
    entry = b"\x00" + struct.pack(">H", len(name)) + name
    return struct.pack(">H", len(entry)) + entry


def alpn(*protocols):
    items = b"".join(bytes([len(p)]) + p for p in protocols)
    return struct.pack(">H", len(items)) + items


def client_hello(ciphers, extensions):
    """A TLS record carrying one ClientHello with these cipher suites and (type, data) extensions, in this order."""
    body = b"\x03\x03" + bytes(range(32)) + b"\x00"
    suites = b"".join(struct.pack(">H", c) for c in ciphers)
    body += struct.pack(">H", len(suites)) + suites + b"\x01\x00"
    ext = b"".join(struct.pack(">HH", t, len(d)) + d for t, d in extensions)
    body += struct.pack(">H", len(ext)) + ext
    handshake = b"\x01" + len(body).to_bytes(3, "big") + body
    return b"\x16\x03\x01" + struct.pack(">H", len(handshake)) + handshake


def fingerprint(record):
    hello = bridge.parse_client_hello(record)
    assert hello is not None, "parser wants more data"
    return bridge.client_fingerprint(hello)


CIPHERS = [0x1301, 0x1302, 0xC02B]
EXTENSIONS = [(0, sni(b"chat.example.test")), (10, b"\x00\x02\x00\x1d"), (13, b"\x00\x02\x04\x03"),
              (16, alpn(b"h2", b"http/1.1")), (43, b"\x02\x03\x04"), (51, b"\x00\x00")]
BASE = client_hello(CIPHERS, EXTENSIONS)
# The rule written out by hand (independent of the bridge's code) and the value it gives; the literal pins the rule.
BY_HAND = hashlib.sha256(b"[4865, 4866, 49195]|[0, 10, 13, 16, 43, 51]|h2,http/1.1").hexdigest()[:12]
PINNED = "c30b9fb4aff8"

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail else ""), flush=True)


def run():
    base = fingerprint(BASE)
    check("fixed ClientHello bytes -> fixed fingerprint", base == BY_HAND == PINNED, "%s / by hand %s / pinned %s" % (base, BY_HAND, PINNED))
    shuffled = client_hello(CIPHERS, [EXTENSIONS[i] for i in (4, 0, 5, 2, 1, 3)])
    check("same extensions in another order -> same fingerprint", fingerprint(shuffled) == base)
    check("same cipher suites in another order -> same fingerprint", fingerprint(client_hello(list(reversed(CIPHERS)), EXTENSIONS)) == base)
    noisy = client_hello([0x2A2A] + CIPHERS + [0xFAFA],
                         [(0x0A0A, b"")] + EXTENSIONS + [(21, bytes(40)), (42, b""), (0x5A5A, b"\x00"), (41, b"\x00\x05" + bytes(5))])
    check("GREASE, padding, early_data, pre_shared_key added -> same fingerprint", fingerprint(noisy) == base)
    other_sni = client_hello(CIPHERS, [(0, sni(b"api.example.test"))] + EXTENSIONS[1:])
    check("another server name -> same fingerprint (the library, not the host)", fingerprint(other_sni) == base)
    no_alpn = client_hello(CIPHERS, [e for e in EXTENSIONS if e[0] != 16])
    check("without ALPN -> different", fingerprint(no_alpn) != base)
    other_alpn = client_hello(CIPHERS, [(16, alpn(b"http/1.1")) if t == 16 else (t, d) for t, d in EXTENSIONS])
    check("other ALPN -> different", fingerprint(other_alpn) != base)
    check("other cipher suites -> different", fingerprint(client_hello(CIPHERS + [0xC02F], EXTENSIONS)) != base)
    check("one more extension type -> different", fingerprint(client_hello(CIPHERS, EXTENSIONS + [(23, b"")])) != base)
    check("incomplete record -> parser asks for more", bridge.parse_client_hello(BASE[:40]) is None)
    print("SELFTEST " + ("OK" if all(results) else "FAILED") + " (%d checks)" % len(results), flush=True)


def running():
    try:
        run()
    except Exception as error:
        print("SELFTEST FAILED", repr(error), flush=True)
    ctx.master.shutdown()
