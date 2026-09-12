import AppKit

/// The **one** implementation of "build a pane from a description".
///
/// Both `pane new` and `spec apply` create their panes here. The price of a second implementation
/// is concrete in this app: the engine forces wait-after-command on any surface that carries a
/// command (without taking `closesOnChildExit` over ourselves, the pane sits there frozen forever
/// once the command finishes), a file-manager pane has to register its session or the close
/// confirmation comes back, and a browser pane that misses the theming step comes up with a white
/// background - write those three out twice and one of them is guaranteed to be forgotten.
@MainActor
enum ControlPaneFactory {
    struct Request {
        var kind = "terminal"
        /// An absolute path with `~` already expanded and `..` already normalized; nil = inherit
        /// from the anchor
        var cwd: String?
        var cmd: String?
        var hold = false
        var env: [String: String] = [:]
        var url: String?

        init(kind: String = "terminal", cwd: String? = nil, cmd: String? = nil,
             hold: Bool = false, env: [String: String] = [:], url: String? = nil) {
            self.kind = kind
            self.cwd = cwd
            self.cmd = cmd
            self.hold = hold
            self.env = env
            self.url = url
        }
    }

    /// Built, but **not yet inserted into any layout**. Call `register` once it is in, `discard`
    /// if it never gets in
    struct Made {
        var pane: PaneView
        var fileManagerSession: FileManagerLaunch.Session?
        var fileManagerFound = false
    }

    /// Mutual-exclusion and value checks on the arguments. Done **before** anything is built:
    /// `spec apply` relies on it to guarantee "if validation fails, not a single pane is created"
    static func validate(_ request: Request) throws {
        switch request.kind {
        case "terminal", "file-manager", "browser": break
        default:
            throw ControlErrorBody(.badRequest, "Unknown pane kind \(request.kind)",
                                   candidates: ["terminal", "browser", "file-manager"])
        }
        if request.kind != "browser", request.url != nil {
            throw ControlErrorBody(.badRequest, "--url only means anything with --kind browser",
                                   hint: "quickterm pane new --kind browser --url …")
        }
        if request.kind == "browser", request.cmd != nil {
            throw ControlErrorBody(.badRequest, "--cmd means nothing to a browser pane")
        }
        if let cwd = request.cwd {
            guard cwd.hasPrefix("/"), !cwd.contains("\0") else {
                throw ControlErrorBody(.badRequest, "--cwd is not a usable path: \(cwd)")
            }
        }
        if request.kind == "browser" {
            _ = try browserURL(request)
        }
    }

    /// Whether this kind actually makes any use of `cwd`.
    ///
    /// A browser pane does not: the browser branch of `make` takes only a url, and
    /// `BrowserPaneView.workingDirectory` is always nil. `--cwd` together with `--kind browser` has
    /// always been **accepted and ignored** (no error, so that a script which passes `--cwd "$PWD"`
    /// unconditionally does not break every time it opens a browser pane), which means the privacy
    /// guard's warnings and `--require-cwd` have to skip it as well - otherwise the very same
    /// ignored argument turns into a bogus warning, or even a failure, just because the current
    /// directory happens to be ~/Downloads
    static func consumesWorkingDirectory(_ kind: String) -> Bool { kind != "browser" }

    /// Does the target directory actually exist. `spec apply` walks the whole spec through this
    /// **before touching anything** - discovering half way in that some directory is missing leaves
    /// the workspace already half torn down
    static func directoryProblem(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) else {
            return "no such directory: \(cwd)"
        }
        guard isDirectory.boolValue else { return "not a directory: \(cwd)" }
        return nil
    }

    /// Schemes the address-bar heuristics do not recognize but a browser pane really can open.
    /// `webkit-extension://` is the only member, and since 1.5.7 it is first-class state (the
    /// embedded extension panel is exactly this): `url(forInput:)` only knows
    /// http/https/file/about, so an extension page first gets read as "looks like a domain" and
    /// padded out into `https://webkit-extension://...`, and anything that does not look like a
    /// domain gets percent-encoded and thrown at a search engine - which means
    /// `spec dump -> apply` would replace an open extension panel with a web search
    static let passthroughSchemes: Set<String> = ["webkit-extension"]

    /// An **absolute** URL coming back from a spec / from saved state -> URL. The path for what a
    /// human types into the address bar still goes through `url(forInput:)` (a word like
    /// "quickterm" should reach a search engine, not be read as a scheme)
    static func resolveURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           passthroughSchemes.contains(scheme) {
            return url
        }
        return BrowserPaneView.settings.url(forInput: raw)
    }

    /// **Do these two URLs mean the same page.**
    ///
    /// Comparing `absoluteString` directly is guaranteed to be wrong in one place: the URL WebKit
    /// settles on carries a normalized path, while humans (and agents) write the elided form -
    /// `http://localhost:3000` becomes `http://localhost:3000/` once it is loaded into the WebView.
    /// So `browser goto --url http://localhost:3000` would forever report "changed" for a tab that
    /// is **already sitting there** (the absolute-assignment promise is void on the spot, and the
    /// page is pointlessly reloaded), and a hand-written
    /// `{"kind":"browser","url":"http://localhost:3000"}` in a `spec apply` would never match the
    /// live pane, so every apply tears it down and rebuilds it.
    ///
    /// Normalization only does what WebKit itself does (lowercase scheme / host, an empty path
    /// counts as `/`, drop the default port); query and fragment are not touched by a single
    /// character: `?a=1&b=2` and `?b=2&a=1` are two different pages
    static func sameURL(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return canonical(a) == canonical(b)
    }

    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.path.isEmpty, parts.host != nil { parts.path = "/" }
        if let port = parts.port, port == Self.defaultPort(parts.scheme) { parts.port = nil }
        return parts.string ?? url.absoluteString
    }

    private static func defaultPort(_ scheme: String?) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        case "ftp": 21
        default: nil
        }
    }

    static func browserURL(_ request: Request) throws -> URL {
        let raw = request.url ?? BrowserPaneView.settings.home
        guard let url = resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "Could not resolve \(raw) to a URL")
        }
        return url
    }

    /// Build it. **Does not insert into the layout** (`spec apply` needs to compute the whole
    /// layout value first and assign it in one go)
    static func make(_ request: Request, controller: MainWindowController,
                     inheriting anchorDirectory: String?) throws -> Made {
        try validate(request)
        switch request.kind {
        case "browser":
            let pane = controller.controlMakeBrowserPane(url: try browserURL(request))
            return Made(pane: pane)
        case "file-manager":
            let start = request.cwd ?? anchorDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            let made = controller.makeFileManagerPane(startDirectory: start)
            return Made(pane: made.pane, fileManagerSession: made.launch.session,
                        fileManagerFound: made.launch.found)
        default:
            let directory = request.cwd ?? anchorDirectory
            let surface = controller.newSurface(workingDirectory: directory,
                                                command: request.cmd, environment: request.env)
            // The engine forces wait-after-command on a surface that carries a command and will
            // never close on its own: if we want "the pane disappears when the command finishes",
            // we have to take that over ourselves (--hold is the explicit request not to).
            if request.cmd != nil, !request.hold { surface.closesOnChildExit = true }
            // When a directory was given explicitly, **seed pwd with it right away** (the yazi
            // pane has always done this). Otherwise the cwd that `spec dump` reads only shows up
            // once the shell's first prompt emits OSC 7, and whether `dump -> apply -> dump` comes
            // out equal then depends on how long you waited between the two dumps - that is not a
            // fixed point, that is a race.
            // A directory the privacy guard turned down is **not** seeded: no shell was started
            // there at all, and seeding it would make `state`'s cwd say something that can be
            // falsified on the spot (`pane new` returns a cwd_denied warning in the response to
            // explain this).
            if let directory, WorkingDirectoryGate.usable(directory) != nil {
                surface.pwd = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            }
            return Made(pane: surface)
        }
    }

    /// It is in the layout now: register whatever needs registering
    static func register(_ made: Made, controller: MainWindowController) {
        guard let session = made.fileManagerSession else { return }
        // Only register the session when the file manager really did start (that is what buys the
        // close-confirmation exemption + reading the directory back on exit) - same rule as
        // perform(.fileManager).
        if made.fileManagerFound {
            controller.registerFileManagerSession(made.pane, session)
        } else {
            FileManagerLaunch.cleanup(session)
        }
    }

    /// Built but never landed in the layout (insertion failed / another pane in the same batch
    /// failed to build): **clean it up on the spot**. A terminal relies on dropping the last
    /// reference to trigger `SurfaceView.deinit -> ghostty_surface_free`; a browser pane needs one
    /// `paneWillClose()` (cancel downloads, tell the extension the window closed); a file manager
    /// needs its cwd temp file deleted. Miss any one of them and it is a silent leak
    static func discard(_ made: Made, controller: MainWindowController) {
        if let session = made.fileManagerSession { FileManagerLaunch.cleanup(session) }
        (made.pane as? BrowserPaneView)?.paneWillClose()
    }
}
