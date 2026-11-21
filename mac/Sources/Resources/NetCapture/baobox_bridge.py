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
import json
import re
import socket
import sys
import threading
import time
import zlib

from mitmproxy import connection, contentviews, ctx, http, tls

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
        self.rules = []                  # mock rules, in the order the user keeps them
        self.listen_ports = set()        # ports this engine listens on
        self.local_names = local_names()
        self.page_port = 0               # Baobox's setup page for phones, 0 = not running

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

    def running(self):
        self.body_cap = max(1024, ctx.options.baobox_body_cap)
        if ctx.options.baobox_scope:
            try:
                self.apply_scope(json.loads(ctx.options.baobox_scope))
            except ValueError:
                pass
        self.allowed.update(ip for ip in ctx.options.baobox_allowed.split(",") if ip)
        self.page_port = max(0, ctx.options.baobox_page_port)
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

    def apply_scope(self, cmd):
        mode = cmd.get("mode")
        domains = cmd.get("domains")
        if mode in ("all", "allow", "deny") and isinstance(domains, list):
            self.scope_mode = mode
            self.scope_domains = [d for d in domains if isinstance(d, str) and d.strip()]
            self.reported = {r for r in self.reported if r[2] != "out_of_scope"}

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

    def admitted(self, ip):
        if is_loopback(ip) or ip in self.allowed:
            return True
        if ip not in self.denied and ip not in self.announced:
            self.announced.add(ip)
            emit({"event": "device", "client": ip})
        return False

    def http_connect(self, flow: http.HTTPFlow):
        if self.addressed_to_proxy(flow):
            flow.metadata["baobox_self"] = True
            flow.response = http.Response.make(403, b"", {"Connection": "close"})
            return
        if not self.admitted(client_ip(flow.client_conn)):
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
        """True when the request's host is this machine: a loopback name, the host name, or the
        address the client itself used to reach the engine."""
        host = bare_host(flow.request.host)
        if host in self.local_names:
            return True
        sock = getattr(flow.client_conn, "sockname", None)
        return bool(sock) and host == bare_host(sock[0])

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
        if self.addressed_to_proxy(flow):
            # Not traffic to capture: no event, no admission prompt.
            flow.metadata["baobox_self"] = True
            flow.response = self.self_response(flow.request)
            return
        if self.addressed_to_setup_page(flow):
            # Baobox's own page: pass it on, keep it out of the list, and don't ask to allow the device for it.
            flow.metadata["baobox_self"] = True
            return
        ip = client_ip(flow.client_conn)
        if not self.admitted(ip):
            flow.response = http.Response.make(
                403, FORBIDDEN_PAGE.encode("utf-8"),
                {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"})
            return
        req = flow.request
        body, truncated, sniffed = self.body_fields(req)
        rule = self.match_rule(req)
        emit({
            "event": "request", "id": flow.id, "client": ip,
            "replay": bool(flow.metadata.get("baobox_replay")),
            "decoded": self.structured_text(req, flow),
            "method": req.method, "scheme": req.scheme, "host": req.pretty_host,
            "port": req.port, "path": req.path, "http": req.http_version,
            "headers": self.headers(req), "body": body, "truncated": truncated, "sniffed": sniffed,
            "bytes": self.wire_size(req), "ts": req.timestamp_start,
        })
        if rule is not None:
            # Answer from the rule; the request never reaches the server.
            flow.metadata["baobox_mock"] = rule["id"]
            flow.response = http.Response.make(rule["status"], rule["body"], http.Headers(rule["headers"]))

    def response(self, flow: http.HTTPFlow):
        if flow.metadata.get("baobox_self") or not self.admitted(client_ip(flow.client_conn)):
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
        if flow.metadata.get("baobox_self"):
            return
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
