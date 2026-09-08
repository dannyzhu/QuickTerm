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
/// 6. 同一个网页里的扩展 iframe，**IndexedDB 是 WebKit 按顶层站点分区的另一份空库**——不是扩展进程页面与
///    service worker 用的那份（`navigator.storage` 在那里是 undefined，`document.requestStorageAccess()` 一律被拒）。
///    消息通道、`chrome.storage.*` 都是通的，所以现象很迷惑：后台明明有数据，侧栏面板却显示"未登录 / 没有数据"
///    （Stylish 的面板直接从 IndexedDB 读已装样式与 Firebase 登录态）。修法：`frameScript` 在这种框架里把整个
///    `indexedDB` 换成一层门面（`frameIndexedDBScript`），每次请求经 `runtime.sendMessage` 交给后台垫片
///    （`backgroundIndexedDBScript`）在扩展真正的分区里执行。`localStorage` 同样被分区，但它是同步 API，
///    没法这样转发——只能仍是每个顶层站点各一份。
///
/// 改写是幂等的：manifest 里 `__quickterm` 记着原始 `background` 与垫片版本，版本一致就不再动。
/// 扩展更新（重装）会整目录替换，随之重新生成。
enum BrowserExtensionCompat {
    /// 垫片版本：脚本内容或改写规则变了就 +1，已装扩展下次启动会重新生成
    static let version = 4
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

    /// 值编解码（后台与 iframe 两侧共用一份，经 runtime.sendMessage 传 IndexedDB 的键 / 值 / 查询区间）
    static let valueCodecScript = """
      // 消息通道只过 JSON 样的值（Date 会变字符串、undefined 会丢）：两侧共用同一份编解码，
      // 另外把 IDBKeyRange 也打成标记对象（查询参数经常是它）
      const TAG = "__quickterm_v";
      const encode = (value, depth) => {
        const level = depth || 0;
        if (value === undefined) return { [TAG]: "undefined" };
        if (value === null) return null;
        const type = typeof value;
        if (type === "boolean" || type === "number" || type === "string") return value;
        if (type !== "object" || level > 24) return null;
        if (value instanceof Date) return { [TAG]: "date", time: value.getTime() };
        if (typeof IDBKeyRange !== "undefined" && value instanceof IDBKeyRange) {
          return { [TAG]: "range", lower: encode(value.lower, level + 1), upper: encode(value.upper, level + 1),
                   lowerOpen: !!value.lowerOpen, upperOpen: !!value.upperOpen };
        }
        if (Array.isArray(value)) return value.map((item) => encode(item, level + 1));
        const out = {};
        for (const key of Object.keys(value)) out[key] = encode(value[key], level + 1);
        return out;
      };
      const decode = (value) => {
        if (value === null || typeof value !== "object") return value;
        if (Array.isArray(value)) return value.map(decode);
        const tag = value[TAG];
        if (tag === "undefined") return undefined;
        if (tag === "date") return new Date(value.time);
        if (tag === "range") {
          const lower = decode(value.lower);
          const upper = decode(value.upper);
          if (lower === undefined && upper === undefined) return undefined;
          if (lower === undefined) return IDBKeyRange.upperBound(upper, !!value.upperOpen);
          if (upper === undefined) return IDBKeyRange.lowerBound(lower, !!value.lowerOpen);
          return IDBKeyRange.bound(lower, upper, !!value.lowerOpen, !!value.upperOpen);
        }
        const out = {};
        for (const key of Object.keys(value)) out[key] = decode(value[key]);
        return out;
      };
    """

    /// 后台侧的 IndexedDB 执行端（垫片里注册；只服务扩展自己 origin 的请求）
    static let backgroundIndexedDBScript = """
      // 网页里嵌的扩展 iframe 拿到的 IndexedDB 是按顶层站点分区的空库（见 frameScript）：代为在扩展自己的分区里执行。
      // 每个请求一个独立事务——转发是异步的，IDB 事务撑不过一次消息往返
      const handles = new Map();
      const dropHandle = (name) => {
        const db = handles.get(name);
        handles.delete(name);
        if (db) { try { db.close(); } catch (_) {} }
      };
      const openPlain = (name) => {
        const cached = handles.get(name);
        if (cached) return Promise.resolve(cached);
        return new Promise((resolve, reject) => {
          const request = g.indexedDB.open(name);
          request.onerror = () => reject(request.error);
          request.onblocked = () => reject(new Error("QuickTerm indexedDB bridge: open is blocked"));
          request.onsuccess = () => {
            const db = request.result;
            db.onversionchange = () => dropHandle(name);   // 别挡住扩展自己发起的升级
            db.onclose = () => { if (handles.get(name) === db) handles.delete(name); };
            handles.set(name, db);
            resolve(db);
          };
        });
      };
      const schemaOf = (db) => {
        const stores = [];
        const names = Array.from(db.objectStoreNames);
        if (names.length) {
          const tx = db.transaction(names, "readonly");
          for (const name of names) {
            const store = tx.objectStore(name);
            stores.push({
              name, keyPath: store.keyPath === undefined ? null : store.keyPath,
              autoIncrement: !!store.autoIncrement,
              indexes: Array.from(store.indexNames).map((indexName) => {
                const index = store.index(indexName);
                return { name: indexName, keyPath: index.keyPath, unique: !!index.unique, multiEntry: !!index.multiEntry };
              }),
            });
          }
          try { tx.abort(); } catch (_) {}
        }
        return { name: db.name, version: db.version, stores };
      };
      const listDatabases = () => {
        if (typeof g.indexedDB.databases !== "function") return Promise.resolve(null);
        return g.indexedDB.databases().then((list) => list || [], () => null);
      };
      const applyUpgrade = (db, tx, ops) => {
        for (const op of ops) {
          const kind = op && op.op;
          if (kind === "createObjectStore") db.createObjectStore(op.name, decode(op.options) || undefined);
          else if (kind === "deleteObjectStore") db.deleteObjectStore(op.name);
          else if (kind === "createIndex") tx.objectStore(op.store).createIndex(op.name, decode(op.keyPath), decode(op.options) || undefined);
          else if (kind === "deleteIndex") tx.objectStore(op.store).deleteIndex(op.name);
          else if (kind === "put" || kind === "add" || kind === "delete" || kind === "clear") {
            const store = tx.objectStore(op.store);
            store[kind].apply(store, decode(op.args) || []);
          }
        }
      };
      // 一个事务里跑一次请求，等到事务真的 complete 再回结果（写入才算落盘）
      const runTransaction = (db, store, mode, body) => new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction([store], mode); } catch (error) { reject(error); return; }
        let settled = false;
        let value;
        const fail = (error) => {
          if (settled) return;
          settled = true;
          reject(error || new Error("QuickTerm indexedDB bridge: the transaction failed"));
        };
        tx.onabort = () => fail(tx.error);
        tx.onerror = () => fail(tx.error);
        tx.oncomplete = () => { if (!settled) { settled = true; resolve(value); } };
        try { body(tx, (result) => { value = result; }, fail); }
        catch (error) { try { tx.abort(); } catch (_) {} fail(error); }
      });
      const idbCall = async (payload) => {
        const p = payload || {};
        if (!g.indexedDB) throw new Error("QuickTerm indexedDB bridge: this background has no indexedDB");
        const name = String(p.name === undefined ? "" : p.name);
        if (p.op === "databases") {
          const list = await listDatabases();
          return (list || []).map((entry) => ({ name: entry.name, version: entry.version }));
        }
        if (p.op === "deleteDatabase") {
          dropHandle(name);
          return await new Promise((resolve, reject) => {
            const request = g.indexedDB.deleteDatabase(name);
            request.onsuccess = () => resolve(null);
            request.onblocked = () => resolve(null);
            request.onerror = () => reject(request.error);
          });
        }
        if (p.op === "open") {
          const wanted = p.version === null || p.version === undefined ? null : Number(p.version);
          // 库还不存在时不能直接 open（那会凭空建一个 v1、还把 upgradeneeded 吞掉）：先问 databases()。
          // 不带版本号的 open 同样要走这一步——原生对不存在的库也会 upgradeneeded(0→1)，
          // 直接 openPlain 的话扩展建表的那个回调永远不跑，之后 transaction() 一律 NotFoundError
          const list = await listDatabases();
          if (list) {
            const found = list.find((entry) => entry.name === name);
            const current = found ? found.version : 0;
            const target = wanted === null ? Math.max(current, 1) : wanted;
            if (current < target) {
              const stores = current > 0 ? schemaOf(await openPlain(name)).stores : [];
              dropHandle(name);
              return { upgrade: true, oldVersion: current, version: target, stores };
            }
          }
          const db = await openPlain(name);
          if (wanted !== null && db.version < wanted) {
            const stores = schemaOf(db).stores;
            dropHandle(name);
            return { upgrade: true, oldVersion: db.version, version: wanted, stores };
          }
          if (wanted !== null && db.version > wanted) {
            const error = new Error("The requested version is older than the existing version");
            error.name = "VersionError";
            throw error;
          }
          return schemaOf(db);
        }
        if (p.op === "upgrade") {
          dropHandle(name);
          const ops = Array.isArray(p.ops) ? p.ops : [];
          const db = await new Promise((resolve, reject) => {
            const request = g.indexedDB.open(name, Number(p.version));
            request.onupgradeneeded = () => {
              try { applyUpgrade(request.result, request.transaction, ops); }
              catch (error) { try { request.transaction.abort(); } catch (_) {} reject(error); }
            };
            request.onblocked = () => reject(new Error("QuickTerm indexedDB bridge: the upgrade is blocked"));
            request.onerror = () => reject(request.error);
            request.onsuccess = () => resolve(request.result);
          });
          db.onversionchange = () => dropHandle(name);
          db.onclose = () => { if (handles.get(name) === db) handles.delete(name); };
          handles.set(name, db);
          return schemaOf(db);
        }
        if (p.op === "call" || p.op === "cursor") {
          const db = await openPlain(name);
          const store = String(p.store);
          const mode = p.mode === "readwrite" ? "readwrite" : "readonly";
          const index = p.index === null || p.index === undefined ? null : String(p.index);
          const method = String(p.method);
          const args = decode(p.args) || [];
          if (p.op === "call") {
            return await runTransaction(db, store, mode, (tx, keep, fail) => {
              const target = index ? tx.objectStore(store).index(index) : tx.objectStore(store);
              const fn = target[method];
              if (typeof fn !== "function") throw new Error("QuickTerm indexedDB bridge: " + method + " is not available");
              const request = fn.apply(target, args);
              request.onsuccess = () => keep(request.result);
              request.onerror = () => fail(request.error);
            });
          }
          // 游标撑不过消息往返：后台一次跑完，把结果拍平送回去，iframe 侧在这份快照上走 continue()
          const limit = Math.max(1, Math.min(Number(p.limit) || 1000, 10000));
          const keysOnly = method === "openKeyCursor";
          const rows = [];
          await runTransaction(db, store, mode, (tx, keep, fail) => {
            const target = index ? tx.objectStore(store).index(index) : tx.objectStore(store);
            const request = keysOnly ? target.openKeyCursor.apply(target, args) : target.openCursor.apply(target, args);
            request.onerror = () => fail(request.error);
            request.onsuccess = () => {
              const cursor = request.result;
              if (!cursor) return;
              rows.push({ key: cursor.key, primaryKey: cursor.primaryKey, value: keysOnly ? undefined : cursor.value });
              // 多取一条才分得清"正好 limit 条"和"还有更多"：iframe 侧要靠这个区分走完与被截断
              if (rows.length <= limit) cursor.continue();
            };
          });
          const truncated = rows.length > limit;
          if (truncated) rows.length = limit;
          return { rows, truncated };
        }
        throw new Error("QuickTerm indexedDB bridge: unknown operation " + String(p.op));
      };
    """

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
          // 嵌在网页里的扩展 iframe 直接调 tabs.* 等会被 WebKit 杀掉页面进程、而它的 IndexedDB 是按顶层站点
          // 分区的另一份空库（都见 frameScript）：这两条都由这里代为执行
          const RELAY = "__quickterm_relay";
          const STORAGE = "__quickterm_idb";
        \(valueCodecScript)
        \(backgroundIndexedDBScript)
          const relayed = new Set();   // chrome 与 browser 多半是同一个对象：同一个 runtime 只挂一次
          for (const api of [g.chrome, g.browser]) {
            if (!api || !api.runtime || !api.runtime.onMessage || relayed.has(api.runtime)) continue;
            relayed.add(api.runtime);
            const own = api.runtime.getURL("");
            api.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || typeof message !== "object") return false;
              const isRelay = RELAY in message;
              const isStorage = STORAGE in message;
              if (!isRelay && !isStorage) return false;
              const url = sender && sender.url;
              if (typeof url !== "string" || !url.startsWith(own)) { reply({ error: "QuickTerm relay: sender is not an extension page" }); return false; }
              const fail = (e) => { try { reply({ error: String((e && e.message) || e) || "error", name: e && e.name }); } catch (_) {} };
              if (isStorage) {
                idbCall(message[STORAGE]).then((result) => {
                  try { reply({ result: encode(result) }); } catch (e) { fail(e); }
                }, fail);
                return true;
              }
              const { ns, fn, args } = message[RELAY] || {};
              const target = api[ns];
              const f = target && target[fn];
              if (typeof f !== "function") { reply({ error: "QuickTerm relay: " + ns + "." + fn + " is not available" }); return false; }
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

    /// iframe 侧的 IndexedDB 桥：`frameScript` 里用，见那里的注释
    static let frameIndexedDBScript = """
      // 网页里嵌的扩展 iframe 拿到的 IndexedDB / localStorage 是 WebKit 按顶层站点分区的**另一份空库**，
      // 不是扩展进程页面与 service worker 用的那份（navigator.storage 也没有，requestStorageAccess 一律被拒）。
      // 侧栏这类面板的登录态、数据全在扩展自己那份里，于是面板永远显示"未登录 / 没有数据"。
      // 这里把整个 indexedDB 换成一层门面：每个请求都经 runtime.sendMessage 交给后台，在扩展真正的分区里执行。
      const bridgeIndexedDB = (runtime) => {
        const native = globalThis.indexedDB;
        if (!native || typeof globalThis.IDBRequest !== "function" || typeof runtime.sendMessage !== "function") return;
        const CHANNEL = "__quickterm_idb";
        // 消息通道只过 JSON 样的值（Date 会变字符串、undefined 会丢）：两侧共用同一份编解码，
        // 另外把 IDBKeyRange 也打成标记对象（查询参数经常是它）
        const TAG = "__quickterm_v";
        const encode = (value, depth) => {
          const level = depth || 0;
          if (value === undefined) return { [TAG]: "undefined" };
          if (value === null) return null;
          const type = typeof value;
          if (type === "boolean" || type === "number" || type === "string") return value;
          if (type !== "object" || level > 24) return null;
          if (value instanceof Date) return { [TAG]: "date", time: value.getTime() };
          if (typeof IDBKeyRange !== "undefined" && value instanceof IDBKeyRange) {
            return { [TAG]: "range", lower: encode(value.lower, level + 1), upper: encode(value.upper, level + 1),
                     lowerOpen: !!value.lowerOpen, upperOpen: !!value.upperOpen };
          }
          if (Array.isArray(value)) return value.map((item) => encode(item, level + 1));
          const out = {};
          for (const key of Object.keys(value)) out[key] = encode(value[key], level + 1);
          return out;
        };
        const decode = (value) => {
          if (value === null || typeof value !== "object") return value;
          if (Array.isArray(value)) return value.map(decode);
          const tag = value[TAG];
          if (tag === "undefined") return undefined;
          if (tag === "date") return new Date(value.time);
          if (tag === "range") {
            const lower = decode(value.lower);
            const upper = decode(value.upper);
            if (lower === undefined && upper === undefined) return undefined;
            if (lower === undefined) return IDBKeyRange.upperBound(upper, !!value.upperOpen);
            if (upper === undefined) return IDBKeyRange.lowerBound(lower, !!value.lowerOpen);
            return IDBKeyRange.bound(lower, upper, !!value.lowerOpen, !!value.upperOpen);
          }
          const out = {};
          for (const key of Object.keys(value)) out[key] = decode(value[key]);
          return out;
        };
        const failure = (message, name) => {
          try { return new DOMException(String(message), name || "UnknownError"); }
          catch (_) { const error = new Error(String(message)); error.name = name || "UnknownError"; return error; }
        };
        const send = (payload) => runtime.sendMessage({ [CHANNEL]: payload }).then((response) => {
          if (!response) throw new Error("QuickTerm indexedDB bridge: no response from the extension background");
          if (response.error) throw failure(response.error, response.name);
          return decode(response.result);
        });
        // 事件：on<type> 属性与 addEventListener 都要发到（event.target 得是对象本身，所以统一走 dispatchEvent）
        const fire = (target, type, event) => {
          const handler = target["on" + type];
          if (typeof handler === "function") target.addEventListener(type, handler, { once: true });
          try { target.dispatchEvent(event); } catch (_) {}
        };
        const succeed = (request, value) => {
          request.readyState = "done"; request.result = value; request.error = null;
          fire(request, "success", new Event("success"));
        };
        const failRequest = (request, error) => {
          request.readyState = "done"; request.error = error;
          fire(request, "error", new Event("error"));
        };
        const nameList = (values) => {
          const list = values.slice();
          list.contains = (value) => list.indexOf(String(value)) !== -1;
          list.item = (i) => (i >= 0 && i < list.length ? list[i] : null);
          return list;
        };
        // 门面对象要能通过 `x instanceof IDBRequest`（idb 之类的包装库全靠它认路）：把原型接到原生原型上。
        // 原生原型上的 name / result / … 是只读 getter，class 里 `this.name = …` 在严格模式下会抛，
        // 所以接完再把这些名字在自己的原型上覆写成可写数据属性
        const inherit = (klass, base, fields) => {
          try { if (typeof base === "function" && base.prototype) Object.setPrototypeOf(klass.prototype, base.prototype); } catch (_) {}
          for (const field of fields) {
            try { Object.defineProperty(klass.prototype, field, { value: undefined, writable: true, configurable: true }); } catch (_) {}
          }
        };

        class BridgeRequest extends EventTarget {
          constructor(source, transaction) {
            super();
            this.source = source || null; this.transaction = transaction || null;
            this.result = undefined; this.error = null; this.readyState = "pending";
            this.onsuccess = null; this.onerror = null;
          }
        }
        inherit(BridgeRequest, globalThis.IDBRequest,
                ["source", "transaction", "result", "error", "readyState", "onsuccess", "onerror"]);

        class BridgeOpenRequest extends EventTarget {
          constructor() {
            super();
            this.source = null; this.transaction = null;
            this.result = undefined; this.error = null; this.readyState = "pending";
            this.onsuccess = null; this.onerror = null; this.onupgradeneeded = null; this.onblocked = null;
          }
        }
        inherit(BridgeOpenRequest, globalThis.IDBOpenDBRequest || globalThis.IDBRequest,
                ["source", "transaction", "result", "error", "readyState", "onsuccess", "onerror", "onupgradeneeded", "onblocked"]);

        class BridgeCursor {
          constructor(request, store, indexName, direction, rows, keysOnly, truncated) {
            this.request = request;
            this.source = indexName ? store.index(indexName) : store;
            this.direction = direction || "next";
            this.key = undefined; this.primaryKey = undefined; this.value = undefined;
            this._store = store; this._rows = rows; this._keysOnly = keysOnly; this._at = 0;
            this._truncated = !!truncated;
            this._load(0);
          }
          _load(at) {
            const row = this._rows[at];
            this._at = at;
            this.key = row ? decode(row.key) : undefined;
            this.primaryKey = row ? decode(row.primaryKey) : undefined;
            if (!this._keysOnly) this.value = row ? decode(row.value) : undefined;
          }
          // continue(key)：正向游标找第一条 >= key 的，反向（prev*）游标的快照是降序的，要找第一条 <= key 的
          _seek(key, from) {
            const back = String(this.direction).indexOf("prev") === 0;
            for (let i = from; i < this._rows.length; i += 1) {
              try {
                const order = native.cmp(decode(this._rows[i].key), key);
                if (back ? order <= 0 : order >= 0) return i;
              } catch (_) { return i; }
            }
            return this._rows.length;
          }
          // 原生的 continue() 返回 undefined、让原来那个 request 再触发一次 success；这里照做，
          // 另外把 request 返回出去（idb 会把返回值再包一层 Promise，正好拿到下一个游标）
          _step(next) {
            const request = this.request;
            const transaction = request.transaction;
            transaction._pending += 1;
            Promise.resolve().then(() => {
              transaction._pending -= 1;
              if (next < this._rows.length) { this._load(next); succeed(request, this); }
              else if (this._truncated) {
                // 快照被截断了：走到末尾不能报"迭代结束"（那是把剩下的记录悄悄抹掉），明确失败
                const error = failure("QuickTerm indexedDB bridge: the cursor snapshot was truncated at "
                                      + this._rows.length + " rows", "UnknownError");
                transaction.error = error;
                failRequest(request, error);
                transaction._finish("error");
              }
              else succeed(request, null);
              transaction._schedule();
            });
            return request;
          }
          continue(key) { return this._step(key === undefined ? this._at + 1 : this._seek(key, this._at + 1)); }
          continuePrimaryKey(key) { return this.continue(key); }
          advance(count) { return this._step(this._at + Math.max(1, Number(count) || 1)); }
          update(value) {
            const keyPath = this._store.keyPath;
            return this._store._call("put", keyPath === null || keyPath === undefined ? [value, this.primaryKey] : [value], true);
          }
          delete() { return this._store._call("delete", [this.primaryKey], true); }
        }
        inherit(BridgeCursor, globalThis.IDBCursorWithValue || globalThis.IDBCursor,
                ["request", "source", "direction", "key", "primaryKey", "value"]);

        class BridgeIndex {
          constructor(store, info) {
            this.objectStore = store; this.name = info.name; this.keyPath = info.keyPath;
            this.unique = !!info.unique; this.multiEntry = !!info.multiEntry;
          }
          get(...args) { return this.objectStore._call("get", args, false, this.name); }
          getKey(...args) { return this.objectStore._call("getKey", args, false, this.name); }
          getAll(...args) { return this.objectStore._call("getAll", args, false, this.name); }
          getAllKeys(...args) { return this.objectStore._call("getAllKeys", args, false, this.name); }
          count(...args) { return this.objectStore._call("count", args, false, this.name); }
          openCursor(...args) { return this.objectStore._cursor("openCursor", args, this.name); }
          openKeyCursor(...args) { return this.objectStore._cursor("openKeyCursor", args, this.name); }
        }
        inherit(BridgeIndex, globalThis.IDBIndex, ["objectStore", "name", "keyPath", "unique", "multiEntry"]);

        class BridgeObjectStore {
          constructor(transaction, info) {
            this.transaction = transaction; this.name = info.name;
            this.keyPath = info.keyPath === undefined ? null : info.keyPath;
            this.autoIncrement = !!info.autoIncrement;
            this.indexNames = nameList((info.indexes || []).map((index) => index.name));
            this._info = info;
          }
          get(...args) { return this._call("get", args); }
          getKey(...args) { return this._call("getKey", args); }
          getAll(...args) { return this._call("getAll", args); }
          getAllKeys(...args) { return this._call("getAllKeys", args); }
          count(...args) { return this._call("count", args); }
          put(...args) { return this._call("put", args, true); }
          add(...args) { return this._call("add", args, true); }
          delete(...args) { return this._call("delete", args, true); }
          clear(...args) { return this._call("clear", args, true); }
          openCursor(...args) { return this._cursor("openCursor", args); }
          openKeyCursor(...args) { return this._cursor("openKeyCursor", args); }
          index(name) {
            const info = (this._info.indexes || []).find((index) => index.name === String(name));
            if (!info) throw failure("No index named " + name, "NotFoundError");
            return new BridgeIndex(this, info);
          }
          createIndex(name, keyPath, options) {
            const transaction = this.transaction;
            if (!transaction._ops) throw failure("createIndex is only allowed during an upgrade", "InvalidStateError");
            const info = { name: String(name), keyPath, unique: !!(options && options.unique), multiEntry: !!(options && options.multiEntry) };
            this._info.indexes = (this._info.indexes || []).concat([info]);
            this.indexNames = nameList(this._info.indexes.map((index) => index.name));
            transaction._ops.push({ op: "createIndex", store: this.name, name: info.name,
                                    keyPath: encode(keyPath), options: encode(options || {}) });
            return new BridgeIndex(this, info);
          }
          deleteIndex(name) {
            const transaction = this.transaction;
            if (!transaction._ops) throw failure("deleteIndex is only allowed during an upgrade", "InvalidStateError");
            this._info.indexes = (this._info.indexes || []).filter((index) => index.name !== String(name));
            this.indexNames = nameList(this._info.indexes.map((index) => index.name));
            transaction._ops.push({ op: "deleteIndex", store: this.name, name: String(name) });
          }
          _call(method, args, write, indexName) {
            const transaction = this.transaction;
            if (transaction._ops) {
              // 升级事务：后台那边的 versionchange 事务撑不过消息往返，先录下来一起重放
              if (!write) throw failure("QuickTerm indexedDB bridge: reads are not supported inside an upgrade transaction", "InvalidStateError");
              transaction._ops.push({ op: method, store: this.name, args: encode(args) });
              const request = new BridgeRequest(this, transaction);
              Promise.resolve().then(() => succeed(request, undefined));
              return request;
            }
            return transaction._request(this, indexName || null, method, args, !!write);
          }
          _cursor(method, args, indexName) {
            return this.transaction._cursor(this, indexName || null, method, args);
          }
        }
        inherit(BridgeObjectStore, globalThis.IDBObjectStore,
                ["transaction", "name", "keyPath", "autoIncrement", "indexNames"]);

        class BridgeTransaction extends EventTarget {
          constructor(db, storeNames, mode, manual) {
            super();
            this.db = db; this.mode = mode; this.error = null; this.durability = "default";
            this.objectStoreNames = nameList(storeNames.map(String));
            this.oncomplete = null; this.onerror = null; this.onabort = null;
            this._pending = 0; this._finished = false; this._ops = null;
            if (!manual) this._schedule();
          }
          objectStore(name) {
            if (this._finished) throw failure("The transaction has finished", "TransactionInactiveError");
            const key = String(name);
            const info = this.db._stores.get(key);
            if (!info || this.objectStoreNames.indexOf(key) === -1) throw failure("No object store named " + key, "NotFoundError");
            return new BridgeObjectStore(this, info);
          }
          abort() { this._finish("abort"); }
          commit() { this._schedule(); }
          // 原生事务在"所有请求都结束、且这一轮没有新请求"时自动提交：这里用一个 microtask 做同样的判断
          _schedule() {
            Promise.resolve().then(() => {
              if (!this._finished && this._pending === 0 && !this._ops) this._finish("complete");
            });
          }
          _finish(type) {
            if (this._finished) return;
            this._finished = true;
            if (type === "complete") { fire(this, "complete", new Event("complete")); return; }
            if (type === "error") fire(this, "error", new Event("error"));
            fire(this, "abort", new Event("abort"));
          }
          _request(store, indexName, method, args, write) {
            if (this._finished) throw failure("The transaction has finished", "TransactionInactiveError");
            if (write && this.mode === "readonly") throw failure("The transaction is read-only", "ReadOnlyError");
            const request = new BridgeRequest(store, this);
            this._pending += 1;
            send({ op: "call", name: this.db.name, store: store.name, index: indexName,
                   mode: this.mode === "readonly" ? "readonly" : "readwrite", method, args: encode(args) })
              .then((result) => { this._pending -= 1; succeed(request, result); this._schedule(); },
                    (error) => { this._pending -= 1; this.error = error; failRequest(request, error); this._finish("error"); });
            return request;
          }
          _cursor(store, indexName, method, args) {
            if (this._finished) throw failure("The transaction has finished", "TransactionInactiveError");
            const request = new BridgeRequest(store, this);
            const direction = typeof args[1] === "string" ? args[1] : "next";
            this._pending += 1;
            send({ op: "cursor", name: this.db.name, store: store.name, index: indexName,
                   mode: this.mode === "readonly" ? "readonly" : "readwrite", method, args: encode(args), limit: 5000 })
              .then((data) => {
                this._pending -= 1;
                const rows = (data && data.rows) || [];
                succeed(request, rows.length ? new BridgeCursor(request, store, indexName, direction, rows,
                                                                method === "openKeyCursor", !!(data && data.truncated)) : null);
                this._schedule();
              },
                    (error) => { this._pending -= 1; this.error = error; failRequest(request, error); this._finish("error"); });
            return request;
          }
        }
        inherit(BridgeTransaction, globalThis.IDBTransaction,
                ["db", "mode", "error", "durability", "objectStoreNames", "oncomplete", "onerror", "onabort"]);

        class BridgeDatabase extends EventTarget {
          constructor(schema) {
            super();
            this.name = schema.name; this.version = schema.version;
            this._stores = new Map((schema.stores || []).map((store) => [store.name, store]));
            this.objectStoreNames = nameList(Array.from(this._stores.keys()).sort());
            this.onversionchange = null; this.onclose = null; this.onerror = null; this.onabort = null;
            this._upgrade = null; this._closed = false;
          }
          transaction(storeNames, mode) {
            if (this._closed) throw failure("The database connection is closed", "InvalidStateError");
            const names = typeof storeNames === "string" ? [String(storeNames)] : Array.from(storeNames).map(String);
            if (!names.length) throw failure("No object stores were given", "InvalidAccessError");
            for (const name of names) {
              if (!this._stores.has(name)) throw failure("No object store named " + name, "NotFoundError");
            }
            return new BridgeTransaction(this, names, mode === "readwrite" || mode === "versionchange" ? mode : "readonly");
          }
          close() { this._closed = true; }
          createObjectStore(name, options) {
            const upgrade = this._upgrade;
            if (!upgrade) throw failure("createObjectStore is only allowed during an upgrade", "InvalidStateError");
            const info = { name: String(name), keyPath: options && options.keyPath !== undefined ? options.keyPath : null,
                           autoIncrement: !!(options && options.autoIncrement), indexes: [] };
            this._stores.set(info.name, info);
            this.objectStoreNames = nameList(Array.from(this._stores.keys()).sort());
            upgrade.objectStoreNames = this.objectStoreNames;
            upgrade._ops.push({ op: "createObjectStore", name: info.name, options: encode(options || {}) });
            return new BridgeObjectStore(upgrade, info);
          }
          deleteObjectStore(name) {
            const upgrade = this._upgrade;
            if (!upgrade) throw failure("deleteObjectStore is only allowed during an upgrade", "InvalidStateError");
            this._stores.delete(String(name));
            this.objectStoreNames = nameList(Array.from(this._stores.keys()).sort());
            upgrade.objectStoreNames = this.objectStoreNames;
            upgrade._ops.push({ op: "deleteObjectStore", name: String(name) });
          }
        }
        inherit(BridgeDatabase, globalThis.IDBDatabase,
                ["name", "version", "objectStoreNames", "onversionchange", "onclose", "onerror", "onabort"]);

        const versionChangeEvent = (oldVersion, newVersion) => {
          try { return new IDBVersionChangeEvent("upgradeneeded", { oldVersion, newVersion }); }
          catch (_) {
            const event = new Event("upgradeneeded");
            try { event.oldVersion = oldVersion; event.newVersion = newVersion; } catch (__) {}
            return event;
          }
        };

        class BridgeFactory {
          open(name, version) {
            const request = new BridgeOpenRequest();
            const dbName = String(name);
            send({ op: "open", name: dbName, version: version === undefined ? null : Number(version) })
              .then((info) => {
                if (!info || !info.upgrade) return info;
                // 需要升级：本地放一个"录制"版本的 versionchange 事务，让扩展照常建库，再把这些操作交给后台重放
                const db = new BridgeDatabase({ name: dbName, version: info.version, stores: info.stores || [] });
                const transaction = new BridgeTransaction(db, Array.from(db.objectStoreNames), "versionchange", true);
                transaction._ops = [];
                db._upgrade = transaction;
                request.result = db;
                request.transaction = transaction;
                fire(request, "upgradeneeded", versionChangeEvent(info.oldVersion, info.version));
                return send({ op: "upgrade", name: dbName, version: info.version, ops: transaction._ops })
                  .then((schema) => {
                    db._upgrade = null;
                    transaction._ops = null;
                    transaction._finish("complete");
                    return schema;
                  });
              })
              .then((schema) => {
                request.transaction = null;
                succeed(request, new BridgeDatabase(schema));
              }, (error) => failRequest(request, error));
            return request;
          }
          deleteDatabase(name) {
            const request = new BridgeOpenRequest();
            send({ op: "deleteDatabase", name: String(name) })
              .then(() => succeed(request, undefined), (error) => failRequest(request, error));
            return request;
          }
          databases() { return send({ op: "databases" }); }
          cmp(first, second) { return native.cmp(first, second); }
        }
        inherit(BridgeFactory, globalThis.IDBFactory, []);

        try {
          Object.defineProperty(globalThis, "indexedDB",
                                { value: new BridgeFactory(), configurable: true, writable: true, enumerable: true });
        } catch (_) {}
      };
    """

    /// 注入到**网页** WebView 全部框架的脚本（document start，page world）：只在 `webkit-extension:` 框架里生效，
    /// 干两件事——
    /// 1. 把从网页进程直接调会被杀的命名空间（tabs / windows / …）换成经后台转发的代理。事件（onXxx）与常量
    ///    保留原样——注册监听不会触发那条 IPC。已知取舍：回调形式拿不到 runtime.lastError；带函数的参数
    ///    （scripting.executeScript 的 func）过不了消息序列化；后台若对所有消息都同步 reply，会抢在转发结果之前。
    /// 2. 把 `indexedDB` 换成经后台执行的门面（见文件头第 6 条）：这种框架里的 IndexedDB 被 WebKit 按顶层站点
    ///    分区，读到的是另一份空库。已知取舍：一次调用 = 后台一个独立事务（同一个事务里的多个请求不再是原子的，
    ///    abort() 也回滚不了已经执行的），升级事务里只能建表 / 建索引 / 写入（读不了，操作录下来交给后台重放），
    ///    游标是后台一次跑完的快照（上限 5000 条；超出时走到快照末尾明确报错，不假装迭代正常结束），
    ///    值按 JSON 语义过通道（Date 与 IDBKeyRange 单独编码，Blob / File / ArrayBuffer 过不去）。
    ///    `runtime.sendMessage` 本身在这种框架里是通的（回调、Promise、connect 端口都实测过），所以桥只加在存储这一层。
    ///    桥只在**后台真的挂上了垫片**（manifest.background 有改写痕迹）时才装：执行端不在的话每次调用都会失败，
    ///    那还不如留着原生那份分区库。
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
    \(frameIndexedDBScript)
      // IndexedDB 桥的执行端在后台垫片（__quickterm-compat.js）里。没把垫片挂上后台的扩展——没有 background、
      // 只有 background.page（HTML，不改写）、service_worker 路径越界、或者装的时候垫片没写成——装了桥只会让
      // 每一次 IDB 调用都以"no response from the extension background"失败，比不装还糟：那种情况下留着原生的
      // （按顶层站点分区的）indexedDB，iframe 自己读写自己至少是自洽的，跟加桥之前一模一样。
      // 判断只看改写留在 manifest.background 里的痕迹（`apply(to:)` 最后才写 manifest，垫片没落盘就不会有痕迹）；
      // manifest 读不上来时按"挂了"算——宁可保住桥，也不要静默退回"面板没数据"那个 bug
      const backgroundIsShimmed = (runtime) => {
        let manifest;
        try { manifest = typeof runtime.getManifest === "function" ? runtime.getManifest() : null; }
        catch (_) { return true; }
        if (!manifest) return true;
        const background = manifest.background;
        if (!background || typeof background !== "object") return false;
        const worker = background.service_worker;
        if (typeof worker === "string" && worker.split("/").pop() === \(jsString(wrapperFile))) return true;
        return Array.isArray(background.scripts) && background.scripts.indexOf(\(jsString("/" + compatFile))) !== -1;
      };
      try {
        const api = globalThis.chrome || globalThis.browser;
        if (api && api.runtime && backgroundIsShimmed(api.runtime)) bridgeIndexedDB(api.runtime);
      } catch (_) {}
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
