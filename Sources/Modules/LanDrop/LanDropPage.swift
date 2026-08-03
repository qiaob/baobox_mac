import Foundation

/// 局域网传输 —— 手机端上传页。
///
/// 整页零外部依赖（CSS / JS 全内联，无任何 CDN 资源）：手机连着的 Wi-Fi 可能没有外网，
/// 一旦引外链资源页面就会白屏或卡住。
///
/// 文案**不走 `L()`**：这是发给手机的字符串，语言应跟随手机而非 Mac 的界面语言
/// （两者未必一致），故按请求头 `Accept-Language` 在本文件的两套常量里选。
enum LanDropPage {

    // MARK: - 文案

    struct Strings {
        let title: String
        let saveTo: String
        let pick: String
        let pickHint: String
        let camera: String
        let uploading: String
        let done: String
        let failed: String
        let tooLarge: String
        let closed: String
        let allDone: String
        let limitNote: String
        /// Mac → 手机方向
        let fromMac: String
        let save: String
        let sendUp: String
    }

    static let zh = Strings(
        title: "传文件到 Mac",
        saveTo: "保存到",
        pick: "选择文件",
        pickHint: "或把文件拖到这里",
        camera: "拍照上传",
        uploading: "上传中",
        done: "已完成",
        failed: "失败",
        tooLarge: "文件超过大小上限",
        closed: "Mac 端已关闭接收，请重新开启后再扫码",
        allDone: "全部完成",
        limitNote: "单个文件上限",
        fromMac: "Mac 发来的文件",
        save: "保存",
        sendUp: "发文件给 Mac"
    )

    static let en = Strings(
        title: "Send to Mac",
        saveTo: "Saving to",
        pick: "Choose files",
        pickHint: "or drop files here",
        camera: "Take a photo",
        uploading: "Uploading",
        done: "Done",
        failed: "Failed",
        tooLarge: "File exceeds the size limit",
        closed: "The Mac stopped receiving. Turn it back on and scan again.",
        allDone: "All done",
        limitNote: "Max file size",
        fromMac: "From your Mac",
        save: "Save",
        sendUp: "Send to your Mac"
    )

    /// 按 `Accept-Language` 选中英文：只要出现中文标记就用中文，否则英文。
    static func strings(acceptLanguage: String?) -> Strings {
        let lang = (acceptLanguage ?? "").lowercased()
        if lang.contains("zh") { return zh }
        return en
    }

    // MARK: - 渲染

    /// 生成完整页面。
    /// - Parameters:
    ///   - token: 访问码，写进页面里的上传 URL
    ///   - folderName: 保存目录名（只给最后一级，不暴露完整路径）
    ///   - maxFileSize: 单文件上限字节数，0 = 不限。前端据此提前拦下超大文件
    ///   - shared: Mac 侧拖进面板的文件（只含句柄 / 名称 / 大小，**不含路径**）
    ///   - acceptLanguage: 请求头原值
    static func html(token: String,
                     folderName: String,
                     maxFileSize: Int,
                     shared: [LanDropSharedItem],
                     acceptLanguage: String?) -> String {
        let s = strings(acceptLanguage: acceptLanguage)
        let limitText = maxFileSize > 0 ? "\(s.limitNote) \(LanDropEnv.formatBytes(maxFileSize))" : ""
        // 首屏直接渲染一份，随后由 /list 轮询增量刷新（Mac 上后拖进来的文件不用手动刷页面）。
        let sharedJSON = json(shared.map { ["id": $0.id, "name": $0.name, "size": $0.size] })

        return """
        <!doctype html>
        <html lang="\(s.title == zh.title ? "zh-Hans" : "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>\(s.title)</title>
        <style>
        :root {
          --accent: #17A398; --bg: #F4F6F5; --card: #FFFFFF; --text: #1B2422;
          --muted: #5D6B68; --line: #DDE4E2; --bad: #C4482F;
        }
        @media (prefers-color-scheme: dark) {
          :root { --accent: #2BC4B8; --bg: #14181A; --card: #1C2224; --text: #E6ECEA;
                  --muted: #9CAAA6; --line: #2A3234; --bad: #FF7A5E; }
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
          margin: 0; background: var(--bg); color: var(--text);
          font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          padding: env(safe-area-inset-top) 16px calc(24px + env(safe-area-inset-bottom));
        }
        header { padding: 26px 4px 18px; }
        h1 { margin: 0; font-size: 24px; letter-spacing: -0.02em; }
        .sub { margin-top: 5px; color: var(--muted); font-size: 14px; }
        .banner {
          display: none; margin-bottom: 14px; padding: 12px 14px; border-radius: 12px;
          background: var(--bad); color: #fff; font-size: 14.5px;
        }
        .banner.on { display: block; }
        .drop {
          display: block; border: 2px dashed var(--line); border-radius: 16px;
          background: var(--card); padding: 34px 18px; text-align: center; cursor: pointer;
          transition: border-color .15s, background .15s;
        }
        .drop.hot { border-color: var(--accent); }
        .drop .plus { font-size: 34px; line-height: 1; color: var(--accent); }
        .drop .main { margin-top: 10px; font-weight: 600; }
        .drop .hint { margin-top: 3px; color: var(--muted); font-size: 14px; }
        .cam {
          display: block; width: 100%; margin-top: 12px; padding: 15px;
          border: 1px solid var(--line); border-radius: 14px; background: var(--card);
          color: var(--text); font: inherit; font-weight: 600; text-align: center; cursor: pointer;
        }
        .note { margin: 14px 4px 0; color: var(--muted); font-size: 13px; }
        h2 { margin: 26px 4px 10px; font-size: 13px; letter-spacing: .04em; text-transform: uppercase;
             color: var(--muted); font-weight: 600; }
        #inbox { display: none; }
        #inbox.on { display: block; }
        .dl {
          display: flex; align-items: center; gap: 12px;
          background: var(--card); border-radius: 13px; padding: 13px 15px; margin-bottom: 10px;
          text-decoration: none; color: inherit;
        }
        .dl .meta { flex: 1; min-width: 0; }
        .dl .fname { font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .dl .fsize { font-size: 12.5px; color: var(--muted); }
        .dl .go {
          flex: none; font-size: 14px; font-weight: 600; color: #fff; background: var(--accent);
          border-radius: 9px; padding: 7px 15px;
        }
        ul { list-style: none; margin: 20px 0 0; padding: 0; display: grid; gap: 10px; }
        li { background: var(--card); border-radius: 13px; padding: 13px 15px; }
        .row { display: flex; align-items: baseline; gap: 10px; }
        .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 15px; }
        .state { font-size: 13px; color: var(--muted); font-variant-numeric: tabular-nums; }
        .state.ok { color: var(--accent); }
        .state.bad { color: var(--bad); }
        .track { height: 5px; margin-top: 9px; border-radius: 3px; background: var(--line); overflow: hidden; }
        .fill { height: 100%; width: 0; background: var(--accent); transition: width .18s ease; }
        li.done .track { display: none; }
        input[type=file] { display: none; }
        </style>
        </head>
        <body>
        <header>
          <h1>\(s.title)</h1>
          <div class="sub">\(s.saveTo) \(escape(folderName))</div>
        </header>
        <div class="banner" id="banner">\(s.closed)</div>
        <section id="inbox">
          <h2>\(s.fromMac)</h2>
          <div id="inboxList"></div>
        </section>
        <h2>\(s.sendUp)</h2>
        <label class="drop" id="drop">
          <div class="plus">+</div>
          <div class="main">\(s.pick)</div>
          <div class="hint">\(s.pickHint)</div>
          <input type="file" id="picker" multiple>
        </label>
        <label class="cam">
          \(s.camera)
          <input type="file" id="cam" accept="image/*" capture="environment">
        </label>
        <div class="note">\(limitText)</div>
        <ul id="list"></ul>
        <script>
        var TOKEN = "\(token)";
        var MAX = \(maxFileSize);
        var T = {
          uploading: "\(s.uploading)", done: "\(s.done)", failed: "\(s.failed)",
          tooLarge: "\(s.tooLarge)", closed: "\(s.closed)", allDone: "\(s.allDone)",
          save: "\(s.save)"
        };
        var SHARED = \(sharedJSON);
        var list = document.getElementById("list");
        var banner = document.getElementById("banner");
        var queue = [];
        var busy = false;

        function add(files) {
          for (var i = 0; i < files.length; i++) {
            var f = files[i];
            var li = document.createElement("li");
            var row = document.createElement("div");
            row.className = "row";
            var name = document.createElement("div");
            name.className = "name";
            name.textContent = f.name;
            var state = document.createElement("div");
            state.className = "state";
            state.textContent = "0%";
            row.appendChild(name);
            row.appendChild(state);
            var track = document.createElement("div");
            track.className = "track";
            var fill = document.createElement("div");
            fill.className = "fill";
            track.appendChild(fill);
            li.appendChild(row);
            li.appendChild(track);
            list.insertBefore(li, list.firstChild);

            if (MAX > 0 && f.size > MAX) {
              li.className = "done";
              state.className = "state bad";
              state.textContent = T.tooLarge;
              continue;
            }
            queue.push({ file: f, li: li, state: state, fill: fill });
          }
          pump();
        }

        function pump() {
          if (busy) { return; }
          var job = queue.shift();
          if (!job) { return; }
          busy = true;
          var xhr = new XMLHttpRequest();
          xhr.open("POST", "/upload?k=" + encodeURIComponent(TOKEN) +
                            "&name=" + encodeURIComponent(job.file.name));
          xhr.upload.onprogress = function (e) {
            if (!e.lengthComputable) { return; }
            var pct = Math.round(e.loaded * 100 / e.total);
            job.fill.style.width = pct + "%";
            job.state.textContent = pct + "%";
          };
          xhr.onload = function () {
            busy = false;
            job.li.className = "done";
            if (xhr.status === 200) {
              job.state.className = "state ok";
              job.state.textContent = T.done;
            } else if (xhr.status === 413) {
              job.state.className = "state bad";
              job.state.textContent = T.tooLarge;
            } else if (xhr.status === 404 || xhr.status === 403) {
              job.state.className = "state bad";
              job.state.textContent = T.failed;
              showClosed();
            } else {
              job.state.className = "state bad";
              job.state.textContent = T.failed;
            }
            pump();
          };
          xhr.onerror = function () {
            busy = false;
            job.li.className = "done";
            job.state.className = "state bad";
            job.state.textContent = T.failed;
            showClosed();
            pump();
          };
          xhr.send(job.file);
        }

        function showClosed() {
          banner.className = "banner on";
        }

        // ---- Mac 发来的文件 ----

        var inbox = document.getElementById("inbox");
        var inboxList = document.getElementById("inboxList");
        var shownIds = "";

        function human(n) {
          var units = ["B", "KB", "MB", "GB"];
          var i = 0;
          while (n >= 1024 && i < units.length - 1) { n = n / 1024; i++; }
          return (i === 0 ? n : n.toFixed(1)) + " " + units[i];
        }

        function renderInbox(items) {
          var key = items.map(function (it) { return it.id; }).join(",");
          if (key === shownIds) { return; }   // 没变化就不重绘，免得打断正在长按的操作
          shownIds = key;
          inboxList.textContent = "";
          items.forEach(function (it) {
            var a = document.createElement("a");
            a.className = "dl";
            a.href = "/file?k=" + encodeURIComponent(TOKEN) + "&id=" + encodeURIComponent(it.id);
            a.setAttribute("download", it.name);
            var meta = document.createElement("div");
            meta.className = "meta";
            var n = document.createElement("div");
            n.className = "fname";
            n.textContent = it.name;
            var sz = document.createElement("div");
            sz.className = "fsize";
            sz.textContent = human(it.size);
            meta.appendChild(n);
            meta.appendChild(sz);
            var go = document.createElement("span");
            go.className = "go";
            go.textContent = T.save;
            a.appendChild(meta);
            a.appendChild(go);
            inboxList.appendChild(a);
          });
          inbox.className = items.length ? "on" : "";
        }

        // 轮询 /list：Mac 上后拖进来的文件会自动出现，不用手动刷页面。
        // 服务端**不把 /list 计为活动**，所以页面一直开着也不会妨碍空闲自动关闭。
        function poll() {
          if (document.hidden) { return; }
          var xhr = new XMLHttpRequest();
          xhr.open("GET", "/list?k=" + encodeURIComponent(TOKEN));
          xhr.onload = function () {
            if (xhr.status !== 200) { showClosed(); return; }
            try {
              renderInbox(JSON.parse(xhr.responseText).items || []);
            } catch (e) { /* 回包异常就保持上一次的渲染 */ }
          };
          xhr.onerror = function () { showClosed(); };
          xhr.send();
        }

        renderInbox(SHARED);
        setInterval(poll, 5000);

        document.getElementById("picker").addEventListener("change", function (e) {
          add(e.target.files);
          e.target.value = "";
        });
        document.getElementById("cam").addEventListener("change", function (e) {
          add(e.target.files);
          e.target.value = "";
        });

        var drop = document.getElementById("drop");
        ["dragenter", "dragover"].forEach(function (name) {
          drop.addEventListener(name, function (e) {
            e.preventDefault();
            drop.className = "drop hot";
          });
        });
        ["dragleave", "drop"].forEach(function (name) {
          drop.addEventListener(name, function (e) {
            e.preventDefault();
            drop.className = "drop";
          });
        });
        drop.addEventListener("drop", function (e) {
          if (e.dataTransfer && e.dataTransfer.files) { add(e.dataTransfer.files); }
        });

        // 回到前台时探活：服务可能已被空闲超时自动关掉，早点告诉用户，别让他上传到一半才发现。
        document.addEventListener("visibilitychange", function () {
          if (document.hidden || busy) { return; }
          var ping = new XMLHttpRequest();
          ping.open("GET", "/ping?k=" + encodeURIComponent(TOKEN));
          ping.onload = function () { if (ping.status !== 200) { showClosed(); } };
          ping.onerror = function () { showClosed(); };
          ping.send();
        });
        </script>
        </body>
        </html>
        """
    }

    /// 序列化成可直接嵌进 `<script>` 的 JSON 字面量。
    ///
    /// 文件名由用户拖进来的文件决定，可能含引号、反斜杠，甚至 `</script>`。
    /// 交给 `JSONSerialization` 生成，再把 `<` `>` 转成 `<` `>`——
    /// 这样任何名字都无法提前闭合脚本标签。
    private static func json(_ value: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    /// 最小 HTML 转义。目录名来自本机设置，仍然转义 —— 不给「设置里写一段脚本」留任何缝。
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
