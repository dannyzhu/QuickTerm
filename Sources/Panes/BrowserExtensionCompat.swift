import Foundation
import WebKit

/// WebKit 与 Chrome 的 WebExtension 运行时差异垫片。
///
/// 扩展装进 store 时改写目录：后台脚本前面先跑一段 `__quickterm-compat.js`，补齐 WebKit 缺的 API、
/// 绕开 WebKit 特有的行为差异。目前修的两件事（都有真实扩展因此完全起不来）：
///
/// 1. `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated`：WebKit 没有这两个事件，
///    Stylish 在后台顶层直接 `addListener` → TypeError → 后台加载失败、整个扩展死掉。补成永不触发的空事件。
/// 2. `importScripts()`：WebKit 在每个被导入脚本求值后会清空 microtask 队列（Chrome 不会）。Tampermonkey
///    用「`await null` 之后把启动标记置 false」判断监听器是否在启动阶段注册，而它启动时 `importScripts("/test.js")`
///    一个空文件——在 WebKit 上标记就此翻转，随后 `tabs.onUpdated.addListener` 抛错、初始化中止，popup 永远转圈。
///    空脚本求值本来就没有任何效果，垫片里的 `importScripts` 直接跳过它们（列表在安装时扫描生成）。
///
/// 3. 扩展页面的 URL scheme：Chrome 下是 `chrome-extension://<id>/…`，WebKit 下是 `webkit-extension://<id>/…`。
///    不少 Chrome 构建把 `chrome-extension:` 写死在代码里判断"这是不是我自己的页面"（Tampermonkey 的后台据此拒掉
///    popup 的请求，popup 一片空白）。把所有 .js 里的字面量 `chrome-extension:` 改成 `webkit-extension:`——对 WebKit
///    来说这正是"移植"时该改的那一处，且 Chrome 专属的 `chrome-extension://` URL 在 WebKit 里本来也打不开。
///
/// 4. 嵌在网页里的扩展页面（Stylish 的侧栏是网页里一个 `webkit-extension://…/index.html` iframe）跑在网页的
///    WebContent 进程里，从那里直接调 `tabs.*` / `windows.*` / `action.*` / `scripting.*` / `alarms.*` / `contextMenus.*` /
///    `cookies.*`，UI 进程当成非法 IPC（"Received an invalid message WebExtensionContext_TabsQuery"）直接杀掉整个页面进程。
///    `runtime.sendMessage` / `storage` / `i18n` / `permissions` 从那里调是允许的，于是：网页 WebView 里注入
///    `frameScript`，把这些命名空间换成经 `runtime.sendMessage` 转给后台的代理；后台的垫片（本文件的 compat.js）收到
///    `__quickterm_relay` 消息后代为调用、回传结果。只接受来自扩展自己 origin 的请求。
///
/// 5. `externally_connectable`（网页给扩展发消息）：WebKit 实现了这条通道，但只挂在网页的 `browser.runtime` 上，
///    网页里没有 `chrome`。Chrome 生态的站点一律先看 `"chrome" in window` 再 `chrome.runtime.sendMessage(id, …)`，
///    握手就此静默失败（userstyles.org 这样把登录 token 递给 Stylish，扩展永远显示未登录）。给匹配扩展
///    `externally_connectable.matches` 的网页注入一层最小别名，见 `externalMessagingScript`。
///
/// 改写是幂等的：manifest 里 `__quickterm` 记着原始 `background` 与垫片版本，版本一致就不再动。
/// 扩展更新（重装）会整目录替换，随之重新生成。
enum BrowserExtensionCompat {
    /// 垫片版本：脚本内容或改写规则变了就 +1，已装扩展下次启动会重新生成
    static let version = 2
    static let compatFile = "__quickterm-compat.js"
    static let wrapperFile = "__quickterm-background.js"
    static let manifestKey = "__quickterm"

    enum Failure: Error { case badManifest }

    /// 给扩展目录套上垫片。返回是否改写了文件（已是当前版本 / 没有后台脚本 → false）
    @discardableResult
    static func apply(to directory: URL) throws -> Bool {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badManifest
        }
        let marker = manifest[manifestKey] as? [String: Any]
        // 原始 background：已经改写过的取记录，否则取 manifest 里现成的
        let original: [String: Any]?
        if let marker {
            original = marker["background"] as? [String: Any]
        } else {
            original = manifest["background"] as? [String: Any]
        }
        if let marker, marker["shim"] as? Int == version, shimFilesPresent(for: original, in: directory) {
            return false
        }
        // scheme 字面量替换对没有后台的扩展同样有意义（popup / 选项页自己也会判断 URL）
        try rewriteExtensionScheme(in: directory)
        guard let original, !original.isEmpty else {
            manifest[manifestKey] = ["shim": version]
            try write(manifest: manifest, to: manifestURL)
            return true
        }

        var rewritten = original
        var wrapper: (url: URL, content: String)?
        if let worker = original["service_worker"] as? String, let wrapperPath = wrapperPath(forWorker: worker) {
            let wrapperURL = directory.appendingPathComponent(String(wrapperPath.dropFirst()))
            let workerPath = rootPath(worker)
            let isModule = (original["type"] as? String) == "module"
            let content: String
            if isModule {
                content = "import \(jsString("/" + compatFile));\nimport \(jsString(workerPath));\n"
            } else {
                content = "importScripts(\(jsString("/" + compatFile)), \(jsString(workerPath)));\n"
            }
            wrapper = (wrapperURL, content)
            rewritten["service_worker"] = String(wrapperPath.dropFirst())
        }
        if let scripts = original["scripts"] as? [String] {
            rewritten["scripts"] = ["/" + compatFile] + scripts
        }
        // 只有 background.page（HTML）的：不改，仍然记下版本免得每次启动都扫一遍
        manifest["background"] = rewritten
        manifest[manifestKey] = ["shim": version, "background": original]

        let compat = compatScript(emptyScripts: emptyScripts(in: directory))
        try compat.write(to: directory.appendingPathComponent(compatFile), atomically: true, encoding: .utf8)
        if let wrapper {
            try fm.createDirectory(at: wrapper.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wrapper.content.write(to: wrapper.url, atomically: true, encoding: .utf8)
        }
        try write(manifest: manifest, to: manifestURL)
        return true
    }

    private static func write(manifest: [String: Any], to url: URL) throws {
        let out = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    static let chromeScheme = "chrome-extension:"
    static let webKitScheme = "webkit-extension:"

    /// 所有 .js / .mjs 里的 `chrome-extension:` → `webkit-extension:`（只碰含有该字面量的文件；非 UTF-8 的跳过）。
    /// 两个 scheme 等长，压缩代码里的偏移量 / sourcemap 列号不受影响
    static func rewriteExtensionScheme(in directory: URL) throws {
        for relative in scriptFiles(in: directory) where relative != compatFile {
            let url = directory.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  text.contains(chromeScheme) else { continue }
            try text.replacingOccurrences(of: chromeScheme, with: webKitScheme)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 包装脚本的根相对路径：放在原 worker 同一目录（classic worker 里相对路径的 importScripts 仍按原目录解析）。
    /// worker 路径为空、或带 `..`（manifest 写 "../../x.js" 不能让我们往扩展目录外写文件）→ nil，不包装。
    /// 纯字符串判断，不碰文件系统：目标文件还不存在时解析符号链接的结果不稳定（/var 与 /private/var 只解析一边）
    static func wrapperPath(forWorker worker: String) -> String? {
        let workerPath = rootPath(worker)
        let components = workerPath.split(separator: "/", omittingEmptySubsequences: false)
        guard workerPath != "/", !(workerPath as NSString).lastPathComponent.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        let workerDirectory = (workerPath as NSString).deletingLastPathComponent
        return (workerDirectory as NSString).appendingPathComponent(wrapperFile)
    }

    /// 当前版本该有的文件是否都在（垫片本体 + service_worker 的包装）；没有后台脚本的扩展没有这些文件
    private static func shimFilesPresent(for original: [String: Any]?, in directory: URL) -> Bool {
        guard let original, !original.isEmpty else { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(compatFile).path) else { return false }
        if let worker = original["service_worker"] as? String, let wrapperPath = wrapperPath(forWorker: worker) {
            return fm.fileExists(atPath: directory.appendingPathComponent(String(wrapperPath.dropFirst())).path)
        }
        return true
    }

    /// manifest 里的脚本路径统一成根相对（"bg.js" / "./a/b.js" / "/a/b.js" → "/a/b.js"）
    static func rootPath(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        if !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    static let scriptExtensions: Set<String> = ["js", "mjs"]

    /// 目录里全部脚本文件的相对路径（不含隐藏文件）。用 `enumerator(atPath:)` 拿相对路径：`enumerator(at:)` 给的是
    /// 解析过符号链接的绝对 URL，store 目录本身是链接（放 Dropbox 之类）时前缀对不上、整个列表会空掉
    static func scriptFiles(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        var result: [String] = []
        for case let relative as String in enumerator {
            guard scriptExtensions.contains((relative as NSString).pathExtension),
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path,
                                                 isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            result.append(relative)
        }
        return result.sorted()
    }

    /// 目录里内容为空（或只有空白）的脚本文件，根相对路径；给垫片的 importScripts 跳过用
    static func emptyScripts(in directory: URL) -> [String] {
        scriptFiles(in: directory).filter { relative in
            let url = directory.appendingPathComponent(relative)
            // 大文件不用读：先看 size，只有小于 1 KB 的才读内容判断是否全空白
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size < 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.allSatisfy(\.isWhitespace)
        }.map { "/" + $0 }
    }

    /// 垫片脚本本体（后台脚本之前执行；classic 与 module worker 都能跑）
    static func compatScript(emptyScripts: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: emptyScripts, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        // QuickTerm WebKit 兼容垫片 v\(version)（安装时自动生成，勿手改）
        (() => {
          const g = globalThis;
          const noopEvent = () => ({
            addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; }
          });
          const define = (obj, key, value) => { try { if (obj && obj[key] === undefined) obj[key] = value; } catch (_) {} };
          for (const api of [g.chrome, g.browser]) {
            if (!api) continue;
            // WebKit 没有这两个 webNavigation 事件；有扩展在顶层直接 addListener，缺了整个后台起不来
            if (api.webNavigation) {
              define(api.webNavigation, "onHistoryStateUpdated", noopEvent());
              define(api.webNavigation, "onReferenceFragmentUpdated", noopEvent());
            }
          }
          // 嵌在网页里的扩展 iframe 直接调 tabs.* 等会被 WebKit 杀掉页面进程（见 frameScript）：这里代为调用
          const RELAY = "__quickterm_relay";
          const relayed = new Set();   // chrome 与 browser 多半是同一个对象：同一个 runtime 只挂一次
          for (const api of [g.chrome, g.browser]) {
            if (!api || !api.runtime || !api.runtime.onMessage || relayed.has(api.runtime)) continue;
            relayed.add(api.runtime);
            const own = api.runtime.getURL("");
            api.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || typeof message !== "object" || !(RELAY in message)) return false;
              const url = sender && sender.url;
              if (typeof url !== "string" || !url.startsWith(own)) { reply({ error: "QuickTerm relay: sender is not an extension page" }); return false; }
              const { ns, fn, args } = message[RELAY] || {};
              const target = api[ns];
              const f = target && target[fn];
              if (typeof f !== "function") { reply({ error: "QuickTerm relay: " + ns + "." + fn + " is not available" }); return false; }
              const fail = (e) => { try { reply({ error: String((e && e.message) || e) }); } catch (_) {} };
              Promise.resolve().then(() => f.apply(target, Array.isArray(args) ? args : []))
                .then((result) => {
                  // 结果可能带不过消息通道（Window、宿主对象）：给个明确的错误而不是让框架等到"no response"
                  try { reply({ result: result === undefined ? null : result }); } catch (e) { fail(e); }
                }, fail);
              return true;
            });
          }
          // WebKit 的 importScripts 在每个脚本求值后清空 microtask 队列（Chrome 不会）。空脚本本来就没有效果，
          // 直接跳过，免得靠「一个 microtask 之后」判断启动阶段的扩展（Tampermonkey）被打断
          const EMPTY = new Set(\(list));
          const nativeImport = g.importScripts;
          if (typeof nativeImport === "function" && EMPTY.size) {
            g.importScripts = function (...urls) {
              const keep = urls.filter((u) => {
                try { return !EMPTY.has(decodeURIComponent(new URL(String(u), g.location.href).pathname)); } catch (_) { return true; }
              });
              if (keep.length) return nativeImport.apply(this, keep);
            };
          }
        })();

        """
    }

    /// 注入到**网页** WebView 全部框架的脚本（document start，page world）：只在 `webkit-extension:` 框架里生效，
    /// 把从网页进程直接调会被杀的命名空间换成经后台转发的代理。事件（onXxx）与常量保留原样——注册监听不会触发那条 IPC。
    /// 已知取舍：回调形式拿不到 runtime.lastError；带函数的参数（scripting.executeScript 的 func）过不了消息序列化；
    /// 后台若对所有消息都同步 reply，会抢在转发结果之前
    static let frameScript = """
    (() => {
      // 只管嵌在网页里的扩展 iframe；扩展页面做主帧时跑在扩展进程里（普通配置的 WebView 根本进不去扩展主帧）
      if (location.protocol !== "webkit-extension:" || window === window.top) return;
      const RELAY = "__quickterm_relay";
      const SAFE = new Set(["runtime", "storage", "i18n", "permissions", "extension", "dom", "devtools", "test"]);
      const MARK = Symbol.for("QuickTerm.relayed");
      // API 方法多半挂在原型上：沿原型链收集属性名（到 Object.prototype 为止）
      const propertyNames = (object) => {
        const names = new Set();
        for (let o = object; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
          for (const name of Object.getOwnPropertyNames(o)) if (name !== "constructor") names.add(name);
        }
        return names;
      };
      const relay = (runtime, ns, fn) => function (...args) {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = runtime.sendMessage({ [RELAY]: { ns, fn, args } }).then((response) => {
          if (!response) throw new Error("QuickTerm relay: no response from the extension background");
          if (response.error) throw new Error(response.error);
          return response.result;
        });
        if (!callback) return promise;
        promise.then((value) => callback(value), () => callback(undefined));
        return undefined;
      };
      // WebKit 的命名空间对象上 defineProperty 不生效（宿主对象的静态属性），只能整个换掉根对象：
      // 复制一份普通对象，安全的命名空间原样引用，危险的换成代理
      const wrap = (root) => {
        if (!root || typeof root !== "object" || root[MARK]) return root;
        const runtime = root.runtime;
        if (!runtime || typeof runtime.sendMessage !== "function") return root;
        const wrapped = { [MARK]: true };
        for (const ns of propertyNames(root)) {
          let original;
          try { original = root[ns]; } catch (_) { continue; }
          if (SAFE.has(ns) || !original || typeof original !== "object") { wrapped[ns] = original; continue; }
          const replacement = { [MARK]: true };
          for (const key of propertyNames(original)) {
            let value;
            try { value = original[key]; } catch (_) { continue; }
            replacement[key] = typeof value === "function" ? relay(runtime, ns, key) : value;
          }
          wrapped[ns] = replacement;
        }
        return wrapped;
      };
      for (const name of ["chrome", "browser"]) {
        try {
          const wrapped = wrap(globalThis[name]);
          if (wrapped !== globalThis[name]) Object.defineProperty(globalThis, name, { value: wrapped, configurable: true, writable: true, enumerable: false });
        } catch (_) {}
      }
    })();
    """

    static let frameUserScript = WKUserScript(source: frameScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    // MARK: - externally_connectable：网页 → 扩展的消息通道

    /// 网页侧垫片源码的首行标记：同一个 userContentController 里认得出"这是外部消息垫片"
    /// （内容随已装扩展变化，不能像 frameUserScript 那样按对象同一性去重）
    static let externalMessagingMarker = "// QuickTerm externally_connectable"

    /// manifest 里 `externally_connectable.matches`：允许给这个扩展发消息的网页地址（Chrome match pattern）。
    /// 没声明 / 形状不对 → 空。读的是装进 store 后的 manifest：改写只动 `background`，这个键原样保留
    static func externallyConnectableMatches(in directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = manifest["externally_connectable"] as? [String: Any],
              let matches = block["matches"] as? [Any] else { return [] }
        return matches.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// 网页侧的 `chrome.runtime` 垫片（page world、全部框架、document start）。
    ///
    /// WebKit **实现了** externally_connectable（后台的 `runtime.onMessageExternal` 会照常收到消息），
    /// 但只把入口挂在网页的 `browser.runtime.{sendMessage,connect}` 上——网页里根本没有 `chrome`。
    /// Chrome 生态的站点判断"扩展装没装 / 把 token 递给扩展"用的都是 `"chrome" in window` +
    /// `chrome.runtime.sendMessage(<扩展 id>, msg, cb)`，于是那条握手在 QuickTerm 里静默失败
    /// （userstyles.org 把登录 token 这样递给 Stylish，扩展因此一直显示未登录、没有样式）。
    ///
    /// 这里只补最小的一层别名：`chrome.runtime.sendMessage` / `connect` 直接转给 `browser.runtime`，
    /// 真正的投递与鉴权仍是 WebKit 自己做的（发给没声明本页的扩展只会拿到 undefined）。
    /// 只在**至少一个已装扩展声明了 externally_connectable 且本框架地址匹配**时才定义，
    /// 且绝不覆盖页面上已有的 `chrome`；除消息外不暴露任何 API。
    static func externalMessagingScript(matches: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: matches, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return #"""
        \#(externalMessagingMarker)（按已装扩展的 externally_connectable 生成，勿手改）
        (() => {
          const g = globalThis;
          // 页面上已经有 chrome（真 Chrome、或别的注入）：一概不动
          if (typeof g.chrome !== "undefined") return;
          const runtime = g.browser && g.browser.runtime;
          if (!runtime || typeof runtime.sendMessage !== "function") return;
          const PATTERNS = \#(list);
          const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const glob = (value) => new RegExp("^" + value.split("*").map(escapeRe).join("[\\s\\S]*") + "$");
          // Chrome match pattern：<scheme>://<host><path>，scheme 的 * 只代表 http/https，host 的 *. 含自身
          const parse = (pattern) => {
            if (pattern === "<all_urls>") return { scheme: "*", host: "*", path: /^[\s\S]*$/ };
            const m = /^(\*|[a-zA-Z][a-zA-Z0-9+.-]*):\/\/(\*|(?:\*\.)?[^/*]*)(\/[\s\S]*)$/.exec(pattern);
            return m ? { scheme: m[1].toLowerCase(), host: m[2].toLowerCase(), path: glob(m[3]) } : null;
          };
          let here;
          try { here = new URL(location.href); } catch (_) { return; }
          const scheme = here.protocol.replace(/:$/, "").toLowerCase();
          const host = here.hostname.toLowerCase();
          const path = here.pathname + here.search;
          const matches = PATTERNS.some((pattern) => {
            const p = parse(pattern);
            if (!p) return false;
            if (p.scheme === "*" ? (scheme !== "http" && scheme !== "https") : p.scheme !== scheme) return false;
            if (p.host !== "*") {
              if (p.host.startsWith("*.")) {
                const base = p.host.slice(2);
                if (host !== base && !host.endsWith("." + base)) return false;
              } else if (p.host !== host) return false;
            }
            return p.path.test(path);
          });
          if (!matches) return;
          // Chrome 给普通网页的 runtime 也只有 sendMessage / connect（没有 id、没有 onMessage），这里照此对齐
          const api = {
            sendMessage: function sendMessage(...args) {
              const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
              let promise;
              try { promise = Promise.resolve(runtime.sendMessage.apply(runtime, args)); }
              catch (error) { promise = Promise.reject(error); }
              if (!callback) return promise;   // 无回调 = Promise 形式（Chrome MV3 语义）
              promise.then((value) => callback(value), () => callback(undefined));
              return undefined;
            },
          };
          if (typeof runtime.connect === "function") {
            api.connect = function connect(...args) { return runtime.connect.apply(runtime, args); };
          }
          // 站点常写 `if (chrome.runtime.lastError)`：Chrome 里没出错时读到 undefined
          try { Object.defineProperty(api, "lastError", { get: () => undefined, configurable: true }); } catch (_) {}
          try {
            Object.defineProperty(g, "chrome", { value: { runtime: api }, writable: true, configurable: true, enumerable: true });
          } catch (_) {}
        })();
        """#
    }

    /// 当前应注入网页的外部消息垫片；没有任何扩展声明 externally_connectable → nil（什么都不注入）
    static func externalMessagingUserScript(matches: [String]) -> WKUserScript? {
        let unique = Array(Set(matches)).sorted()
        guard !unique.isEmpty else { return nil }
        return WKUserScript(source: externalMessagingScript(matches: unique),
                            injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// JS 字符串字面量（JSON 编码的字符串在 JS 里是合法字面量）
    static func jsString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }
}
