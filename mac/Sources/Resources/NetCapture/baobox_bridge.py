"""Baobox <-> mitmproxy bridge (docs/packet-capture/TECH_DESIGN.md §4).

Loaded by the bundled mitmdump with `-s`. It only uses mitmproxy's public addon
hooks.

  stdout  one event per line:  BAOBOX <json>
  stdin   one command per line: <json>      (EOF = Baobox is gone -> shut down)

Bodies travel base64-encoded inside the events; nothing is written to disk.
"""

import asyncio
import base64
import fnmatch
import hashlib
import json
import os
import re
import shutil
import socket
import sys
import threading
import time
import uuid
import zlib
from pathlib import Path

from mitmproxy import certs, connection, contentviews, ctx, http, tls
from mitmproxy.connection import ConnectionState
from mitmproxy.proxy import commands, events, layer
from mitmproxy.proxy.layers import modes
from mitmproxy.proxy.layers.tls import parse_client_hello

PREFIX = "BAOBOX "

# Reloads itself every 3 s: once the device is allowed on the Mac the page the user asked for appears
# without another tap (a user reported "nothing happens" after clicking Allow, 2026-11-21).
FORBIDDEN_PAGE = (
    "<!doctype html><meta charset=utf-8>"
    "<meta name=viewport content='width=device-width, initial-scale=1'>"
    "<meta http-equiv=refresh content=3>"
    "<title>Baobox</title>"
    "<body style='font-family:-apple-system,sans-serif;padding:32px;line-height:1.6'>"
    "<h2>请在 Mac 上允许这台设备</h2>"
    "<p>打开 Baobox 的抓包窗口，点「允许」。允许后这个页面会自己刷新。</p>"
    "<h2>Allow this device on the Mac</h2>"
    "<p>Open the Baobox capture window and click Allow. This page reloads by itself afterwards.</p>"
)

# Manual Proxy is off on the Mac: the engine still listens on the LAN (the setup page's certificate
# check needs it), but other devices may not use it as their proxy.
LAN_PROXY_OFF_PAGE = (
    "<!doctype html><meta charset=utf-8>"
    "<meta name=viewport content='width=device-width, initial-scale=1'>"
    "<title>Baobox</title>"
    "<body style='font-family:-apple-system,sans-serif;padding:32px;line-height:1.6'>"
    "<h2>手动代理没有打开</h2>"
    "<p>这台 Mac 上 Baobox 的「手动代理」是关着的，不能拿它当代理上网。要抓这台设备，请在 Mac 的抓包窗口里打开「手动代理」；不抓了就把设备的代理改回去。</p>"
    "<h2>Manual Proxy is off</h2>"
    "<p>Manual Proxy is turned off in Baobox on this Mac, so it cannot be used as a proxy. To capture this device, "
    "turn on Manual Proxy in the capture window on the Mac; otherwise set the device's proxy back.</p>"
)

SELF_PAGE = (
    "<!doctype html><meta charset=utf-8>"
    "<meta name=viewport content='width=device-width, initial-scale=1'>"
    "<title>Baobox</title>"
    "<body style='font-family:-apple-system,sans-serif;padding:32px;line-height:1.6'>"
    "<h2>这是 Baobox 的代理地址</h2>"
    "<p>它不是网页，不能在浏览器里直接打开。请把这个地址填到设备的 Wi-Fi 代理里。</p>"
    "<h2>This is the Baobox proxy address</h2>"
    "<p>It is not a web page. Enter it as the Wi-Fi proxy of the device instead.</p>"
)

# The setup page asks for this host to learn whether the phone's traffic already goes through the
# proxy (the name does not exist, so the request only gets anywhere with the proxy set).
CHECK_HOST = "check.baobox.invalid"
TRUST_CHECK_PATH = "/baobox-trust-check"

# Raw TCP (Baobox's "TCP" tab): at most this much of one read travels in a `tcp_data` event.
TCP_CHUNK = 16 * 1024

# XMPP STARTTLS (docs/packet-capture/STARTTLS.md): how much of the client's first bytes is kept to read the stream
# header (`to='…'`), and the stream header itself. Same rule as TCPProtocol on the Swift side: `<stream:stream` at
# the start, or `<?xml …` followed by `<stream` (a bare `<?xml` is also how SOAP and friends begin).
XMPP_HEAD = 4096
XMPP_TO = re.compile(rb"""<stream:stream\b[^>]*?\sto\s*=\s*['"]([^'"]+)['"]""")


# Client TLS fingerprint (docs/packet-capture/TLS-FINGERPRINT.md §3.1): which TLS library made the ClientHello. On a
# phone with Baobox's certificate installed the browser trusts it and most apps do not, on the same domain; the
# handshake-failure passthrough is remembered per device + domain + fingerprint so one does not decide for the other.
GREASE = frozenset(0x0A0A + 0x1010 * i for i in range(16))
VOLATILE_EXTENSIONS = frozenset({21, 41, 42})   # padding, pre_shared_key, early_data: differ from one connection to the next
# A ClientHello that has not arrived in full after this many bytes is not one (STARTTLS waits for it).
CLIENT_HELLO_MAX = 64 * 1024


def client_fingerprint(client_hello):
    """Sorted cipher suites + sorted extension types + ALPN, without GREASE / padding / pre_shared_key / early_data;
    first 12 hex digits of SHA-256. Chromium shuffles its extension order per connection, hence the sorting.
    None when the hello does not expose the fields (the caller then falls back to device + domain)."""
    try:
        ciphers = sorted(c for c in client_hello.cipher_suites if c not in GREASE)
        extensions = sorted(t for t, _ in client_hello.extensions if t not in GREASE and t not in VOLATILE_EXTENSIONS)
        alpn = ",".join(a.decode("ascii", "replace") if isinstance(a, bytes) else str(a)
                        for a in (client_hello.alpn_protocols or []))
    except Exception:
        return None
    return hashlib.sha256(("%s|%s|%s" % (ciphers, extensions, alpn)).encode()).hexdigest()[:12]


XMPP_OPENINGS = (b"<stream:stream", b"<?xml")


def maybe_xmpp(head):
    """The client's first bytes open an XMPP stream, or are still too short to tell (a strict prefix of one of the
    openings, e.g. `<?x`): the STARTTLS layer goes in and decides once it has seen a stream header."""
    return bool(head) and any(head.startswith(o) or o.startswith(head) for o in XMPP_OPENINGS)


def xmpp_stream_header(data):
    """True when `data` (the client's first bytes) opens an XMPP stream."""
    head = data.lstrip()
    if head.startswith(b"<stream:stream"):
        return True
    return head.startswith(b"<?xml") and b"<stream" in head


def xmpp_domain(data):
    """The `to='…'` of the client's stream header (the XMPP domain, same as the SNI of the TLS that follows)."""
    match = XMPP_TO.search(data)
    if not match:
        return None
    return match.group(1).decode("utf-8", "replace").strip().lower() or None


def tcp_data_event(conn_id, from_client, content, sent, cap):
    """One `tcp_data` event. Past the body cap only the size travels; below it at most TCP_CHUNK bytes of each read.
    Returns (event, bytes sent so far on this connection)."""
    event = {"event": "tcp_data", "id": conn_id, "from_client": from_client, "size": len(content),
             "truncated": False, "ts": time.time()}
    if sent < cap and content:
        chunk = content[: min(TCP_CHUNK, cap - sent)]
        sent += len(chunk)
        event["data"] = base64.b64encode(chunk).decode("ascii")
        event["truncated"] = len(chunk) < len(content)
    return event, sent


class StartTLSState:
    """One XMPP connection the STARTTLS layer looks after. Shared between the layer, the TLS hooks and the TCP flow
    the engine creates once Baobox has taken over the TLS, so the whole connection stays one row."""

    def __init__(self, conn_id, key, rec):
        self.id = conn_id          # the row id (tcp_open / tcp_data / tcp_tls / tcp_close)
        self.key = key             # device key (wg:<id> or source IP): the handshake-failure table is per device
        self.rec = rec             # tcp_open was reported (not paused, not this Mac with "TCP" off)
        self.sent = 0              # bytes of data reported so far (body cap)
        self.domain = None         # from the stream header
        self.fingerprint = None    # of the client's ClientHello after <proceed/>
        self.takeover = False      # Baobox does the TLS with the phone (and separately with the server)
        self.tls_reported = False  # tcp_tls sent (only the first outcome counts)
        self.error = None
        self.closed = False        # tcp_close sent


class StartTLSLayer(layer.Layer):
    """XMPP with STARTTLS (docs/packet-capture/STARTTLS.md §3).

    Until the server says `<proceed/>` this relays the plaintext both ways and reports it as a TCP connection of its
    own. At `<proceed/>`, with Decrypt HTTPS off or the domain out of scope, it keeps relaying the bytes untouched
    (the TLS ciphertext) and keeps reporting them. Otherwise it holds the client's next bytes until the ClientHello
    is complete (TLS-FINGERPRINT.md §3.3): this device + domain + client fingerprint failed a handshake before ->
    send the held bytes on and keep relaying; if not, the connection goes to a fresh `NextLayer` with the held bytes,
    and the engine stacks its own TLS layers on top (phone <-> Baobox certificate, Baobox <-> server); the plaintext
    that comes out of them lands in the same row.
    """

    def __init__(self, context, bridge, state):
        super().__init__(context)
        self.bridge = bridge
        self.state = state
        self.child = None
        self.client_head = b""
        self.server_tail = b""
        self.decided = False
        self.hello = None          # bytes held after <proceed/> until the ClientHello is complete (None = not waiting)

    def _handle_event(self, event):
        if self.child is not None:
            yield from self.child.handle_event(event)
            return
        client, server = self.context.client, self.context.server
        if isinstance(event, events.Start):
            self.bridge.starttls_open(self.state, self.context)
            if server.timestamp_start is None:
                err = yield commands.OpenConnection(server)
                if err:
                    self.state.error = str(err)
                    yield commands.CloseConnection(client)
                    self._handle_event = self.done
            return
        if isinstance(event, events.DataReceived):
            from_client = event.connection == client
            if from_client and self.hello is not None:
                yield from self.hold_hello(event.data)
                return
            self.bridge.starttls_data(self.state, from_client, event.data)
            if from_client:
                yield commands.SendData(server, event.data)
                if len(self.client_head) < XMPP_HEAD:
                    self.client_head += event.data[: XMPP_HEAD - len(self.client_head)]
                return
            yield commands.SendData(client, event.data)
            if self.decided:
                return
            window = self.server_tail + event.data
            self.server_tail = window[-16:]
            if b"<proceed" in window and xmpp_stream_header(self.client_head):
                self.decided = True
                if self.bridge.starttls_may_take_over(self.state, self.context, self.client_head):
                    self.hello = b""
            return
        if isinstance(event, events.ConnectionClosed):
            if self.hello is not None:
                # The connection closes (or half-closes) while a ClientHello is being held: what arrived so far still
                # goes on and is recorded, nothing is taken over.
                held, self.hello = self.hello, None
                yield from self.release_hello(held)
            # Like the engine's TCP layer: pass a half-close on, finish when both sides are done.
            done = not ((client.state & ConnectionState.CAN_READ) or (server.state & ConnectionState.CAN_READ))
            if done:
                self._handle_event = self.done
                if server.state is not ConnectionState.CLOSED:
                    yield commands.CloseConnection(server)
                if client.state is not ConnectionState.CLOSED:
                    yield commands.CloseConnection(client)
            else:
                yield commands.CloseTcpConnection(server if event.connection == client else client, half_close=True)

    def hold_hello(self, data):
        """After <proceed/>: hold the client's bytes until the ClientHello is complete, then take over or pass on."""
        if not data:
            return                          # an empty read says nothing yet
        self.hello += data
        try:
            hello = parse_client_hello(self.hello) if self.hello[:1] == b"\x16" else None
            broken = self.hello[:1] != b"\x16" or len(self.hello) > CLIENT_HELLO_MAX
        except ValueError:
            hello, broken = None, True
        if hello is None and not broken:
            return                          # not complete yet
        held, self.hello = self.hello, None
        if hello is not None and self.bridge.starttls_take_over(self.state, client_fingerprint(hello)):
            self.child = layer.NextLayer(self.context)
            yield from self.child.handle_event(events.Start())
            yield from self.child.handle_event(events.DataReceived(self.context.client, held))
            return
        # Passed through (failed before, or not TLS at all): the held bytes go on as they are, and are recorded.
        yield from self.release_hello(held)

    def release_hello(self, held):
        if held:
            self.bridge.starttls_data(self.state, True, held)
            if self.context.server.state & ConnectionState.CAN_WRITE:
                yield commands.SendData(self.context.server, held)

    def done(self, _):
        yield from ()

def bare_host(value):
    """Lower-case host without brackets, IPv4-mapped prefix or zone id."""
    host = str(value or "").lower().strip("[]")
    if host.startswith("::ffff:"):
        host = host[7:]
    return host.split("%", 1)[0]


def local_names():
    """Names under which this machine reaches itself (besides the address a client connected to)."""
    names = {"localhost", "127.0.0.1", "::1"}
    try:
        name = socket.gethostname().lower()
        if name:
            names.add(name)
            names.add(name.split(".", 1)[0] + ".local")
    except OSError:
        pass
    return names

# The name people see when they install or inspect the root certificate (iOS profile details, Android's
# credential list, Keychain Access). Not "Baobox Proxy CA": that was the first version's certificate,
# which Baobox removes by that name.
CA_COMMON_NAME = "Baobox Capture CA"
CA_ORGANIZATION = "Baobox"


def replace_ca(confdir):
    """Replace the root certificate in `confdir` with a new one under Baobox's name.

    The engine creates its own, called "mitmproxy", before any script is loaded, so there is no way to
    get in first. Baobox therefore runs the engine once without listeners (`baobox_new_ca`) whenever
    there is no certificate yet, or the user asks for a new one: by then the engine has made its
    default, and this swaps it for one made by the engine's own generator under the right name. The
    engine picks it up on its next start. Returns the common name on success.
    """
    staging = confdir / ".baobox-new-ca"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        certs.CertStore.create_store(
            staging, "mitmproxy", 2048, organization=CA_ORGANIZATION, cn=CA_COMMON_NAME)
        for item in sorted(staging.iterdir()):
            os.replace(item, confdir / item.name)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return CA_COMMON_NAME


def emit(obj):
    """Write one event line. Never raises: a closed pipe means Baobox is gone."""
    try:
        sys.stdout.write(PREFIX + json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, ValueError, OSError):
        pass


def client_ip(conn):
    """Source address of a client connection, IPv4-mapped IPv6 folded to IPv4."""
    peer = getattr(conn, "peername", None)
    if not peer:
        return None
    ip = str(peer[0])
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    return ip.split("%", 1)[0]


def is_loopback(ip):
    return ip in (None, "127.0.0.1", "::1", "localhost")


def sniff_decompress(content, limit):
    """Undo compression that the headers do not declare.

    Plenty of apps and SDKs gzip a body and send it as application/octet-stream with no
    Content-Encoding, so the engine has nothing to go on and passes the bytes through. Recognise the
    common containers by their magic bytes instead. Returns (bytes, name, truncated); name is None when
    nothing was recognised or the data did not actually decompress. Output is capped at `limit` bytes so
    a small body cannot blow up into gigabytes.
    """
    if len(content) < 4:
        return content, None, False
    name, wbits = None, None
    if content[:2] == b"\x1f\x8b":
        name, wbits = "gzip", 16 + zlib.MAX_WBITS
    elif content[0] == 0x78 and content[1] in (0x01, 0x5E, 0x9C, 0xDA):
        name, wbits = "zlib", zlib.MAX_WBITS
    if name:
        try:
            decoder = zlib.decompressobj(wbits)
            out = decoder.decompress(content, limit + 1)
        except zlib.error:
            return content, None, False
        if not out:
            return content, None, False
        return out[:limit], name, len(out) > limit
    if content[:4] == b"\x28\xb5\x2f\xfd":
        try:
            import zstandard
            reader = zstandard.ZstdDecompressor().stream_reader(content)
            out = reader.read(limit + 1)
        except Exception:
            return content, None, False
        if not out:
            return content, None, False
        return out[:limit], "zstd", len(out) > limit
    return content, None, False


# Headers that describe the wire form of a body. When a body is replaced (replay with an edited body, mock
# response) they would describe the old bytes, so they are dropped and the engine recomputes what it needs.
WIRE_HEADERS = ("content-length", "content-encoding", "transfer-encoding")

# Content types whose bodies are structured binary. The engine can render them as text.
STRUCTURED_VIEWS = (("grpc", "grpc"), ("protobuf", "protobuf"), ("application/proto", "protobuf"),
                    ("msgpack", "msgpack"))


def structured_view(message):
    """Name of the engine view for this body's content type, or None."""
    content_type = (message.headers.get("content-type") or "").lower()
    for needle, view in STRUCTURED_VIEWS:
        if needle in content_type:
            return view
    return None


def header_pairs(raw):
    """[[name, value], ...] from a command -> list of (bytes, bytes), minus the wire headers."""
    pairs = []
    for item in raw or []:
        if isinstance(item, list) and len(item) == 2 and all(isinstance(x, str) for x in item):
            if item[0].lower() not in WIRE_HEADERS and item[0]:
                pairs.append((item[0].encode("utf-8", "surrogateescape"), item[1].encode("utf-8", "surrogateescape")))
    return pairs


def mode_name(client):
    mode = getattr(client, "proxy_mode", None)
    return getattr(mode, "type_name", "")


def via_socks(client):
    """True when the client connection came in through the SOCKS5 listener."""
    return mode_name(client) == "socks5"


def via_wireguard(client):
    """True when the client is a device inside the WireGuard tunnel (it needed the key to get here)."""
    return mode_name(client) == "wireguard"


def wireguard_device(client):
    """Which WireGuard device a connection belongs to: Baobox runs one listener per device, each with its
    own key file named `<device id>.json` (docs/packet-capture/WIREGUARD-DEVICES.md §4). Every device has
    the same tunnel address (10.0.0.1), so the listener is the only way to tell them apart. None for
    anything that did not come in through WireGuard."""
    if not via_wireguard(client):
        return None
    path = str(getattr(getattr(client, "proxy_mode", None), "data", "") or "")
    name = os.path.basename(path)
    if name.endswith(".json"):
        name = name[:-5]
    return name or None


def device_key(client):
    """`wg:<id>` for a WireGuard device, the source IP for everything else (this Mac, LAN devices)."""
    wg = wireguard_device(client)
    return "wg:" + wg if wg else client_ip(client)


def with_device(event, client):
    """Add `wg` to an event when the connection came in through WireGuard."""
    wg = wireguard_device(client)
    if wg:
        event["wg"] = wg
    return event


def address_fields(address):
    """(host, port) of a server address, or (None, None)."""
    try:
        return str(address[0]), int(address[1])
    except (TypeError, ValueError, IndexError):
        return None, None


def server_port(server):
    address = getattr(server, "address", None)
    try:
        return int(address[1]) if address else None
    except (TypeError, ValueError, IndexError):
        return None


def host_in(host, domains):
    """Suffix match: `x.com` covers `x.com` and `api.x.com`; a leading `*.` is ignored."""
    host = (host or "").lower().rstrip(".")
    for domain in domains:
        d = domain.lower().lstrip("*").lstrip(".")
        if d and (host == d or host.endswith("." + d)):
            return True
    return False


class Bridge:
    def __init__(self):
        self.scope_mode = "all"          # all | allow | deny
        self.scope_domains = []
        self.allowed = set()             # LAN source IPs the user allowed
        self.denied = set()
        self.announced = set()           # source IPs already reported as pending
        self.failed = set()              # (device key, host, client fingerprint or None): handshake failed -> pass through
        self.reported = set()            # (device key, host, reason, fingerprint): `tls` already sent
        self.trusted = set()             # (device key, fingerprint): this kind of client completed a handshake with us
        self.body_cap = 5 * 1024 * 1024
        self.rules = []                  # mock rules, in the order the user keeps them
        self.listen_ports = set()        # ports this engine listens on
        self.local_names = local_names()
        self.page_port = 0               # Baobox's setup page for phones, 0 = not running
        self.lan_ip = ""                 # this Mac's LAN address (what a tunnel device uses to reach it)
        self.recording = True            # False = paused: nothing new is reported
        self.lan_proxy = True            # False = LAN devices may not use the engine as a proxy
        self.mac_tcp = False             # report raw TCP from this Mac (it arrives through SOCKS)
        self.starttls = {}               # client connection id -> StartTLSState (XMPP connections)
        self.fingerprints = {}           # client connection id -> fingerprint of its ClientHello (for tls_failed_client)

    # ----- options --------------------------------------------------------

    def load(self, loader):
        loader.add_option("baobox_oneshot", bool, False,
                          "Exit as soon as the proxy is up (used to generate the CA).")
        loader.add_option("baobox_body_cap", int, 5 * 1024 * 1024,
                          "Largest body (bytes) forwarded to Baobox.")
        loader.add_option("baobox_scope", str, "",
                          "Initial decrypt scope as JSON: {mode, domains}.")
        loader.add_option("baobox_allowed", str, "",
                          "Initially allowed LAN source IPs, comma separated.")
        loader.add_option("baobox_page_port", int, 0,
                          "Port of Baobox's setup page; requests sent to the proxy itself are redirected there.")
        loader.add_option("baobox_new_ca", bool, False,
                          "Replace the root certificate with a new one named after Baobox, then exit.")
        loader.add_option("baobox_lan_ip", str, "",
                          "This Mac's LAN address; a request to it from inside the tunnel is for this machine.")
        loader.add_option("baobox_record", bool, True,
                          "Report new traffic (False = capture paused).")
        loader.add_option("baobox_lan_proxy", bool, True,
                          "Let allowed LAN devices use the engine as their proxy.")
        loader.add_option("baobox_mac_tcp", bool, False,
                          "Report raw TCP connections that come from this Mac.")

    def running(self):
        self.body_cap = max(1024, ctx.options.baobox_body_cap)
        if ctx.options.baobox_scope:
            try:
                self.apply_scope(json.loads(ctx.options.baobox_scope))
            except ValueError:
                pass
        self.allowed.update(ip for ip in ctx.options.baobox_allowed.split(",") if ip)
        self.page_port = max(0, ctx.options.baobox_page_port)
        self.lan_ip = bare_host(ctx.options.baobox_lan_ip)
        self.recording = ctx.options.baobox_record
        self.lan_proxy = ctx.options.baobox_lan_proxy
        self.mac_tcp = ctx.options.baobox_mac_tcp
        for spec in ctx.options.mode:
            match = re.search(r":(\d+)$", spec)
            if match:
                self.listen_ports.add(int(match.group(1)))

        version = ""
        try:
            from mitmproxy import version as mitm_version
            version = mitm_version.VERSION
        except Exception:
            pass
        emit({"event": "running", "version": version})

        if ctx.options.baobox_new_ca:
            try:
                name = replace_ca(Path(os.path.expanduser(ctx.options.confdir)))
                emit({"event": "ca", "name": name})
            except Exception as error:
                emit({"event": "ca", "error": str(error)})
            ctx.master.shutdown()
            return
        if ctx.options.baobox_oneshot:
            ctx.master.shutdown()
            return
        loop = asyncio.get_running_loop()
        threading.Thread(target=self.read_stdin, args=(loop,), daemon=True).start()

    # ----- commands -------------------------------------------------------

    def read_stdin(self, loop):
        # A plain thread: asyncio's pipe reader does not report EOF on every
        # kind of pipe (TECH_DESIGN §1).
        try:
            for line in sys.stdin:
                loop.call_soon_threadsafe(self.handle, line)
        except Exception:
            pass
        loop.call_soon_threadsafe(self.handle, None)

    def handle(self, line):
        if line is None:
            ctx.master.shutdown()
            return
        try:
            cmd = json.loads(line)
        except ValueError:
            return
        if not isinstance(cmd, dict):
            return
        name = cmd.get("cmd")
        if name == "shutdown":
            ctx.master.shutdown()
        elif name == "scope":
            self.apply_scope(cmd)
        elif name == "rules":
            self.apply_rules(cmd.get("rules"))
        elif name == "replay":
            self.replay(cmd)
        elif name == "allow_device":
            ip = cmd.get("client")
            if ip:
                self.allowed.add(ip)
                self.denied.discard(ip)
        elif name == "deny_device":
            ip = cmd.get("client")
            if ip:
                self.denied.add(ip)
                self.allowed.discard(ip)
        elif name == "record":
            self.recording = bool(cmd.get("on"))
        elif name == "lan_proxy":
            self.lan_proxy = bool(cmd.get("on"))
        elif name == "mac_tcp":
            self.mac_tcp = bool(cmd.get("on"))
        elif name == "page_port":
            port = cmd.get("port")
            if isinstance(port, int) and 0 <= port <= 65535:
                self.page_port = port
        elif name == "forget_reported":
            # The list was cleared (all of it, or one device's rows): report passed-through domains again the next
            # time they show up. The failure table stays: clearing the list says nothing about the certificate.
            device = cmd.get("device")
            if isinstance(device, str) and device:
                self.reported = {r for r in self.reported if r[0] != device}
            else:
                self.reported = set()
        elif name == "retry_decrypt":
            # "Try decrypting again" on a passed-through row: forget this device + domain for every fingerprint. The
            # next connection is taken over again; if the device still refuses the certificate it fails once more,
            # gets recorded again and shows a new row (TLS-FINGERPRINT.md §7.2).
            device, host = cmd.get("device"), cmd.get("host")
            if isinstance(device, str) and isinstance(host, str) and device and host:
                self.failed = {f for f in self.failed if not (f[0] == device and f[1] == host)}
                self.reported = {r for r in self.reported if not (r[0] == device and r[1] == host)}

    def apply_scope(self, cmd):
        mode = cmd.get("mode")
        domains = cmd.get("domains")
        # none = decrypt nothing (Baobox's "Decrypt HTTPS" switch is off).
        if mode in ("all", "allow", "deny", "none") and isinstance(domains, list):
            self.scope_mode = mode
            self.scope_domains = [d for d in domains if isinstance(d, str) and d.strip()]
            self.reported = {r for r in self.reported if r[2] not in ("out_of_scope", "decrypt_off")}

    # ----- mock rules ------------------------------------------------------

    def apply_rules(self, rules):
        """Replace the whole rule list. Malformed entries are skipped."""
        kept = []
        for rule in rules if isinstance(rules, list) else []:
            if not isinstance(rule, dict) or not rule.get("enabled", True):
                continue
            host, path = rule.get("host"), rule.get("path")
            if not isinstance(host, str) or not isinstance(path, str) or not host:
                continue
            try:
                body = base64.b64decode(rule.get("body") or "")
                status = int(rule.get("status", 200))
            except (ValueError, TypeError):
                continue
            kept.append({
                "id": str(rule.get("id", "")),
                "method": str(rule.get("method") or "*").upper(),
                "host": host.lower(),
                "path": path or "/",
                "status": status if 100 <= status <= 599 else 200,
                "headers": header_pairs(rule.get("headers")),
                "body": body,
            })
        self.rules = kept

    def match_rule(self, request):
        """First enabled rule for this request. Host is exact, path ignores the query and may use `*`."""
        if not self.rules:
            return None
        host = (request.pretty_host or "").lower()
        path = request.path.split("?", 1)[0]
        for rule in self.rules:
            if rule["method"] not in ("*", request.method.upper()) or rule["host"] != host:
                continue
            if rule["path"] == path or fnmatch.fnmatchcase(path, rule["path"]):
                return rule
        return None

    # ----- replay ----------------------------------------------------------

    def replay(self, cmd):
        """Send a request again. Everything comes from the command, so it also works for a request that
        was captured before the engine was restarted. Built the same way as the engine's own
        `view.flows.create`. The caller picks the flow id, so it knows which row is the answer."""
        try:
            method, url = cmd["method"], cmd["url"]
            body = base64.b64decode(cmd.get("body") or "")
            request = http.Request.make(str(method).upper(), str(url), body)
        except (KeyError, ValueError, TypeError) as error:
            emit({"event": "replay_failed", "id": cmd.get("id"), "message": str(error)})
            return
        headers = header_pairs(cmd.get("headers"))
        if headers:
            request.headers = http.Headers(headers)
        # A request captured over HTTP/2 has no Host header (it was `:authority`), and one built from
        # nothing has none either; without it servers answer 400.
        if "host" not in request.headers:
            request.headers["host"] = request.pretty_host
        if body or request.method in ("POST", "PUT", "PATCH"):
            request.headers["content-length"] = str(len(body))
        else:
            request.headers.pop("content-length", None)
        client = connection.Client(peername=("127.0.0.1", 0), sockname=("127.0.0.1", 0),
                                   timestamp_start=time.time())
        server = connection.Server(address=(request.host, request.port))
        flow = http.HTTPFlow(client, server)
        flow.request = request
        if isinstance(cmd.get("id"), str) and cmd["id"]:
            flow.id = cmd["id"]
        flow.metadata["baobox_replay"] = True
        try:
            ctx.master.commands.call("replay.client", [flow])
        except Exception as error:
            emit({"event": "replay_failed", "id": flow.id, "message": str(error)})

    # ----- device admission ------------------------------------------------

    def admitted(self, client):
        """This Mac and devices inside the WireGuard tunnel (they needed the key to get in) are always
        admitted; a LAN device only after the user allowed it on the Mac."""
        ip = client_ip(client)
        if is_loopback(ip) or via_wireguard(client) or ip in self.allowed:
            return True
        if ip not in self.denied and ip not in self.announced:
            self.announced.add(ip)
            emit(with_device({"event": "device", "client": ip}, client))
        return False

    def proxy_refused(self, client):
        """A LAN device using the engine as its proxy while Manual Proxy is off. Tunnel devices and this
        Mac are never refused."""
        return not self.lan_proxy and not is_loopback(client_ip(client)) and not via_wireguard(client)

    def http_connect(self, flow: http.HTTPFlow):
        if self.addressed_to_proxy(flow):
            if self.page_port:
                # The setup page's trust check, sent by a phone that already has the proxy set: it wants
                # TLS with the engine itself. Accept the tunnel and answer inside it (`request`). The
                # tunnel needs somewhere to point that is not the engine; the setup page's listener on
                # this machine will do, nothing is ever sent to it (see `tls_clienthello`).
                flow.request.host = "127.0.0.1"
                flow.request.port = self.page_port
            else:
                flow.response = http.Response.make(403, b"", {"Connection": "close"})
            return
        if self.proxy_refused(flow.client_conn):
            flow.response = http.Response.make(403, b"", {"Connection": "close"})
            return
        if not self.admitted(flow.client_conn):
            flow.response = http.Response.make(403, b"", {"Connection": "close"})

    # ----- requests sent to the proxy itself --------------------------------

    def addressed_to_proxy(self, flow):
        """True when the request's destination is this engine.

        Happens when someone opens the proxy address in a browser. Forwarding it would make the
        engine connect to itself over and over until the machine runs out of ports (seen
        2026-11-21: 16000 requests, then 502).
        """
        return flow.request.port in self.listen_ports and self.is_this_machine(flow)

    def is_this_machine(self, flow):
        """True when the request's host is this machine: a loopback name, the host name, this Mac's LAN
        address (how a device inside the tunnel reaches it), or the address the client itself used to
        reach the engine."""
        host = bare_host(flow.request.host)
        if host in self.local_names or (self.lan_ip and host == self.lan_ip):
            return True
        sock = getattr(flow.client_conn, "sockname", None)
        return bool(sock) and host == bare_host(sock[0])

    def engine_itself(self, address):
        """True when a TLS connection is aimed at the engine itself (the setup page's certificate check):
        connected straight to the proxy port (no destination yet), or, from inside the tunnel, to this
        Mac's address on one of the engine's ports."""
        if not address:
            return True
        host, port = address_fields(address)
        host = bare_host(host)
        return port in self.listen_ports and (host in self.local_names or (bool(self.lan_ip) and host == self.lan_ip))

    def addressed_to_setup_page(self, flow):
        """True for the phone setup page fetched through the proxy (the phone already has the proxy set)."""
        return bool(self.page_port) and flow.request.port == self.page_port and self.is_this_machine(flow)

    def self_response(self, req):
        """Send a browser that opened the proxy address to the setup page, or say what the address is."""
        if self.page_port:
            host = bare_host(req.host)
            if ":" in host:
                host = "[" + host + "]"
            return http.Response.make(
                302, b"", {"Location": "http://%s:%d/" % (host, self.page_port), "Cache-Control": "no-store"})
        return http.Response.make(
            200, SELF_PAGE.encode("utf-8"),
            {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"})

    # ----- decrypt scope + automatic passthrough ---------------------------

    def in_scope(self, host):
        if self.scope_mode == "allow":
            return host_in(host, self.scope_domains)
        if self.scope_mode == "deny":
            return not host_in(host, self.scope_domains)
        return True

    def has_failed(self, key, host, fingerprint):
        """This device + domain + client fingerprint failed a handshake before. An entry recorded without a fingerprint
        (it could not be read) stands for every fingerprint, as before fingerprints were kept."""
        return (key, host, fingerprint) in self.failed or (key, host, None) in self.failed

    def report_tls(self, client, host, reason, fingerprint=None):
        # A refused certificate is reported once per client fingerprint: the browser decrypting a domain does not hide
        # that an app on the same phone is refusing it.
        key = (device_key(client), host, reason, fingerprint if reason == "handshake_failed" else None)
        # Paused: nothing is reported, and nothing is remembered as reported, so the row shows up once
        # capture resumes and the host is seen again.
        if key in self.reported or not self.recording:
            return
        self.reported.add(key)
        emit(with_device({"event": "tls", "client": client_ip(client), "host": host, "reason": reason}, client))

    def tls_clienthello(self, data: tls.ClientHelloData):
        server = getattr(data.context.server, "address", None)
        if self.page_port and server and server[1] == self.page_port and bare_host(server[0]) in self.local_names:
            # Tunnel parked on the setup page listener (see `http_connect`): that listener speaks plain
            # HTTP and would sit on a TLS hello forever, stalling the phone. Mark the server side as
            # not TLS: the engine's own TLS addon runs after this hook and derives "handshake with the
            # server first" from that flag. Only the handshake with the phone matters here.
            data.context.server.tls = False
            data.establish_server_tls_first = False
            return
        host = data.client_hello.sni
        client = data.context.client
        fingerprint = client_fingerprint(data.client_hello)
        self.fingerprints[client.id] = fingerprint
        state = self.starttls.get(client.id)
        if state is not None and state.takeover:
            # XMPP after <proceed/>: the decision (Decrypt HTTPS, scope, failure table) was made right then, on the
            # domain from the stream header. Let the engine do the TLS.
            return
        # The SOCKS listener exists for WebSocket: Apple's WebSocket stack ignores the HTTP proxy and only
        # uses the system SOCKS proxy. But every SOCKS-aware app sends all of its TCP through it (mail,
        # chat, ...). Only web traffic (443) is of interest here; leave everything else untouched.
        if via_socks(data.context.client) and server_port(data.context.server) != 443:
            data.ignore_connection = True
            return
        if self.scope_mode == "none" and not self.engine_itself(server):
            # Decrypt HTTPS is off: pass every TLS connection through untouched. The certificate check
            # still needs its handshake with the engine, so connections to the engine itself are kept.
            data.ignore_connection = True
            if host:
                self.report_tls(client, host, "decrypt_off")
            return
        if not host:
            return
        # Keyed by device (every WireGuard device is 10.0.0.1 inside its tunnel, and one phone not trusting the
        # certificate says nothing about another) and by client fingerprint (the browser trusting it says nothing about
        # an app on the same phone, TLS-FINGERPRINT.md).
        if self.has_failed(device_key(client), host, fingerprint):
            data.ignore_connection = True
            self.report_tls(client, host, "handshake_failed", fingerprint)
        elif not self.in_scope(host):
            data.ignore_connection = True
            self.report_tls(client, host, "out_of_scope")

    def tls_failed_client(self, data: tls.TlsData):
        client = data.context.client
        state = self.starttls.get(client.id)
        if state is not None and state.takeover:
            # The phone refused Baobox's certificate after <proceed/>: this connection breaks, the app reconnects and
            # then gets passed through (same table as HTTPS). Shown on the TCP row, not as an HTTP row.
            self.failed.add((state.key, state.domain, state.fingerprint))
            state.error = getattr(data.conn, "error", None) or "TLS handshake failed"
            self.report_tcp_tls(state, "failed", reason="handshake_failed")
            return
        host = data.conn.sni
        if not host:
            return
        fingerprint = self.fingerprints.get(client.id)
        self.failed.add((device_key(client), host, fingerprint))
        self.report_tls(client, host, "handshake_failed", fingerprint)

    def tls_failed_server(self, data: tls.TlsData):
        state = self.starttls.get(data.context.client.id)
        if state is not None and state.takeover:
            # Baobox could not do TLS with the server (its certificate did not check out). Not the phone's fault, but
            # the connection breaks just the same: pass the reconnect through so the app keeps working.
            self.failed.add((state.key, state.domain, state.fingerprint))
            state.error = getattr(data.conn, "error", None) or "TLS handshake with the server failed"
            self.report_tcp_tls(state, "failed", reason="server_handshake_failed")

    def tls_established_client(self, data: tls.TlsData):
        client = data.context.client
        state = self.starttls.get(client.id)
        if state is not None and state.takeover:
            self.note_trusted(state.key, state.fingerprint)
            self.report_tcp_tls(state, "decrypted", sni=getattr(data.conn, "sni", None) or state.domain,
                                version=getattr(data.conn, "tls_version", None))
            return
        self.note_trusted(device_key(client), self.fingerprints.get(client.id))

    def note_trusted(self, key, fingerprint):
        """A handshake with this device + client fingerprint just succeeded: that kind of client trusts Baobox's
        certificate now, so the failures recorded for it earlier (before the certificate was installed) no longer hold.
        Once per engine run and (device, fingerprint): on iOS one fingerprint covers Safari, system services and most
        apps, and services that never accept the certificate (iCloud) would otherwise be taken over again after every
        success and keep breaking. Entries recorded without a fingerprint are left alone (TLS-FINGERPRINT.md §7.2)."""
        if fingerprint is None or (key, fingerprint) in self.trusted:
            return
        self.trusted.add((key, fingerprint))
        self.failed = {f for f in self.failed if not (f[0] == key and f[2] == fingerprint)}
        self.reported = {r for r in self.reported
                         if not (r[0] == key and r[2] == "handshake_failed" and r[3] == fingerprint)}

    # ----- flows ----------------------------------------------------------

    def body_fields(self, message):
        """(base64 or None, truncated, sniffed).

        Uses the decoded content: the engine undoes whatever Content-Encoding declares (gzip, deflate,
        br, zstd). `sniffed` names a compression that was *not* declared but recognised from the bytes.
        """
        try:
            content = message.content
        except ValueError:
            # Declared encoding does not match the bytes; fall back to what was on the wire.
            content = message.raw_content
        if content is None:
            # Streamed past `stream_large_bodies`: not captured.
            return None, True, None
        if not content:
            return None, False, None
        content, sniffed, truncated = sniff_decompress(content, self.body_cap)
        if len(content) > self.body_cap:
            content = content[: self.body_cap]
            truncated = True
        return base64.b64encode(content).decode("ascii"), truncated, sniffed

    def structured_text(self, message, flow):
        """Protobuf / gRPC / msgpack bodies rendered as text by the engine, or None.

        Without a .proto file a protobuf message only has field numbers, not names; that is what the
        engine prints. Returns {"view": name, "text": ...}."""
        view = structured_view(message)
        if view is None:
            return None
        try:
            if not message.raw_content:
                return None
            result = contentviews.prettify_message(message, flow, view)
        except Exception:
            return None
        text = getattr(result, "text", None)
        if not text:
            return None
        name = getattr(result, "view_name", view) or view
        # The engine falls back to a hex/raw view, or returns its own error text, when the bytes do not
        # parse; neither is a decode.
        if "raw" in name.lower() or "hex" in name.lower() or text.startswith("Couldn't parse"):
            return None
        return {"view": name, "text": text[:400000]}

    @staticmethod
    def wire_size(message):
        """Body size on the wire. A streamed body was never buffered, so fall back to Content-Length."""
        raw = message.raw_content
        if raw:
            return len(raw)
        try:
            return max(0, int(message.headers.get("content-length", "0")))
        except ValueError:
            return 0

    @staticmethod
    def headers(message):
        return [[k, v] for k, v in message.headers.items(multi=True)]

    def request(self, flow: http.HTTPFlow):
        if flow.request.path.split("?", 1)[0] == TRUST_CHECK_PATH and self.is_this_machine(flow):
            # The setup page asks over https whether this device trusts the CA. Getting here at all
            # means the handshake with a certificate signed by the CA succeeded.
            flow.response = http.Response.make(
                204, b"", {"Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"})
            return
        if self.addressed_to_proxy(flow):
            # Not traffic to capture: no event, no admission prompt.
            flow.response = self.self_response(flow.request)
            return
        if flow.request.pretty_host == CHECK_HOST:
            # Asking also announces the device, so the Mac shows "allow" as soon as the proxy is set. Not while
            # Manual Proxy is off: the device could not use the proxy anyway.
            ip = client_ip(flow.client_conn)
            if self.proxy_refused(flow.client_conn):
                allowed = ip in self.allowed
            else:
                allowed = self.admitted(flow.client_conn)
            flow.response = http.Response.make(
                200, json.dumps({"proxy": True, "allowed": allowed}).encode("utf-8"),
                {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*",
                 "Cache-Control": "no-store"})
            return
        if self.addressed_to_setup_page(flow):
            # Baobox's own page: pass it on, keep it out of the list, and don't ask to allow the device for it.
            # The page server would otherwise only see this Mac as the sender; tell it who really asked
            # (it uses that for scan-to-allow). Always overwritten, so a client cannot claim to be another.
            flow.request.headers["X-Baobox-Client"] = client_ip(flow.client_conn) or ""
            # How the device came in: the page leaves out the proxy steps for a tunnel device. Told by the
            # listener, not by the address (a home network can be 10.0.0.x too).
            if via_wireguard(flow.client_conn):
                flow.request.headers["X-Baobox-Via"] = "wireguard"
            else:
                flow.request.headers.pop("X-Baobox-Via", None)
            return
        if self.proxy_refused(flow.client_conn):
            # No `device` event: the device is not waiting to be allowed, Manual Proxy is simply off.
            flow.response = http.Response.make(
                403, LAN_PROXY_OFF_PAGE.encode("utf-8"),
                {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"})
            return
        ip = client_ip(flow.client_conn)
        if not self.admitted(flow.client_conn):
            flow.response = http.Response.make(
                403, FORBIDDEN_PAGE.encode("utf-8"),
                {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"})
            return
        req = flow.request
        rule = self.match_rule(req)
        replay = bool(flow.metadata.get("baobox_replay"))
        # Paused: the request still goes out (and a mock still answers it), it just is not reported.
        # A replay is something the user clicked, so it is reported anyway. Only flows whose request was
        # reported get their response, error and WebSocket messages reported (`baobox_rec`), so nothing
        # shows up half after resuming.
        if self.recording or replay:
            self.emit_request(flow, ip, replay)
        if rule is not None:
            # Answer from the rule; the request never reaches the server.
            flow.metadata["baobox_mock"] = rule["id"]
            flow.response = http.Response.make(rule["status"], rule["body"], http.Headers(rule["headers"]))

    def emit_request(self, flow, ip, replay):
        flow.metadata["baobox_rec"] = True
        req = flow.request
        body, truncated, sniffed = self.body_fields(req)
        emit(with_device({
            "event": "request", "id": flow.id, "client": ip,
            "replay": replay,
            "decoded": self.structured_text(req, flow),
            "method": req.method, "scheme": req.scheme, "host": req.pretty_host,
            "port": req.port, "path": req.path, "http": req.http_version,
            "headers": self.headers(req), "body": body, "truncated": truncated, "sniffed": sniffed,
            "bytes": self.wire_size(req), "ts": req.timestamp_start,
        }, flow.client_conn))

    def response(self, flow: http.HTTPFlow):
        if not flow.metadata.get("baobox_rec"):
            return
        resp = flow.response
        body, truncated, sniffed = self.body_fields(resp)
        remote = None
        peer = getattr(flow.server_conn, "peername", None)
        if peer:
            remote = str(peer[0])
        emit({
            "event": "response", "id": flow.id, "status": resp.status_code,
            "mock": flow.metadata.get("baobox_mock"),
            "decoded": self.structured_text(resp, flow),
            "http": resp.http_version, "headers": self.headers(resp),
            "body": body, "truncated": truncated, "sniffed": sniffed,
            "encoding": resp.headers.get("content-encoding"),
            "bytes": self.wire_size(resp), "remote": remote,
            "ts": resp.timestamp_end or resp.timestamp_start,
        })

    def error(self, flow: http.HTTPFlow):
        if flow.error and flow.metadata.get("baobox_rec"):
            emit({"event": "error", "id": flow.id, "message": flow.error.msg,
                  "ts": flow.error.timestamp})

    def websocket_message(self, flow: http.HTTPFlow):
        if flow.websocket is None or not flow.websocket.messages or not flow.metadata.get("baobox_rec"):
            return
        message = flow.websocket.messages[-1]
        event = {"event": "ws", "id": flow.id, "from_client": message.from_client,
                 "size": len(message.content), "ts": message.timestamp}
        if message.is_text:
            event["text"] = message.text[:65536]
        emit(event)


    # ----- raw TCP (Baobox's "TCP" tab) -------------------------------------
    #
    # The engine treats a connection as raw TCP when it is neither HTTP nor TLS it decrypted into HTTP.
    # TLS it passes through untouched (handshake failed, out of scope, Decrypt HTTPS off, SOCKS on a port
    # other than 443) creates no TCP flow at all, so none of it shows up here; UDP and DNS have hooks of
    # their own and are left alone.

    def tcp_start(self, flow):
        client = flow.client_conn
        state = self.starttls.get(client.id)
        if state is not None:
            # The plaintext that comes out of the TLS Baobox took over after <proceed/>: same row as the XMPP before it.
            flow.metadata["baobox_starttls"] = state
            return
        ip = client_ip(client)
        if not self.recording:
            return
        # From this Mac (through SOCKS, or a CONNECT tunnel on the HTTP proxy) only with "This Mac → TCP"
        # on; tunnel devices always.
        if is_loopback(ip) and not via_wireguard(client) and not self.mac_tcp:
            return
        flow.metadata["baobox_rec"] = True
        flow.metadata["baobox_tcp_bytes"] = 0
        host, port = address_fields(getattr(flow.server_conn, "address", None))
        emit(with_device({"event": "tcp_open", "id": flow.id, "client": ip, "host": host or "", "port": port or 0,
                          "sni": getattr(client, "sni", None),
                          "ts": getattr(flow, "timestamp_created", None) or time.time()}, client))

    def tcp_message(self, flow):
        message = flow.messages[-1]
        # The engine keeps every message of a TCP flow for the life of the connection. Nothing in this
        # process reads the older ones (the layer forwards its own reference to the newest), so drop them
        # and keep memory flat on long-lived connections.
        del flow.messages[:-1]
        state = flow.metadata.get("baobox_starttls")
        if state is not None:
            if state.rec:
                event, state.sent = tcp_data_event(state.id, message.from_client, message.content, state.sent,
                                                   self.body_cap)
                event["ts"] = message.timestamp
                emit(event)
            return
        if not flow.metadata.get("baobox_rec"):
            return
        event, sent = tcp_data_event(flow.id, message.from_client, message.content,
                                     flow.metadata.get("baobox_tcp_bytes", 0), self.body_cap)
        flow.metadata["baobox_tcp_bytes"] = sent
        event["ts"] = message.timestamp
        emit(event)

    def tcp_end(self, flow):
        state = flow.metadata.get("baobox_starttls")
        if state is not None:
            self.close_starttls(state)
        elif flow.metadata.get("baobox_rec"):
            emit({"event": "tcp_close", "id": flow.id, "error": None, "ts": time.time()})

    def tcp_error(self, flow):
        message = getattr(flow.error, "msg", None) or str(flow.error or "")
        state = flow.metadata.get("baobox_starttls")
        if state is not None:
            state.error = state.error or message or "error"
            self.close_starttls(state)
        elif flow.metadata.get("baobox_rec"):
            emit({"event": "tcp_close", "id": flow.id, "error": message or "error", "ts": time.time()})

    # ----- XMPP STARTTLS (docs/packet-capture/STARTTLS.md) ---------------------
    #
    # A connection whose client opens with an XMPP stream header gets StartTLSLayer instead of the engine's TCP layer.
    # It relays and reports the plaintext itself; at <proceed/> it either hands the connection to the engine's TLS
    # layers (Baobox's certificate to the phone) or keeps passing the bytes through.

    def next_layer(self, nextlayer):
        if nextlayer.layer is not None:
            return
        context = nextlayer.context
        client = context.client
        if client.transport_protocol != "tcp" or via_socks(client):
            # SOCKS: leave mail, chat and other apps on this Mac alone (same rule as non-443 TLS there).
            return
        if any(isinstance(item, StartTLSLayer) for item in context.layers):
            return  # inside a connection already taken over: the decrypted stream is plain TCP
        if len(context.layers) == 1 and isinstance(context.layers[0], (modes.HttpProxy, modes.HttpUpstreamProxy)):
            # Bytes written straight to the HTTP proxy port, before any CONNECT: not a tunnel. Leave it to the HTTP
            # proxy layer (otherwise a LAN device could get past "allow" / "block" and fill the TCP tab).
            return
        head = nextlayer.data_client().lstrip()
        if not maybe_xmpp(head):
            return
        # Only connections that may use the engine at all: this Mac, tunnel devices, LAN devices the user allowed
        # (with Manual Proxy on). Anything else is not taken over and not recorded.
        ip = client_ip(client)
        if self.proxy_refused(client) or not (is_loopback(ip) or via_wireguard(client) or ip in self.allowed):
            return
        # A bare `<?xml` (or less) may still turn into an XMPP stream header in the next read (some clients write the
        # XML declaration on its own); the layer only takes over once it has seen one.
        rec = self.recording and not (is_loopback(ip) and not via_wireguard(client) and not self.mac_tcp)
        state = StartTLSState(str(uuid.uuid4()), device_key(client), rec)
        self.starttls[client.id] = state
        nextlayer.layer = StartTLSLayer(context, self, state)

    def starttls_open(self, state, context):
        if not state.rec:
            return
        client = context.client
        host, port = address_fields(getattr(context.server, "address", None))
        emit(with_device({"event": "tcp_open", "id": state.id, "client": client_ip(client), "host": host or "",
                          "port": port or 0, "sni": None, "ts": time.time()}, client))

    def starttls_data(self, state, from_client, data):
        if state.rec and not state.closed:
            event, state.sent = tcp_data_event(state.id, from_client, data, state.sent, self.body_cap)
            emit(event)

    def starttls_may_take_over(self, state, context, head):
        """At <proceed/>: with Decrypt HTTPS off or the XMPP domain out of scope, say why on the row and keep passing
        bytes through (False). Otherwise wait for the ClientHello (True): the failure table needs its fingerprint."""
        state.domain = xmpp_domain(head) or address_fields(getattr(context.server, "address", None))[0] or ""
        if self.scope_mode == "none":
            self.report_tcp_tls(state, "failed", reason="decrypt_off")
            return False
        if not self.in_scope(state.domain):
            self.report_tcp_tls(state, "failed", reason="out_of_scope")
            return False
        return True

    def starttls_take_over(self, state, fingerprint):
        """The ClientHello is complete: take over unless this device + domain + fingerprint failed a handshake before."""
        state.fingerprint = fingerprint
        if self.has_failed(state.key, state.domain, fingerprint):
            self.report_tcp_tls(state, "failed", reason="handshake_failed")
            return False
        state.takeover = True
        return True

    def report_tcp_tls(self, state, outcome, reason=None, sni=None, version=None):
        if state.tls_reported:
            return
        state.tls_reported = True
        if not state.rec:
            return
        event = {"event": "tcp_tls", "id": state.id, "state": outcome, "sni": sni or state.domain}
        if reason:
            event["reason"] = reason
        if version:
            event["version"] = version
        emit(event)

    def close_starttls(self, state):
        if state.rec and not state.closed:
            emit({"event": "tcp_close", "id": state.id, "error": state.error, "ts": time.time()})
        state.closed = True

    def client_disconnected(self, client):
        # The row ends with the client: covers connections that never got (or lost) a TCP flow after <proceed/> --
        # passed through, refused certificate, server unreachable.
        self.fingerprints.pop(client.id, None)
        state = self.starttls.pop(client.id, None)
        if state is not None:
            self.close_starttls(state)


addons = [Bridge()]
