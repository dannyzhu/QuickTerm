import Foundation
import WebKit

/// Shims for the runtime differences between WebKit's and Chrome's WebExtension implementations.
///
/// When an extension is installed into the store its directory is rewritten so that a
/// `__quickterm-compat.js` runs ahead of the background script, filling in the APIs WebKit lacks and
/// working around WebKit-specific behavior. What it currently fixes (each of these kept a real
/// extension from starting at all):
///
/// 1. `webNavigation.onHistoryStateUpdated` / `onReferenceFragmentUpdated`: WebKit has neither event,
///    and Stylish calls `addListener` on them at the top level of its background -> TypeError -> the
///    background fails to load and the whole extension is dead. Filled in as events that never fire.
/// 2. `importScripts()`: WebKit drains the microtask queue after evaluating each imported script,
///    which Chrome does not. Tampermonkey decides whether a listener was registered during startup by
///    setting a startup flag to false after `await null`, and at startup it calls
///    `importScripts("/test.js")` on an empty file - on WebKit the flag flips right there, the
///    following `tabs.onUpdated.addListener` throws, initialization aborts, and the popup spins
///    forever. Evaluating an empty script has no effect in the first place, so the shim's
///    `importScripts` skips those outright (the list is produced by a scan at install time).
///
/// 3. The URL scheme for extension pages: `chrome-extension://<id>/...` under Chrome,
///    `webkit-extension://<id>/...` under WebKit. Plenty of Chrome builds hardcode
///    `chrome-extension:` to test "is this one of my own pages" (Tampermonkey's background rejects
///    the popup's requests on that basis, and the popup comes up blank). So every literal
///    `chrome-extension:` in every .js is rewritten to `webkit-extension:` - for WebKit that is
///    exactly the line a port is supposed to change, and a Chrome-only `chrome-extension://` URL
///    would not open under WebKit anyway.
///
/// 4. An extension page embedded in a web page (Stylish's sidebar is a
///    `webkit-extension://.../index.html` iframe inside the page) runs in the page's WebContent
///    process, and calling `tabs.*` / `windows.*` / `action.*` / `scripting.*` / `alarms.*` /
///    `contextMenus.*` / `cookies.*` directly from there is treated by the UI process as an illegal
///    IPC ("Received an invalid message WebExtensionContext_TabsQuery") and it kills the entire page
///    process. `runtime.sendMessage` / `storage` / `i18n` / `permissions` are allowed from there, so:
///    the web WebView gets `frameScript` injected, which replaces those namespaces with proxies that
///    relay through `runtime.sendMessage` to the background; the background's shim (the compat.js in
///    this file) receives the `__quickterm_relay` message, makes the call on their behalf and sends
///    the result back. Only requests from the extension's own origin are accepted.
///
/// 5. `externally_connectable` (a web page messaging an extension): WebKit implements this channel,
///    but only hangs it off the page's `browser.runtime` - there is no `chrome` in the page at all.
///    Sites in the Chrome ecosystem invariably check `"chrome" in window` first and then call
///    `chrome.runtime.sendMessage(id, ...)`, so the handshake fails silently (userstyles.org hands
///    Stylish its login token this way, and the extension shows as permanently signed out). Inject a
///    minimal alias into pages matching an extension's `externally_connectable.matches`; see
///    `externalMessagingScript`.
///
/// 6. For an extension iframe inside a web page, **IndexedDB is a different, empty database that
///    WebKit partitions by top-level site** - not the one the extension-process pages and the service
///    worker use (`navigator.storage` is undefined there, and `document.requestStorageAccess()` is
///    always refused). The message channel and `chrome.storage.*` both work, which makes the symptom
///    thoroughly confusing: the background clearly has the data, yet the sidebar panel shows "signed
///    out / no data" (Stylish's panel reads the installed styles and the Firebase login state
///    straight out of IndexedDB). The fix: in such a frame `frameScript` replaces the whole of
///    `indexedDB` with a facade (`frameIndexedDBScript`) whose requests go through
///    `runtime.sendMessage` to the background shim (`backgroundIndexedDBScript`), which runs them in
///    the extension's real partition. The batch of requests issued within one microtask is sent
///    together and run inside one real transaction in the background, which is what makes
///    transactional atomicity (rollback on error, rollback on abort()) line up with the native
///    behavior. `localStorage` is partitioned the same way, but it is a synchronous API and cannot be
///    relayed like this, so it stays one store per top-level site.
///
/// The rewrite is idempotent: `__quickterm` in the manifest records the original `background` and the
/// shim version, and a matching version means nothing is touched. Updating (reinstalling) an
/// extension replaces the whole directory, and the rewrite is regenerated with it.
enum BrowserExtensionCompat {
    /// Shim version: bump it whenever the injected script's **behavior** or the rewrite rules
    /// change, and every installed extension regenerates on its next startup.
    ///
    /// Behavior, not bytes. Regenerating rewrites every installed extension's directory, so a diff
    /// that cannot change what the shim does is not worth making every user pay for it - when the
    /// comments inside the generated JS were translated to English (2026-09-12) this deliberately
    /// stayed at 5, and installs from before then keep a Chinese-commented `__quickterm-compat.js`
    /// on disk until the next real bump. If you are unsure whether your change is behavioral, it is:
    /// bump it.
    static let version = 5
    static let compatFile = "__quickterm-compat.js"
    static let wrapperFile = "__quickterm-background.js"
    static let manifestKey = "__quickterm"

    enum Failure: Error { case badManifest }

    /// Apply the shim to an extension directory. Returns whether any file was rewritten: already at
    /// the current version, or no background script at all, both give false.
    @discardableResult
    static func apply(to directory: URL) throws -> Bool {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badManifest
        }
        let marker = manifest[manifestKey] as? [String: Any]
        // The original background: read it from the record if we have rewritten this before, otherwise
        // take whatever the manifest holds now.
        let original: [String: Any]?
        if let marker {
            original = marker["background"] as? [String: Any]
        } else {
            original = manifest["background"] as? [String: Any]
        }
        if let marker, marker["shim"] as? Int == version, shimFilesPresent(for: original, in: directory) {
            return false
        }
        // The scheme literal replacement matters even for an extension with no background: the popup
        // and the options page test URLs themselves.
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
        // Extensions with only a background.page (HTML) are left alone, but the version is still
        // recorded so we do not rescan on every startup.
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

    /// Rewrite `chrome-extension:` to `webkit-extension:` in every .js / .mjs, touching only files that
    /// actually contain the literal and skipping anything that is not UTF-8.
    /// The two schemes are the same length, so offsets in minified code and sourcemap column numbers
    /// are unaffected.
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

    /// Root-relative path of the wrapper script: it goes in the same directory as the original worker,
    /// so that relative importScripts paths inside a classic worker still resolve against that
    /// directory.
    /// An empty worker path, or one containing `..` (a manifest writing "../../x.js" must not make us
    /// write files outside the extension directory), returns nil and nothing is wrapped.
    /// This is pure string work and never touches the file system: while the target file does not exist
    /// yet, resolving symlinks gives unstable results (only one side of /var versus /private/var gets
    /// resolved).
    static func wrapperPath(forWorker worker: String) -> String? {
        let workerPath = rootPath(worker)
        let components = workerPath.split(separator: "/", omittingEmptySubsequences: false)
        guard workerPath != "/", !(workerPath as NSString).lastPathComponent.isEmpty,
              !components.contains(".."), !components.contains(".") else { return nil }
        let workerDirectory = (workerPath as NSString).deletingLastPathComponent
        return (workerDirectory as NSString).appendingPathComponent(wrapperFile)
    }

    /// Whether all the files the current version should have are present: the shim itself plus the
    /// service_worker wrapper. An extension with no background script has neither.
    private static func shimFilesPresent(for original: [String: Any]?, in directory: URL) -> Bool {
        guard let original, !original.isEmpty else { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(compatFile).path) else { return false }
        if let worker = original["service_worker"] as? String, let wrapperPath = wrapperPath(forWorker: worker) {
            return fm.fileExists(atPath: directory.appendingPathComponent(String(wrapperPath.dropFirst())).path)
        }
        return true
    }

    /// Normalize a script path from the manifest to root-relative ("bg.js" / "./a/b.js" / "/a/b.js"
    /// all become "/a/b.js").
    static func rootPath(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        if !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    static let scriptExtensions: Set<String> = ["js", "mjs"]

    /// Relative paths of every script file in the directory, hidden files excluded. It uses
    /// `enumerator(atPath:)` to get relative paths: `enumerator(at:)` hands back absolute URLs with
    /// symlinks resolved, so when the store directory is itself a link (parked in Dropbox, say) the
    /// prefix no longer matches and the whole list comes out empty.
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

    /// Root-relative paths of the script files in the directory that are empty, or contain only
    /// whitespace; the shim's importScripts uses this list to skip them.
    static func emptyScripts(in directory: URL) -> [String] {
        scriptFiles(in: directory).filter { relative in
            let url = directory.appendingPathComponent(relative)
            // No need to read a large file: check the size first and only read the contents, to test
            // for all-whitespace, when it is under 1 KB.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size < 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.allSatisfy(\.isWhitespace)
        }.map { "/" + $0 }
    }

    /// Value codec, shared by the background and the iframe sides, for passing IndexedDB keys, values
    /// and query ranges over runtime.sendMessage.
    static let valueCodecScript = """
      // The message channel only carries JSON-shaped values (a Date turns into a string, undefined is
      // lost), so both sides share one codec. It also tags IDBKeyRange into a marker object, since
      // query arguments are very often one of those.
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

    /// The IndexedDB executor on the background side, registered by the shim; it serves only requests
    /// from the extension's own origin.
    static let backgroundIndexedDBScript = """
      // The IndexedDB an extension iframe embedded in a web page gets is an empty database partitioned
      // by top-level site (see frameScript), so run the requests here in the extension's own partition
      // on its behalf.
      // The relay is asynchronous and an IDB transaction cannot survive a message round trip, so the
      // unit of a transaction is one batch: the iframe side collects the requests issued within one
      // microtask and sends them together, and here they run in order inside one real transaction
      // (see runBatch).
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
            // Do not block an upgrade the extension itself started.
            db.onversionchange = () => dropHandle(name);
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
      const errorInfo = (error) => ({
        message: String((error && error.message) || error || "QuickTerm indexedDB bridge: the request failed"),
        name: (error && error.name) || "UnknownError",
      });
      // The requests the iframe side collected within one microtask become one real transaction here:
      // they are issued in order, and if any one fails the whole batch rolls back (no preventDefault -
      // let the transaction abort exactly as it natively would). The reply carries which request
      // failed, and the iframe side then synthesizes the events in native order.
      // A transaction cannot survive a message round trip, so a batch is the largest thing that can be
      // atomic; requests the iframe side issues from an event callback belong to the next transaction.
      const runBatch = (db, storeNames, mode, ops) => new Promise((resolve, reject) => {
        let tx;
        try { tx = db.transaction(storeNames, mode); } catch (error) { reject(error); return; }
        const results = new Array(ops.length);
        // "Did this request actually complete?": when the batch aborts, the entries in `results` that
        // never ran are holes (a cursor request queues itself at the back, and on a synchronous throw
        // none of the earlier requests have come back yet). A hole becomes null over the message
        // channel, indistinguishable from a result that genuinely is null.
        const done = new Array(ops.length).fill(false);
        let broke = null;   // { index, error }: the first request that failed
        let settled = false;
        tx.oncomplete = () => { if (!settled) { settled = true; resolve({ results, version: db.version }); } };
        tx.onabort = () => {
          if (settled) return;
          settled = true;
          if (broke) resolve({ results: results.slice(0, broke.index), done: done.slice(0, broke.index),
                               failed: broke.index, error: errorInfo(broke.error), version: db.version });
          else reject(tx.error || new Error("QuickTerm indexedDB bridge: the transaction was aborted"));
        };
        const issue = (index, op) => {
          const store = tx.objectStore(String(op.store));
          const target = op.index === null || op.index === undefined ? store : store.index(String(op.index));
          const args = decode(op.args) || [];
          if (op.kind === "cursor") {
            // A cursor cannot survive a message round trip: the background runs it to completion in one
            // go and ships the rows back flattened, and the iframe side walks continue() over that
            // snapshot.
            const keysOnly = op.method === "openKeyCursor";
            const limit = Math.max(1, Math.min(Number(op.limit) || 1000, 10000));
            const rows = [];
            const request = keysOnly ? target.openKeyCursor.apply(target, args) : target.openCursor.apply(target, args);
            request.onerror = () => { if (!broke) broke = { index, error: request.error }; };
            request.onsuccess = () => {
              const cursor = request.result;
              if (!cursor) { results[index] = { rows, truncated: false }; done[index] = true; return; }
              rows.push({ key: cursor.key, primaryKey: cursor.primaryKey, value: keysOnly ? undefined : cursor.value });
              // Fetch one row past the limit: that is the only way to tell "exactly limit rows" from
              // "there are more", which the iframe side needs to distinguish finished from truncated.
              if (rows.length <= limit) { cursor.continue(); return; }
              rows.length = limit;
              results[index] = { rows, truncated: true }; done[index] = true;
            };
            return;
          }
          const fn = target[String(op.method)];
          if (typeof fn !== "function") throw new Error("QuickTerm indexedDB bridge: " + op.method + " is not available");
          const request = fn.apply(target, args);
          request.onsuccess = () => { results[index] = request.result; done[index] = true; };
          request.onerror = () => { if (!broke) broke = { index, error: request.error }; };
        };
        for (let i = 0; i < ops.length; i += 1) {
          // A synchronous throw (bad arguments, no such index, ...) natively throws at the call site
          // while the transaction carries on; here the call site returned long ago, so the only option
          // is to treat it as "this request failed" and abort the batch with it.
          try { issue(i, ops[i]); }
          catch (error) { broke = { index: i, error }; try { tx.abort(); } catch (_) {} break; }
        }
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
          // Do not open straight away when the database does not exist yet: that conjures up a v1 and
          // swallows upgradeneeded. Ask databases() first.
          // An open without a version number needs the same step: natively a nonexistent database also
          // fires upgradeneeded(0 -> 1), and going straight to openPlain means the callback where the
          // extension creates its object stores never runs, after which every transaction() is a
          // NotFoundError.
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
        if (p.op === "batch") {
          const db = await openPlain(name);
          const ops = Array.isArray(p.ops) ? p.ops : [];
          // The transaction locks only the stores this batch actually touches; the set the iframe side
          // declared to transaction() may well be wider.
          const names = [];
          for (const op of ops) {
            const store = String(op && op.store);
            if (names.indexOf(store) === -1) names.push(store);
          }
          if (!names.length) return { results: [], version: db.version };
          return await runBatch(db, names, p.mode === "readwrite" ? "readwrite" : "readonly", ops);
        }
        throw new Error("QuickTerm indexedDB bridge: unknown operation " + String(p.op));
      };
    """

    /// The shim script itself, evaluated ahead of the background script; it runs under both classic and
    /// module workers.
    static func compatScript(emptyScripts: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: emptyScripts, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        // QuickTerm WebKit compatibility shim v\(version) - generated at install time, do not edit
        (() => {
          const g = globalThis;
          const noopEvent = () => ({
            addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; }
          });
          const define = (obj, key, value) => { try { if (obj && obj[key] === undefined) obj[key] = value; } catch (_) {} };
          for (const api of [g.chrome, g.browser]) {
            if (!api) continue;
            // WebKit has neither of these webNavigation events, and some extensions call addListener on
            // them at the top level, so without them the whole background fails to start.
            if (api.webNavigation) {
              define(api.webNavigation, "onHistoryStateUpdated", noopEvent());
              define(api.webNavigation, "onReferenceFragmentUpdated", noopEvent());
            }
          }
          // An extension iframe embedded in a web page gets its page process killed by WebKit if it
          // calls tabs.* and friends directly, and its IndexedDB is a different, empty database
          // partitioned by top-level site (both covered in frameScript). This end executes both on its
          // behalf.
          const RELAY = "__quickterm_relay";
          const STORAGE = "__quickterm_idb";
        \(valueCodecScript)
        \(backgroundIndexedDBScript)
          // chrome and browser are usually the same object: hook each runtime once.
          const relayed = new Set();
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
                  // The result may not survive the message channel (a Window, a host object): report a
                  // definite error rather than leaving the frame waiting for a "no response".
                  try { reply({ result: result === undefined ? null : result }); } catch (e) { fail(e); }
                }, fail);
              return true;
            });
          }
          // WebKit's importScripts drains the microtask queue after evaluating each script, which Chrome
          // does not. An empty script has no effect in the first place, so skip it outright and avoid
          // interrupting an extension (Tampermonkey) that decides it is past startup "one microtask
          // later".
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

    /// The IndexedDB bridge on the iframe side, used from `frameScript`; see the comments there.
    static let frameIndexedDBScript = """
      // The IndexedDB and localStorage an extension iframe embedded in a web page gets are **a
      // different, empty store** that WebKit partitions by top-level site, not the one the
      // extension-process pages and the service worker use (navigator.storage is missing there too, and
      // requestStorageAccess is always refused).
      // The login state and the data a panel like a sidebar needs all live in the extension's own
      // store, so the panel shows "signed out / no data" forever.
      // This replaces the whole of indexedDB with a facade: every request goes through
      // runtime.sendMessage to the background and runs in the extension's real partition.
      const bridgeIndexedDB = (runtime) => {
        const native = globalThis.indexedDB;
        if (!native || typeof globalThis.IDBRequest !== "function" || typeof runtime.sendMessage !== "function") return;
        const CHANNEL = "__quickterm_idb";
        // The message channel only carries JSON-shaped values (a Date turns into a string, undefined is
        // lost), so both sides share one codec. It also tags IDBKeyRange into a marker object, since
        // query arguments are very often one of those.
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
        // Events have to reach both the on<type> property and addEventListener, and event.target has to
        // be the object itself, so everything goes through dispatchEvent.
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
        // The facade objects have to pass `x instanceof IDBRequest`, which is how wrapper libraries such
        // as idb find their way. So splice the prototype onto the native one.
        // name / result / ... on the native prototype are read-only getters, and `this.name = ...` inside
        // a class throws in strict mode, so after splicing, redefine those names on our own prototype as
        // writable data properties.
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
          // send() already decoded the snapshot; do not decode it a second time (decoding a Date twice
          // turns it into {}).
          _load(at) {
            const row = this._rows[at];
            this._at = at;
            this.key = row ? row.key : undefined;
            this.primaryKey = row ? row.primaryKey : undefined;
            if (!this._keysOnly) this.value = row ? row.value : undefined;
          }
          // continue(key): a forward cursor looks for the first row >= key, while a reverse (prev*)
          // cursor's snapshot is in descending order, so it looks for the first row <= key.
          _seek(key, from) {
            const back = String(this.direction).indexOf("prev") === 0;
            for (let i = from; i < this._rows.length; i += 1) {
              try {
                const order = native.cmp(this._rows[i].key, key);
                if (back ? order <= 0 : order >= 0) return i;
              } catch (_) { return i; }
            }
            return this._rows.length;
          }
          // Natively continue() returns undefined and makes the original request fire success once more.
          // We do the same, and additionally return the request: idb wraps the return value in another
          // Promise, which then resolves to the next cursor.
          _step(next) {
            const request = this.request;
            const transaction = request.transaction;
            return transaction._localStep(request, () => {
              if (next < this._rows.length) { this._load(next); succeed(request, this); return; }
              if (this._truncated) {
                // The snapshot was truncated: reaching its end must not be reported as "iteration
                // finished", which would quietly erase the remaining records. Fail explicitly.
                const error = failure("QuickTerm indexedDB bridge: the cursor snapshot was truncated at "
                                      + this._rows.length + " rows", "UnknownError");
                transaction.error = error;
                failRequest(request, error);
                transaction._finish("error");
                return;
              }
              succeed(request, null);
            });
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
              // An upgrade transaction: the versionchange transaction on the background side cannot
              // survive a message round trip, so record the operations and replay them together.
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

        // A transaction cannot survive a message round trip, but **the batch of requests issued within
        // one microtask** can: collect them, send them to the background in one go, and it runs them in
        // order inside one real transaction. That makes "one request fails -> the whole transaction
        // rolls back" and "abort() rolls back whatever has not run" match the native behavior.
        // Requests issued from an event callback queue into the next batch, which is the background's
        // next transaction; see porting-notes.
        class BridgeTransaction extends EventTarget {
          constructor(db, storeNames, mode, manual) {
            super();
            this.db = db; this.mode = mode; this.error = null; this.durability = "default";
            this.objectStoreNames = nameList(storeNames.map(String));
            this.oncomplete = null; this.onerror = null; this.onabort = null;
            this._live = new Set();     // requests that have not settled yet (queued plus in flight)
            this._queue = []; this._inflight = false; this._flushing = false;
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
          commit() { this._flush(); this._schedule(); }
          // A native transaction commits automatically once every request has settled and no new request
          // was issued in that turn; one microtask makes the same decision here.
          _schedule() {
            Promise.resolve().then(() => {
              if (this._finished || this._ops || this._inflight) return;
              if (this._pending === 0 && !this._queue.length) this._finish("complete");
            });
          }
          // The native teardown order: the failing request's error bubbles up as the transaction's
          // error, then every request still outstanding gets an AbortError, then abort.
          _finish(type) {
            if (this._finished) return;
            this._finished = true;
            const stranded = Array.from(this._live);
            this._live.clear(); this._queue.length = 0; this._pending = 0;
            if (type === "complete") { fire(this, "complete", new Event("complete")); return; }
            if (type === "error") fire(this, "error", new Event("error"));
            const aborted = failure("The transaction was aborted", "AbortError");
            for (const entry of stranded) {
              if (entry.settled) continue;
              entry.settled = true;
              failRequest(entry.request, aborted);
            }
            fire(this, "abort", new Event("abort"));
          }
          _enqueue(entry) {
            this._live.add(entry); this._pending += 1; this._queue.push(entry);
            if (!this._flushing) {
              this._flushing = true;
              Promise.resolve().then(() => { this._flushing = false; this._flush(); });
            }
            return entry.request;
          }
          _settle(entry) {
            if (entry.settled || this._finished) return false;
            entry.settled = true; this._live.delete(entry); this._pending -= 1;
            return true;
          }
          // Only one batch is in flight at a time: requests within one transaction have to settle in the
          // order they were issued.
          _flush() {
            if (this._finished || this._inflight || !this._queue.length) return;
            const batch = this._queue;
            this._queue = [];
            this._inflight = true;
            send({ op: "batch", name: this.db.name, mode: this.mode === "readonly" ? "readonly" : "readwrite",
                   ops: batch.map((entry) => entry.op) })
              .then((data) => { this._inflight = false; this._deliver(batch, data || {}); },
                    (error) => {
                      this._inflight = false;
                      this.error = error;
                      for (const entry of batch) { if (this._settle(entry)) failRequest(entry.request, error); }
                      this._finish("error");
                    });
          }
          // The native order: requests before the failure still succeed, the failing one errors, and
          // then the transaction errors and aborts.
          _deliver(batch, data) {
            const results = data.results || [];
            // Only an aborted reply carries this; a batch that committed ran in full.
            const done = Array.isArray(data.done) ? data.done : null;
            const failedAt = typeof data.failed === "number" ? data.failed : -1;
            const delivered = failedAt < 0 ? batch.length : Math.min(failedAt, batch.length);
            for (let i = 0; i < delivered; i += 1) {
              if (this._finished) return;   // some success callback called abort()
              const entry = batch[i];
              // Queued before the failing request but not yet complete when the background rolled back
              // (a cursor still iterating, or nothing having come back yet on a synchronous throw):
              // it must not report success. Leave it in _live and let _finish("error") send it an
              // AbortError, exactly as the native implementation would.
              if (done && done[i] !== true) continue;
              if (!this._settle(entry)) continue;
              succeed(entry.request, entry.wrap ? entry.wrap(results[i]) : results[i]);
            }
            if (this._finished) return;
            // A version from the background newer than this connection's means someone else upgraded.
            // Fire the event on the next microtask rather than wedging it between transaction events.
            if (data.version !== this.db.version) Promise.resolve().then(() => this.db._noteVersion(data.version));
            if (failedAt < 0) { this._flush(); this._schedule(); return; }
            const error = failure((data.error && data.error.message) || "The request failed",
                                  data.error && data.error.name);
            const entry = batch[failedAt];
            if (entry && this._settle(entry)) { this.error = error; failRequest(entry.request, error); }
            this._finish("error");
          }
          _request(store, indexName, method, args, write) {
            if (this._finished) throw failure("The transaction has finished", "TransactionInactiveError");
            if (write && this.mode === "readonly") throw failure("The transaction is read-only", "ReadOnlyError");
            const request = new BridgeRequest(store, this);
            return this._enqueue({ request, settled: false,
                                   op: { kind: "call", store: store.name, index: indexName, method, args: encode(args) } });
          }
          _cursor(store, indexName, method, args) {
            if (this._finished) throw failure("The transaction has finished", "TransactionInactiveError");
            const request = new BridgeRequest(store, this);
            const direction = typeof args[1] === "string" ? args[1] : "next";
            const entry = { request, settled: false,
                            op: { kind: "cursor", store: store.name, index: indexName, method,
                                  args: encode(args), limit: 5000 } };
            entry.wrap = (data) => {
              const rows = (data && data.rows) || [];
              return rows.length ? new BridgeCursor(request, store, indexName, direction, rows,
                                                    method === "openKeyCursor", !!(data && data.truncated)) : null;
            };
            return this._enqueue(entry);
          }
          // Stepping a cursor over the local snapshot: no message is sent, but it still has to hold the
          // transaction open the way a real request does.
          _localStep(request, body) {
            const entry = { request, settled: false };
            this._live.add(entry); this._pending += 1;
            Promise.resolve().then(() => {
              if (!this._settle(entry)) return;
              body();
              if (this._finished) return;
              this._flush(); this._schedule();
            });
            return request;
          }
        }
        inherit(BridgeTransaction, globalThis.IDBTransaction,
                ["db", "mode", "error", "durability", "objectStoreNames", "oncomplete", "onerror", "onabort"]);

        const versionChangeEvent = (type, oldVersion, newVersion) => {
          try { return new IDBVersionChangeEvent(type, { oldVersion, newVersion }); }
          catch (_) {
            const event = new Event(type);
            try { event.oldVersion = oldVersion; event.newVersion = newVersion; } catch (__) {}
            return event;
          }
        };

        // The facade connections that are open: when something else (this frame, the background,
        // another tab) upgrades or deletes the database, send them versionchange exactly as the native
        // implementation would.
        // Held weakly: some libraries (firebase-auth) open a fresh connection for every operation and
        // never close() it, so strong references would pile up without end.
        const connections = new Set();
        const weakRef = (value) => {
          try { return new WeakRef(value); } catch (_) { return { deref: () => value }; }
        };
        const trackConnection = (db) => {
          if (connections.size > 64) {
            for (const ref of Array.from(connections)) { if (!ref.deref()) connections.delete(ref); }
          }
          db._ref = weakRef(db);
          connections.add(db._ref);
        };
        const announceVersionChange = (name, newVersion) => {
          for (const ref of Array.from(connections)) {
            const db = ref.deref();
            if (!db) { connections.delete(ref); continue; }
            if (db.name === String(name)) db._noteVersion(newVersion);
          }
        };

        class BridgeDatabase extends EventTarget {
          constructor(schema) {
            super();
            this.name = schema.name; this.version = schema.version;
            this._stores = new Map((schema.stores || []).map((store) => [store.name, store]));
            this.objectStoreNames = nameList(Array.from(this._stores.keys()).sort());
            this.onversionchange = null; this.onclose = null; this.onerror = null; this.onabort = null;
            this._upgrade = null; this._closed = false; this._noticed = undefined; this._ref = null;
            trackConnection(this);
          }
          // The version of the database in the background changed (an upgrade or a delete). Natively the
          // connections still open get a versionchange at this point and decide for themselves whether
          // to close(). We cannot actually block the upgrade - the background knows nothing about the
          // iframe's lifetime - so all we can do is deliver the event.
          // Each change is announced once, and `version` stays whatever this connection holds, since a
          // stale native connection likewise stays on the old version.
          _noteVersion(version) {
            const next = version === null ? null : (typeof version === "number" ? version : undefined);
            if (next === undefined || this._closed) return;
            if (next === this.version || next === this._noticed) return;
            this._noticed = next;
            fire(this, "versionchange", versionChangeEvent("versionchange", this.version, next));
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
          close() { this._closed = true; if (this._ref) connections.delete(this._ref); }
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

        class BridgeFactory {
          open(name, version) {
            const request = new BridgeOpenRequest();
            const dbName = String(name);
            send({ op: "open", name: dbName, version: version === undefined ? null : Number(version) })
              .then((info) => {
                if (!info || !info.upgrade) { announceVersionChange(dbName, info && info.version); return info; }
                // Connections to the same name still open in this frame: natively they receive
                // versionchange right now (the connection doing the upgrade itself excepted).
                announceVersionChange(dbName, info.version);
                // An upgrade is needed: stage a "recording" versionchange transaction locally so the
                // extension builds its schema as usual, then hand those operations to the background to
                // replay.
                const db = new BridgeDatabase({ name: dbName, version: info.version, stores: info.stores || [] });
                const transaction = new BridgeTransaction(db, Array.from(db.objectStoreNames), "versionchange", true);
                transaction._ops = [];
                db._upgrade = transaction;
                request.result = db;
                request.transaction = transaction;
                fire(request, "upgradeneeded", versionChangeEvent("upgradeneeded", info.oldVersion, info.version));
                // The callback aborted the upgrade transaction: natively the version stays put and the
                // open request fails with AbortError, so not one of the recorded operations may be
                // replayed by the background. Its op:"open" changed nothing, so backing out now is
                // still in time.
                if (transaction._finished) {
                  db._upgrade = null; transaction._ops = null; request.transaction = null;
                  db.close();
                  throw failure("The version change transaction was aborted", "AbortError");
                }
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
            // Native behavior: connections still open get versionchange (newVersion null) before
            // the delete.
            announceVersionChange(name, null);
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

    /// The script injected into every frame of a **web** WebView (document start, page world). It only
    /// does anything inside a `webkit-extension:` frame, where it does two things:
    /// 1. Replaces the namespaces that get the page process killed when called directly (tabs /
    ///    windows / ...) with proxies that relay through the background. Events (onXxx) and constants
    ///    are left as they are, since registering a listener does not trigger that IPC. Known
    ///    trade-offs: the callback form cannot surface runtime.lastError; arguments carrying functions
    ///    (scripting.executeScript's `func`) do not survive message serialization; and a background
    ///    that replies synchronously to every message will answer ahead of the relayed result.
    /// 2. Replaces `indexedDB` with a facade executed by the background (see point 6 at the top of this
    ///    file): IndexedDB inside such a frame is partitioned by top-level site by WebKit, so what it
    ///    reads is a different, empty database. Known trade-offs: the unit of a transaction is "the
    ///    batch issued within one microtask" - that batch is one real transaction in the background
    ///    (one failing request rolls back the whole batch, abort() rolls back whatever has not been
    ///    sent), and requests issued from an event callback land in the next transaction; an upgrade
    ///    transaction can only create stores, create indexes and write (it cannot read, and the
    ///    operations are recorded and replayed by the background); a cursor is a snapshot the
    ///    background runs to completion in one go (capped at 5000 rows, and going past the end of a
    ///    truncated snapshot fails explicitly rather than pretending the iteration ended normally);
    ///    values cross the channel with JSON semantics (Date and IDBKeyRange are encoded specially,
    ///    while Blob / File / ArrayBuffer do not make it across); and `versionchange` is only
    ///    synthesized when this frame itself upgrades or deletes the database, or when the next request
    ///    notices the background's version has changed (the background cannot push into such a frame).
    ///    `runtime.sendMessage` itself does work inside such a frame - callbacks, Promises and connect
    ///    ports were all verified - so the bridge is added only at the storage layer.
    ///    The bridge is only installed when the background **really has the shim attached** (the
    ///    rewrite left its trace in manifest.background): without the executor on the other end every
    ///    call would fail, which is worse than leaving the native partitioned database in place.
    static let frameScript = """
    (() => {
      // Only extension iframes embedded in a web page matter here: an extension page as the main frame
      // runs in the extension process, and a WebView with an ordinary configuration cannot load an
      // extension main frame at all.
      if (location.protocol !== "webkit-extension:" || window === window.top) return;
      const RELAY = "__quickterm_relay";
      const SAFE = new Set(["runtime", "storage", "i18n", "permissions", "extension", "dom", "devtools", "test"]);
      const MARK = Symbol.for("QuickTerm.relayed");
      // API methods usually live on the prototype, so collect property names up the prototype chain,
      // stopping at Object.prototype.
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
      // defineProperty has no effect on WebKit's namespace objects (static properties of a host
      // object), so the only option is to replace the root object outright: copy it into a plain
      // object, reference the safe namespaces as they are, and swap the dangerous ones for proxies.
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
      // The executor end of the IndexedDB bridge lives in the background shim
      // (__quickterm-compat.js). For an extension whose background never got the shim - no background
      // at all, only a background.page (HTML, which is not rewritten), a service_worker path outside
      // the directory, or a shim that failed to be written at install time - installing the bridge
      // would only make every IDB call fail with "no response from the extension background", which is
      // worse than not installing it: in that case the native (top-level-site partitioned) indexedDB
      // stays, and the iframe reading and writing its own store is at least self-consistent, exactly as
      // it was before the bridge existed.
      // The test looks only at the trace the rewrite left in manifest.background (`apply(to:)` writes
      // the manifest last, so no trace exists unless the shim reached disk); if the manifest cannot be
      // read, assume the shim is there - better to keep the bridge than to fall back silently into the
      // "the panel has no data" bug.
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

    // MARK: - The User-Agent inside extension frames

    /// First-line marker, so this script can be recognized inside one userContentController. Its
    /// contents change with the measured UA, so it cannot be deduplicated by object identity.
    static let userAgentMarker = "// QuickTerm extension frame user agent"

    /// An extension iframe embedded in a web page (a `webkit-extension://...` frame running inside the
    /// page's WebView) inherits the site-facing UA disguise we apply (`browser.user_agent`, Safari by
    /// default), while the same extension's background, workers and extension pages get WebKit's own
    /// UA.
    /// Chrome has no such split: an extension's frames always report the browser's own UA, and a
    /// page-side UA override never reaches an extension's frames.
    /// The consequence is that **the two halves of one extension believe they are in two different
    /// browsers**, and a library takes a different branch in the iframe half alone. A real case:
    /// under the Safari UA, Stylish's sidebar makes firebase-auth enable its "proactive"
    /// initialization and await the gapi popup/redirect resolver, which only means anything in a
    /// browser - and in this MV3 build `_loadJS`, which loads remote scripts, is an empty stub (MV3
    /// forbids remote code). That promise therefore never settles: `onAuthStateChanged` never fires
    /// once, `getCurrentUser()` hangs forever, and the panel sits on its defaults showing "signed out"
    /// even though the login record is right there in IndexedDB and the styles are being injected as
    /// usual.
    /// The fix: inside such a frame, swap `navigator.userAgent` / `appVersion` back to WebKit's own and
    /// line up with the extension's other half.
    /// Only frames on the extension's own origin are changed; web pages still see the disguise (and the
    /// HTTP request headers stay disguised too - an extension cannot see its own request headers).
    static func userAgentScript(_ userAgent: String) -> String {
        """
        \(userAgentMarker)
        (() => {
          if (location.protocol !== "webkit-extension:") return;
          const ua = \(jsString(userAgent));
          if (!ua || navigator.userAgent === ua) return;
          const define = (target, name, value) => {
            try {
              Object.defineProperty(target, name, { get: () => value, configurable: true, enumerable: true });
              return navigator[name] === value;
            } catch (_) { return false; }
          };
          // Shadow the prototype getter on the instance; if WebKit ever stops allowing a definition on
          // the instance, fall back to the prototype.
          if (!define(navigator, "userAgent", ua)) define(Navigator.prototype, "userAgent", ua);
          const appVersion = ua.replace(/^Mozilla\\//, "");
          if (!define(navigator, "appVersion", appVersion)) define(Navigator.prototype, "appVersion", appVersion);
        })();
        """
    }

    static func userAgentUserScript(_ userAgent: String) -> WKUserScript {
        WKUserScript(source: userAgentScript(userAgent), injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - externally_connectable: the page-to-extension message channel

    /// First-line marker in the page-side shim's source, so "this is the external messaging shim" can be
    /// recognized inside one userContentController. Its contents change with the set of installed
    /// extensions, so unlike frameUserScript it cannot be deduplicated by object identity.
    static let externalMessagingMarker = "// QuickTerm externally_connectable"

    /// `externally_connectable.matches` from the manifest: the page addresses allowed to message this
    /// extension, as Chrome match patterns.
    /// Nothing declared, or the wrong shape, gives an empty list. This reads the manifest as installed
    /// into the store: the rewrite only touches `background` and leaves this key untouched.
    static func externallyConnectableMatches(in directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = manifest["externally_connectable"] as? [String: Any],
              let matches = block["matches"] as? [Any] else { return [] }
        return matches.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// The page-side `chrome.runtime` shim (page world, every frame, document start).
    ///
    /// WebKit **does implement** externally_connectable - the background's
    /// `runtime.onMessageExternal` receives the messages exactly as it should - but it only hangs the
    /// entry point off the page's `browser.runtime.{sendMessage,connect}`, and there is no `chrome` in
    /// the page at all.
    /// Sites in the Chrome ecosystem test "is the extension installed" and hand it a token with
    /// `"chrome" in window` plus `chrome.runtime.sendMessage(<extension id>, msg, cb)`, so that
    /// handshake fails silently in QuickTerm (userstyles.org passes Stylish its login token this way,
    /// which is why the extension kept showing as signed out with no styles).
    ///
    /// This adds the thinnest possible alias: `chrome.runtime.sendMessage` / `connect` forward straight
    /// to `browser.runtime`, and the actual delivery and authorization are still WebKit's own (sending
    /// to an extension that did not declare this page just yields undefined).
    /// It is defined only when **at least one installed extension declared externally_connectable and
    /// this frame's address matches**, it never overwrites a `chrome` that already exists on the page,
    /// and it exposes no API beyond messaging.
    static func externalMessagingScript(matches: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: matches, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return #"""
        \#(externalMessagingMarker) - generated from the installed extensions' externally_connectable, do not edit
        (() => {
          const g = globalThis;
          // The page already has a chrome (real Chrome, or something else injected it): leave it alone.
          if (typeof g.chrome !== "undefined") return;
          const runtime = g.browser && g.browser.runtime;
          if (!runtime || typeof runtime.sendMessage !== "function") return;
          const PATTERNS = \#(list);
          const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const glob = (value) => new RegExp("^" + value.split("*").map(escapeRe).join("[\\s\\S]*") + "$");
          // Chrome match pattern: <scheme>://<host><path>. A * scheme means http/https only, and a *.
          // host includes the bare host itself.
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
          // The runtime Chrome gives an ordinary web page also has only sendMessage / connect - no id,
          // no onMessage - so match that exactly.
          const api = {
            sendMessage: function sendMessage(...args) {
              const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
              let promise;
              try { promise = Promise.resolve(runtime.sendMessage.apply(runtime, args)); }
              catch (error) { promise = Promise.reject(error); }
              // No callback means the Promise form (Chrome MV3 semantics).
              if (!callback) return promise;
              promise.then((value) => callback(value), () => callback(undefined));
              return undefined;
            },
          };
          if (typeof runtime.connect === "function") {
            api.connect = function connect(...args) { return runtime.connect.apply(runtime, args); };
          }
          // Sites routinely write `if (chrome.runtime.lastError)`, and in Chrome that reads undefined
          // when nothing went wrong.
          try { Object.defineProperty(api, "lastError", { get: () => undefined, configurable: true }); } catch (_) {}
          try {
            Object.defineProperty(g, "chrome", { value: { runtime: api }, writable: true, configurable: true, enumerable: true });
          } catch (_) {}
        })();
        """#
    }

    /// The external messaging shim that should currently be injected into web pages; nil, meaning
    /// nothing is injected, when no extension declared externally_connectable.
    static func externalMessagingUserScript(matches: [String]) -> WKUserScript? {
        let unique = Array(Set(matches)).sorted()
        guard !unique.isEmpty else { return nil }
        return WKUserScript(source: externalMessagingScript(matches: unique),
                            injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// A JS string literal: a JSON-encoded string is a valid literal in JS.
    static func jsString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }
}
