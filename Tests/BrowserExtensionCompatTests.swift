import WebKit
import XCTest
@testable import QuickTerm

/// The WebKit compatibility shim (BrowserExtensionCompat): the manifest rewrite rules, plus what they
/// actually do inside a live WKWebExtension.
final class BrowserExtensionCompatTests: XCTestCase {
    // MARK: - Manifest rewriting

    func testClassicServiceWorkerGetsWrapperNextToOriginal() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "./bg/worker.js"],
                                         files: ["bg/worker.js": "self.x = 1;\n", "empty.js": "\n", "bg/blank.js": "  \n\t",
                                                 "real.js": "1;\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))

        let manifest = try Self.manifest(dir)
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "bg/__quickterm-background.js",
                       "the wrapper sits in the original worker's directory, so relative importScripts still resolve there")
        XCTAssertNil(background["type"])
        let marker = try XCTUnwrap(manifest["__quickterm"] as? [String: Any])
        XCTAssertEqual(marker["shim"] as? Int, BrowserExtensionCompat.version)
        XCTAssertEqual((marker["background"] as? [String: Any])?["service_worker"] as? String, "./bg/worker.js",
                       "the original background is recorded verbatim")

        let wrapper = try String(contentsOf: dir.appendingPathComponent("bg/__quickterm-background.js"), encoding: .utf8)
        XCTAssertEqual(wrapper, "importScripts(\"/__quickterm-compat.js\", \"/bg/worker.js\");\n")
        let compat = try String(contentsOf: dir.appendingPathComponent("__quickterm-compat.js"), encoding: .utf8)
        XCTAssertTrue(compat.contains("[\"/bg/blank.js\",\"/empty.js\"]"), "the list of empty scripts, root-relative and sorted: \(compat)")
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
                       "../../evil/x.js", "a path that escapes the directory: no wrapper, and background is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().appendingPathComponent("evil").path),
                       "nothing may be written outside the extension directory")
        // An empty path is left alone as well.
        let empty = try Self.makeExtension(background: ["service_worker": ""], files: [:])
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: empty))
        XCTAssertEqual((try Self.manifest(empty)["background"] as? [String: Any])?["service_worker"] as? String, "")
    }

    /// When the store directory is a symlink (someone keeps it in Dropbox or on an external drive), the
    /// empty-script scan must not come back empty just because the path prefixes do not line up.
    /// The fixture keeps a space and a CJK character in one filename: those paths have to survive the scan too.
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
                      "written through the link into the real directory")
    }

    func testModuleServiceWorkerUsesImports() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "sw.js", "type": "module"],
                                         files: ["sw.js": "export {};\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        let background = try XCTUnwrap(try Self.manifest(dir)["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__quickterm-background.js")
        XCTAssertEqual(background["type"] as? String, "module", "the module type is kept")
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
                       "a scripts array needs no wrapper file")
    }

    func testApplyIsIdempotentAndNoBackgroundOnlyMarks() throws {
        let dir = try Self.makeExtension(background: ["service_worker": "bg.js"], files: ["bg.js": "1;\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir))
        let first = try Self.manifest(dir)
        XCTAssertFalse(try BrowserExtensionCompat.apply(to: dir), "already at the current version: nothing changes")
        XCTAssertEqual(try Self.manifest(dir) as NSDictionary, first as NSDictionary)
        let background = try XCTUnwrap(first["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__quickterm-background.js", "it never wraps twice")

        // The shim or the wrapper file was deleted (or the version went up): regenerate, still starting from
        // the recorded original background.
        for file in ["__quickterm-compat.js", "__quickterm-background.js"] {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir), "\(file) is missing and has to be regenerated")
            XCTAssertEqual(try Self.manifest(dir) as NSDictionary, first as NSDictionary)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path))
        }

        // No background script: only the version is recorded (the scheme-literal replacement still happens),
        // no wrapper or shim file is generated, and a second pass changes nothing.
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
        XCTAssertTrue(try BrowserExtensionCompat.apply(to: dir), "the scheme literals are rewritten even with no background")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("popup.js"), encoding: .utf8),
                       "const own = location.href.startsWith(\"webkit-extension://\" + chrome.runtime.id);\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sub/x.js"), encoding: .utf8),
                       "// webkit-extension: twice webkit-extension://a/b\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("data.json"), encoding: .utf8),
                       "{\"url\": \"chrome-extension://keep\"}\n", "only .js / .mjs are touched")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("m.mjs"), encoding: .utf8),
                       "export const p = \"webkit-extension:\";\n")
        XCTAssertEqual((try Self.manifest(dir)["__quickterm"] as? [String: Any])?["shim"] as? Int, BrowserExtensionCompat.version)
        XCTAssertNil(try Self.manifest(dir)["background"])
        XCTAssertFalse(try BrowserExtensionCompat.apply(to: dir), "idempotent")
    }

    // MARK: - Live runs: APIs WebKit lacks, importScripts draining microtasks, scheme literals

    /// WebKit has no webNavigation.onHistoryStateUpdated, so a background that calls addListener at the top
    /// level (Stylish does) fails to load without the shim.
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
            XCTAssertEqual(loaded as? Bool, true, "module=\(module): the background reached its last line")
            XCTAssertTrue(item.context.errors.isEmpty, "module=\(module): \(item.context.errors)")
        }
    }

    /// WebKit's importScripts drains the microtask queue, so empty scripts are skipped; that is what keeps a
    /// Tampermonkey-style startup flag alive.
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
        XCTAssertEqual(result["afterEmpty"] as? Bool, true, "the empty script was skipped and the microtasks survived")
        XCTAssertEqual(result["realRan"] as? Bool, true, "a non-empty script still goes through the native importScripts")
        // Recorded, not asserted: afterReal == false is WebKit's behavior today (the native importScripts
        // drains microtasks), and this must not go red if Apple ever fixes it.
        print("BrowserExtensionCompatTests: WebKit importScripts drains microtasks = \(result["afterReal"] as? Bool == false)")
    }

    /// The Tampermonkey pattern: the background decides "one of ours" by whether sender.url starts with
    /// `chrome-extension://`, which under WebKit is webkit-extension://.
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
        XCTAssertEqual(reply as? Bool, true, "the background recognizes its popup and options page as its own")
    }

    /// Reinstalling under the same id (a store update): the background has to run the new script, not reuse
    /// the old worker.
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
        XCTAssertEqual(v2 as? Int, 2, "after the reinstall it is the new background that runs")
    }

    /// An extension iframe embedded in a web page (Stylish's sidebar): calling tabs.query directly gets the
    /// page process killed by WebKit. Relayed through the background it returns the real answer and the page
    /// process survives, while a relay request originating in the web page (a content script) is refused.
    @MainActor
    func testEmbeddedExtensionFrameRelaysPrivilegedAPIs() async throws {
        let (manager, item) = try await Self.installed(background: ["service_worker": "bg.js"], files: [
            "bg.js": "// The background does nothing but the relaying inside the shim\n",
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
                      "an ordinary tab's configuration carries the frame script")
        _ = await Self.loadBackground(item.context)
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let storedFrame = try await Self.storageValue(item, key: "fromFrame")
        let fromFrame = try XCTUnwrap(storedFrame as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(fromFrame["relayed"] as? Bool, true, "chrome.tabs has been replaced by the proxy")
        XCTAssertEqual(fromFrame["tabs"] as? [String], ["http://example.test/"],
                       "tabs.query relayed through the background returns the pane's tabs")
        XCTAssertEqual(fromFrame["window"] as? String, "number", "windows.getCurrent is relayed too")
        XCTAssertEqual(fromFrame["callback"] as? Int, 1, "the callback form works as well")
        XCTAssertEqual(fromFrame["eventsKept"] as? String, "function", "event objects are left as they are")
        XCTAssertEqual(fromFrame["storageDirect"] as? String, "object", "storage is not relayed")
        let storedCS = try await Self.storageValue(item, key: "fromContentScript")
        let fromContentScript = try XCTUnwrap(storedCS as? [String: Any])
        XCTAssertNotNil(fromContentScript["error"], "a relay request originating in the web page is refused: \(fromContentScript)")
    }

    /// An extension iframe embedded in a web page: WebKit partitions IndexedDB by the top-level site, so it
    /// would otherwise read an empty database of its own. Bridged, it shares one store with the background
    /// and the extension's own pages: it reads what the background wrote, the background sees its writes
    /// immediately, and indexes, cursors and upgrade transactions all keep working.
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
                // Write one ourselves: the background has to see it immediately.
                const write = db.transaction("items", "readwrite");
                out.txIsNative = write instanceof IDBTransaction;
                write.objectStore("items").put({ id: 2, tag: "b", text: "from-frame" });
                await new Promise((resolve, reject) => { write.oncomplete = () => resolve(); write.onerror = () => reject(write.error); });
                out.count = await wait(db.transaction("items", "readonly").objectStore("items").count());
                out.byIndex = (await wait(db.transaction("items", "readonly").objectStore("items").index("by-tag").getAll("a"))).map((r) => r.id);
                out.byKey = (await wait(db.transaction("items", "readonly").objectStore("items").get(2))).text;
                out.range = (await wait(db.transaction("items", "readonly").objectStore("items").getAll(IDBKeyRange.lowerBound(2)))).map((r) => r.id);
                // Cursors.
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
                // Create a new database from inside the iframe (the upgrade transaction, the store creation
                // and the write alike, has to be replayed into the background's copy).
                const made = await openDB("made-by-frame", 1, (fresh) => {
                  fresh.createObjectStore("s", { keyPath: "id" }).put({ id: 7, text: "made-in-frame" });
                });
                out.made = await wait(made.transaction("s", "readonly").objectStore("s").getAll());
                // Open a database that does not exist yet, with no version: natively that fires
                // upgradeneeded(0->1), and the bridge must not quietly create an empty database instead.
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
                // Open it a second time, now that it exists: no upgrade may fire.
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "nothing threw inside the iframe: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["bridged"] as? Bool, true, "indexedDB inside the iframe has been replaced by the bridge")
        // The facades have to pass instanceof: wrapper libraries like idb navigate entirely by it.
        for key in ["requestIsNative", "dbIsNative", "txIsNative", "cursorIsNative"] {
            XCTAssertEqual(out[key] as? Bool, true, "\(key): \(out)")
        }
        XCTAssertEqual(out["version"] as? Int, 1)
        XCTAssertEqual(out["stores"] as? [String], ["items"])
        XCTAssertTrue((out["databases"] as? [String] ?? []).contains("shared@1"), "databases() is the background's list: \(out)")
        let read = try XCTUnwrap(out["read"] as? [[String: Any]])
        XCTAssertEqual(read.count, 1, "it reads the record the background wrote: \(out)")
        XCTAssertEqual(read.first?["text"] as? String, "from-bg")
        XCTAssertEqual(out["count"] as? Int, 2)
        XCTAssertEqual(out["byIndex"] as? [Int], [1], "an index lookup")
        XCTAssertEqual(out["byKey"] as? String, "from-frame", "fetching by primary key what it just wrote")
        XCTAssertEqual(out["range"] as? [Int], [2], "IDBKeyRange gets through")
        XCTAssertEqual(out["cursor"] as? [Int], [1, 2], "the cursor")
        XCTAssertEqual((out["made"] as? [[String: Any]])?.first?["text"] as? String, "made-in-frame",
                       "a database created inside the iframe, its upgrade transaction replayed into the background")
        XCTAssertEqual(out["freshUpgrades"] as? [String], ["0->1"],
                       "opening a non-existent database without a version behaves natively, upgradeneeded(0->1): \(out)")
        XCTAssertEqual(out["freshVersion"] as? Int, 1)
        XCTAssertEqual(out["freshStores"] as? [String], ["s"], "the store-creation callback really ran")
        XCTAssertEqual((out["freshRead"] as? [[String: Any]])?.first?["text"] as? String, "no-version")
        XCTAssertEqual(out["freshAgain"] as? [String], [], "once the database exists, no upgrade fires again")
        let fromBackground = try XCTUnwrap(out["fromBackground"] as? [String: Any])
        let items = try XCTUnwrap(fromBackground["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? Int }.sorted(), [1, 2],
                       "the background sees the row the iframe wrote: \(fromBackground)")
        XCTAssertEqual((fromBackground["inMade"] as? [[String: Any]])?.first?["id"] as? Int, 7,
                       "the database the iframe created lives in the background's partition: \(fromBackground)")
        XCTAssertEqual((fromBackground["inFresh"] as? [[String: Any]])?.first?["id"] as? Int, 9,
                       "and so does the one created without a version: \(fromBackground)")

        // An ordinary web page, not an extension frame, is not touched at all.
        let plain = try await Self.evaluate(inPage: tab.webView, at: "http://example.test/", load: nil, """
        return { chrome: typeof globalThis.chrome, native: indexedDB.open === IDBFactory.prototype.open,
                 factory: indexedDB instanceof IDBFactory };
        """)
        let plainOut = try XCTUnwrap(plain as? [String: Any])
        XCTAssertEqual(plainOut["native"] as? Bool, true, "an ordinary frame's indexedDB is still the native one: \(plainOut)")
        XCTAssertEqual(plainOut["chrome"] as? String, "undefined", "and no chrome appears in an ordinary frame either")
    }

    /// A real panel (Stylish) reads its database through a wrapper like `idb`, which navigates by
    /// `instanceof IDBRequest / IDBDatabase / IDBTransaction`, takes `tx.done` from the transaction's
    /// `complete` event, and takes `tx.store` from `tx.objectStoreNames`.
    /// This copies idb's core (wrap, the Proxy traps, openDB, the db.getAll shortcuts) into the iframe and
    /// runs it for real.
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
            // ---- The core of idb v7 (structure copied as-is, minus the cursor advance and reverse cache,
            // which this case does not exercise)
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
            // ---- Use it to read and write
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
                // A database the wrapper creates itself, through its upgrade callback.
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "the wrapper library ran through: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["read"] as? [String], ["from-bg"], "the wrapper reads the record the background wrote")
        XCTAssertEqual(out["after"] as? [Int], [1, 2, 3], "both db.put and tx.done hold")
        XCTAssertEqual(out["fresh"] as? [String], ["fresh"], "the wrapper's upgrade callback creates the database")
    }

    /// A cursor is a snapshot the background walks in one go: a reverse cursor's `continue(key)` has to search
    /// in descending order rather than reuse the forward comparison, and past the 5000-row limit, reaching the
    /// end of the snapshot has to raise an explicit error. Reporting "iteration finished" would silently erase
    /// the rows that are left.
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
                // Reverse cursor: continue(key) lands on the largest row <= key (50 -> 30, not 40), and ends
                // once there is nothing smaller.
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
                // 5002 rows is past the limit: after row 5000 there has to be an error.
                out.overflow = await walk(db.transaction("big", "readonly").objectStore("big").openCursor());
                // Exactly 5000 rows, the limit itself: it walks to the end as usual.
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "nothing threw inside the iframe: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["prev"] as? [Int], [50, 30, 20], "a reverse cursor's continue(key) searches in descending order: \(out)")
        let overflow = try XCTUnwrap(out["overflow"] as? [String: Any])
        XCTAssertEqual(overflow["count"] as? Int, 5000, "the snapshot limit: \(overflow)")
        XCTAssertEqual(overflow["ended"] as? String, "error", "a truncated walk must not report \"iteration finished\": \(overflow)")
        XCTAssertTrue((overflow["message"] as? String ?? "").contains("truncated"), "the error says why: \(overflow)")
        let exact = try XCTUnwrap(out["exact"] as? [String: Any])
        XCTAssertEqual(exact["count"] as? Int, 5000)
        XCTAssertEqual(exact["ended"] as? String, "null", "the walk that stops exactly at the limit really did finish: \(exact)")
    }

    /// An extension whose background carries no shim (here there is no background at all): the bridge has no
    /// executor, so installing it would make every IDB call fail. A frame like that keeps the native
    /// indexedDB instead, partitioned by the top-level site but self-consistent for its own reads and writes.
    /// The tabs.* relaying is unaffected: calling those directly from such a frame gets the page process
    /// killed by WebKit, and a relay that cannot get through still beats being killed.
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
        XCTAssertNil(try Self.manifest(directory)["background"], "an extension with no background does not grow one out of nowhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(BrowserExtensionCompat.compatFile).path),
                       "no background means no shim file: the bridge would have no executor")
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "the native indexedDB still works: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["wrapped"] as? Bool, true, "the root object is still the replaced one (tabs.* relaying is unchanged)")
        XCTAssertEqual(out["bridged"] as? Bool, false, "with no executor there is no bridge: \(out)")
        XCTAssertEqual((out["read"] as? [[String: Any]])?.first?["text"] as? String, "local", "the native store is self-consistent")
    }

    /// Inside an extension iframe embedded in a web page, every Chrome API shape has to work:
    /// runtime.sendMessage / storage.local.get in both callback and Promise form, and background listeners
    /// that answer synchronously as well as asynchronously (`return true` plus a delayed sendResponse).
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["callbackSync"] as? String, "sync", "callback form with a synchronous sendResponse: \(out)")
        XCTAssertEqual(out["callbackAsync"] as? String, "async", "callback form with an asynchronous sendResponse: \(out)")
        XCTAssertEqual(out["promiseSync"] as? String, "sync")
        XCTAssertEqual(out["promiseAsync"] as? String, "async")
        XCTAssertEqual(out["storageCallback"] as? String, "SEEDED", "the callback form of storage")
        XCTAssertEqual(out["storagePromise"] as? String, "SEEDED")
        XCTAssertEqual(out["lastError"] as? String, "true",
                       "with no error, runtime.lastError is falsy (in a frame like this WebKit gives null, not undefined)")
        XCTAssertEqual(out["relayCallback"] as? Int, 1, "a relayed tabs.query in callback form")
        XCTAssertEqual(out["relayPromise"] as? Int, 1, "a relayed tabs.query in Promise form")
    }

    /// Firebase Auth's `persistence/indexed_db` has exactly this shape: `fbase_key` as the keyPath, a fresh
    /// transaction per operation, events only through `addEventListener`, an availability probe (open -> put
    /// -> delete), and a timer that polls for what other contexts wrote.
    /// The background (a service worker) writes the sign-in record into the extension's real partition first,
    /// and the panel iframe embedded in a web page has to read it back unchanged.
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
            // firebase-auth's DBPromise: addEventListener only, never on<type>.
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
                // _isAvailable(): open -> put -> delete, and nothing may throw along the way.
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
                // The transaction's complete (both idb and firebase rely on it to know a write landed).
                out.txComplete = await new Promise((resolve) => {
                  const tx = db.transaction([STORE], "readonly");
                  tx.objectStore(STORE).get(KEY);
                  tx.addEventListener("complete", () => resolve("complete"));
                  tx.addEventListener("abort", () => resolve("abort"));
                });
                // Opening a transaction after close(): InvalidStateError.
                const closable = await openDatabase();
                closable.close();
                try { closable.transaction([STORE], "readonly"); out.afterClose = "no throw"; }
                catch (e) { out.afterClose = e.name; }
                // A record written by another context (the background): polling has to see it.
                await chrome.runtime.sendMessage({ probe: "seed2" });
                out.polled = await (async () => {
                  for (let i = 0; i < 20; i += 1) {
                    const keys = await promisify(store(db, false).getAllKeys());
                    if (keys.length === 2) return keys.slice().sort();
                    await new Promise((r) => setTimeout(r, 100));
                  }
                  return "timeout";
                })();
                // The panel writes one itself: the background has to see it immediately.
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "nothing threw inside the iframe: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["available"] as? Bool, true, "the availability probe (open -> put -> delete): \(out)")
        XCTAssertEqual(out["version"] as? Int, 1)
        XCTAssertEqual(out["user"] as? String, "u-1", "the panel iframe reads back the sign-in record the background wrote: \(out)")
        XCTAssertEqual(out["keys"] as? [String], ["firebase:authUser:TESTKEY:[DEFAULT]"], "getAllKeys: \(out)")
        XCTAssertNil(out["sakGone"] as? String, "the probe's own record was deleted cleanly: \(out)")
        XCTAssertEqual(out["txComplete"] as? String, "complete", "the transaction's complete event")
        XCTAssertEqual(out["afterClose"] as? String, "InvalidStateError", "after close(), transaction() throws InvalidStateError")
        XCTAssertEqual(out["polled"] as? [String], ["firebase:authUser:TESTKEY:[DEFAULT]", "second"],
                       "polling sees the record the background wrote afterwards: \(out)")
        XCTAssertEqual(out["fromBackground"] as? [String],
                       ["firebase:authUser:TESTKEY:[DEFAULT]", "from-frame", "second"],
                       "the background sees the panel's write immediately: \(out)")
    }

    /// Transaction semantics: everything issued in one turn is **one real transaction** on the background
    /// side. `abort()` rolls it back, one failing request rolls the whole batch back, and the event order
    /// (successes first, then the failing request's error, the transaction error, AbortError for the rest,
    /// then abort) matches native. On top of that, a connection still open when the database is upgraded
    /// elsewhere has to receive `versionchange`.
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
                // 1) abort() rolls back the writes issued in the same turn.
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
                // 2) One failing request rolls the whole batch back, in the native event order.
                {
                  const order = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const a = s.put({ id: 1 });
                  const b = s.add({ id: 9 });        // The key already exists -> ConstraintError
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
                // 3) A normal batch: every request succeeds in order and the transaction completes.
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
                // 4) Another connection in this frame upgrades: the one still open receives versionchange.
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
                // 5) A database the background upgraded: the panel gets versionchange on its next request.
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
                // 6) A request that throws synchronously (get(undefined) -> DataError): the whole batch rolls
                //    back, and writes queued before it must not report success.
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
                // 7) A cursor batched with a write that is bound to fail: the cursor request gets AbortError
                //    just as it would natively, not "iteration finished, 0 rows".
                {
                  const order = [];
                  const tx = db.transaction("items", "readwrite");
                  const s = tx.objectStore("items");
                  const c = s.openCursor();
                  const bad = s.add({ id: 9 });     // The key already exists -> ConstraintError
                  c.addEventListener("success", () => order.push("c:ok:" + String(c.result && c.result.key)));
                  c.addEventListener("error", () => order.push("c:" + c.error.name));
                  bad.addEventListener("error", () => order.push("bad:" + bad.error.name));
                  tx.addEventListener("error", () => order.push("tx:error"));
                  tx.addEventListener("abort", () => order.push("tx:abort"));
                  await tick(400);
                  out.cursorInFailedBatch = order;
                }
                // 8) Deleting the database: a connection still open receives versionchange (newVersion null).
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
                // 9) abort() inside an upgrade transaction: not one recorded operation is replayed, and the
                //    open request fails with AbortError.
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
        let out = try XCTUnwrap(stored as? [String: Any], "the script inside the iframe ran to completion")
        XCTAssertNil(out["error"], "nothing threw inside the iframe: \(out)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")
        XCTAssertEqual(out["afterAbort"] as? [Int], [9], "abort() rolled back the writes issued in the same turn: \(out)")
        XCTAssertEqual(out["abortEvents"] as? [String], ["a:AbortError", "b:AbortError", "tx:abort"],
                       "abort(): every pending request gets its own AbortError, then the transaction aborts: \(out)")
        XCTAssertEqual(out["failOrder"] as? [String],
                       ["a:ok", "b:ConstraintError", "tx:error", "c:AbortError", "tx:abort"],
                       "the event order on failure matches native: \(out)")
        XCTAssertEqual(out["txError"] as? String, "ConstraintError")
        XCTAssertEqual(out["afterFail"] as? [Int], [9], "the failing batch rolls back entirely (neither id 1 nor 3 landed): \(out)")
        XCTAssertEqual(out["fromBackground"] as? [Int], [9], "the background also sees the post-rollback state: \(out)")
        XCTAssertEqual(out["batchComplete"] as? String, "complete", "a normal batch commits as usual")
        XCTAssertEqual(out["batchKeys"] as? [Int], [11, 12, 13], "a batch finishes in issue order, each request with its own result")
        XCTAssertEqual(out["localVersionChange"] as? String, "1->2",
                       "when another connection in this frame upgrades, the still-open one receives versionchange: \(out)")
        XCTAssertEqual(out["staleVersion"] as? Int, 1)
        XCTAssertEqual(out["remoteVersionChange"] as? String, "1->2",
                       "a database the background upgraded: the panel gets versionchange on its next request: \(out)")
        XCTAssertEqual(out["syncThrowOrder"] as? [String],
                       ["b:DataError", "tx:error", "a:AbortError", "tx:abort"],
                       "a synchronously thrown request rolls the whole batch back: writes queued before it get AbortError, never success: \(out)")
        XCTAssertEqual(out["afterSyncThrow"] as? [Int], [9, 11, 12, 13],
                       "that batch rolls back entirely (id 77 never landed): \(out)")
        XCTAssertEqual(out["cursorInFailedBatch"] as? [String],
                       ["bad:ConstraintError", "tx:error", "c:AbortError", "tx:abort"],
                       "a cursor batched with a failing write gets AbortError, not success(null): \(out)")
        XCTAssertEqual(out["deleteVersionChange"] as? String, "1->null",
                       "before the database is deleted, a still-open connection gets versionchange(newVersion=null): \(out)")
        XCTAssertEqual(out["abortedUpgrade"] as? String, "error:AbortError",
                       "abort() inside an upgrade transaction: the open request fails with AbortError: \(out)")
        XCTAssertEqual(out["abortedUpgradeExists"] as? Bool, false,
                       "abort() inside an upgrade transaction: the background replayed nothing and the database was never created: \(out)")
    }

    // MARK: - The UA inside an extension frame

    /// An extension iframe embedded in a web page has to report the same UA as the rest of the extension (the
    /// background and the extension's own pages). The Safari spoof meant for web pages must not leak into the
    /// extension's own frames: when it does, a library like firebase-auth takes its Safari-only branch inside
    /// the iframe alone, and that branch never settles in an MV3 build. The page itself still sees the spoof.
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
            .contains { $0.source.hasPrefix(BrowserExtensionCompat.userAgentMarker) }, "an ordinary tab's configuration carries the UA shim")
        _ = await Self.loadBackground(item.context)
        tab.webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "http://example.test/")!)

        let storedFrameUA = try await Self.storageValue(item, key: "frameUA")
        let frameUA = try XCTUnwrap(storedFrameUA as? String, "the script inside the iframe ran to completion")
        let storedPageUA = try await Self.storageValue(item, key: "pageUA")
        let pageUA = try XCTUnwrap(storedPageUA as? String)
        let evaluated = try await Self.evaluate(item, "return navigator.userAgent;")
        let extensionPageUA = try XCTUnwrap(evaluated as? String)
        XCTAssertEqual(pageUA, BrowserPaneView.Settings.safariUserAgent, "the page itself still gets the spoofed UA")
        XCTAssertEqual(frameUA, extensionPageUA, "the extension iframe and the extension's own pages report one UA: \(frameUA)")
        XCTAssertNotEqual(frameUA, pageUA, "an extension iframe must not inherit the page's spoof")
        if let backgroundUA = try await Self.storageValue(item, key: "backgroundUA") as? String, !backgroundUA.isEmpty {
            XCTAssertEqual(frameUA, backgroundUA, "the extension iframe and the background report the same UA")
        }
        let storedAppVersion = try await Self.storageValue(item, key: "frameAppVersion")
        let appVersion = try XCTUnwrap(storedAppVersion as? String)
        XCTAssertEqual(appVersion, String(frameUA.dropFirst("Mozilla/".count)), "appVersion is swapped along with it")
        // This only means something when the fallback and the measured value agree: the UA hard-coded in the
        // script is exactly what the other half of the extension sees.
        XCTAssertEqual(BrowserPaneView.webKitUserAgent, extensionPageUA, "the measured WebKit UA matches the extension page's")
    }

    /// An extension page opened as a tab (the options page, or tabs.create(runtime.getURL(...))) is likewise
    /// not given the page-side UA spoof.
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
        XCTAssertEqual(webTab.webView.customUserAgent, BrowserPaneView.Settings.safariUserAgent, "an ordinary tab still spoofs")
        let extensionTab = pane.addTab(url: item.context.baseURL.appendingPathComponent("page.html"), activate: true)
        XCTAssertNotNil(extensionTab.extensionContext, "an extension-page tab uses the extension's configuration")
        // Once it is set to nil, WebKit's getter reads back an empty string: all that matters is that it is
        // not the spoof.
        XCTAssertTrue(extensionTab.webView.customUserAgent?.isEmpty ?? true, "an extension's own page does not wear the page-side spoof")
        pane.applySettings()
        XCTAssertTrue(extensionTab.webView.customUserAgent?.isEmpty ?? true, "and still does not after a config hot reload")
        XCTAssertEqual(webTab.webView.customUserAgent, BrowserPaneView.Settings.safariUserAgent)
        // Run it for real: the UA read inside the page matches the extension's own pages, not the spoof.
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
        XCTAssertEqual(tabUA, extensionPageUA, "the UA read in an extension-page tab matches the extension's own pages")
    }

    /// An extension page that opens another extension page with window.open / target=_blank: WebKit hands the
    /// opener's configuration back, so the new tab's extension binding has to be in place before install runs.
    /// Otherwise this half is treated as a web page, gets the UA spoof, and splits from the rest of the
    /// extension all over again. A popup opened by a web page still spoofs.
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

        // What WebKit hands back in createWebViewWith is the opener's own configuration: the popup shares its
        // process and its extension.
        let popup = try XCTUnwrap(pane.webView(opener.webView, createWebViewWith: opener.webView.configuration,
                                               for: WKNavigationAction(), windowFeatures: WKWindowFeatures()))
        let popupTab = try XCTUnwrap(pane.tabs.last)
        XCTAssertTrue(popupTab.webView === popup, "what comes back is the new tab's WebView")
        XCTAssertTrue(popupTab.extensionContext === item.context, "the popup is recorded under the same extension as its opener")
        XCTAssertTrue(popup.customUserAgent?.isEmpty ?? true, "an extension popup opened from an extension page does not wear the spoof")

        // A popup opened by a web page still spoofs: the same code path, just a different opener.
        let webPopup = try XCTUnwrap(pane.webView(webTab.webView, createWebViewWith: webTab.webView.configuration,
                                                  for: WKNavigationAction(), windowFeatures: WKWindowFeatures()))
        XCTAssertNil(try XCTUnwrap(pane.tabs.last).extensionContext, "a popup opened by a web page belongs to no extension")
        XCTAssertEqual(webPopup.customUserAgent, BrowserPaneView.Settings.safariUserAgent, "a popup opened by a web page still spoofs")

        // Run it for real: the UA read inside the popup matches the extension's own pages.
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
        XCTAssertEqual(popupUA, extensionPageUA, "the UA read in the extension popup matches the extension's own pages")
    }

    final class Host: BrowserExtensionHost {
        var panes: [BrowserPaneView] = []
        var browserPanes: [BrowserPaneView] { panes }
        var focusedBrowserPane: BrowserPaneView? { panes.first }
        func openBrowserWindow(url: URL?) -> BrowserPaneView? { nil }
    }

    // MARK: - externally_connectable (web page -> extension)

    /// The match list comes from the extension's own manifest; an extension that declares no
    /// externally_connectable contributes no pattern at all.
    func testExternallyConnectableMatchesComeFromManifest() throws {
        let declared = try Self.makeExtension(background: nil, files: [:], manifest: [
            "externally_connectable": ["matches": ["https://*.example.test/*", "*://localhost/*", "", 7]],
        ])
        defer { try? FileManager.default.removeItem(at: declared) }
        XCTAssertEqual(BrowserExtensionCompat.externallyConnectableMatches(in: declared),
                       ["https://*.example.test/*", "*://localhost/*"], "only non-empty strings are taken")
        // Still readable after the shim rewrite, since apply only touches background.
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

        XCTAssertNil(BrowserExtensionCompat.externalMessagingUserScript(matches: []), "nobody declared it, so nothing is injected")
        let script = try XCTUnwrap(BrowserExtensionCompat.externalMessagingUserScript(matches: ["b://x/*", "a://y/*", "b://x/*"]))
        XCTAssertTrue(script.source.hasPrefix(BrowserExtensionCompat.externalMessagingMarker))
        XCTAssertTrue(script.source.contains("[\"a://y/*\",\"b://x/*\"]"), "deduplicated and sorted: \(script.source.prefix(400))")
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertFalse(script.isForMainFrameOnly, "subframes need it too: a matching iframe can message the extension as well")
    }

    /// The matching rule for the page-side shim: define chrome only on addresses externally_connectable
    /// matches, and never overwrite a chrome the page already has.
    @MainActor
    func testExternalMessagingScriptOnlyDefinesChromeOnMatchingPages() async throws {
        let script = BrowserExtensionCompat.externalMessagingScript(matches: ["https://*.userstyles.test/*",
                                                                              "*://localhost/*"])
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        let cases: [(String, Bool)] = [
            ("https://userstyles.test/styles/1", true),
            ("https://www.userstyles.test/", true),
            ("https://evil-userstyles.test/", false),
            ("http://userstyles.test/", false),          // The pattern pins https
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
                XCTAssertEqual(result["lastError"] as? String, "undefined", "with no error, lastError is undefined")
            }
        }
        // The page already has a chrome of its own: do not touch a single byte.
        let kept = try await Self.evaluate(inPage: webView, at: "https://userstyles.test/x", load: "<html><body>p</body></html>", """
        globalThis.browser = { runtime: { sendMessage: () => Promise.resolve("stub") } };
        globalThis.chrome = { marker: true };
        \(script)
        return { marker: chrome.marker === true, runtime: typeof chrome.runtime };
        """)
        let result = try XCTUnwrap(kept as? [String: Any])
        XCTAssertEqual(result["marker"] as? Bool, true, "a chrome the page already has is not overwritten")
        XCTAssertEqual(result["runtime"] as? String, "undefined")
    }

    /// For real: a page matching externally_connectable sends with `chrome.runtime.sendMessage(<id>, ...)`,
    /// the background's onMessageExternal receives it with the right sender and replies; a page that does not
    /// match has no chrome at all.
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
            "an installed extension declares externally_connectable, so an ordinary tab carries the page-side shim")
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
        XCTAssertEqual(result["chrome"] as? String, "object", "chrome was filled in on the page")
        XCTAssertEqual((result["promise"] as? [String: Any])?["pong"] as? String, "sync",
                       "the Promise form gets the background's reply: \(result)")
        XCTAssertEqual((result["callback"] as? [String: Any])?["pong"] as? String, "async",
                       "the callback form with an async sendResponse (return true): \(result)")
        XCTAssertNil(tab.lastProcessTerminationAt, "the page process was not killed")

        let stored = try await Self.storageValue(item, key: "external")
        let external = try XCTUnwrap(stored as? [String: Any], "the background's onMessageExternal received the message")
        XCTAssertEqual(external["url"] as? String, "http://example.test/", "sender.url is the page that sent it")
        XCTAssertEqual(external["origin"] as? String, "http://example.test")

        // Navigate the same tab to a non-matching address: the shim defines nothing.
        tab.webView.loadHTMLString("<html><body>other</body></html>", baseURL: URL(string: "http://other.test/")!)
        let outside = try await Self.evaluate(inPage: tab.webView, at: "http://other.test/", load: nil,
                                              "return { chrome: typeof chrome };")
        XCTAssertEqual((outside as? [String: Any])?["chrome"] as? String, "undefined",
                       "a page outside externally_connectable gets no chrome")
    }

    /// Extensions are installed asynchronously after launch, so a tab that is already open has to gain the
    /// page-side shim once browserExtensionsDidChange fires.
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
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) }, "no extension installed yet: nothing injected")

        let fixture = try Self.makeExtension(background: nil, files: [:],
                                             manifest: ["externally_connectable": ["matches": ["https://x.test/*"]]])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let item = try await manager.install(directory: fixture, id: Self.freshID(), source: .local)
        XCTAssertTrue(scripts().contains { $0.source.hasPrefix(marker) && $0.source.contains("https://x.test/*") },
                      "once installed, a tab that was already open carries the shim too")
        XCTAssertEqual(scripts().filter { $0.source.hasPrefix(marker) }.count, 1, "re-adding does not stack them up")
        XCTAssertTrue(scripts().contains { $0 === BrowserExtensionCompat.frameUserScript }, "the other injected scripts are untouched")

        manager.setEnabled(false, for: item)
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) }, "disabling takes it away again")
        manager.remove(item)
        XCTAssertFalse(scripts().contains { $0.source.hasPrefix(marker) })
    }

    /// An extension installed by an older version, whose directory has no shim, gets one when it is loaded at launch.
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
        XCTAssertNotNil(try Self.manifest(dir)["__quickterm"], "loadInstalled fills in the shim")
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

    /// A minimal MV3 extension plus one blank page, used to read storage from the extension's origin.
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

    /// A fresh id per case: the background worker's URL follows the id. Register two workers with different
    /// contents one after another at the same `webkit-extension://<id>/...-background.js` inside one process
    /// and WebKit keeps the earlier script (so a missing /test.js, say, fails the whole load).
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

    /// Read storage.local[key] from the extension's own page (the background writes asynchronously, so poll
    /// until a value shows up).
    @MainActor
    private static func storageValue(_ item: BrowserExtensionManager.Installed, key: String, timeout: Double = 10) async throws -> Any? {
        try await evaluate(item, "const v = await new Promise(r => chrome.storage.local.get([key], r)); return v[key] === undefined ? null : v[key];",
                           arguments: ["key": key], timeout: timeout)
    }

    /// Run an async script inside a **web page** (the page world): when `load` is non-nil it is first loaded as
    /// the content of the `at` address, and evaluation waits for that address to finish loading, so nothing is
    /// ever evaluated against the previous page.
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

    /// Run an async script inside the extension's own page (page.html), polling until it returns non-null.
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
