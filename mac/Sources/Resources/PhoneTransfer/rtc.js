/*
 * Baobox 手机互传 —— 公网模式共享层（手机网页与 Mac 宿主页共用同一份）。
 *
 * 加密信令（AES-GCM，密钥只在二维码里）+ 公共信令后端（ntfy.sh / 公共 MQTT，先到先得）+
 * WebRTC DataChannel 建连 + 分块收发。无第三方依赖。协议见 docs/phone-transfer/TECH_DESIGN.md §4。
 */
(function (global) {
  'use strict';

  const PT = {};

  PT.ICE_SERVERS = [
    { urls: 'stun:stun.cloudflare.com:3478' },
    { urls: 'stun:stun.miwifi.com:3478' },
    { urls: 'stun:stun.chat.bilibili.com:3478' },
    { urls: 'stun:stun.l.google.com:19302' }
  ];

  PT.BACKENDS = [
    { kind: 'ntfy', base: 'https://ntfy.sh', ws: 'wss://ntfy.sh' },
    { kind: 'mqtt', url: 'wss://broker.emqx.io:8084/mqtt' },
    { kind: 'mqtt', url: 'wss://broker.hivemq.com:8884/mqtt' }
  ];

  PT.CHUNK = 16 * 1024;              // DataChannel 单条消息大小（Safari 兼容的安全值）
  PT.HIGH_WATER = 4 * 1024 * 1024;   // bufferedAmount 超过它就暂停
  PT.LOW_WATER = 1024 * 1024;        // 回落到它以下继续
  const NTFY_MAX = 4000;             // ntfy 单条消息上限（超出会被转成附件）
  const MAX_AGE_MS = 10 * 60 * 1000;
  const MAX_SKEW_MS = 2 * 60 * 1000;

  // MARK: - 编码

  function bytesToBinary(bytes) {
    let s = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
    }
    return s;
  }

  function binaryToBytes(s) {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0xff;
    return out;
  }

  PT.b64 = function (bytes) { return btoa(bytesToBinary(bytes)); };
  PT.unb64 = function (s) { return binaryToBytes(atob(s)); };
  PT.b64u = function (bytes) {
    return PT.b64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  PT.unb64u = function (s) {
    let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
    while (t.length % 4) t += '=';
    return PT.unb64(t);
  };
  PT.random = function (n) {
    const b = new Uint8Array(n);
    crypto.getRandomValues(b);
    return b;
  };

  const enc = new TextEncoder();
  const dec = new TextDecoder();

  function hex(bytes) {
    return Array.prototype.map.call(bytes, function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }

  PT.hasCrypto = function () {
    return !!(global.crypto && crypto.subtle && global.isSecureContext !== false);
  };

  PT.hasRTC = function () {
    return typeof global.RTCPeerConnection === 'function';
  };

  PT.canCompress = function () {
    return typeof global.CompressionStream === 'function' && typeof global.DecompressionStream === 'function';
  };

  async function pipeThrough(bytes, stream) {
    const out = new Blob([bytes]).stream().pipeThrough(stream);
    return new Uint8Array(await new Response(out).arrayBuffer());
  }

  PT.topicFor = async function (sid) {
    const digest = await crypto.subtle.digest('SHA-256', enc.encode('baobox-pt:' + sid));
    return 'bbx' + hex(new Uint8Array(digest)).slice(0, 40);
  };

  // MARK: - 信令加密

  async function seal(key, topic, obj, compress) {
    let plain = enc.encode(JSON.stringify(obj));
    let prefix = 'B1.';
    if (compress && PT.canCompress()) {
      plain = await pipeThrough(plain, new CompressionStream('deflate-raw'));
      prefix = 'B1z.';
    }
    const iv = PT.random(12);
    const ct = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: iv, additionalData: enc.encode(topic) }, key, plain));
    const all = new Uint8Array(iv.length + ct.length);
    all.set(iv, 0);
    all.set(ct, iv.length);
    return prefix + PT.b64u(all);
  }

  async function unseal(key, topic, wire) {
    let compressed = false;
    let body;
    if (wire.indexOf('B1.') === 0) body = wire.slice(3);
    else if (wire.indexOf('B1z.') === 0) { body = wire.slice(4); compressed = true; }
    else return null;
    const all = PT.unb64u(body);
    if (all.length < 13) return null;
    const plain = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: all.subarray(0, 12), additionalData: enc.encode(topic) },
      key, all.subarray(12)));
    const json = compressed ? await pipeThrough(plain, new DecompressionStream('deflate-raw')) : plain;
    return JSON.parse(dec.decode(json));
  }

  // MARK: - 信令后端：ntfy

  function NtfyBackend(cfg, topic, sinceSec, onWire, onState) {
    this.cfg = cfg;
    this.topic = topic;
    this.since = sinceSec;
    this.onWire = onWire;
    this.onState = onState;
    this.ready = false;
    this.closed = false;
    this.delay = 1000;
    this.ws = null;
  }

  NtfyBackend.prototype.connect = function () {
    if (this.closed) return;
    const self = this;
    let ws;
    try {
      ws = new WebSocket(this.cfg.ws + '/' + this.topic + '/ws?since=' + this.since);
    } catch (e) {
      this.retry();
      return;
    }
    this.ws = ws;
    ws.onopen = function () { self.ready = true; self.delay = 1000; self.onState(); };
    ws.onmessage = function (ev) {
      try {
        const m = JSON.parse(ev.data);
        if (m && m.event === 'message' && typeof m.message === 'string') self.onWire(m.message);
      } catch (e) { /* 忽略非 JSON */ }
    };
    ws.onclose = function () {
      const was = self.ready;
      self.ready = false;
      if (was) self.onState();
      self.retry();
    };
    ws.onerror = function () { try { ws.close(); } catch (e) { /* noop */ } };
  };

  NtfyBackend.prototype.retry = function () {
    if (this.closed) return;
    const self = this;
    setTimeout(function () { self.connect(); }, this.delay);
    this.delay = Math.min(this.delay * 2, 15000);
  };

  NtfyBackend.prototype.send = function (wire) {
    if (wire.length > NTFY_MAX) return;
    fetch(this.cfg.base + '/' + this.topic, { method: 'POST', body: wire }).catch(function () { /* 其他后端兜底 */ });
  };

  NtfyBackend.prototype.close = function () {
    this.closed = true;
    this.ready = false;
    if (this.ws) { try { this.ws.close(); } catch (e) { /* noop */ } }
  };

  // MARK: - 信令后端：MQTT 3.1.1 over WebSocket（最小实现：QoS 0）

  function mqttString(s) {
    const b = enc.encode(s);
    const out = new Uint8Array(2 + b.length);
    out[0] = b.length >> 8;
    out[1] = b.length & 0xff;
    out.set(b, 2);
    return out;
  }

  function concatBytes(parts) {
    let n = 0;
    parts.forEach(function (p) { n += p.length; });
    const out = new Uint8Array(n);
    let o = 0;
    parts.forEach(function (p) { out.set(p, o); o += p.length; });
    return out;
  }

  function mqttPacket(header, body) {
    const len = [];
    let x = body.length;
    do {
      let d = x % 128;
      x = Math.floor(x / 128);
      if (x > 0) d |= 0x80;
      len.push(d);
    } while (x > 0);
    return concatBytes([new Uint8Array([header]), new Uint8Array(len), body]);
  }

  function MqttBackend(cfg, topic, sinceSec, onWire, onState) {
    this.cfg = cfg;
    this.topic = 'baobox/pt/' + topic;
    this.onWire = onWire;
    this.onState = onState;
    this.ready = false;
    this.closed = false;
    this.delay = 1000;
    this.buf = new Uint8Array(0);
    this.ws = null;
    this.ping = null;
  }

  MqttBackend.prototype.connect = function () {
    if (this.closed) return;
    const self = this;
    let ws;
    try {
      ws = new WebSocket(this.cfg.url, ['mqtt']);
    } catch (e) {
      this.retry();
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    this.buf = new Uint8Array(0);
    ws.onopen = function () {
      const clientID = 'bbx' + hex(PT.random(8));
      const vh = concatBytes([mqttString('MQTT'), new Uint8Array([4, 0x02, 0, 60])]);
      ws.send(mqttPacket(0x10, concatBytes([vh, mqttString(clientID)])));
    };
    ws.onmessage = function (ev) {
      if (!(ev.data instanceof ArrayBuffer)) return;
      self.buf = concatBytes([self.buf, new Uint8Array(ev.data)]);
      self.parse();
    };
    ws.onclose = function () {
      const was = self.ready;
      self.ready = false;
      if (self.ping) { clearInterval(self.ping); self.ping = null; }
      if (was) self.onState();
      self.retry();
    };
    ws.onerror = function () { try { ws.close(); } catch (e) { /* noop */ } };
  };

  MqttBackend.prototype.parse = function () {
    for (;;) {
      const b = this.buf;
      if (b.length < 2) return;
      let mult = 1;
      let len = 0;
      let i = 1;
      let d;
      do {
        if (i >= b.length) return;
        d = b[i++];
        len += (d & 0x7f) * mult;
        mult *= 128;
      } while ((d & 0x80) && i < 5);
      if (b.length < i + len) return;
      const type = b[0] >> 4;
      const body = b.subarray(i, i + len);
      this.buf = b.slice(i + len);
      this.handle(type, b[0] & 0x0f, body);
    }
  };

  MqttBackend.prototype.handle = function (type, flags, body) {
    const self = this;
    if (type === 2) { // CONNACK
      if (body.length >= 2 && body[1] === 0) {
        const sub = concatBytes([new Uint8Array([0, 1]), mqttString(this.topic), new Uint8Array([0])]);
        this.ws.send(mqttPacket(0x82, sub));
      } else {
        try { this.ws.close(); } catch (e) { /* noop */ }
      }
    } else if (type === 9) { // SUBACK
      this.ready = true;
      this.delay = 1000;
      this.ping = setInterval(function () {
        try { self.ws.send(new Uint8Array([0xc0, 0])); } catch (e) { /* noop */ }
      }, 30000);
      this.onState();
    } else if (type === 3) { // PUBLISH
      if (body.length < 2) return;
      const tlen = (body[0] << 8) | body[1];
      let off = 2 + tlen;
      if (((flags >> 1) & 3) > 0) off += 2; // QoS>0 带 packet id（我们只订 QoS0，防御性处理）
      if (off > body.length) return;
      this.onWire(dec.decode(body.subarray(off)));
    }
  };

  MqttBackend.prototype.retry = NtfyBackend.prototype.retry;

  MqttBackend.prototype.send = function (wire) {
    if (!this.ready) return;
    try {
      this.ws.send(mqttPacket(0x30, concatBytes([mqttString(this.topic), enc.encode(wire)])));
    } catch (e) { /* 其他后端兜底 */ }
  };

  MqttBackend.prototype.close = function () {
    this.closed = true;
    this.ready = false;
    if (this.ping) { clearInterval(this.ping); this.ping = null; }
    if (this.ws) {
      try { this.ws.send(new Uint8Array([0xe0, 0])); } catch (e) { /* noop */ }
      try { this.ws.close(); } catch (e) { /* noop */ }
    }
  };

  // MARK: - 信令

  /**
   * opts: { sid, key(Uint8Array 32), self:'p'|'m', since(秒), backends?, onMessage(obj), onStatus(readyCount) }
   */
  function Signaling(opts) {
    this.opts = opts;
    this.backends = [];
    this.seen = {};
    this.waiters = [];
  }

  Signaling.prototype.start = async function () {
    const o = this.opts;
    this.topic = await PT.topicFor(o.sid);
    this.key = await crypto.subtle.importKey('raw', o.key, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
    const self = this;
    const onWire = function (w) { self.incoming(w); };
    const onState = function () {
      const n = self.readyCount();
      if (n > 0) {
        const ws = self.waiters;
        self.waiters = [];
        ws.forEach(function (f) { f(); });
      }
      if (o.onStatus) o.onStatus(n);
    };
    (o.backends || PT.BACKENDS).forEach(function (cfg) {
      const B = cfg.kind === 'ntfy' ? NtfyBackend : MqttBackend;
      const b = new B(cfg, self.topic, o.since, onWire, onState);
      self.backends.push(b);
      b.connect();
    });
  };

  Signaling.prototype.readyCount = function () {
    return this.backends.filter(function (b) { return b.ready; }).length;
  };

  /** 至少一个后端就绪后再多等 graceMs，让其他后端也有机会连上；超时 reject。 */
  Signaling.prototype.whenReady = function (timeoutMs, graceMs) {
    const self = this;
    return new Promise(function (resolve, reject) {
      const done = function () { setTimeout(resolve, graceMs || 0); };
      if (self.readyCount() > 0) { done(); return; }
      const t = setTimeout(function () { reject(new Error('signal-timeout')); }, timeoutMs);
      self.waiters.push(function () { clearTimeout(t); done(); });
    });
  };

  Signaling.prototype.send = async function (obj, compress) {
    obj.v = 1;
    obj.from = this.opts.self;
    obj.id = PT.b64u(PT.random(9));
    obj.ts = Date.now();
    this.seen[obj.id] = true;
    const wire = await seal(this.key, this.topic, obj, compress);
    this.backends.forEach(function (b) { if (b.ready) b.send(wire); });
  };

  Signaling.prototype.incoming = async function (wire) {
    if (typeof wire !== 'string' || wire.indexOf('B1') !== 0) return;
    let obj;
    try {
      obj = await unseal(this.key, this.topic, wire);
    } catch (e) {
      return; // 密钥不对 / 被篡改
    }
    if (!obj || obj.v !== 1 || obj.from === this.opts.self || typeof obj.id !== 'string') return;
    if (this.seen[obj.id]) return;
    const now = Date.now();
    if (typeof obj.ts !== 'number' || obj.ts < now - MAX_AGE_MS || obj.ts > now + MAX_SKEW_MS) return;
    this.seen[obj.id] = true;
    if (this.opts.onMessage) this.opts.onMessage(obj);
  };

  Signaling.prototype.close = function () {
    this.backends.forEach(function (b) { b.close(); });
    this.backends = [];
  };

  PT.Signaling = Signaling;

  // MARK: - WebRTC

  PT.createPeer = function () {
    return new RTCPeerConnection({ iceServers: PT.ICE_SERVERS });
  };

  /** 等候选地址收集完（最多 ms 毫秒），不做 trickle。 */
  PT.gather = function (pc, ms) {
    return new Promise(function (resolve) {
      if (pc.iceGatheringState === 'complete') { resolve(); return; }
      const t = setTimeout(finish, ms);
      function finish() {
        clearTimeout(t);
        pc.removeEventListener('icegatheringstatechange', check);
        resolve();
      }
      function check() { if (pc.iceGatheringState === 'complete') finish(); }
      pc.addEventListener('icegatheringstatechange', check);
    });
  };

  /** 从本地 SDP 的 srflx 候选粗判 NAT：'blocked' | 'symmetric' | 'ok'。 */
  PT.natHint = function (sdp) {
    const ports = {};
    let srflx = 0;
    String(sdp || '').split(/\r?\n/).forEach(function (line) {
      const m = /^a=candidate:\S+ (\d+) udp \d+ (\S+) (\d+) typ srflx/i.exec(line);
      if (!m || m[1] !== '1') return;
      srflx++;
      (ports[m[2]] = ports[m[2]] || {})[m[3]] = true;
    });
    if (srflx === 0) return 'blocked';
    for (const ip in ports) {
      if (Object.keys(ports[ip]).length > 1) return 'symmetric';
    }
    return 'ok';
  };

  /** 选中候选对的类型：两端都是 host → 'lan'，否则 'p2p'；取不到 → 'unknown'。 */
  PT.routeOf = async function (pc) {
    try {
      const stats = await pc.getStats();
      let pair = null;
      let selectedID = null;
      stats.forEach(function (r) {
        if (r.type === 'transport' && r.selectedCandidatePairId) selectedID = r.selectedCandidatePairId;
      });
      stats.forEach(function (r) {
        if (r.type !== 'candidate-pair') return;
        if (selectedID ? r.id === selectedID : (r.nominated && r.state === 'succeeded')) pair = r;
      });
      if (!pair) return 'unknown';
      const local = stats.get(pair.localCandidateId);
      const remote = stats.get(pair.remoteCandidateId);
      if (!local || !remote) return 'unknown';
      return (local.candidateType === 'host' && remote.candidateType === 'host') ? 'lan' : 'p2p';
    } catch (e) {
      return 'unknown';
    }
  };

  // MARK: - DataChannel 收发

  /**
   * handlers: { control(obj), binary(ArrayBuffer), open(), close() }
   */
  function Link(dc, handlers) {
    this.dc = dc;
    dc.binaryType = 'arraybuffer';
    dc.bufferedAmountLowThreshold = PT.LOW_WATER;
    dc.onmessage = function (ev) {
      if (typeof ev.data === 'string') {
        let obj = null;
        try { obj = JSON.parse(ev.data); } catch (e) { return; }
        if (obj && handlers.control) handlers.control(obj);
      } else if (ev.data instanceof ArrayBuffer) {
        if (handlers.binary) handlers.binary(ev.data);
      }
    };
    dc.onopen = function () { if (handlers.open) handlers.open(); };
    dc.onclose = function () { if (handlers.close) handlers.close(); };
  }

  Link.prototype.isOpen = function () { return this.dc.readyState === 'open'; };

  Link.prototype.sendJSON = function (obj) {
    if (!this.isOpen()) throw new Error('closed');
    this.dc.send(JSON.stringify(obj));
  };

  Link.prototype.drain = function () {
    const dc = this.dc;
    if (dc.bufferedAmount <= PT.HIGH_WATER) return Promise.resolve();
    return new Promise(function (resolve) {
      function done() {
        dc.removeEventListener('bufferedamountlow', done);
        dc.removeEventListener('close', done);
        resolve();
      }
      dc.addEventListener('bufferedamountlow', done);
      dc.addEventListener('close', done);
    });
  };

  /** 把一段字节切成 16KB 发出，带背压。 */
  Link.prototype.sendBytes = async function (u8) {
    for (let off = 0; off < u8.length; off += PT.CHUNK) {
      await this.drain();
      if (!this.isOpen()) throw new Error('closed');
      this.dc.send(u8.slice(off, Math.min(off + PT.CHUNK, u8.length)).buffer);
    }
  };

  Link.prototype.close = function () {
    try { this.dc.close(); } catch (e) { /* noop */ }
  };

  PT.Link = Link;

  global.BaoboxPT = PT;
})(typeof window !== 'undefined' ? window : this);
