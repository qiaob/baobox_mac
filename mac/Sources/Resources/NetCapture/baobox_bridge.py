"""Baobox <-> mitmproxy bridge (docs/packet-capture/TECH_DESIGN.md §4).

Loaded by the bundled mitmdump with `-s`. It only uses mitmproxy's public addon
hooks.

  stdout  one event per line:  BAOBOX <json>
  stdin   one command per line: <json>      (EOF = Baobox is gone -> shut down)

Bodies travel base64-encoded inside the events; nothing is written to disk.
"""

import asyncio
import base64
import json
import sys
import threading
import zlib

from mitmproxy import ctx, http, tls

PREFIX = "BAOBOX "

FORBIDDEN_PAGE = (
    "<!doctype html><meta charset=utf-8>"
    "<meta name=viewport content='width=device-width, initial-scale=1'>"
    "<title>Baobox</title>"
    "<body style='font-family:-apple-system,sans-serif;padding:32px;line-height:1.6'>"
    "<h2>请在 Mac 上允许这台设备</h2>"
    "<p>打开 Baobox 的抓包窗口，点「允许」后再试。</p>"
    "<h2>Allow this device on the Mac</h2>"
    "<p>Open the Baobox capture window, click Allow, then retry.</p>"
)


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


def via_socks(client):
    """True when the client connection came in through the SOCKS5 listener."""
    mode = getattr(client, "proxy_mode", None)
    return getattr(mode, "type_name", "") == "socks5"


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
        self.failed = set()              # (client ip, host): handshake failed -> pass through
        self.reported = set()            # (client ip, host, reason): `tls` already sent
        self.body_cap = 5 * 1024 * 1024

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

    def running(self):
        self.body_cap = max(1024, ctx.options.baobox_body_cap)
        if ctx.options.baobox_scope:
            try:
                self.apply_scope(json.loads(ctx.options.baobox_scope))
            except ValueError:
                pass
        self.allowed.update(ip for ip in ctx.options.baobox_allowed.split(",") if ip)

        version = ""
        try:
            from mitmproxy import version as mitm_version
            version = mitm_version.VERSION
        except Exception:
            pass
        emit({"event": "running", "version": version})

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

    def apply_scope(self, cmd):
        mode = cmd.get("mode")
        domains = cmd.get("domains")
        if mode in ("all", "allow", "deny") and isinstance(domains, list):
            self.scope_mode = mode
            self.scope_domains = [d for d in domains if isinstance(d, str) and d.strip()]
            self.reported = {r for r in self.reported if r[2] != "out_of_scope"}

    # ----- device admission ------------------------------------------------

    def admitted(self, ip):
        if is_loopback(ip) or ip in self.allowed:
            return True
        if ip not in self.denied and ip not in self.announced:
            self.announced.add(ip)
            emit({"event": "device", "client": ip})
        return False

    def http_connect(self, flow: http.HTTPFlow):
        if not self.admitted(client_ip(flow.client_conn)):
            flow.response = http.Response.make(403, b"", {"Connection": "close"})

    # ----- decrypt scope + automatic passthrough ---------------------------

    def in_scope(self, host):
        if self.scope_mode == "allow":
            return host_in(host, self.scope_domains)
        if self.scope_mode == "deny":
            return not host_in(host, self.scope_domains)
        return True

    def report_tls(self, ip, host, reason):
        key = (ip, host, reason)
        if key in self.reported:
            return
        self.reported.add(key)
        emit({"event": "tls", "client": ip, "host": host, "reason": reason})

    def tls_clienthello(self, data: tls.ClientHelloData):
        host = data.client_hello.sni
        if not host:
            return
        ip = client_ip(data.context.client)
        # The SOCKS listener exists for WebSocket: Apple's WebSocket stack ignores the HTTP proxy and only
        # uses the system SOCKS proxy. But every SOCKS-aware app sends all of its TCP through it (mail,
        # chat, ...). Only web traffic (443) is of interest here; leave everything else untouched.
        if via_socks(data.context.client) and server_port(data.context.server) != 443:
            data.ignore_connection = True
            return
        if (ip, host) in self.failed:
            data.ignore_connection = True
            self.report_tls(ip, host, "handshake_failed")
        elif not self.in_scope(host):
            data.ignore_connection = True
            self.report_tls(ip, host, "out_of_scope")

    def tls_failed_client(self, data: tls.TlsData):
        host = data.conn.sni
        if not host:
            return
        ip = client_ip(data.context.client)
        self.failed.add((ip, host))
        self.report_tls(ip, host, "handshake_failed")

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
        ip = client_ip(flow.client_conn)
        if not self.admitted(ip):
            flow.response = http.Response.make(
                403, FORBIDDEN_PAGE.encode("utf-8"),
                {"Content-Type": "text/html; charset=utf-8"})
            return
        req = flow.request
        body, truncated, sniffed = self.body_fields(req)
        emit({
            "event": "request", "id": flow.id, "client": ip,
            "method": req.method, "scheme": req.scheme, "host": req.pretty_host,
            "port": req.port, "path": req.path, "http": req.http_version,
            "headers": self.headers(req), "body": body, "truncated": truncated, "sniffed": sniffed,
            "bytes": self.wire_size(req), "ts": req.timestamp_start,
        })

    def response(self, flow: http.HTTPFlow):
        if not self.admitted(client_ip(flow.client_conn)):
            return
        resp = flow.response
        body, truncated, sniffed = self.body_fields(resp)
        remote = None
        peer = getattr(flow.server_conn, "peername", None)
        if peer:
            remote = str(peer[0])
        emit({
            "event": "response", "id": flow.id, "status": resp.status_code,
            "http": resp.http_version, "headers": self.headers(resp),
            "body": body, "truncated": truncated, "sniffed": sniffed,
            "encoding": resp.headers.get("content-encoding"),
            "bytes": self.wire_size(resp), "remote": remote,
            "ts": resp.timestamp_end or resp.timestamp_start,
        })

    def error(self, flow: http.HTTPFlow):
        if flow.error and self.admitted(client_ip(flow.client_conn)):
            emit({"event": "error", "id": flow.id, "message": flow.error.msg,
                  "ts": flow.error.timestamp})

    def websocket_message(self, flow: http.HTTPFlow):
        if flow.websocket is None or not flow.websocket.messages:
            return
        message = flow.websocket.messages[-1]
        event = {"event": "ws", "id": flow.id, "from_client": message.from_client,
                 "size": len(message.content), "ts": message.timestamp}
        if message.is_text:
            event["text"] = message.text[:65536]
        emit(event)


addons = [Bridge()]
