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

    final class Host: BrowserExtensionHost {
        var panes: [BrowserPaneView] = []
        var browserPanes: [BrowserPaneView] { panes }
        var focusedBrowserPane: BrowserPaneView? { panes.first }
        func openBrowserWindow(url: URL?) -> BrowserPaneView? { nil }
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
    private static func installed(background: [String: Any], files: [String: String], id: String = freshID(),
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
