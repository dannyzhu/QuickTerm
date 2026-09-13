import AppKit

/// `browser open|goto|reload|close` - the **tab** level inside a browser pane.
///
/// Three rules that run through all of it:
///
/// 1. **`-t` names the pane, `--tab` names the tab.** The two levels are written separately
///    (rather than packed into something like `b3.2`) because `.` is already the
///    "workspace.pane" separator in the addressing grammar; once they are mixed, "b3 in
///    workspace 2" and "the 2nd tab of b3" look exactly the same.
/// 2. **The redaction rules are not loosened by a single character.** A tab's title and URL go
///    down the same line as the pane-level url / title: a caller without a token reads
///    `<redacted>` - including **the diff in the change envelope** (`from` is the URL of the page
///    before the command ran, and leaking that is no different from reading `state` directly).
/// 3. **Closing the last tab = closing the whole pane.** That is not a semantic we invented, it is
///    the one Cmd+W already has in `MainWindowController.perform(.closePane)` (Chrome's
///    semantics). If the command line took it upon itself to say "the last tab cannot be closed",
///    the same act would produce two different results through the two entry points.
@MainActor
extension ControlCommandRunner {
    func runBrowser(_ ctx: ControlContext) throws -> (echo: ResolvedTarget?, data: any Encodable) {
        switch ctx.spec.verb {
        case "open": return try browserOpen(ctx)
        case "goto": return try browserGoto(ctx)
        case "reload": return try browserReload(ctx)
        case "close": return try browserClose(ctx)
        default:
            throw ControlErrorBody(.unknownCommand, "browser has no verb \(ctx.spec.verb)",
                                   candidates: ControlCommandTable.commands(inGroup: "browser").map(\.verb))
        }
    }

    // MARK: Resolution

    /// Resolve down to a browser pane. A terminal pane has to get an **explicit** error, not a
    /// bland "nothing was done"
    func requireBrowser(_ ctx: ControlContext) throws -> (hit: PaneHit, pane: BrowserPaneView) {
        let hit = try requirePane(ctx, ctx.target)
        guard let browser = hit.pane as? BrowserPaneView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) is a \(hit.pane.kind.rawValue) pane, so it has no tabs",
                hint: "Browser pane handles start with b (quickterm list panes); "
                    + "to open a new one: quickterm pane new --kind browser --url <url>")
        }
        return (hit, browser)
    }

    /// `--tab` -> a 0-based index. **Out of range and ambiguous both raise**; never "pick the
    /// nearest one"
    func resolveTab(_ ref: ControlTabRef, in pane: BrowserPaneView, handle: String) throws -> Int {
        let count = pane.tabs.count
        guard count > 0 else {
            throw ControlErrorBody(.notFound, "\(handle) has no tabs at all", retryAfterMs: 200)
        }
        switch ref {
        case .active:
            return pane.activeTabIndex
        case .last:
            return count - 1
        case .index(let number):
            guard number <= count else {
                throw ControlErrorBody(
                    .notFound, "\(handle) has \(count) tab\(count == 1 ? "" : "s"), so --tab \(number) is out of range",
                    hint: "quickterm get -t \(handle) --json | jq '.data.pane.tabList'")
            }
            return number - 1
        case .id(let prefix):
            let matches = pane.tabs.indices.filter {
                pane.tabs[$0].id.uuidString.replacingOccurrences(of: "-", with: "")
                    .lowercased().hasPrefix(prefix)
            }
            guard !matches.isEmpty else {
                throw ControlErrorBody(
                    .notFound, "\(handle) has no tab whose id starts with \(prefix)",
                    hint: "quickterm get -t \(handle) --json | jq '.data.pane.tabList'")
            }
            guard matches.count == 1 else {
                throw ControlErrorBody(
                    .ambiguousTarget, "--tab #\(prefix) matches \(matches.count) tabs in \(handle)",
                    hint: "Write out a few more digits of the id.",
                    candidates: matches.map { "#\(pane.tabs[$0].id.uuidString.prefix(8))" })
            }
            return matches[0]
        }
    }

    func tabRef(_ ctx: ControlContext) throws -> ControlTabRef {
        try ControlTabRef.parse(ctx.string("tab") ?? "")
    }

    /// Whether the real URL / title may be written into the diff. **The change envelope goes back
    /// to the caller verbatim**, so this has to use the same redaction rule as `state`; hard-coding
    /// it on the grounds that "it is only a log" is a channel around redaction
    func browserVisible(_ ctx: ControlContext, _ text: String?) -> String {
        guard ctx.encoder.exposesBrowser else { return ControlStateEncoder.redacted }
        let value = text ?? ""
        return value.isEmpty ? "—" : value
    }

    // MARK: open (a new tab)

    private func browserOpen(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        let raw = ctx.string("url") ?? BrowserPaneView.settings.home
        guard let url = ControlPaneFactory.resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "Could not resolve \(raw) to a URL")
        }
        let activate = try ctx.onOff("activate") ?? true
        let before = browser.tabs.count
        guard before < ControlBrowserLimits.maxTabs else {
            // `limit`, not `denied`: a structural cap, not a policy and not a person. An agent
            // that sees this has to close a tab, not ask the user to allow anything.
            throw ControlErrorBody(
                .limit, "\(handleName(hit.pane)) already holds \(before) tabs (limit \(ControlBrowserLimits.maxTabs))",
                hint: "Close a few first: quickterm browser close -t \(handleName(hit.pane)) --others")
        }
        let base = path(hit.controller, hit.workspace, hit.pane)

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("\(base).tabs", from: ControlChange.count(before, "tab"),
                                    to: ControlChange.count(before + 1, "tab"))],
            controllers: [hit.controller],
            // The layout did not move, and putting a fake "close that tab" step on the undo stack
            // would only make things murkier.
            undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.addTab(url: url, activate: activate)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: goto (absolute assignment: if it is already there, do nothing)

    private func browserGoto(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        guard let raw = ctx.string("url") else {
            throw ControlErrorBody(.badRequest, "browser goto needs --url")
        }
        guard let url = ControlPaneFactory.resolveURL(raw) else {
            throw ControlErrorBody(.badRequest, "Could not resolve \(raw) to a URL")
        }
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let tab = browser.tabs[index]
        let base = "\(path(hit.controller, hit.workspace, hit.pane)).tab\(index + 1)"

        // Already on this URL = a no-op (`--fail-if-noop` exits 7). To force a refetch, use
        // browser reload - "assign a value" and "reload" are two different intents, and once they
        // are fused into one command an unintended replay wipes out a half-filled form.
        //
        // **But this idempotency only holds for callers that can read the URL.** For those that
        // cannot (no token / expose-browser=never), "did it change" is itself an answer - a
        // `--dry-run --fail-if-noop` goto could ask "is this tab currently sitting on <some URL>",
        // while the same caller reading `state` gets `<redacted>`. `SpecApplier.identityMatches`
        // closes exactly this channel ("rebuild rather than let 'did it match' become a probe for
        // guessing URLs"). So callers like that always count as a change: load unconditionally,
        // `changed` is always true, and nothing about the current URL is carried out.
        var changes: [ControlChange] = []
        //
        // What gets compared is the two URLs **after normalization**
        // (`ControlPaneFactory.sameURL`): what WebKit settles on is `http://localhost:3000/`, and
        // nobody writes it that way. Compared literally, this command would forever report
        // "changed" for the most common spelling - the absolute-assignment promise is void on the
        // spot and the page is reloaded for nothing.
        if !ctx.encoder.exposesBrowser
            || !ControlPaneFactory.sameURL(tab.effectiveURL, url) {
            changes.append(ControlChange(
                "\(base).url",
                from: browserVisible(ctx, tab.effectiveURL?.absoluteString),
                to: browserVisible(ctx, url.absoluteString),
                sensitive: true))
        }
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller], undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.load(url, in: tab)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: reload

    private func browserReload(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let tab = browser.tabs[index]
        let hard = ctx.flag("hard")
        let base = "\(path(hit.controller, hit.workspace, hit.pane)).tab\(index + 1)"

        // A reload **always has something to do** (that is its entire point): `changes` is never
        // empty, so `--fail-if-noop` never fires for it, and `--dry-run` honestly says which tab
        // would be reloaded.
        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer,
            changes: [ControlChange("\(base).load",
                                    from: browserVisible(ctx, tab.effectiveURL?.absoluteString),
                                    to: hard ? "reload (bypassing the cache)" : "reload",
                                    sensitive: true)],
            controllers: [hit.controller], undoCommand: nil, target: base)
        var payload = try commit(mutation) {
            browser.reload(tab, fromOrigin: hard)
        }
        payload.pane = paneInfo(hit, encoder: ctx.encoder)
        return (hit.echo, payload)
    }

    // MARK: close (destructive: the last tab takes the pane with it)

    private func browserClose(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let (hit, browser) = try requireBrowser(ctx)
        try verifyPinned(ctx, controller: hit.controller, pane: hit.pane)
        let handle = handleName(hit.pane)
        let index = try resolveTab(try tabRef(ctx), in: browser, handle: handle)
        let others = ctx.flag("others")
        let force = ctx.flag(ControlCommandTable.Flag.force)
        let count = browser.tabs.count
        let panePath = path(hit.controller, hit.workspace, hit.pane)

        // Closing down to the last tab **closes the whole pane with it** (= Cmd+W semantics,
        // see the file header). `--others` always leaves one tab behind, so it can never end up on
        // the close-the-pane path by itself.
        let closesPane = !others && count == 1
        var changes: [ControlChange] = []
        if others {
            for (i, tab) in browser.tabs.enumerated() where i != index {
                changes.append(ControlChange("\(panePath).tab\(i + 1)",
                                             from: browserVisible(ctx, tab.displayTitle), to: "closed",
                                             sensitive: true))
            }
        } else {
            changes.append(ControlChange(
                closesPane ? panePath : "\(panePath).tab\(index + 1)",
                from: browserVisible(ctx, browser.tabs[index].displayTitle),
                to: closesPane ? "closed (last tab: the whole pane goes with it)" : "closed",
                sensitive: true))
        }

        // **Refuse before recording anything.** `BrowserPaneView.closeTab` returns false for a tab
        // whose web view WebKit currently holds in element fullscreen: tearing that view out would
        // leave the user staring at an empty fullscreen window. In the app that refusal is invisible
        // and correct - a keystroke that does nothing. Over the socket it must not be: swallowing it
        // here would report `applied: true` and a "closed" change for a tab that is still open, which
        // is the one answer a caller cannot recover from. Check every tab this command would destroy.
        let doomed = others ? browser.tabs.indices.filter { $0 != index }
                            : (closesPane ? Array(browser.tabs.indices) : [index])
        if let held = doomed.first(where: { browser.webKitHoldsFullscreen(browser.tabs[$0]) }) {
            throw ControlErrorBody(
                .busy,
                "\(handle) tab \(held + 1) is in element fullscreen, so WebKit owns its web view; "
                    + "nothing was closed",
                hint: "Leave fullscreen first (Esc in the page, or the video's own control), then run it again.")
        }

        let mutation = ControlMutationRequest(
            command: ctx.spec.name, request: ctx.request, peer: ctx.peer, changes: changes,
            controllers: [hit.controller],
            // A closed page cannot be put back (both the process and the session are gone), and
            // registering an undo would only manufacture an illusion.
            undoCommand: nil, target: panePath)

        var stillOpen = false
        var payload = try commit(mutation) {
            if others {
                // **Close back to front**: going front to back, every close shifts the indices
                // after it down by one.
                for i in stride(from: browser.tabs.count - 1, through: 0, by: -1) where i != index {
                    browser.closeTab(at: i)
                }
            } else if closesPane {
                if hit.workspace == hit.controller.model.activeIndex {
                    hit.controller.closePane(hit.pane, confirmIfNeeded: !force, animated: false)
                } else {
                    hit.controller.removeFromAnyWorkspace(hit.pane)
                }
                hit.controller.flushPendingCloses()
                stillOpen = hit.controller.model.allPanes.contains { $0 === hit.pane }
            } else {
                browser.closeTab(at: index)
            }
        }
        // The close-the-pane path can run into the "processes are still running" confirmation:
        // **decide from the facts**, do not guess (same as pane close).
        if payload.applied, closesPane, stillOpen {
            payload.confirmPending = true
            payload.applied = false
            payload.note = "QuickTerm put up a confirmation prompt, so the pane is not closed yet; --force skips it."
        }
        if payload.applied, closesPane, !stillOpen {
            payload.note = "That was the last tab, so the whole pane closed with it (same as ⌘W)."
        }
        // Only return the pane record while the pane is still there (it was not closed, only a tab
        // was, or this was a dry run): encoding it after the close would report something that no
        // longer exists.
        if hit.controller.model.allPanes.contains(where: { $0 === hit.pane }) {
            payload.pane = paneInfo(hit, encoder: ctx.encoder)
        }
        payload.workspace = ctx.encoder.workspaceInfo(hit.controller, index: hit.workspace)
        return (ResolvedTarget(screen: hit.controller.screenIndex + 1,
                               screenID: hit.controller.windowID.uuidString,
                               workspace: hit.workspace + 1,
                               pane: handle, paneID: hit.pane.id.uuidString), payload)
    }
}

/// The ceiling at the tab level. The ceiling is itself the policy: without it a runaway agent can
/// open several hundred WKWebViews inside one pane (each one its own WebContent process), and the
/// machine finds out about it before the user does
enum ControlBrowserLimits {
    static let maxTabs = 50
}
