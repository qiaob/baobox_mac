/*
 * Baobox 手机互传 —— 手机网页逻辑。
 * 地址带 ?t=<令牌>：局域网模式，页面由 Mac 的 HTTP 服务提供，走普通 HTTP 接口。
 * 地址带 #s=<会话>&k=<密钥>：公网模式，页面来自 GitHub Pages，走加密信令 + WebRTC（rtc.js）。
 * 见 docs/phone-transfer/TECH_DESIGN.md。
 */
(function () {
  'use strict';

  // MARK: - 文案

  const STR = {
    zh: {
      title: 'Baobox 互传',
      sendTitle: '发送到电脑',
      typeImages: '图片',
      typeVideos: '视频',
      typeMusic: '音乐',
      typePdf: 'PDF',
      typeWord: 'Word',
      typeExcel: 'Excel',
      typePpt: 'PPT',
      typeText: '文本',
      typeArchive: '压缩包',
      typeAll: '全部文件',
      view: '查看',
      close: '关闭',
      saveHint: '长按图片可存到相册',
      noPreview: '这个格式浏览器显示不了，请用下载。',
      took: '用时 ',
      unitSec: ' 秒',
      unitMin: ' 分 ',
      textPlaceholder: '输入要发送的文字…',
      sendText: '发送文字',
      fromMac: '电脑发来的',
      nothingYet: '还没有内容。在电脑上把文件拖进「手机互传」窗口即可发到这里。',
      download: '下载',
      save: '保存',
      copy: '复制',
      copied: '已复制',
      sent: '已发送',
      failed: '失败',
      waiting: '排队中',
      stConnecting: '连接中',
      stWaiting: '等待确认',
      stConnected: '已连接',
      stLan: '已连接 · 局域网',
      stP2P: '已连接 · 公网直连',
      stOffline: '已断开',
      waitHello: '正在连接电脑…',
      waitApprove: '请在电脑上点击「允许」',
      waitSignal: '正在连接信令服务…',
      waitGather: '正在探测网络…',
      waitRTC: '电脑已允许，正在建立直连…',
      errExpiredTitle: '二维码已失效',
      errExpired: '请在电脑上的「手机互传」窗口点「刷新二维码」，再重新扫码。',
      errDeniedTitle: '电脑拒绝了连接',
      errDenied: '如果是误操作，请在电脑上刷新二维码后重新扫码。',
      errBusy: '电脑已经连着另一台设备。请在电脑上点「新会话」后重新扫码。',
      errUnsupportedTitle: '这个浏览器不支持',
      errUnsupported: '公网模式需要支持 WebRTC 的浏览器（iOS Safari 14.5+ / 新版 Chrome）。',
      errBadLinkTitle: '链接不完整',
      errBadLink: '请直接用相机扫描电脑上的二维码打开。',
      errSignalTitle: '连不上信令服务',
      errSignal: '公共信令服务暂时不可用，或当前网络屏蔽了它们。',
      errNoAnswerTitle: '电脑没有回应',
      errNoAnswer: '请确认电脑上的「手机互传」窗口还开着、处于公网模式，并且能上网。',
      errP2PTitle: '无法建立公网直连',
      errP2P: '手机和电脑之间没能打通直连（本功能不使用中继服务器）。',
      errClosedTitle: '连接已断开',
      errClosed: '电脑关闭了窗口或网络中断。需要的话请重新扫码。',
      natPhone: '手机网络：',
      natMac: '电脑网络：',
      natOk: '正常',
      natSymmetric: '对称型 NAT（运营商网络常见，难以打洞）',
      natBlocked: 'UDP 被拦截或探测失败',
      natUnknown: '未知',
      tipSameWifi: '让手机连上和电脑相同的 Wi-Fi，在电脑上切回「局域网」模式',
      tipHotspot: '电脑连上手机的个人热点，再切回「局域网」模式（一定可用）',
      tipOtherNet: '换个网络再试（例如手机从流量切到 Wi-Fi）',
      noteLan: '局域网模式是明文传输。在咖啡馆等公共 Wi-Fi 上，建议在电脑上改用「公网」模式（端到端加密）。',
      noteBackground: '传输时请保持本页面在前台，切到后台可能导致连接断开。',
      lanLost: '与电脑的连接中断，正在重试…',
      tooBig: '文件较大，手机浏览器可能内存不足',
      deviceCode: '设备码（和电脑上显示的一致再点「允许」）',
      rejSize: '超过单个文件上限 {n}，电脑没收',
      rejRoom: '电脑这次最多还能收 {n}，没收',
      rejBusy: '电脑正忙，稍后再试',
      errMacTitle: '电脑那边出错了',
      errMac: '请在电脑上点「刷新二维码」，再重新扫码。'
    },
    en: {
      title: 'Baobox Transfer',
      sendTitle: 'Send to computer',
      typeImages: 'Photos',
      typeVideos: 'Videos',
      typeMusic: 'Music',
      typePdf: 'PDF',
      typeWord: 'Word',
      typeExcel: 'Excel',
      typePpt: 'PPT',
      typeText: 'Text',
      typeArchive: 'Archives',
      typeAll: 'All files',
      view: 'View',
      close: 'Close',
      saveHint: 'Long-press the image to save it to Photos',
      noPreview: 'This browser can’t display this format. Use Download instead.',
      took: 'took ',
      unitSec: ' s',
      unitMin: 'm ',
      textPlaceholder: 'Type text to send…',
      sendText: 'Send text',
      fromMac: 'From your computer',
      nothingYet: 'Nothing yet. Drag files into the Phone Transfer window on your Mac to send them here.',
      download: 'Download',
      save: 'Save',
      copy: 'Copy',
      copied: 'Copied',
      sent: 'Sent',
      failed: 'Failed',
      waiting: 'Queued',
      stConnecting: 'Connecting',
      stWaiting: 'Waiting',
      stConnected: 'Connected',
      stLan: 'Connected · LAN',
      stP2P: 'Connected · Direct',
      stOffline: 'Disconnected',
      waitHello: 'Connecting to your computer…',
      waitApprove: 'Click “Allow” on your computer',
      waitSignal: 'Connecting to the signaling service…',
      waitGather: 'Probing the network…',
      waitRTC: 'Allowed. Setting up a direct connection…',
      errExpiredTitle: 'This QR code has expired',
      errExpired: 'Click “Refresh QR Code” in the Phone Transfer window on your computer and scan again.',
      errDeniedTitle: 'The computer declined',
      errDenied: 'If that was a mistake, refresh the QR code on your computer and scan again.',
      errBusy: 'The computer is already connected to another device. Click “New Session” there and scan again.',
      errUnsupportedTitle: 'This browser isn’t supported',
      errUnsupported: 'Internet mode needs a browser with WebRTC (iOS Safari 14.5+ or a recent Chrome).',
      errBadLinkTitle: 'Incomplete link',
      errBadLink: 'Open this page by scanning the QR code on your computer with the camera.',
      errSignalTitle: 'Can’t reach the signaling service',
      errSignal: 'The public signaling services are unavailable or blocked on this network.',
      errNoAnswerTitle: 'No response from the computer',
      errNoAnswer: 'Make sure the Phone Transfer window is still open in Internet mode and the computer is online.',
      errP2PTitle: 'Couldn’t connect directly',
      errP2P: 'No direct path could be opened between the phone and the computer (this feature doesn’t use relay servers).',
      errClosedTitle: 'Disconnected',
      errClosed: 'The computer closed the window or the network dropped. Scan again if you need to.',
      natPhone: 'Phone network: ',
      natMac: 'Computer network: ',
      natOk: 'normal',
      natSymmetric: 'symmetric NAT (common on mobile carriers; hard to traverse)',
      natBlocked: 'UDP blocked or probing failed',
      natUnknown: 'unknown',
      tipSameWifi: 'Join the same Wi-Fi as the computer and switch it back to LAN mode',
      tipHotspot: 'Connect the computer to your phone’s hotspot, then switch to LAN mode (always works)',
      tipOtherNet: 'Try another network (for example switch the phone from cellular to Wi-Fi)',
      noteLan: 'LAN mode is not encrypted. On public Wi-Fi (cafés etc.), switch your computer to Internet mode, which is end-to-end encrypted.',
      noteBackground: 'Keep this page in the foreground while transferring; switching away may drop the connection.',
      lanLost: 'Lost the connection to the computer. Retrying…',
      tooBig: 'Large file — the phone browser may run out of memory',
      deviceCode: 'Device code (allow only if the computer shows the same)',
      rejSize: 'Over the {n} per-file limit; the computer didn’t take it',
      rejRoom: 'The computer can take only {n} more this session; not sent',
      rejBusy: 'The computer is busy; try again shortly',
      errMacTitle: 'Something went wrong on the computer',
      errMac: 'Click “Refresh QR Code” on the computer and scan again.'
    }
  };
  const lang = /^zh/i.test(navigator.language || '') ? 'zh' : 'en';
  function T(k) { return (STR[lang] && STR[lang][k]) || STR.en[k] || k; }

  document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en';
  document.title = T('title');
  document.querySelectorAll('[data-i18n]').forEach(function (el) { el.textContent = T(el.getAttribute('data-i18n')); });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
    el.setAttribute('placeholder', T(el.getAttribute('data-i18n-placeholder')));
  });

  // MARK: - 界面工具

  const $ = function (id) { return document.getElementById(id); };

  function fmtSize(n) {
    if (!(n >= 0)) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
    return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  }

  /** 时刻：跟随手机的语言和 12/24 小时制。 */
  function fmtTime(ts) {
    return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }

  /** 用时：不到一分钟保留一位小数。 */
  function fmtDuration(ms) {
    const s = Math.max(0, ms) / 1000;
    if (s < 60) return s.toFixed(1) + T('unitSec');
    return Math.floor(s / 60) + T('unitMin') + Math.round(s % 60) + T('unitSec');
  }

  /** 按扩展名判断图片（显示不了的格式，看大图时会提示改用下载）。 */
  function isImageName(name) {
    return /\.(jpe?g|png|gif|webp|heic|heif|bmp|avif|tiff?)$/i.test(name || '');
  }

  /** 相册给的图片偶尔没有扩展名：按类型补上，电脑端才认得出是图片。 */
  function uploadName(file) {
    const name = file.name || 'file';
    if (/\.[a-z0-9]{2,5}$/i.test(name)) return name;
    const m = /^image\/(jpeg|png|gif|webp|heic|heif|avif|bmp)$/i.exec(file.type || '');
    return m ? name + '.' + (m[1].toLowerCase() === 'jpeg' ? 'jpg' : m[1].toLowerCase()) : name;
  }

  function setStatus(text, kind) {
    const el = $('status');
    el.textContent = text;
    el.className = 'pill' + (kind ? ' ' + kind : '');
  }

  function showWait(text) {
    $('wait-text').textContent = text;
    $('wait').classList.remove('hidden');
    $('main').classList.add('hidden');
    $('error').classList.add('hidden');
  }

  function showMain() {
    $('wait').classList.add('hidden');
    $('error').classList.add('hidden');
    $('main').classList.remove('hidden');
  }

  function showError(title, detail, tips) {
    $('wait').classList.add('hidden');
    $('main').classList.add('hidden');
    $('error').classList.remove('hidden');
    $('error-title').textContent = title;
    const d = $('error-detail');
    d.textContent = '';
    (Array.isArray(detail) ? detail : [detail]).forEach(function (line) {
      const p = document.createElement('div');
      p.textContent = line;
      d.appendChild(p);
    });
    const ul = $('error-tips');
    ul.textContent = '';
    (tips || []).forEach(function (t) {
      const li = document.createElement('li');
      li.textContent = t;
      ul.appendChild(li);
    });
    setStatus(T('stOffline'), 'bad');
  }

  function showNote(text) {
    const n = $('note');
    n.textContent = text;
    n.classList.remove('hidden');
  }

  function showCode(code) {
    const box = $('wait-code');
    box.textContent = T('deviceCode');
    const b = document.createElement('b');
    b.textContent = code;
    box.appendChild(b);
    box.classList.remove('hidden');
  }

  // MARK: - 请求签名（局域网模式，#98，见 TECH_DESIGN §3.4）
  // 页面是 http，浏览器不给用 crypto.subtle，SHA-256 / HMAC 在这里自己算：签的只是几十字节的请求行，文字最多 1 MB，都很快。

  const SHA256_K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]);

  function sha256(bytes) {
    const H = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    const len = bytes.length;
    const total = ((len + 9 + 63) >> 6) << 6;
    const buf = new Uint8Array(total);
    buf.set(bytes);
    buf[len] = 0x80;
    const view = new DataView(buf.buffer);
    view.setUint32(total - 8, Math.floor(len / 0x20000000));
    view.setUint32(total - 4, (len * 8) >>> 0);
    const W = new Uint32Array(64);
    const rotr = function (x, n) { return (x >>> n) | (x << (32 - n)); };
    for (let off = 0; off < total; off += 64) {
      for (let i = 0; i < 16; i++) W[i] = view.getUint32(off + i * 4);
      for (let i = 16; i < 64; i++) {
        const s0 = rotr(W[i - 15], 7) ^ rotr(W[i - 15], 18) ^ (W[i - 15] >>> 3);
        const s1 = rotr(W[i - 2], 17) ^ rotr(W[i - 2], 19) ^ (W[i - 2] >>> 10);
        W[i] = (W[i - 16] + s0 + W[i - 7] + s1) >>> 0;
      }
      let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (let i = 0; i < 64; i++) {
        const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + SHA256_K[i] + W[i]) >>> 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    const out = new Uint8Array(32);
    const outView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) outView.setUint32(i * 4, H[i]);
    return out;
  }

  function hmacSHA256(key, message) {
    if (key.length > 64) key = sha256(key);
    const inner = new Uint8Array(64 + message.length);
    const outer = new Uint8Array(64 + 32);
    for (let i = 0; i < 64; i++) {
      const k = i < key.length ? key[i] : 0;
      inner[i] = k ^ 0x36;
      outer[i] = k ^ 0x5c;
    }
    inner.set(message, 64);
    outer.set(sha256(inner), 64);
    return sha256(outer);
  }

  function utf8(text) { return new TextEncoder().encode(text); }
  function hex(bytes) {
    return Array.prototype.map.call(bytes, function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }
  function unhex(text) {
    const out = new Uint8Array(text.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(text.substr(i * 2, 2), 16);
    return out;
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  /** 发出列表的一行，返回 { begin(), setProgress(0..1), done(), fail() }。传完显示「已发送 · 时刻 · 用时」。 */
  function outRow(name, size) {
    const li = el('li');
    const box = el('div', 'grow');
    box.appendChild(el('div', 'name', name));
    const meta = el('div', 'meta', fmtSize(size) + ' · ' + T('waiting'));
    box.appendChild(meta);
    const bar = el('div', 'bar');
    const fill = el('i');
    bar.appendChild(fill);
    box.appendChild(bar);
    li.appendChild(box);
    $('out-list').prepend(li);
    let started = 0;
    return {
      begin: function () { started = Date.now(); },
      setProgress: function (p) {
        fill.style.width = Math.round(Math.max(0, Math.min(1, p)) * 100) + '%';
        meta.textContent = fmtSize(size) + ' · ' + Math.round(p * 100) + '%';
      },
      done: function () {
        const now = Date.now();
        fill.style.width = '100%';
        meta.textContent = [fmtSize(size), T('sent'), fmtTime(now), T('took') + fmtDuration(now - (started || now))].join(' · ');
      },
      fail: function (why) {
        meta.textContent = [fmtSize(size), why || T('failed'), fmtTime(Date.now())].join(' · ');
      }
    };
  }

  /** 电脑拒收（超过上限，#99）：抛给发送队列，那一行显示原因。 */
  function rejection(why, limit) {
    const e = new Error('rejected');
    e.reason = why === 'size' ? T('rejSize').replace('{n}', fmtSize(limit))
      : why === 'room' ? T('rejRoom').replace('{n}', fmtSize(limit))
      : T('rejBusy');
    return e;
  }

  // MARK: - 看大图（长按存相册）

  function openViewer(src, name, saveLabel) {
    const img = $('viewer-img');
    $('viewer-hint').classList.add('hidden');
    $('viewer-msg').classList.add('hidden');
    img.classList.remove('hidden');
    img.onload = function () { $('viewer-hint').classList.remove('hidden'); };
    img.onerror = function () {
      img.classList.add('hidden');
      $('viewer-msg').classList.remove('hidden');
    };
    img.alt = name;
    img.src = src;
    const save = $('viewer-save');
    save.href = src;
    save.setAttribute('download', name);
    save.textContent = saveLabel;
    $('viewer').classList.remove('hidden');
  }

  function closeViewer() {
    const img = $('viewer-img');
    img.onload = null;
    img.onerror = null;
    img.removeAttribute('src');
    $('viewer').classList.add('hidden');
  }

  $('viewer-close').addEventListener('click', closeViewer);
  $('viewer').addEventListener('click', function (ev) { if (ev.target === $('viewer')) closeViewer(); });

  /** 收到的文件那一行右边的按钮：图片「查看」，其他文件下载 / 保存。 */
  function fileAction(name, href, saveLabel) {
    if (isImageName(name)) {
      const btn = el('button', 'small', T('view'));
      btn.addEventListener('click', function () { openViewer(href, name, saveLabel); });
      return btn;
    }
    const a = el('a', 'btn small', saveLabel);
    a.href = href;
    a.setAttribute('download', name);
    return a;
  }

  function refreshEmpty() {
    $('in-empty').classList.toggle('hidden', $('in-list').children.length > 0);
  }

  function copyText(text, btn) {
    const done = function () { btn.textContent = T('copied'); setTimeout(function () { btn.textContent = T('copy'); }, 1500); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else {
      fallbackCopy(text);
      done();
    }
  }

  function fallbackCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* noop */ }
    ta.remove();
  }

  function addInText(text, ts) {
    const li = el('li');
    const box = el('div', 'grow');
    box.appendChild(el('div', 'textbody', text));
    box.appendChild(el('div', 'meta', fmtTime(ts || Date.now())));
    li.appendChild(box);
    const btn = el('button', 'secondary small', T('copy'));
    btn.addEventListener('click', function () { copyText(text, btn); });
    li.appendChild(btn);
    $('in-list').prepend(li);
    refreshEmpty();
  }

  function deviceName() {
    const ua = navigator.userAgent || '';
    let dev = 'Phone';
    if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) dev = 'iPad';
    else if (/iPhone/.test(ua)) dev = 'iPhone';
    else if (/Android/.test(ua)) {
      const m = /Android[^;]*;\s*([^;)]+?)(?:\s+Build|\))/.exec(ua);
      dev = m ? m[1].trim() : 'Android';
    }
    let br = 'Browser';
    if (/MicroMessenger/.test(ua)) br = 'WeChat';
    else if (/EdgA|EdgiOS/.test(ua)) br = 'Edge';
    else if (/CriOS|Chrome/.test(ua)) br = 'Chrome';
    else if (/FxiOS|Firefox/.test(ua)) br = 'Firefox';
    else if (/Safari/.test(ua)) br = 'Safari';
    return dev + ' · ' + br;
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  // 发送入口：两种模式各自实现 sendFile / sendText。
  let transport = null;
  const queue = [];
  let sending = false;

  async function pump() {
    if (sending) return;
    sending = true;
    while (queue.length) {
      const job = queue.shift();
      job.row.begin();
      try {
        await transport.sendFile(job.file, job.row);
        job.row.done();
      } catch (e) {
        job.row.fail(e && e.reason);
      }
    }
    sending = false;
  }

  function enqueue(input) {
    const files = Array.prototype.slice.call(input.files || []);
    input.value = '';
    files.forEach(function (f) { queue.push({ file: f, row: outRow(uploadName(f), f.size) }); });
    pump();
  }

  // 按类型选文件：筛选由手机系统的选择器做（安卓只列匹配的，iOS「文件」里不匹配的置灰）。
  // accept 同时写扩展名和 MIME：安卓 Chrome 把扩展名换成 MIME 交给系统，iOS 两种都认。
  // WPS 的 .wps / .et / .dps 并入 Word / Excel / PPT，.csv 并入 Excel。
  const TYPES = [
    { key: 'typeImages', icon: '🖼️', accept: 'image/*' },
    { key: 'typeVideos', icon: '🎬', accept: 'video/*' },
    { key: 'typeMusic', icon: '🎵', accept: 'audio/*' },
    { key: 'typePdf', icon: '📄', accept: '.pdf,application/pdf' },
    { key: 'typeWord', icon: '📝', accept: '.doc,.docx,.wps,application/msword,' +
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.ms-works,application/kswps' },
    { key: 'typeExcel', icon: '📊', accept: '.xls,.xlsx,.et,.csv,application/vnd.ms-excel,' +
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/kset,text/csv,text/comma-separated-values' },
    { key: 'typePpt', icon: '📽️', accept: '.ppt,.pptx,.dps,application/vnd.ms-powerpoint,' +
      'application/vnd.openxmlformats-officedocument.presentationml.presentation,application/ksdps' },
    { key: 'typeText', icon: '🗒️', accept: '.txt,text/plain' },
    { key: 'typeArchive', icon: '🗜️', accept: '.zip,.rar,.7z,application/zip,application/x-zip-compressed,' +
      'application/vnd.rar,application/x-rar-compressed,application/x-7z-compressed' },
    { key: 'typeAll', icon: '📁', accept: '' }
  ];
  const fileInput = $('file-input');
  TYPES.forEach(function (t) {
    const btn = el('button', t.accept ? 'secondary' : 'all', t.icon + ' ' + T(t.key));
    btn.type = 'button';
    // 在同一个点击事件里设 accept 再 click()，算用户手势，iOS 也会弹选择器。
    btn.addEventListener('click', function () {
      if (t.accept) fileInput.setAttribute('accept', t.accept);
      else fileInput.removeAttribute('accept');
      fileInput.click();
    });
    $('types').appendChild(btn);
  });
  fileInput.addEventListener('change', function () { enqueue(fileInput); });
  $('send-text').addEventListener('click', async function () {
    const ta = $('text-input');
    const text = ta.value;
    if (!text.trim() || !transport) return;
    const btn = $('send-text');
    btn.disabled = true;
    try {
      await transport.sendText(text);
      ta.value = '';
      btn.textContent = T('sent');
    } catch (e) {
      btn.textContent = T('failed');
    }
    setTimeout(function () { btn.textContent = T('sendText'); btn.disabled = false; }, 1200);
  });

  // MARK: - 局域网模式

  function startLAN(token) {
    let cid = '';
    try { cid = localStorage.getItem('bbx-client') || ''; } catch (e) { /* 无痕模式 */ }
    if (!/^[0-9a-f]{16}$/.test(cid)) {
      cid = Array.prototype.map.call(BaoboxPT.random(8), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
      try { localStorage.setItem('bbx-client', cid); } catch (e) { /* noop */ }
    }
    // 令牌只当密钥，不出现在任何请求里（#98）。批准后电脑发来这台设备自己的密钥 dk，之后都用它签。
    const keyQR = utf8(token);
    let dk = null;
    try {
      const saved = JSON.parse(sessionStorage.getItem('bbx-lan') || 'null');
      if (saved && saved.token === token && saved.cid === cid && /^[0-9a-f]{64}$/.test(saved.dk || '')) dk = unhex(saved.dk);
    } catch (e) { /* noop */ }
    let clock = 0;   // 电脑时钟比本机快多少毫秒：电脑回 401 clock 时按它的 now 校准
    const saveSession = function () {
      try { sessionStorage.setItem('bbx-lan', JSON.stringify({ token: token, cid: cid, dk: dk ? hex(dk) : '' })); } catch (e) { /* noop */ }
    };
    saveSession();
    // 签名：sig = HMAC(dk 或令牌, 方法 \n 路径 \n 查询串)，sig 放最后。下载链接（<img> / <a>）带 exp，其余带 ts + 随机数。
    const signed = function (method, path, extra, exp) {
      let qs = 'c=' + cid + (extra ? '&' + extra : '');
      qs += exp ? '&exp=' + exp : '&ts=' + (Date.now() + clock) + '&n=' + hex(BaoboxPT.random(16));
      const full = '/api/' + path;
      return full + '?' + qs + '&sig=' + hex(hmacSHA256(dk || keyQR, utf8(method + '\n' + full + '\n' + qs)));
    };
    const call = async function (method, path, extra, body) {
      for (let attempt = 0; ; attempt++) {
        const init = { method: method, cache: 'no-store' };
        if (body !== undefined) init.body = body;
        const r = await fetch(signed(method, path, extra), init);
        if (r.status === 401 && attempt === 0) {
          let j = {};
          try { j = await r.clone().json(); } catch (e) { /* noop */ }
          if (j.error === 'clock' && typeof j.now === 'number') { clock = j.now - Date.now(); continue; }
        }
        return r;
      }
    };
    const fileLink = function (id) {
      // <img> / <a download> 加不了随机数：给 6 小时有效期，设备作废时链接一起失效。
      return signed('GET', 'file', 'id=' + encodeURIComponent(id), Date.now() + clock + 6 * 3600 * 1000);
    };
    const codeMac = hmacSHA256(keyQR, utf8('fp:' + cid));
    const deviceCode = ('000' + (((codeMac[0] << 8) | codeMac[1]) % 10000)).slice(-4);

    showNote(T('noteLan'));
    showWait(T('waitHello'));
    setStatus(T('stConnecting'));

    const knownFiles = {};
    let since = 0;
    let lostSince = 0;
    let limits = null;   // 电脑报的上限 { file, room }（#99）：发之前先比一下

    function renderFiles(files) {
      files.forEach(function (f) {
        if (knownFiles[f.id]) return;
        knownFiles[f.id] = true;
        const li = el('li');
        const box = el('div', 'grow');
        box.appendChild(el('div', 'name', f.name));
        box.appendChild(el('div', 'meta', fmtSize(f.size) + (f.ts ? ' · ' + fmtTime(f.ts) : '')));
        li.appendChild(box);
        // 图片直接用下载地址显示：<img> 不理会 Content-Disposition，服务端按扩展名给了图片类型。
        li.appendChild(fileAction(f.name, fileLink(f.id), T('download')));
        $('in-list').prepend(li);
      });
      refreshEmpty();
    }

    async function poll() {
      for (;;) {
        try {
          const r = await call('GET', 'poll', 'since=' + since);
          if (r.status === 401 || r.status === 403) { showError(T('errExpiredTitle'), T('errExpired')); return; }
          const j = await r.json();
          if (j.state === 'denied') { showError(T('errDeniedTitle'), T('errDenied')); return; }
          if (lostSince) { lostSince = 0; setStatus(T('stLan'), 'ok'); }
          renderFiles(j.files || []);
          (j.texts || []).forEach(function (t) { addInText(t.text, t.ts); });
          if (typeof j.seq === 'number') since = j.seq;
          if (j.limits && typeof j.limits.file === 'number' && typeof j.limits.room === 'number') limits = j.limits;
        } catch (e) {
          if (!lostSince) lostSince = Date.now();
          if (Date.now() - lostSince > 4000) setStatus(T('lanLost'), 'bad');
        }
        await sleep(1500);
      }
    }

    async function hello() {
      for (;;) {
        try {
          const r = await call('GET', 'hello', 'name=' + encodeURIComponent(deviceName()));
          if (r.status === 401 || r.status === 403) { showError(T('errExpiredTitle'), T('errExpired')); return; }
          const j = await r.json();
          if (j.state === 'approved' && !dk && typeof j.dk === 'string' && /^[0-9a-f]{64}$/.test(j.dk)) {
            // 电脑发来的设备密钥是用令牌派生的掩码异或过的，抓包的人没有令牌解不出来。
            const mask = hmacSHA256(keyQR, utf8('dk:' + cid));
            dk = unhex(j.dk).map(function (b, i) { return b ^ mask[i]; });
            saveSession();
          }
          if (j.state === 'approved' && dk) {
            setStatus(T('stLan'), 'ok');
            showMain();
            refreshEmpty();
            poll();
            return;
          }
          if (j.state === 'denied') { showError(T('errDeniedTitle'), T('errDenied')); return; }
          showWait(T('waitApprove'));
          showCode(deviceCode);
          setStatus(T('stWaiting'));
        } catch (e) { /* 继续重试 */ }
        await sleep(1000);
      }
    }

    transport = {
      sendFile: function (file, row) {
        return new Promise(function (resolve, reject) {
          // 超了直接在这儿说清楚：传到一半被电脑断开的话，浏览器只会报「网络错误」。
          if (limits && file.size > limits.file) { reject(rejection('size', limits.file)); return; }
          if (limits && file.size > limits.room) { reject(rejection('room', limits.room)); return; }
          const xhr = new XMLHttpRequest();
          xhr.open('POST', signed('POST', 'upload', 'name=' + encodeURIComponent(uploadName(file))));
          xhr.upload.onprogress = function (e) { if (e.lengthComputable && e.total > 0) row.setProgress(e.loaded / e.total); };
          xhr.onload = function () {
            if (xhr.status >= 200 && xhr.status < 300) { resolve(); return; }
            if (xhr.status === 413 || xhr.status === 429) {
              let j = {};
              try { j = JSON.parse(xhr.responseText); } catch (e) { /* noop */ }
              reject(rejection(xhr.status === 429 ? 'busy' : j.error, Number(j.limit) || 0));
              return;
            }
            reject(new Error('http ' + xhr.status));
          };
          xhr.onerror = function () { reject(new Error('network')); };
          xhr.send(file);
        });
      },
      sendText: async function (text) {
        // 文字的哈希放进签过名的查询串，内容被改了电脑那边对不上（#98）。
        const r = await call('POST', 'text', 'bh=' + hex(sha256(utf8(text))), text);
        if (!r.ok) throw new Error('http ' + r.status);
      }
    };

    hello();
  }

  // MARK: - 公网模式

  async function startRTC(sid, keyText) {
    const PT = BaoboxPT;
    if (!PT.hasRTC() || !PT.hasCrypto()) {
      showError(T('errUnsupportedTitle'), T('errUnsupported'));
      return;
    }
    let key;
    try { key = PT.unb64u(keyText); } catch (e) { key = null; }
    if (!key || key.length !== 32 || !sid) {
      showError(T('errBadLinkTitle'), T('errBadLink'));
      return;
    }

    showNote(T('noteBackground'));
    setStatus(T('stConnecting'));
    showWait(T('waitSignal'));

    let answered = false;
    let connected = false;
    let finished = false;
    let connectTimer = null;
    let phoneNat = 'unknown';
    let macNat = 'unknown';
    let pc = null;
    let link = null;
    let rx = null;
    const rejected = {};   // 电脑拒收的文件 id → { why, limit }（#99）
    let limits = null;     // 电脑报的上限 { file, room }：发之前先比一下
    const oid = PT.b64u(PT.random(9));

    function natText(n) {
      return n === 'ok' ? T('natOk') : n === 'symmetric' ? T('natSymmetric') : n === 'blocked' ? T('natBlocked') : T('natUnknown');
    }

    function fail(title, detail, tips) {
      if (finished) return;
      finished = true;
      if (connectTimer) clearTimeout(connectTimer);
      try { sig.close(); } catch (e) { /* noop */ }
      showError(title, detail, tips);
    }

    function failP2P() {
      fail(T('errP2PTitle'),
        [T('errP2P'), T('natPhone') + natText(phoneNat), T('natMac') + natText(macNat)],
        [T('tipSameWifi'), T('tipHotspot'), T('tipOtherNet')]);
    }

    const sig = new PT.Signaling({
      sid: sid, key: key, self: 'p', since: Math.floor(Date.now() / 1000) - 60,
      onMessage: async function (m) {
        if (finished || m.re !== oid) return;
        if (m.t === 'deny' && m.why === 'error') {
          fail(T('errMacTitle'), T('errMac'));
        } else if (m.t === 'deny') {
          fail(T('errDeniedTitle'), m.why === 'busy' ? T('errBusy') : T('errDenied'));
        } else if (m.t === 'answer' && !answered && typeof m.sdp === 'string') {
          answered = true;
          macNat = String(m.nat || 'unknown');
          showWait(T('waitRTC'));
          try {
            await pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
          } catch (e) {
            failP2P();
            return;
          }
          connectTimer = setTimeout(function () { if (!connected) failP2P(); }, 20000);
        }
      }
    });

    try {
      await sig.start();
      await sig.whenReady(12000, 800);
    } catch (e) {
      fail(T('errSignalTitle'), T('errSignal'), [T('tipSameWifi'), T('tipOtherNet')]);
      return;
    }

    showWait(T('waitGather'));
    pc = PT.createPeer();
    const dc = pc.createDataChannel('pt', { ordered: true });
    pc.oniceconnectionstatechange = function () {
      if (pc.iceConnectionState === 'failed' && !connected) failP2P();
    };

    const received = function (name, parts, size, mime, started) {
      const blob = new Blob(parts, { type: mime || '' });
      const url = URL.createObjectURL(blob);
      const now = Date.now();
      const li = el('li');
      const box = el('div', 'grow');
      box.appendChild(el('div', 'name', name));
      box.appendChild(el('div', 'meta', [fmtSize(size), fmtTime(now), T('took') + fmtDuration(now - started)].join(' · ')));
      li.appendChild(box);
      li.appendChild(fileAction(name, url, T('save')));
      $('in-list').prepend(li);
      refreshEmpty();
    };

    link = new PT.Link(dc, {
      open: async function () {
        connected = true;
        if (connectTimer) clearTimeout(connectTimer);
        try { sig.close(); } catch (e) { /* noop */ }
        const route = await PT.routeOf(pc);
        setStatus(route === 'lan' ? T('stLan') : route === 'p2p' ? T('stP2P') : T('stConnected'), 'ok');
        showMain();
        refreshEmpty();
        try { link.sendJSON({ t: 'hello', name: deviceName() }); } catch (e) { /* noop */ }
      },
      close: function () {
        if (connected && !finished) {
          finished = true;
          showError(T('errClosedTitle'), T('errClosed'));
        }
        connected = false;
      },
      control: function (m) {
        if (m.t === 'file' && typeof m.id === 'string') {
          rx = { id: m.id, name: String(m.name || 'file'), size: Number(m.size) || 0, mime: String(m.mime || ''),
                 started: Date.now(), parts: [], got: 0, row: null };
          if (rx.size > 1024 * 1024 * 1024) showNote(T('tooBig'));
          rx.row = (function () {
            const li = el('li');
            const box = el('div', 'grow');
            box.appendChild(el('div', 'name', rx.name));
            const meta = el('div', 'meta', fmtSize(rx.size));
            box.appendChild(meta);
            const bar = el('div', 'bar');
            const fill = el('i');
            bar.appendChild(fill);
            box.appendChild(bar);
            li.appendChild(box);
            $('in-list').prepend(li);
            refreshEmpty();
            return { li: li, meta: meta, fill: fill };
          })();
        } else if (m.t === 'end' && rx && m.id === rx.id) {
          rx.row.li.remove();
          received(rx.name, rx.parts, rx.got, rx.mime, rx.started);
          rx = null;
        } else if (m.t === 'cancel' && rx && m.id === rx.id) {
          rx.row.meta.textContent = fmtSize(rx.size) + ' · ' + T('failed');
          rx = null;
        } else if (m.t === 'text' && typeof m.text === 'string') {
          addInText(m.text);
        } else if (m.t === 'reject' && typeof m.id === 'string') {
          rejected[m.id] = { why: String(m.why || ''), limit: Number(m.limit) || 0 };
        } else if (m.t === 'limits' && typeof m.file === 'number' && typeof m.room === 'number') {
          limits = { file: m.file, room: m.room };
        }
      },
      binary: function (buf) {
        if (!rx) return;
        rx.parts.push(buf);
        rx.got += buf.byteLength;
        if (rx.size > 0) {
          const p = Math.min(1, rx.got / rx.size);
          rx.row.fill.style.width = Math.round(p * 100) + '%';
          rx.row.meta.textContent = fmtSize(rx.size) + ' · ' + Math.round(p * 100) + '%';
        }
      }
    });

    let nextID = 1;
    transport = {
      sendFile: async function (file, row) {
        if (limits && file.size > limits.file) throw rejection('size', limits.file);
        if (limits && file.size > limits.room) throw rejection('room', limits.room);
        const id = 'p' + (nextID++);
        link.sendJSON({ t: 'file', id: id, name: uploadName(file), size: file.size, mime: file.type || '' });
        const step = 1024 * 1024;
        try {
          for (let off = 0; off < file.size; off += step) {
            if (rejected[id]) throw rejection(rejected[id].why, rejected[id].limit);
            const buf = new Uint8Array(await file.slice(off, Math.min(off + step, file.size)).arrayBuffer());
            await link.sendBytes(buf);
            row.setProgress(Math.min(1, (off + buf.length) / Math.max(1, file.size)));
          }
          link.sendJSON({ t: 'end', id: id });
        } catch (e) {
          try { link.sendJSON({ t: 'cancel', id: id }); } catch (e2) { /* noop */ }
          throw e;
        }
      },
      sendText: async function (text) {
        link.sendJSON({ t: 'text', text: text });
      }
    };

    try {
      await pc.setLocalDescription(await pc.createOffer());
      await PT.gather(pc, 4000);
    } catch (e) {
      failP2P();
      return;
    }
    phoneNat = PT.natHint(pc.localDescription.sdp);

    const offerMsg = {
      t: 'offer', oid: oid, sdp: pc.localDescription.sdp, name: deviceName(), nat: phoneNat,
      z: PT.canCompress() ? 1 : 0
    };
    showWait(T('waitApprove'));
    setStatus(T('stWaiting'));

    // 电脑那边可能在点「允许」前后重连信令，所以每 6 秒重发一次，最多 3 分钟。
    const started = Date.now();
    while (!answered && !finished) {
      try { await sig.send(Object.assign({}, offerMsg), true); } catch (e) { /* 下一轮再试 */ }
      await sleep(6000);
      if (Date.now() - started > 3 * 60 * 1000 && !answered) {
        fail(T('errNoAnswerTitle'), T('errNoAnswer'));
        return;
      }
    }
  }

  // MARK: - 入口

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible' && location.hash.indexOf('s=') >= 0) showNote(T('noteBackground'));
  });

  const hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  // 局域网令牌在 # 后面（浏览器不发给电脑，#98）；读到就从地址栏抹掉，刷新时从 sessionStorage 接着用。
  let lanToken = hash.get('t');
  if (lanToken) {
    try { history.replaceState(null, '', location.pathname); } catch (e) { /* noop */ }
  } else {
    try { lanToken = (JSON.parse(sessionStorage.getItem('bbx-lan') || 'null') || {}).token || null; } catch (e) { /* noop */ }
  }
  if (hash.get('s') && hash.get('k')) {
    startRTC(hash.get('s'), hash.get('k'));
  } else if (lanToken) {
    startLAN(lanToken);
  } else {
    showError(T('errBadLinkTitle'), T('errBadLink'));
  }
})();
