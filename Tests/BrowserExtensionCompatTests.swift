import WebKit
import XCTest
@testable import QuickTerm

/// WebKit 兼容垫片（BrowserExtensionCompat）：manifest 改写规则 + 真跑在 WKWebExtension 里的效果
final class BrowserExtensionCompatTests: XCTestCase {
    // MARK: - manifest 改写

    func testClassicServiceWorkerGetsWrapperNextToOriginal() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "./bg/worker.js"],
                                         files: ["bg/worker.js": "self.x = 1;\n", "empty.js": "\n", "bg/blank.js": "  \n\t",
                                                 "real.js": "1;\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))

        let manifest = try Self.manifest(dir)
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "bg/__quickterm-background.js",
                       "包装脚本放在原 worker 同目录，相对路径的 importScripts 才按原目录解析")
        XCTAssertNil(background["type"])
        let marker = try XCTUnwrap(manifest["__quickterm"] as? [String: Any])
        XCTAssertEqual(marker["shim"] as? Int, BrowserExtensionCompat.version)
        XCTAssertEqual((marker["background"] as? [String: Any])?["service_worker"] as? String, "./bg/worker.js",
                       "原始 background 原样记下来")

        let wrapper = try String(contentsOf: dir.appendingPathComponent("bg/__quickterm-background.js"), encoding: .utf8)
        XCTAssertEqual(wrapper, "importScripts(\"/__quickterm-compat.js\", \"/bg/worker.js\");\n")
        let compat = try String(contentsOf: dir.appendingPathComponent("__quickterm-compat.js"), encoding: .utf8)
        XCTAssertTrue(compat.contains("[\"/bg/blank.js\",\"/empty.js\"]"), "空脚本列表（根相对、排序）：\(compat)")
        XCTAssertFalse(compat.contains("real.js"))
        XCTAssertFalse(compat.contains("worker.js"))
    }

    func testWorkerPathCannotEscapeExtensionDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("qt-compat-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = try Self.makeExtension(background: ["service_worker": "../../evil/x.js"], files: [:],
                                         at: parent.appendingPathComponent("ext", isDirectory: true))
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        XCTAssertEqual((try Self.manifest(dir)["background"] as? [String: Any])?["service_worker"] as? String,
                       "../../evil/x.js", "越界路径：不包装、不动 background")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().appendingPathComponent("evil").path),
                       "不能往扩展目录外写文件")
        // 空路径同样不碰
        let empty = try Self.makeExtension(background: ["service_worker": ""], files: [:])
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: empty))
        XCTAssertEqual((try Self.manifest(empty)["background"] as? [String: Any])?["service_worker"] as? String, "")
    }

    /// store 目录是符号链接（放 Dropbox / 外置盘）时，空脚本扫描不能因为路径前缀对不上而空掉
    func testEmptyScriptScanWorksThroughSymlinkedStore() throws {
        let real = try Self.makeExtension(background: ["service_worker": "bg.js"],
                                          files: ["bg.js": "1;\n", "sub dir/空.js": "\n", "a.mjs": "  "])
        defer { try? FileManager.default.removeItem(at: real) }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("qt-compat-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(BrowserExtensionCompat.emptyScripts(in: link), ["/a.mjs", "/sub dir/空.js"])
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("__quickterm-background.js").path),
                      "经由链接写进真实目录")
    }

    func testModuleServiceWorkerUsesImports() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "sw.js", "type": "module"],
                                         files: ["sw.js": "export {};\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        let background = try XCTUnwrap(try Self.manifest(dir)["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__quickterm-background.js")
        XCTAssertEqual(background["type"] as? String, "module", "module 类型保留")
        let wrapper = try String(contentsOf: dir.appendingPathComponent("__quickterm-background.js"), encoding: .utf8)
        XCTAssertEqual(wrapper, "import \"/__quickterm-compat.js\";\nimport \"/sw.js\";\n")
    }

    func testBackgroundScriptsArrayGetsCompatPrepended() throws {
        let dir = try Self.makeExtension(background: ["scripts": ["a.js", "b.js"]],
                                         files: ["a.js": "1;\n", "b.js": "2;\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        let background = try XCTUnwrap(try Self.manifest(dir)["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["/__quickterm-compat.js", "a.js", "b.js"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("__quickterm-background.js").path),
                       "scripts 数组不需要包装文件")
    }

    func testApplyIsIdempotentAndNoBackgroundOnlyMarks() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "bg.js"], files: ["bg.js": "1;\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        let first = try Self.manifest(dir)
        XCTAssertFalse(try BrowserExtensionCompat.apply(to: dir), "已是当前版本：不动")
        XCTAssertEqual(try Self.manifest(dir) as NSDictionary, first as NSDictionary)
        let background = try XCTUnwrap(first["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__quickterm-background.js", "不会套两层")

        // 垫片 / 包装文件被删了（或版本升了）→ 重新生成，仍从记录的原始 background 出发
        for file in ["__quickterm-compat.js", "__quickterm-background.js"] {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir), "\(file) 缺了要补")
            XCTAssertEqual(try Self.manifest(dir) as NSDictionary, first as NSDictionary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path))
        }

        // 没有后台脚本：只记版本（scheme 字面量替换仍会做），不生成包装 / 垫片文件；第二次同样不动
        let noBackground = try Self.makeExtension(background: nil, files: [:])
        defer { try? FileManager.default.removeItem(at: noBackground) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: noBackground))
        XCTAssertEqual((try Self.manifest(noBackground)["__quickterm"] as? [String: Any])?["shim"] as? Int, BrowserExtensionCompat.version)
        XCTAssertNil(try Self.manifest(noBackground)["background"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noBackground.appendingPathComponent("__quickterm-compat.js").path))
        XCTAssertFalse(try BrowserExtensionCompat.apply(to: noBackground))
    }

    func testChromeExtensionSchemeLiteralIsRewrittenInScripts() throws {
        let dir = try Self.makeExtension(background: nil, files: [
            "popup.js": "const own = location.href.startsWith(\"chrome-extension://\" + chrome.runtime.id);\n",
            "sub/x.js": "// chrome-extension: twice chrome-extension://a/b\n",
            "data.json": "{\"url\": \"chrome-extension://keep\"}\n",
            "m.mjs": "export const p = \"chrome-extension:\";\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir), "没有 background 也要改 scheme 字面量")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("popup.js"), encoding: .utf8),
                       "const own = location.href.startsWith(\"webkit-extension://\" + chrome.runtime.id);\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sub/x.js"), encoding: .utf8),
                       "// webkit-extension: twice webkit-extension://a/b\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("data.json"), encoding: .utf8),
                       "{\"url\": \"chrome-extension://keep\"}\n", "只碰 .js / .mjs")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("m.mjs"), encoding: .utf8),
                       "export const p = \"webkit-extension:\";\n")
        XCTAssertEqual((try Self.manifest(dir)["__quickterm"] as? [String: Any])?["shim"] as? Int, BrowserExtensionCompat.version)
        XCTAssertNil(try Self.manifest(dir)["background"])
        XCTAssertFalse(try BrowserExtensionCompat.apply(to: dir), "幂等")
    }

    // MARK: - 真跑：WebKit 缺的 API / importScripts 清空 microtask / scheme 字面量

    /// WebKit 没有 webNavigation.onHistoryStateUpdated；顶层直接 addListener 的后台（Stylish）没垫片时加载失败
    @MainActor
    func testMissingWebNavigationEventsBecomeNoops() async throws {
        let variants: [(String, [String: Any])] = [
            ("classic", ["service_worker": "bg.js"]),
            ("module", ["service_worker": "bg.js", "type": "module"]),
            ("scripts", ["scripts": ["bg.js"]]),
        ]
        for (module, background) in variants {
            let (manager, item) = try await Self.installed(background: background, files: [
                "bg.js": """
                chrome.webNavigation.onHistoryStateUpdated.addListener(() => {});
                chrome.webNavigation.onReferenceFragmentUpdated.addListener(() => {});
                chrome.storage.local.set({ loaded: chrome.webNavigation.onHistoryStateUpdated.hasListener(() => {}) === false });
                """,
            ])
            defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
            let bg = await Self.loadBackground(item.context)
            XCTAssertEqual(bg, "OK", "module=\(module)")
            let loaded = try await Self.storageValue(item, key: "loaded")
            XCTAssertEqual(loaded as? Bool, true, "module=\(module)：后台跑到了最后一行")
            XCTAssertTrue(item.context.errors.isEmpty, "module=\(module)：\(item.context.errors)")
        }
    }

    /// WebKit 的 importScripts 会清空 microtask 队列：空脚本跳过，Tampermonkey 式的启动标记才保得住
    @MainActor
    func testEmptyImportScriptsKeepsStartupMicrotaskFlag() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            let startup = true; (async () => { await null; startup = false; })();
            importScripts("/test.js");
            const afterEmpty = startup;
            importScripts("/real.js");
            chrome.storage.local.set({ result: { afterEmpty, afterReal: startup, realRan: self.realRan === true } });
            """,
            "test.js": "\n",
            "real.js": "self.realRan = true;\n",
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let bg = await Self.loadBackground(item.context)
        XCTAssertEqual(bg, "OK")
        let stored = try await Self.storageValue(item, key: "result")
        let result = try XCTUnwrap(stored as? [String: Any])
        XCTAssertEqual(result["afterEmpty"] as? Bool, true, "空脚本被跳过，microtask 没被清")
        XCTAssertEqual(result["realRan"] as? Bool, true, "非空脚本照常走原生 importScripts")
        // 仅记录，不断言：afterReal == false 是 WebKit 当前的行为（原生 importScripts 清 microtask），Apple 修了也不该红
        print("BrowserExtensionCompatTests: WebKit importScripts drains microtasks = \(result["afterReal"] as? Bool == false)")
    }

    /// Tampermonkey 式：后台按 sender.url 是否以 `chrome-extension://` 开头判断"自己人"，WebKit 下是 webkit-extension://
    @MainActor
    func testBackgroundRecognisesOwnPagesByRewrittenScheme() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              reply({ own: typeof sender.url === "string" && sender.url.startsWith("chrome-extension://" + chrome.runtime.id + "/") });
              return true;
            });
            """,
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let bg = await Self.loadBackground(item.context)
        XCTAssertEqual(bg, "OK")
        let reply = try await Self.evaluate(item, "const r = await chrome.runtime.sendMessage({}); return r && r.own === true;")
        XCTAssertEqual(reply as? Bool, true, "后台把 popup / 选项页认成自己的页面")
    }

    /// 同一个 id 重装（商店更新）：后台要跑新脚本，不能沿用旧 worker
    @MainActor
    func testReinstallWithSameIDRunsNewBackground() async throws {
        let id = Self.freshID()
        let (manager, first) = try await Self.installed(background: ["service_worker": "bg.js"],
                                                        files: ["bg.js": "chrome.storage.local.set({ v: 1 });\n"], id: id)
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let bg1 = await Self.loadBackground(first.context)
        XCTAssertEqual(bg1, "OK")
        let v1 = try await Self.storageValue(first, key: "v")
        XCTAssertEqual(v1 as? Int, 1)
        let fixture = try Self.makeExtension(background: ["service_worker": "bg.js"],
                                             files: ["bg.js": "chrome.storage.local.set({ v: 2 });\n"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let second = try await manager.install(directory: fixture, id: id, source: .local)
        let bg2 = await Self.loadBackground(second.context)
        XCTAssertEqual(bg2, "OK")
        let v2 = try await Self.storageValue(second, key: "v")
        XCTAssertEqual(v2 as? Int, 2, "重装后跑的是新后台")
    }

    /// 网页里嵌的扩展 iframe（Stylish 侧栏）：直接调 tabs.query 会被 WebKit 杀掉页面进程；改走后台转发后拿到真结果，
    /// 页面进程活着；来自网页（内容脚本）的转发请求被后台拒绝
    @MainActor
    func testEmbeddedExtensionFrameRelaysPrivilegedAPIs() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": "// 后台只靠垫片里的转发\n",
            "cs.js": """
            const f = document.createElement("iframe"); f.src = chrome.runtime.getURL("frame.html"); document.body.appendChild(f);
            chrome.runtime.sendMessage({ __quickterm_relay: { ns: "tabs", fn: "query", args: [{}] } })
              .then((r) => chrome.storage.local.set({ fromContentScript: r }));
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            (async () => {
              const out = { relayed: !!chrome.tabs[Symbol.for("QuickTerm.relayed")] };
              try { out.tabs = (await chrome.tabs.query({})).map((t) => t.url); } catch (e) { out.tabs = "ERR " + e.message; }
              try { out.window = typeof (await chrome.windows.getCurrent()).id; } catch (e) { out.window = "ERR " + e.message; }
              try { out.callback = await new Promise((r) => chrome.tabs.query({}, (tabs) => r(Array.isArray(tabs) ? tabs.length : "bad"))); } catch (e) { out.callback = "ERR " + e.message; }
              out.eventsKept = typeof chrome.tabs.onUpdated.addListener;
              out.storageDirect = typeof (await chrome.storage.local.get(null));
              chrome.storage.local.set({ fromFrame: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(pane); pane.frame = window.contentView!.bounds; window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        XCTAssertTrue(tab.webView.configuration.userContentController.userScripts.contains { $0.source == BrowserExtensionCompat.frameScript },
                      "普通标签的配置里带 frame 脚本")
        _ = await Self.loadBackground(item.context)
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let storedFrame = try await Self.storageValue(item, key: "fromFrame")
        let fromFrame = try XCTUnwrap(storedFrame as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(fromFrame["relayed"] as? Bool, true, "chrome.tabs 已换成代理")
        XCTAssertEqual(fromFrame["tabs"] as? [String], ["http://example.test/"], "tabs.query 经后台转发拿到 pane 的标签")
        XCTAssertEqual(fromFrame["window"] as? String, "number", "windows.getCurrent 同样转发")
        XCTAssertEqual(fromFrame["callback"] as? Int, 1, "回调形式也能用")
        XCTAssertEqual(fromFrame["eventsKept"] as? String, "function", "事件对象保留原样")
        XCTAssertEqual(fromFrame["storageDirect"] as? String, "object", "storage 不经转发")
        let storedCS = try await Self.storageValue(item, key: "fromContentScript")
        let fromContentScript = try XCTUnwrap(storedCS as? [String: Any])
        XCTAssertNotNil(fromContentScript["error"], "网页来源的转发请求被拒：\(fromContentScript)")
    }

    /// 网页里嵌的扩展 iframe：IndexedDB 被 WebKit 按顶层站点分区（读到的是另一份空库），桥接后与后台 / 扩展进程
    /// 页面共用同一份数据——后台写的读得到、自己写的后台立刻看得到，索引 / 游标 / 建库升级也照常
    @MainActor
    func testEmbeddedExtensionFrameSharesIndexedDBWithBackground() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            const openDB = (name, version, upgrade) => new Promise((resolve, reject) => {
              const request = indexedDB.open(name, version);
              if (upgrade) request.onupgradeneeded = () => upgrade(request.result, request.transaction);
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            const done = (tx) => new Promise((resolve, reject) => { tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); });
            const all = (store) => new Promise((resolve, reject) => {
              const request = store.getAll();
              request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
            });
            let shared;
            const ready = (async () => {
              shared = await openDB("shared", 1, (db) => {
                const store = db.createObjectStore("items", { keyPath: "id" });
                store.createIndex("by-tag", "tag", { unique: false });
              });
              const tx = shared.transaction("items", "readwrite");
              tx.objectStore("items").put({ id: 1, tag: "a", text: "from-bg" });
              await done(tx);
              chrome.storage.local.set({ ready: true });
            })();
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || message.probe !== "read") return false;
              (async () => {
                await ready;
                const items = await all(shared.transaction("items", "readonly").objectStore("items"));
                const made = await openDB("made-by-frame");
                const inMade = made.objectStoreNames.contains("s")
                  ? await all(made.transaction("s", "readonly").objectStore("s")) : "missing";
                made.close();
                const fresh = await openDB("fresh-no-version");
                const inFresh = fresh.objectStoreNames.contains("s")
                  ? await all(fresh.transaction("s", "readonly").objectStore("s")) : "missing";
                fresh.close();
                reply({ items, inMade, inFresh });
              })();
              return true;
            });
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const openDB = (name, version, upgrade) => new Promise((resolve, reject) => {
              const request = indexedDB.open(name, version);
              if (upgrade) request.onupgradeneeded = () => upgrade(request.result, request.transaction);
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
              out.requestIsNative = request instanceof IDBRequest;
            });
            const wait = (request) => new Promise((resolve, reject) => {
              request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
            });
            const out = { bridged: indexedDB.open !== IDBFactory.prototype.open };
            (async () => {
              try {
                await new Promise((resolve) => {
                  const tick = () => chrome.storage.local.get(["ready"], (v) => (v && v.ready ? resolve() : setTimeout(tick, 50)));
                  tick();
                });
                out.databases = (await indexedDB.databases()).map((d) => d.name + "@" + d.version).sort();
                const db = await openDB("shared");
                out.dbIsNative = db instanceof IDBDatabase;
                out.version = db.version;
                out.stores = Array.from(db.objectStoreNames);
                out.read = await wait(db.transaction("items", "readonly").objectStore("items").getAll());
                // 自己写一条：后台那边要立刻看得到
                const write = db.transaction("items", "readwrite");
                out.txIsNative = write instanceof IDBTransaction;
                write.objectStore("items").put({ id: 2, tag: "b", text: "from-frame" });
                await new Promise((resolve, reject) => { write.oncomplete = () => resolve(); write.onerror = () => reject(write.error); });
                out.count = await wait(db.transaction("items", "readonly").objectStore("items").count());
                out.byIndex = (await wait(db.transaction("items", "readonly").objectStore("items").index("by-tag").getAll("a"))).map((r) => r.id);
                out.byKey = (await wait(db.transaction("items", "readonly").objectStore("items").get(2))).text;
                out.range = (await wait(db.transaction("items", "readonly").objectStore("items").getAll(IDBKeyRange.lowerBound(2)))).map((r) => r.id);
                // 游标
                out.cursor = await new Promise((resolve, reject) => {
                  const ids = [];
                  const request = db.transaction("items", "readonly").objectStore("items").openCursor();
                  request.onsuccess = () => {
                    const cursor = request.result;
                    if (!cursor) { resolve(ids); return; }
                    out.cursorIsNative = cursor instanceof IDBCursor;
                    ids.push(cursor.value.id);
                    cursor.continue();
                  };
                  request.onerror = () => reject(request.error);
                });
                // 从 iframe 里新建一个库（升级事务：建表 + 写入都要重放到后台那份）
                const made = await openDB("made-by-frame", 1, (fresh) => {
                  fresh.createObjectStore("s", { keyPath: "id" }).put({ id: 7, text: "made-in-frame" });
                });
                out.made = await wait(made.transaction("s", "readonly").objectStore("s").getAll());
                // 不带版本号 open 一个还不存在的库：原生会 upgradeneeded(0→1)，桥不能悄悄建个空库了事
                out.freshUpgrades = [];
                const freshDB = await new Promise((resolve, reject) => {
                  const request = indexedDB.open("fresh-no-version");
                  request.onupgradeneeded = (event) => {
                    out.freshUpgrades.push(event.oldVersion + "->" + event.newVersion);
                    request.result.createObjectStore("s", { keyPath: "id" }).put({ id: 9, text: "no-version" });
                  };
                  request.onsuccess = () => resolve(request.result);
                  request.onerror = () => reject(request.error);
                });
                out.freshVersion = freshDB.version;
                out.freshStores = Array.from(freshDB.objectStoreNames);
                out.freshRead = await wait(freshDB.transaction("s", "readonly").objectStore("s").getAll());
                // 再 open 一次（库已经在了）：不该再触发升级
                out.freshAgain = [];
                await new Promise((resolve, reject) => {
                  const request = indexedDB.open("fresh-no-version");
                  request.onupgradeneeded = (event) => out.freshAgain.push(event.oldVersion + "->" + event.newVersion);
                  request.onsuccess = () => resolve(request.result);
                  request.onerror = () => reject(request.error);
                });
                out.fromBackground = await chrome.runtime.sendMessage({ probe: "read" });
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ fromFrame: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "fromFrame", timeout: 30)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "iframe 里没抛错：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["bridged"] as? Bool, true, "iframe 里的 indexedDB 已换成桥")
        // 门面要能通过 instanceof：idb 这类包装库全靠它认路
        for key in ["requestIsNative", "dbIsNative", "txIsNative", "cursorIsNative"] {
            XCTAssertEqual(out[key] as? Bool, true, "\(key)：\(out)")
        }
        XCTAssertEqual(out["version"] as? Int, 1)
        XCTAssertEqual(out["stores"] as? [String], ["items"])
        XCTAssertTrue((out["databases"] as? [String] ?? []).contains("shared@1"), "databases() 是后台那份：\(out)")
        let read = try XCTUnwrap(out["read"] as? [[String: Any]])
        XCTAssertEqual(read.count, 1, "读到后台写的记录：\(out)")
        XCTAssertEqual(read.first?["text"] as? String, "from-bg")
        XCTAssertEqual(out["count"] as? Int, 2)
        XCTAssertEqual(out["byIndex"] as? [Int], [1], "索引查询")
        XCTAssertEqual(out["byKey"] as? String, "from-frame", "按主键取自己刚写的")
        XCTAssertEqual(out["range"] as? [Int], [2], "IDBKeyRange 过得去")
        XCTAssertEqual(out["cursor"] as? [Int], [1, 2], "游标")
        XCTAssertEqual((out["made"] as? [[String: Any]])?.first?["text"] as? String, "made-in-frame",
                       "iframe 里新建的库（升级事务重放到后台）")
        XCTAssertEqual(out["freshUpgrades"] as? [String], ["0->1"],
                       "不带版本号 open 一个不存在的库：照原生的 upgradeneeded(0→1) 来：\(out)")
        XCTAssertEqual(out["freshVersion"] as? Int, 1)
        XCTAssertEqual(out["freshStores"] as? [String], ["s"], "建表回调真的跑了")
        XCTAssertEqual((out["freshRead"] as? [[String: Any]])?.first?["text"] as? String, "no-version")
        XCTAssertEqual(out["freshAgain"] as? [String], [], "库已经在了就不再触发升级")
        let fromBackground = try XCTUnwrap(out["fromBackground"] as? [String: Any])
        let items = try XCTUnwrap(fromBackground["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? Int }.sorted(), [1, 2], "后台看得到 iframe 写的那条：\(fromBackground)")
        XCTAssertEqual((fromBackground["inMade"] as? [[String: Any]])?.first?["id"] as? Int, 7,
                       "iframe 建的库在后台那份分区里：\(fromBackground)")
        XCTAssertEqual((fromBackground["inFresh"] as? [[String: Any]])?.first?["id"] as? Int, 9,
                       "不带版本号建的那个库也在后台那份分区里：\(fromBackground)")

        // 普通网页（不是扩展框架）一点都不碰
        let plain = try await Self.evaluate(inPage: tab.webView, at: "http://example.test/", load: nil, """
        return { chrome: typeof globalThis.chrome, native: indexedDB.open === IDBFactory.prototype.open,
                 factory: indexedDB instanceof IDBFactory };
        """)
        let plainOut = try XCTUnwrap(plain as? [String: Any])
        XCTAssertEqual(plainOut["native"] as? Bool, true, "普通框架的 indexedDB 还是原生的：\(plainOut)")
        XCTAssertEqual(plainOut["chrome"] as? String, "undefined", "普通框架里也没多出 chrome")
    }

    /// 真实面板（Stylish）读库用的是 `idb` 那类包装库：它靠 `instanceof IDBRequest / IDBDatabase / IDBTransaction`
    /// 认路、靠事务的 `complete` 事件给 `tx.done`、靠 `tx.objectStoreNames` 给 `tx.store`。
    /// 这里把 idb 的核心（wrap / Proxy 陷阱 / openDB / db.getAll 快捷方法）照搬进 iframe 跑一遍
    @MainActor
    func testEmbeddedExtensionFrameWorksWithIdbStyleWrapper() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            const request = indexedDB.open("wrapped", 1);
            request.onupgradeneeded = () => request.result.createObjectStore("items", { keyPath: "id" });
            request.onsuccess = () => {
              const tx = request.result.transaction("items", "readwrite");
              tx.objectStore("items").put({ id: 1, text: "from-bg" });
              tx.oncomplete = () => chrome.storage.local.set({ ready: true });
            };
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            // ---- idb v7 的核心（照抄结构，删掉游标 / 撤销缓存等与本用例无关的部分）
            const transformCache = new WeakMap(), reverseCache = new WeakMap(), doneMap = new WeakMap();
            const unwrap = (value) => reverseCache.get(value);
            const shortcuts = { get: false, getAll: false, count: false, put: true, delete: true };
            const traps = {
              get(target, prop, receiver) {
                if (target instanceof IDBDatabase && !(prop in target) && prop in shortcuts) {
                  const write = shortcuts[prop];
                  return async function (storeName, ...args) {
                    const tx = this.transaction(storeName, write ? "readwrite" : "readonly");
                    const result = await Promise.all([tx.store[prop](...args), write && tx.done]);
                    return result[0];
                  };
                }
                if (target instanceof IDBTransaction) {
                  if (prop === "done") return doneMap.get(target);
                  if (prop === "store") return receiver.objectStoreNames[1] ? undefined : receiver.objectStore(receiver.objectStoreNames[0]);
                }
                return wrap(target[prop]);
              },
              set(target, prop, value) { target[prop] = value; return true; },
              has(target, prop) {
                if (target instanceof IDBDatabase && prop in shortcuts) return true;
                if (target instanceof IDBTransaction && (prop === "done" || prop === "store")) return true;
                return prop in target;
              },
            };
            function transform(value) {
              if (typeof value === "function") {
                return function (...args) { return wrap(value.apply(unwrap(this), args)); };
              }
              if (value instanceof IDBTransaction && !doneMap.has(value)) {
                doneMap.set(value, new Promise((resolve, reject) => {
                  value.addEventListener("complete", () => resolve());
                  value.addEventListener("error", () => reject(value.error));
                  value.addEventListener("abort", () => reject(value.error));
                }));
              }
              if ([IDBDatabase, IDBObjectStore, IDBIndex, IDBCursor, IDBTransaction].some((type) => value instanceof type)) {
                return new Proxy(value, traps);
              }
              return value;
            }
            function wrap(value) {
              if (value instanceof IDBRequest) {
                const promise = new Promise((resolve, reject) => {
                  const stop = () => { value.removeEventListener("success", ok); value.removeEventListener("error", bad); };
                  const ok = () => { resolve(wrap(value.result)); stop(); };
                  const bad = () => { reject(value.error); stop(); };
                  value.addEventListener("success", ok);
                  value.addEventListener("error", bad);
                });
                reverseCache.set(promise, value);
                return promise;
              }
              if (transformCache.has(value)) return transformCache.get(value);
              const transformed = transform(value);
              if (transformed !== value) { transformCache.set(value, transformed); reverseCache.set(transformed, value); }
              return transformed;
            }
            const openDB = (name, version, upgrade) => {
              const request = indexedDB.open(name, version);
              const promise = wrap(request);
              if (upgrade) request.addEventListener("upgradeneeded", (event) => upgrade(wrap(request.result), event.oldVersion, event.newVersion, wrap(request.transaction)));
              return promise;
            };
            // ---- 用它读写
            (async () => {
              const out = {};
              try {
                await new Promise((resolve) => {
                  const tick = () => chrome.storage.local.get(["ready"], (v) => (v && v.ready ? resolve() : setTimeout(tick, 50)));
                  tick();
                });
                const db = await openDB("wrapped", 1);
                out.read = (await db.getAll("items")).map((row) => row.text);
                await db.put("items", { id: 2, text: "from-frame" });
                const tx = db.transaction("items", "readwrite");
                tx.store.put({ id: 3, text: "in-transaction" });
                await tx.done;
                out.after = (await db.getAll("items")).map((row) => row.id);
                // 包装库自己新建的库（走升级回调）
                const fresh = await openDB("wrapped-fresh", 1, (upgrading) => { upgrading.createObjectStore("s", { keyPath: "id" }); });
                await fresh.put("s", { id: 9, text: "fresh" });
                out.fresh = (await fresh.getAll("s")).map((row) => row.text);
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ wrapped: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "wrapped", timeout: 30)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "包装库跑通：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["read"] as? [String], ["from-bg"], "包装库读到后台写的记录")
        XCTAssertEqual(out["after"] as? [Int], [1, 2, 3], "db.put 与 tx.done 都成立")
        XCTAssertEqual(out["fresh"] as? [String], ["fresh"], "包装库的 upgrade 回调建库")
    }

    /// 游标是后台一次跑完的快照：反向游标的 `continue(key)` 要按降序找（不能拿正向那套比较），
    /// 超过上限（5000）时走到快照末尾必须明确报错——报"迭代结束"等于把剩下的记录悄悄抹掉
    @MainActor
    func testEmbeddedExtensionFrameCursorDirectionAndSnapshotLimit() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            const openDB = (name, version, upgrade) => new Promise((resolve, reject) => {
              const request = indexedDB.open(name, version);
              if (upgrade) request.onupgradeneeded = () => upgrade(request.result, request.transaction);
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            (async () => {
              const db = await openDB("cursors", 1, (fresh) => {
                fresh.createObjectStore("small", { keyPath: "id" });
                fresh.createObjectStore("big", { keyPath: "id" });
              });
              const tx = db.transaction(["small", "big"], "readwrite");
              for (const id of [10, 20, 30, 40, 50]) tx.objectStore("small").put({ id });
              const big = tx.objectStore("big");
              for (let i = 1; i <= 5002; i += 1) big.put({ id: i });
              await new Promise((resolve, reject) => { tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); });
              chrome.storage.local.set({ ready: true });
            })();
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const walk = (request) => new Promise((resolve) => {
              let count = 0;
              request.onsuccess = () => {
                const cursor = request.result;
                if (!cursor) { resolve({ count, ended: "null" }); return; }
                count += 1;
                cursor.continue();
              };
              request.onerror = () => resolve({ count, ended: "error",
                                                message: String(request.error && request.error.message) });
            });
            const out = {};
            (async () => {
              try {
                await new Promise((resolve) => {
                  const tick = () => chrome.storage.local.get(["ready"], (v) => (v && v.ready ? resolve() : setTimeout(tick, 50)));
                  tick();
                });
                const db = await new Promise((resolve, reject) => {
                  const request = indexedDB.open("cursors");
                  request.onsuccess = () => resolve(request.result);
                  request.onerror = () => reject(request.error);
                });
                // 反向游标：continue(key) 落在 <= key 的最大那条（50 → 30，不是 40）；没有更小的就结束
                out.prev = await new Promise((resolve, reject) => {
                  const seen = [];
                  const request = db.transaction("small", "readonly").objectStore("small").openCursor(null, "prev");
                  request.onsuccess = () => {
                    const cursor = request.result;
                    if (!cursor) { resolve(seen); return; }
                    seen.push(cursor.key);
                    if (seen.length === 1) cursor.continue(35);
                    else if (seen.length === 2) cursor.continue();
                    else cursor.continue(5);
                  };
                  request.onerror = () => reject(request.error);
                });
                // 5002 条 > 上限：走到第 5000 条之后要拿到错误
                out.overflow = await walk(db.transaction("big", "readonly").objectStore("big").openCursor());
                // 正好 5000 条（上限本身）：照常走完
                out.exact = await walk(db.transaction("big", "readonly").objectStore("big")
                                         .openKeyCursor(IDBKeyRange.upperBound(5000)));
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ cursors: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "cursors", timeout: 90)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "iframe 里没抛错：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["prev"] as? [Int], [50, 30, 20], "反向游标的 continue(key) 按降序找：\(out)")
        let overflow = try XCTUnwrap(out["overflow"] as? [String: Any])
        XCTAssertEqual(overflow["count"] as? Int, 5000, "快照上限：\(overflow)")
        XCTAssertEqual(overflow["ended"] as? String, "error", "被截断时不能报「迭代结束」：\(overflow)")
        XCTAssertTrue((overflow["message"] as? String ?? "").contains("truncated"), "错误说清原因：\(overflow)")
        let exact = try XCTUnwrap(out["exact"] as? [String: Any])
        XCTAssertEqual(exact["count"] as? Int, 5000)
        XCTAssertEqual(exact["ended"] as? String, "null", "正好等于上限的那次是真的走完了：\(exact)")
    }

    /// 后台没挂上垫片的扩展（这里是压根没有 background）：桥的执行端不存在，装了桥每次 IDB 调用都会失败，
    /// 所以那种框架里要留着原生的 indexedDB（按顶层站点分区，但自己读写自己是自洽的）。
    /// tabs.* 那套转发不受影响——从这种框架直接调它们会被 WebKit 杀掉页面进程，转发不通也好过被杀
    @MainActor
    func testFrameKeepsNativeIndexedDBWhenBackgroundHasNoShim() async throws {
        let (manager, item) = try await Self.installed(background: nil, files: [
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const out = { wrapped: !!chrome[Symbol.for("QuickTerm.relayed")],
                          bridged: indexedDB.open !== IDBFactory.prototype.open };
            (async () => {
              try {
                const db = await new Promise((resolve, reject) => {
                  const request = indexedDB.open("local-only", 1);
                  request.onupgradeneeded = () => request.result.createObjectStore("s", { keyPath: "id" });
                  request.onsuccess = () => resolve(request.result);
                  request.onerror = () => reject(request.error);
                });
                const tx = db.transaction("s", "readwrite");
                tx.objectStore("s").put({ id: 1, text: "local" });
                await new Promise((resolve, reject) => { tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); });
                out.read = await new Promise((resolve, reject) => {
                  const request = db.transaction("s", "readonly").objectStore("s").getAll();
                  request.onsuccess = () => resolve(request.result);
                  request.onerror = () => reject(request.error);
                });
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ fromFrame: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let directory = manager.directory(for: item.id)
        XCTAssertNil(try Self.manifest(directory)["background"], "没有 background 的扩展不会凭空多出一个")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(BrowserExtensionCompat.compatFile).path),
                       "没有后台就没有垫片文件——桥没有执行端")
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "fromFrame", timeout: 30)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "原生 indexedDB 照常能用：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["wrapped"] as? Bool, true, "根对象还是换过的（tabs.* 那套转发照旧）")
        XCTAssertEqual(out["bridged"] as? Bool, false, "没有执行端就不装桥：\(out)")
        XCTAssertEqual((out["read"] as? [[String: Any]])?.first?["text"] as? String, "local", "原生那份读写自洽")
    }

    /// 网页里嵌的扩展 iframe 里，Chrome 那几种 API 形状都要能用：runtime.sendMessage / storage.local.get 的
    /// 回调形式与 Promise 形式、同步与异步（`return true` + 延迟 sendResponse）的后台监听
    @MainActor
    func testEmbeddedExtensionFrameKeepsCallbackAndPromiseShapes() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            chrome.storage.local.set({ seed: "SEEDED" });
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || !message.probe) return false;
              if (message.probe === "sync") { reply({ ok: "sync" }); return true; }
              if (message.probe === "async") { setTimeout(() => reply({ ok: "async" }), 20); return true; }
              return false;
            });
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const guard = (promise) => Promise.race([
              promise.catch((e) => "ERR " + ((e && e.message) || e)),
              new Promise((resolve) => setTimeout(() => resolve("TIMEOUT"), 5000)),
            ]);
            const pick = (value) => (value && value.ok) || String(value);
            (async () => {
              const out = {};
              out.callbackSync = pick(await guard(new Promise((r) => chrome.runtime.sendMessage({ probe: "sync" }, r))));
              out.callbackAsync = pick(await guard(new Promise((r) => chrome.runtime.sendMessage({ probe: "async" }, r))));
              out.promiseSync = pick(await guard(chrome.runtime.sendMessage({ probe: "sync" })));
              out.promiseAsync = pick(await guard(chrome.runtime.sendMessage({ probe: "async" })));
              out.storageCallback = String(await guard(new Promise((r) => chrome.storage.local.get(["seed"], (v) => r(v && v.seed)))));
              out.storagePromise = String((await guard(chrome.storage.local.get(["seed"]))).seed);
              out.lastError = String(!chrome.runtime.lastError);
              out.relayCallback = await guard(new Promise((r) => chrome.tabs.query({}, (tabs) => r(Array.isArray(tabs) ? tabs.length : "bad"))));
              out.relayPromise = (await guard(chrome.tabs.query({}))).length;
              chrome.storage.local.set({ shapes: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "shapes", timeout: 30)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["callbackSync"] as? String, "sync", "回调形式 + 同步 sendResponse：\(out)")
        XCTAssertEqual(out["callbackAsync"] as? String, "async", "回调形式 + 异步 sendResponse：\(out)")
        XCTAssertEqual(out["promiseSync"] as? String, "sync")
        XCTAssertEqual(out["promiseAsync"] as? String, "async")
        XCTAssertEqual(out["storageCallback"] as? String, "SEEDED", "storage 的回调形式")
        XCTAssertEqual(out["storagePromise"] as? String, "SEEDED")
        XCTAssertEqual(out["lastError"] as? String, "true",
                       "没出错时 runtime.lastError 是假值（WebKit 在这种框架里给的是 null，不是 undefined）")
        XCTAssertEqual(out["relayCallback"] as? Int, 1, "转发的 tabs.query（回调形式）")
        XCTAssertEqual(out["relayPromise"] as? Int, 1, "转发的 tabs.query（Promise 形式）")
    }

    /// Firebase Auth 的 `persistence/indexed_db` 就是这个形状：`fbase_key` 当 keyPath、每个操作一个新事务、
    /// 事件一律走 `addEventListener`、可用性探测（open → put → delete）、以及定时轮询看别的上下文写了什么。
    /// 后台（service worker）先把登录记录写进扩展真正的分区，网页里嵌的面板 iframe 要能原样读回来。
    @MainActor
    func testEmbeddedExtensionFrameRunsFirebaseStyleAuthPersistence() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            const DB = "authdb", STORE = "authstore", KEYPATH = "fbase_key";
            const KEY = "firebase:authUser:TESTKEY:[DEFAULT]";
            const open = () => new Promise((resolve, reject) => {
              const request = indexedDB.open(DB, 1);
              request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: KEYPATH });
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            const wait = (r) => new Promise((resolve, reject) => {
              r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
            });
            const put = async (key, value) => {
              const db = await open();
              await wait(db.transaction([STORE], "readwrite").objectStore(STORE).put({ [KEYPATH]: key, value }));
              db.close();
            };
            const ready = put(KEY, { uid: "u-1", email: "a@example.test",
                                     stsTokenManager: { accessToken: "tok", expirationTime: 1 } })
              .then(() => chrome.storage.local.set({ ready: true }));
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || !message.probe) return false;
              (async () => {
                await ready;
                if (message.probe === "seed2") { await put("second", { uid: "u-2" }); reply({ ok: true }); return; }
                const db = await open();
                const rows = await wait(db.transaction([STORE], "readonly").objectStore(STORE).getAll());
                db.close();
                reply({ rows });
              })();
              return true;
            });
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const DB = "authdb", STORE = "authstore", KEYPATH = "fbase_key";
            const KEY = "firebase:authUser:TESTKEY:[DEFAULT]", SAK = "firebase:__sak";
            // firebase-auth 的 DBPromise：只用 addEventListener，不碰 on<type>
            const promisify = (request) => new Promise((resolve, reject) => {
              request.addEventListener("success", () => resolve(request.result));
              request.addEventListener("error", () => reject(request.error));
            });
            const openDatabase = () => new Promise((resolve, reject) => {
              const request = indexedDB.open(DB, 1);
              request.addEventListener("upgradeneeded", () => {
                try { request.result.createObjectStore(STORE, { keyPath: KEYPATH }); } catch (e) { reject(e); }
              });
              request.addEventListener("error", () => reject(request.error));
              request.addEventListener("success", () => resolve(request.result));
            });
            const store = (db, rw) => db.transaction([STORE], rw ? "readwrite" : "readonly").objectStore(STORE);
            const putObject = (db, key, value) => promisify(store(db, true).put({ [KEYPATH]: key, value }));
            const deleteObject = (db, key) => promisify(store(db, true).delete(key));
            const getObject = async (db, key) => {
              const data = await promisify(store(db, false).get(key));
              return data === undefined ? null : data.value;
            };
            const out = {};
            (async () => {
              try {
                await new Promise((resolve) => {
                  const tick = () => chrome.storage.local.get(["ready"], (v) => (v && v.ready ? resolve() : setTimeout(tick, 50)));
                  tick();
                });
                // _isAvailable()：open → put → delete，一路不许抛
                out.available = await (async () => {
                  try {
                    if (!indexedDB) return false;
                    const probe = await openDatabase();
                    await putObject(probe, SAK, "1");
                    await deleteObject(probe, SAK);
                    probe.close();
                    return true;
                  } catch (e) { out.availableError = String((e && e.message) || e); }
                  return false;
                })();
                const db = await openDatabase();
                out.version = db.version;
                out.user = (await getObject(db, KEY) || {}).uid;
                out.keys = await promisify(store(db, false).getAllKeys());
                out.sakGone = await getObject(db, SAK);
                // 事务的 complete（idb / firebase 都靠它知道写落盘了）
                out.txComplete = await new Promise((resolve) => {
                  const tx = db.transaction([STORE], "readonly");
                  tx.objectStore(STORE).get(KEY);
                  tx.addEventListener("complete", () => resolve("complete"));
                  tx.addEventListener("abort", () => resolve("abort"));
                });
                // close() 之后再开事务：InvalidStateError
                const closable = await openDatabase();
                closable.close();
                try { closable.transaction([STORE], "readonly"); out.afterClose = "no throw"; }
                catch (e) { out.afterClose = e.name; }
                // 别的上下文（后台）写进来的记录，轮询要看得到
                await chrome.runtime.sendMessage({ probe: "seed2" });
                out.polled = await (async () => {
                  for (let i = 0; i < 20; i += 1) {
                    const keys = await promisify(store(db, false).getAllKeys());
                    if (keys.length === 2) return keys.slice().sort();
                    await new Promise((r) => setTimeout(r, 100));
                  }
                  return "timeout";
                })();
                // 面板自己写一条，后台要立刻看得到
                await putObject(db, "from-frame", { uid: "u-3" });
                const back = await chrome.runtime.sendMessage({ probe: "read" });
                out.fromBackground = (back.rows || []).map((row) => row[KEYPATH]).sort();
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ firebase: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "firebase", timeout: 45)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "iframe 里没抛错：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["available"] as? Bool, true, "可用性探测（open → put → delete）：\(out)")
        XCTAssertEqual(out["version"] as? Int, 1)
        XCTAssertEqual(out["user"] as? String, "u-1", "后台写的登录记录，面板 iframe 读得到：\(out)")
        XCTAssertEqual(out["keys"] as? [String], ["firebase:authUser:TESTKEY:[DEFAULT]"], "getAllKeys：\(out)")
        XCTAssertNil(out["sakGone"] as? String, "探测用的那条删干净了：\(out)")
        XCTAssertEqual(out["txComplete"] as? String, "complete", "事务的 complete 事件")
        XCTAssertEqual(out["afterClose"] as? String, "InvalidStateError", "close() 之后 transaction() 抛 InvalidStateError")
        XCTAssertEqual(out["polled"] as? [String], ["firebase:authUser:TESTKEY:[DEFAULT]", "second"],
                       "轮询能看到后台后来写的那条：\(out)")
        XCTAssertEqual(out["fromBackground"] as? [String],
                       ["firebase:authUser:TESTKEY:[DEFAULT]", "from-frame", "second"],
                       "面板写的那条后台立刻看得到：\(out)")
    }

    /// 事务语义：同一轮里发出的请求在后台是**一个真事务**——`abort()` 回滚、任一请求出错整批回滚，
    /// 事件顺序（成功的先 success → 出错那个 error → 事务 error → 其余 AbortError → abort）跟原生一致；
    /// 另外别处升级库时还开着的连接要收到 `versionchange`
    @MainActor
    func testEmbeddedExtensionFrameTransactionsAreAtomic() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            const open = (name, version, upgrade) => new Promise((resolve, reject) => {
              const request = indexedDB.open(name, version);
              if (upgrade) request.onupgradeneeded = () => upgrade(request.result, request.transaction);
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            const wait = (r) => new Promise((resolve, reject) => {
              r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
            });
            const ready = (async () => {
              const db = await open("atomic", 1, (d) => d.createObjectStore("items", { keyPath: "id" }));
              await wait(db.transaction("items", "readwrite").objectStore("items").put({ id: 9, from: "bg" }));
              db.close();
              const vc = await open("bgvc", 1, (d) => d.createObjectStore("a"));
              vc.close();
              chrome.storage.local.set({ ready: true });
            })();
            chrome.runtime.onMessage.addListener((message, sender, reply) => {
              if (!message || !message.probe) return false;
              (async () => {
                await ready;
                if (message.probe === "upgrade") {
                  const db = await open("bgvc", 2, (d) => d.createObjectStore("b"));
                  db.close();
                  reply({ version: 2 });
                  return;
                }
                const db = await open("atomic");
                const keys = await wait(db.transaction("items", "readonly").objectStore("items").getAllKeys());
                db.close();
                reply({ keys });
              })();
              return true;
            });
            """,
            "cs.js": """
            const frame = document.createElement("iframe");
            frame.src = chrome.runtime.getURL("frame.html");
            document.body.appendChild(frame);
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            const open = (name, version, upgrade) => new Promise((resolve, reject) => {
              const request = indexedDB.open(name, version);
              if (upgrade) request.onupgradeneeded = () => upgrade(request.result, request.transaction);
              request.onsuccess = () => resolve(request.result);
              request.onerror = () => reject(request.error);
            });
            const wait = (r) => new Promise((resolve, reject) => {
              r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
            });
            const tick = (ms) => new Promise((r) => setTimeout(r, ms));
            const out = {};
            (async () => {
              try {
                await new Promise((resolve) => {
                  const t = () => chrome.storage.local.get(["ready"], (v) => (v && v.ready ? resolve() : setTimeout(t, 50)));
                  t();
                });
                const db = await open("atomic");
                // 1) abort() 回滚同一轮里发出的写
                {
                  const events = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const a = s.put({ id: 1 });
                  const b = s.put({ id: 2 });
                  a.addEventListener("error", () => events.push("a:" + a.error.name));
                  b.addEventListener("error", () => events.push("b:" + b.error.name));
                  tx.addEventListener("error", () => events.push("tx:error"));
                  tx.addEventListener("abort", () => events.push("tx:abort"));
                  tx.addEventListener("complete", () => events.push("tx:complete"));
                  tx.abort();
                  await tick(300);
                  out.abortEvents = events;
                  out.afterAbort = await wait(db.transaction("items", "readonly").objectStore("items").getAllKeys());
                }
                // 2) 一个请求出错 → 整批回滚，事件顺序照原生
                {
                  const order = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const a = s.put({ id: 1 });
                  const b = s.add({ id: 9 });        // 主键已存在 → ConstraintError
                  const c = s.put({ id: 3 });
                  a.addEventListener("success", () => order.push("a:ok"));
                  a.addEventListener("error", () => order.push("a:" + a.error.name));
                  b.addEventListener("success", () => order.push("b:ok"));
                  b.addEventListener("error", () => order.push("b:" + b.error.name));
                  c.addEventListener("success", () => order.push("c:ok"));
                  c.addEventListener("error", () => order.push("c:" + c.error.name));
                  tx.addEventListener("error", () => order.push("tx:error"));
                  tx.addEventListener("abort", () => order.push("tx:abort"));
                  tx.addEventListener("complete", () => order.push("tx:complete"));
                  await tick(400);
                  out.failOrder = order;
                  out.txError = tx.error && tx.error.name;
                  out.afterFail = await wait(db.transaction("items", "readonly").objectStore("items").getAllKeys());
                  out.fromBackground = (await chrome.runtime.sendMessage({ probe: "read" })).keys;
                }
                // 3) 正常一批：全部按序 success，事务 complete
                {
                  const seen = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  for (const id of [11, 12, 13]) {
                    const r = s.put({ id });
                    r.addEventListener("success", () => seen.push(r.result));
                  }
                  out.batchComplete = await new Promise((resolve) => {
                    tx.addEventListener("complete", () => resolve("complete"));
                    tx.addEventListener("abort", () => resolve("abort"));
                  });
                  out.batchKeys = seen;
                }
                // 4) 本框架里另一个连接升级：还开着的那个收到 versionchange
                {
                  const first = await open("framevc", 1, (d) => d.createObjectStore("a"));
                  let seen = "none";
                  first.addEventListener("versionchange", (e) => {
                    seen = e.oldVersion + "->" + String(e.newVersion);
                    first.close();
                  });
                  const second = await open("framevc", 2, (d) => d.createObjectStore("b"));
                  second.close();
                  await tick(200);
                  out.localVersionChange = seen;
                }
                // 5) 后台升级的库：面板下一次请求时补发 versionchange
                {
                  const stale = await open("bgvc");
                  out.staleVersion = stale.version;
                  let seen = "none";
                  stale.onversionchange = (e) => { seen = e.oldVersion + "->" + String(e.newVersion); };
                  await chrome.runtime.sendMessage({ probe: "upgrade" });
                  await wait(stale.transaction("a", "readonly").objectStore("a").count());
                  await tick(200);
                  out.remoteVersionChange = seen;
                }
                // 6) 同步抛出的请求（get(undefined) → DataError）：整批回滚，排在它前面的写不能报 success
                {
                  const order = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const a = s.put({ id: 77 });
                  let threw = "none";
                  let b = null;
                  try { b = s.get(undefined); } catch (e) { threw = e.name; }
                  a.addEventListener("success", () => order.push("a:ok"));
                  a.addEventListener("error", () => order.push("a:" + a.error.name));
                  if (b) {
                    b.addEventListener("success", () => order.push("b:ok"));
                    b.addEventListener("error", () => order.push("b:" + b.error.name));
                  }
                  tx.addEventListener("error", () => order.push("tx:error"));
                  tx.addEventListener("abort", () => order.push("tx:abort"));
                  tx.addEventListener("complete", () => order.push("tx:complete"));
                  await tick(400);
                  out.syncThrowOrder = order;
                  out.afterSyncThrow = await wait(db.transaction("items", "readonly").objectStore("items").getAllKeys());
                }
                // 7) 游标跟一个必然失败的写同批：游标请求照原生收 AbortError，而不是"迭代完了、0 条"
                {
                  const order = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const c = s.openCursor();
                  const bad = s.add({ id: 9 });     // 主键已存在 → ConstraintError
                  c.addEventListener("success", () => order.push("c:ok:" + String(c.result && c.result.key)));
                  c.addEventListener("error", () => order.push("c:" + c.error.name));
                  bad.addEventListener("error", () => order.push("bad:" + bad.error.name));
                  tx.addEventListener("error", () => order.push("tx:error"));
                  tx.addEventListener("abort", () => order.push("tx:abort"));
                  await tick(400);
                  out.cursorInFailedBatch = order;
                }
                // 8) 删库：还开着的连接照原生收到 versionchange（newVersion 为 null）
                {
                  const doomed = await open("dropme", 1, (d) => d.createObjectStore("a"));
                  let seen = "none";
                  doomed.addEventListener("versionchange", (e) => {
                    seen = e.oldVersion + "->" + String(e.newVersion);
                    doomed.close();
                  });
                  await new Promise((resolve, reject) => {
                    const r = indexedDB.deleteDatabase("dropme");
                    r.onsuccess = () => resolve();
                    r.onerror = () => reject(r.error);
                  });
                  await tick(200);
                  out.deleteVersionChange = seen;
                }
                // 9) 升级事务里 abort()：录下来的操作一个都不重放，open 请求以 AbortError 失败
                {
                  out.abortedUpgrade = await new Promise((resolve) => {
                    const r = indexedDB.open("abortup", 1);
                    r.onupgradeneeded = () => { r.result.createObjectStore("s"); r.transaction.abort(); };
                    r.onsuccess = () => resolve("success:v" + r.result.version);
                    r.onerror = () => resolve("error:" + (r.error && r.error.name));
                  });
                  const list = await indexedDB.databases();
                  out.abortedUpgradeExists = (list || []).some((e) => e.name === "abortup");
                }
              } catch (e) { out.error = String((e && e.message) || e); }
              chrome.storage.local.set({ atomic: out });
            })();
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        let loaded = await Self.loadBackground(item.context)
        XCTAssertEqual(loaded, "OK")
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let stored = try await Self.storageValue(item, key: "atomic", timeout: 45)
        let out = try XCTUnwrap(stored as? [String: Any], "iframe 里的脚本跑完")
        XCTAssertNil(out["error"], "iframe 里没抛错：\(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")
        XCTAssertEqual(out["afterAbort"] as? [Int], [9], "abort() 把同一轮里发出的写回滚掉了：\(out)")
        XCTAssertEqual(out["abortEvents"] as? [String], ["a:AbortError", "b:AbortError", "tx:abort"],
                       "abort()：待处理的请求各收一个 AbortError，然后事务 abort：\(out)")
        XCTAssertEqual(out["failOrder"] as? [String],
                       ["a:ok", "b:ConstraintError", "tx:error", "c:AbortError", "tx:abort"],
                       "出错时的事件顺序跟原生一致：\(out)")
        XCTAssertEqual(out["txError"] as? String, "ConstraintError")
        XCTAssertEqual(out["afterFail"] as? [Int], [9], "出错的那批整个回滚（id 1 / 3 都没落盘）：\(out)")
        XCTAssertEqual(out["fromBackground"] as? [Int], [9], "后台看到的也是回滚之后的：\(out)")
        XCTAssertEqual(out["batchComplete"] as? String, "complete", "正常一批照常提交")
        XCTAssertEqual(out["batchKeys"] as? [Int], [11, 12, 13], "一批请求按发出顺序结束，各自拿到自己的结果")
        XCTAssertEqual(out["localVersionChange"] as? String, "1->2",
                       "本框架里另一个连接升级时，还开着的连接收到 versionchange：\(out)")
        XCTAssertEqual(out["staleVersion"] as? Int, 1)
        XCTAssertEqual(out["remoteVersionChange"] as? String, "1->2",
                       "后台升级过的库：面板下一次请求时补发 versionchange：\(out)")
        XCTAssertEqual(out["syncThrowOrder"] as? [String],
                       ["b:DataError", "tx:error", "a:AbortError", "tx:abort"],
                       "同步抛出的请求让整批回滚：排在它前面的写收 AbortError，不能报 success：\(out)")
        XCTAssertEqual(out["afterSyncThrow"] as? [Int], [9, 11, 12, 13],
                       "同步抛出的那批整个回滚（id 77 没落盘）：\(out)")
        XCTAssertEqual(out["cursorInFailedBatch"] as? [String],
                       ["bad:ConstraintError", "tx:error", "c:AbortError", "tx:abort"],
                       "跟失败的写同批的游标收 AbortError，而不是 success(null)：\(out)")
        XCTAssertEqual(out["deleteVersionChange"] as? String, "1->null",
                       "删库前给还开着的连接发 versionchange(newVersion=null)：\(out)")
        XCTAssertEqual(out["abortedUpgrade"] as? String, "error:AbortError",
                       "升级事务里 abort()：open 请求以 AbortError 失败：\(out)")
        XCTAssertEqual(out["abortedUpgradeExists"] as? Bool, false,
                       "升级事务里 abort()：后台那边一个操作都没重放，库也没建出来：\(out)")
    }

    // MARK: - 扩展框架里的 UA

    /// 网页里嵌的扩展 iframe 报的 UA 必须与扩展的另一半（后台 / 扩展自己的页面）一致——
    /// 网页那份 Safari 伪装不能漏进扩展自己的框架（漏进去时 firebase-auth 这类库会只在 iframe 里
    /// 走 Safari 专属分支，且那条分支在 MV3 构建里永远不 settle）。网页自己照旧看到伪装
    @MainActor
    func testEmbeddedExtensionFrameKeepsTheBrowserUserAgent() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            chrome.storage.local.set({ backgroundUA: (typeof navigator === "undefined" ? "" : navigator.userAgent) || "" });
            """,
            "cs.js": """
            const f = document.createElement("iframe"); f.src = chrome.runtime.getURL("frame.html"); document.body.appendChild(f);
            chrome.storage.local.set({ pageUA: navigator.userAgent });
            """,
            "frame.html": "<html><head><script src=\"frame.js\"></script></head><body>F</body></html>\n",
            "frame.js": """
            chrome.storage.local.set({ frameUA: navigator.userAgent, frameAppVersion: navigator.appVersion });
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "content_scripts": [["matches": ["http://example.test/*"], "js": ["cs.js"], "run_at": "document_end"]],
            "web_accessible_resources": [["resources": ["frame.html", "frame.js"], "matches": ["http://example.test/*"]]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.userAgent = "safari"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(pane); pane.frame = window.contentView!.bounds; window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        XCTAssertTrue(tab.webView.configuration.userContentController.userScripts
            .contains { $0.source.hasPrefix(BrowserExtensionCompat.userAgentMarker) }, "普通标签的配置里带 UA 垫片")
        _ = await Self.loadBackground(item.context)
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let storedFrameUA = try await Self.storageValue(item, key: "frameUA")
        let frameUA = try XCTUnwrap(storedFrameUA as? String, "iframe 里的脚本跑完")
        let storedPageUA = try await Self.storageValue(item, key: "pageUA")
        let pageUA = try XCTUnwrap(storedPageUA as? String)
        let evaluated = try await Self.evaluate(item, "return navigator.userAgent;")
        let extensionPageUA = try XCTUnwrap(evaluated as? String)
        XCTAssertEqual(pageUA, BrowserPaneView.Settings.safariUserAgent, "网页自己照旧拿到伪装的 UA")
        XCTAssertEqual(frameUA, extensionPageUA, "扩展 iframe 与扩展自己的页面报同一个 UA：\(frameUA)")
        XCTAssertNotEqual(frameUA, pageUA, "扩展 iframe 不该跟着网页拿到伪装")
        if let backgroundUA = try await Self.storageValue(item, key: "backgroundUA") as? String, !backgroundUA.isEmpty {
            XCTAssertEqual(frameUA, backgroundUA, "扩展 iframe 与后台报同一个 UA")
        }
        let storedAppVersion = try await Self.storageValue(item, key: "frameAppVersion")
        let appVersion = try XCTUnwrap(storedAppVersion as? String)
        XCTAssertEqual(appVersion, String(frameUA.dropFirst("Mozilla/".count)), "appVersion 跟着一起换")
        // 兜底值与实测值都对得上时这条才有意义：脚本里写死的 UA 就是扩展另一半看到的那份
        XCTAssertEqual(BrowserPaneView.webKitUserAgent, extensionPageUA, "实测到的 WebKit UA 与扩展页面一致")
    }

    /// 扩展自己的页面开成标签（选项页 / tabs.create(runtime.getURL(…))）：同样不套网页那份 UA 伪装
    @MainActor
    func testExtensionPageTabKeepsTheBrowserUserAgent() async throws {
        let (manager, item) = try await Self.installed(background: nil, files: [:])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.userAgent = "safari"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(pane); pane.frame = window.contentView!.bounds; window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let webTab = try XCTUnwrap(pane.activeTab)
        XCTAssertEqual(webTab.webView.customUserAgent, BrowserPaneView.Settings.safariUserAgent, "普通标签照旧伪装")
        let extensionTab = pane.addTab(url: item.context.baseURL.appendingPathComponent("page.html"), activate: true)
        XCTAssertNotNil(extensionTab.extensionContext, "扩展页面标签用的是扩展的配置")
        // 设成 nil 之后 WebKit 的 getter 读回空串：只要不是那份伪装就行
        XCTAssertTrue(extensionTab.webView.customUserAgent?.isEmpty ?? true, "扩展自己的页面不套网页那份伪装")
        pane.applySettings()
        XCTAssertTrue(extensionTab.webView.customUserAgent?.isEmpty ?? true, "配置热重载之后也不套")
        XCTAssertEqual(webTab.webView.customUserAgent, BrowserPaneView.Settings.safariUserAgent)
        // 真跑一遍：页面里读到的 UA 与扩展自己的页面一致，不是伪装那份
        let evaluated = try await Self.evaluate(item, "return navigator.userAgent;")
        let extensionPageUA = try XCTUnwrap(evaluated as? String)
        var tabUA: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, tabUA == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
            guard !extensionTab.webView.isLoading, extensionTab.webView.url != nil else { continue }
            tabUA = try? await extensionTab.webView.callAsyncJavaScript("return navigator.userAgent;", arguments: [:],
                                                                       in: nil as WKFrameInfo?, contentWorld: .page) as? String
        }
        XCTAssertEqual(tabUA, extensionPageUA, "扩展页面标签里读到的 UA 与扩展自己的页面一致")
    }

    /// 扩展页面用 window.open / target=_blank 再开一个扩展页面：WebKit 把开窗方的 configuration 递回来，
    /// 新标签的扩展绑定必须在 install 之前就位——否则这半边会被当成网页套上 UA 伪装，和扩展另一半又分裂了。
    /// 网页开的弹窗照旧伪装
    @MainActor
    func testExtensionPagePopupKeepsTheBrowserUserAgent() async throws {
        let (manager, item) = try await Self.installed(background: nil, files: [:])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        BrowserPaneView.settings.userAgent = "safari"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(pane); pane.frame = window.contentView!.bounds; window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let webTab = try XCTUnwrap(pane.activeTab)
        let pageURL = item.context.baseURL.appendingPathComponent("page.html")
        let opener = pane.addTab(url: pageURL, activate: true)
        XCTAssertNotNil(opener.extensionContext)

        // WebKit 在 createWebViewWith 里递回来的就是开窗方的 configuration（弹窗与开窗方同进程同扩展）
        let popup = try XCTUnwrap(pane.webView(opener.webView, createWebViewWith: opener.webView.configuration,
                                               for: WKNavigationAction(), windowFeatures: WKWindowFeatures()))
        let popupTab = try XCTUnwrap(pane.tabs.last)
        XCTAssertTrue(popupTab.webView === popup, "返回的就是新标签的 WebView")
        XCTAssertTrue(popupTab.extensionContext === item.context, "弹窗跟着开窗方记在同一个扩展名下")
        XCTAssertTrue(popup.customUserAgent?.isEmpty ?? true, "扩展页开的扩展弹窗不套网页那份伪装")

        // 网页开的弹窗照旧伪装（同一条路径，只是开窗方不是扩展页）
        let webPopup = try XCTUnwrap(pane.webView(webTab.webView, createWebViewWith: webTab.webView.configuration,
                                                  for: WKNavigationAction(), windowFeatures: WKWindowFeatures()))
        XCTAssertNil(try XCTUnwrap(pane.tabs.last).extensionContext, "网页开的弹窗不属于任何扩展")
        XCTAssertEqual(webPopup.customUserAgent, BrowserPaneView.Settings.safariUserAgent, "网页开的弹窗照旧伪装")

        // 真跑一遍：弹窗里读到的 UA 与扩展自己的页面一致
        let evaluated = try await Self.evaluate(item, "return navigator.userAgent;")
        let extensionPageUA = try XCTUnwrap(evaluated as? String)
        popup.load(URLRequest(url: pageURL))
        var popupUA: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, popupUA == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
            guard !popup.isLoading, popup.url != nil else { continue }
            popupUA = try? await popup.callAsyncJavaScript("return navigator.userAgent;", arguments: [:],
                                                           in: nil as WKFrameInfo?, contentWorld: .page) as? String
        }
        XCTAssertEqual(popupUA, extensionPageUA, "扩展弹窗里读到的 UA 与扩展自己的页面一致")
    }

    final class Host: BrowserExtensionHost {
        var panes: [BrowserPaneView] = []
        var browserPanes: [BrowserPaneView] { panes }
        var focusedBrowserPane: BrowserPaneView? { panes.first }
        func openBrowserWindow(url: URL?) -> BrowserPaneView? { nil }
    }

    // MARK: - externally_connectable（网页 → 扩展）

    /// 地址清单来自扩展自己的 manifest；没声明 externally_connectable 的扩展一个模式都不贡献
    func testExternallyConnectableMatchesComeFromManifest() throws {
        let declared = try Self.makeExtension(background: nil, files: [:], manifest: [
            "externally_connectable": ["matches": ["https://*.example.test/*", "*://localhost/*", "", 7]],
        ])
        defer { try? FileManager.default.removeItem(at: declared) }
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: declared),
                       ["https://*.example.test/*", "*://localhost/*"], "只取非空字符串")
        // 垫片改写之后仍然读得到（apply 只动 background）
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: declared))
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: declared),
                       ["https://*.example.test/*", "*://localhost/*"])

        let plain = try Self.makeExtension(background: nil, files: [:])
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: plain), [])
        let malformed = try Self.makeExtension(background: nil, files: [:],
                                               manifest: ["externally_connectable": ["matches": "everything"]])
        defer { try? FileManager.default.removeItem(at: malformed) }
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: malformed), [])
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: plain.appendingPathComponent("nope")), [])

        XCTAssertNil(BrowserExtensionCompat.externalMessagingUserScript(matches: []), "没人声明就不注入")
        let script = try XCTUnwrap(BrowserExtensionCompat.externalMessagingUserScript(matches: ["b://x/*", "a://y/*", "b://x/*"]))
        XCTAssertTrue(script.source.hasPrefix(BrowserExtensionCompat.externalMessagingMarker))
        XCTAssertTrue(script.source.contains("[\"a://y/*\",\"b://x/*\"]"), "去重 + 排序：\(script.source.prefix(400))")
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertFalse(script.isForMainFrameOnly, "子框架也要（匹配的 iframe 同样能给扩展发消息）")
    }

    /// 网页侧垫片的匹配规则：只在 externally_connectable 命中的地址上定义 chrome，且绝不覆盖页面已有的 chrome
    @MainActor
    func testExternalMessagingScriptOnlyDefinesChromeOnMatchingPages() async throws {
        let script = BrowserExtensionCompat.externalMessagingScript(matches: ["https://*.userstyles.test/*",
                                                                              "*://localhost/*"])
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        let cases: [(String, Bool)] = [
            ("https://userstyles.test/styles/1", true),
            ("https://www.userstyles.test/", true),
            ("https://evil-userstyles.test/", false),
            ("http://userstyles.test/", false),          // 模式写死 https
            ("http://localhost/x?y=1", true),
            ("https://example.test/", false),
        ]
        for (url, expected) in cases {
            let out = try await Self.evaluate(inPage: webView, at: url, load: "<html><body>p</body></html>", """
            globalThis.browser = { runtime: { sendMessage: () => Promise.resolve("stub"), connect: () => ({}) } };
            \(script)
            return { chrome: typeof globalThis.chrome,
                     send: typeof (globalThis.chrome && chrome.runtime && chrome.runtime.sendMessage),
                     connect: typeof (globalThis.chrome && chrome.runtime && chrome.runtime.connect),
                     lastError: String(globalThis.chrome && chrome.runtime.lastError) };
            """)
            let result = try XCTUnwrap(out as? [String: Any], url)
            XCTAssertEqual(result["chrome"] as? String, expected ? "object" : "undefined", url)
            XCTAssertEqual(result["send"] as? String, expected ? "function" : "undefined", url)
            if expected {
                XCTAssertEqual(result["connect"] as? String, "function", url)
                XCTAssertEqual(result["lastError"] as? String, "undefined", "没出错时 lastError 是 undefined")
            }
        }
        // 页面自己已经有 chrome：一个字节都不动
        let kept = try await Self.evaluate(inPage: webView, at: "https://userstyles.test/x", load: "<html><body>p</body></html>", """
        globalThis.browser = { runtime: { sendMessage: () => Promise.resolve("stub") } };
        globalThis.chrome = { marker: true };
        \(script)
        return { marker: chrome.marker === true, runtime: typeof chrome.runtime };
        """)
        let result = try XCTUnwrap(kept as? [String: Any])
        XCTAssertEqual(result["marker"] as? Bool, true, "不覆盖页面已有的 chrome")
        XCTAssertEqual(result["runtime"] as? String, "undefined")
    }

    /// 真跑：匹配 externally_connectable 的网页用 `chrome.runtime.sendMessage(<id>, …)` 发消息，
    /// 后台的 onMessageExternal 收到（sender 正确）并回复；不匹配的网页上根本没有 chrome
    @MainActor
    func testExternallyConnectablePageMessagesBackground() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": """
            chrome.runtime.onMessageExternal.addListener((message, sender, reply) => {
              chrome.storage.local.set({ external: {
                message, url: sender && sender.url, origin: sender && sender.origin,
                id: String(sender && sender.id), tab: typeof (sender && sender.tab),
              } });
              if (message && message.ping === "async") { setTimeout(() => reply({ pong: message.ping }), 10); return true; }
              reply({ pong: message && message.ping });
              return true;
            });
            """,
        ], manifest: [
            "host_permissions": ["http://example.test/*"],
            "externally_connectable": ["matches": ["http://example.test/*"]],
        ])
        defer { try? FileManager.default.removeItem(at: manager.storeDirectory) }
        let host = Host()
        manager.host = host
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        host.panes = [pane]
        let tab = try XCTUnwrap(pane.activeTab)
        XCTAssertTrue(tab.webView.configuration.userContentController.userScripts
            .contains { $0.source.hasPrefix(BrowserExtensionCompat.externalMessagingMarker) },
            "已装扩展声明了 externally_connectable：普通标签带上网页侧垫片")
        _ = await Self.loadBackground(item.context)

        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)
        let out = try await Self.evaluate(inPage: tab.webView, at: "http://example.test/", load: nil, """
        const out = { chrome: typeof chrome, send: typeof (globalThis.chrome && chrome.runtime && chrome.runtime.sendMessage) };
        if (out.send === "function") {
          try { out.promise = await chrome.runtime.sendMessage(id, { ping: "sync" }); } catch (e) { out.promise = "ERR " + e.message; }
          try { out.callback = await new Promise((r) => chrome.runtime.sendMessage(id, { ping: "async" }, r)); } catch (e) { out.callback = "ERR " + e.message; }
        }
        return out;
        """, arguments: ["id": item.context.uniqueIdentifier])
        let result = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(result["chrome"] as? String, "object", "网页上补出了 chrome")
        XCTAssertEqual((result["promise"] as? [String: Any])?["pong"] as? String, "sync",
                       "Promise 形式拿到后台的回复：\(result)")
        XCTAssertEqual((result["callback"] as? [String: Any])?["pong"] as? String, "async",
                       "回调形式 + 异步 sendResponse（return true）：\(result)")
        XCTAssertNil(tab.lastProcessTerminationAt, "页面进程没被杀")

        let stored = try await Self.storageValue(item, key: "external")
        let external = try XCTUnwrap(stored as? [String: Any], "后台的 onMessageExternal 收到了消息")
        XCTAssertEqual(external["url"] as? String, "http://example.test/", "sender.url 是发消息的网页")
        XCTAssertEqual(external["origin"] as? String, "http://example.test")

        // 同一个标签换到不匹配的地址：垫片什么都不定义
        tab.webView.loadHTMLString("<html><body>other</body></html>", baseURL: URL(string: "http://other.test/")!)
        let outside = try await Self.evaluate(inPage: tab.webView, at: "http://other.test/", load: nil,
                                              "return { chrome: typeof chrome };")
        XCTAssertEqual((outside as? [String: Any])?["chrome"] as? String, "undefined",
                       "externally_connectable 之外的网页拿不到 chrome")
    }

    /// 扩展是启动后异步装上的：已经开着的标签在 browserExtensionsDidChange 之后要补上网页侧垫片
    @MainActor
    func testOpenTabsPickUpBridgeAfterInstall() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        BrowserExtensionManager.overrideForTesting = manager
        defer { BrowserExtensionManager.overrideForTesting = nil }
        let previous = BrowserPaneView.settings
        defer { BrowserPaneView.settings = previous }
        BrowserPaneView.settings.home = "about:blank"
        let pane = BrowserPaneView(url: URL(string: "about:blank"))
        defer { pane.paneWillClose() }
        let marker = BrowserExtensionCompat.externalMessagingMarker
        let scripts = { pane.activeTab?.webView.configuration.userContentController.userScripts ?? [] }
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) }, "还没装扩展：不注入")

        let fixture = try Self.makeExtension(background: nil, files: [:],
                                             manifest: ["externally_connectable": ["matches": ["https://x.test/*"]]])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let item = try await manager.install(directory: fixture, id: Self.freshID(), source: .local)
        XCTAssertTrue(scripts().contains { $0.source.hasPrefix(marker) && $0.source.contains("https://x.test/*") },
                      "装上之后已开着的标签也带上了垫片")
        XCTAssertEqual(scripts().filter { $0.source.hasPrefix(marker) }.count, 1, "重挂不会叠加")
        XCTAssertTrue(scripts().contains { $0 === BrowserExtensionCompat.frameUserScript }, "其它注入脚本照旧")

        manager.setEnabled(false, for: item)
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) }, "停用之后撤掉")
        manager.remove(item)
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) })
    }

    /// 旧版本装的扩展（目录里没垫片）：启动加载时补上
    @MainActor
    func testLoadInstalledAppliesShimToExistingDirectories() async throws {
        let store = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let id = Self.freshID()
        let dir = try Self.makeExtension(background: ["service_worker": "bg.js"],
                                         files: ["bg.js": "chrome.webNavigation.onHistoryStateUpdated.addListener(() => {}); chrome.storage.local.set({ loaded: true });\n"],
                                         at: store.appendingPathComponent(id, isDirectory: true))
        XCTAssertNil(try Self.manifest(dir)["__quickterm"])
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        await manager.loadInstalled()
        XCTAssertNotNil(try Self.manifest(dir)["__quickterm"], "loadInstalled 补垫片")
        let item = try XCTUnwrap(manager.installed.first)
        let bg = await Self.loadBackground(item.context)
        XCTAssertEqual(bg, "OK")
        let loaded = try await Self.storageValue(item, key: "loaded")
        XCTAssertEqual(loaded as? Bool, true)
    }

    // MARK: - helpers

    private static func manifest(_ dir: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    private static func makeStore() throws -> URL {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-compatstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return store
    }

    /// 最小 MV3 扩展 + 一个空页面（用来从扩展 origin 读 storage）
    private static func makeExtension(background: [String: Any]?, files: [String: String], at location: URL? = nil,
                                      manifest extra: [String: Any] = [:]) throws -> URL {
        let fm = FileManager.default
        let dir = location ?? fm.temporaryDirectory.appendingPathComponent("qt-compat-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "manifest_version": 3, "name": "Compat Fixture", "description": "x", "version": "1.0",
            "permissions": ["storage", "webNavigation"],
        ]
        if let background { manifest["background"] = background }
        manifest.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("manifest.json"))
        try "<html><body>page</body></html>\n".write(to: dir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// 每个用例一个新 id：后台 worker 的 URL 随 id 变。同一进程里先后在同一个 `webkit-extension://<id>/…-background.js`
    /// 注册内容不同的 worker，WebKit 会沿用先前那份脚本（缺 /test.js 之类就整个加载失败）
    private static func freshID() -> String {
        String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(8)).padding(toLength: 32, withPad: "q", startingAt: 0)
    }

    @MainActor
    private static func installed(background: [String: Any]?, files: [String: String], id: String = freshID(),
                                  manifest extra: [String: Any] = [:]) async throws
        -> (BrowserExtensionManager, BrowserExtensionManager.Installed) {
        let store = try makeStore()
        let manager = BrowserExtensionManager(configuration: .nonPersistent(), storeDirectory: store)
        let fixture = try makeExtension(background: background, files: files, manifest: extra)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let item = try await manager.install(directory: fixture, id: id, source: .local)
        return (manager, item)
    }

    private static func loadBackground(_ context: WKWebExtensionContext, timeout: Double = 10) async -> String {
        await withCheckedContinuation { cont in
            var done = false
            context.loadBackgroundContent { error in
                guard !done else { return }; done = true
                cont.resume(returning: error.map { "ERROR \($0.localizedDescription)" } ?? "OK")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }; done = true
                cont.resume(returning: "TIMEOUT")
            }
        }
    }

    /// 从扩展自己的页面读 storage.local[key]（后台写入是异步的：轮询到有值为止）
    @MainActor
    private static func storageValue(_ item: BrowserExtensionManager.Installed, key: String, timeout: Double = 10) async throws -> Any? {
        try await evaluate(item, "const v = await new Promise(r => chrome.storage.local.get([key], r)); return v[key] === undefined ? null : v[key];",
                           arguments: ["key": key], timeout: timeout)
    }

    /// 在一个**网页**（page world）里跑一段 async 脚本：`load` 非空时先把它当作 `at` 地址的内容加载，
    /// 然后等到那个地址加载完再求值（换页之后不能求值在旧页面上）
    @MainActor
    private static func evaluate(inPage webView: WKWebView, at url: String, load html: String?, _ script: String,
                                 arguments: [String: Any] = [:], timeout: Double = 15) async throws -> Any? {
        if let html { webView.loadHTMLString(html, baseURL: URL(string: url)!) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard !webView.isLoading, webView.url?.absoluteString == url else { continue }
            let value = try? await webView.callAsyncJavaScript(script, arguments: arguments, in: nil as WKFrameInfo?,
                                                               contentWorld: WKContentWorld.page)
            if let value, !(value is NSNull) { return value }
        }
        return nil
    }

    /// 在扩展自己的页面（page.html）里跑一段 async 脚本，轮询到返回非空为止
    @MainActor
    private static func evaluate(_ item: BrowserExtensionManager.Installed, _ script: String,
                                 arguments: [String: Any] = [:], timeout: Double = 10) async throws -> Any? {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10),
                                configuration: try XCTUnwrap(item.context.webViewConfiguration))
        webView.load(URLRequest(url: item.context.baseURL.appendingPathComponent("page.html")))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard !webView.isLoading, webView.url != nil else { continue }
            let value = try? await webView.callAsyncJavaScript(script, arguments: arguments, in: nil as WKFrameInfo?,
                                                               contentWorld: WKContentWorld.page)
            if let value, !(value is NSNull) { return value }
        }
        return nil
    }
}
