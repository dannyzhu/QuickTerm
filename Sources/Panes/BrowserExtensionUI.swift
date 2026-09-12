import AppKit
import WebKit

/// The extension toolbar to the right of the address bar: one button per extension that is pinned to
/// the toolbar, enabled, and has an action for the current tab, with a puzzle-piece menu at the end.
/// Unpinned extensions (Chrome's semantics) show up only in the puzzle menu, so importing a few dozen
/// extensions from Chrome does not squeeze the address bar out of existence.
///
/// Laid out by hand: the pane is hosted by SwiftUI and has no external width constraint, so any width
/// constraint inside the pane at priority >= 500 feeds back and stretches the pane to the toolbar's
/// width (see porting-notes). This view only publishes an intrinsicContentSize (a non-required
/// priority) and computes its own buttons' frames inside layout().
final class BrowserExtensionToolbar: NSView {
    /// Button side length, and the step between adjacent buttons (step = side length + gap).
    static let buttonSize: CGFloat = 22
    static let step: CGFloat = 24

    weak var pane: BrowserPaneView?
    private var actionButtons: [BrowserExtensionActionButton] = []
    private let menuButton = NSButton()
    private var foreground: NSColor = .white

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        menuButton.bezelStyle = .accessoryBarAction
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(systemSymbolName: "puzzlepiece.extension",
                                   accessibilityDescription: L("browser.extension.toolbar"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        menuButton.toolTip = L("browser.extension.toolbar-tooltip")
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        addSubview(menuButton)
        for name in [Notification.Name.browserExtensionsDidChange, .browserExtensionActionDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                                   name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func extensionsDidChange() {
        reload()
    }

    func applyTheme(foreground: NSColor) {
        self.foreground = foreground
        menuButton.contentTintColor = foreground.withAlphaComponent(0.8)
        for button in actionButtons { button.badgeForeground = foreground }
        needsDisplay = true
    }

    // MARK: - Content

    private var manager: BrowserExtensionManager { .current }

    /// Extension actions that should be shown for the current tab (pinned to the toolbar + enabled +
    /// has an action for that tab).
    private func visibleActions(for tab: BrowserPaneView.Tab?)
        -> [(item: BrowserExtensionManager.Installed, action: WKWebExtension.Action)] {
        guard manager.isEnabled else { return [] }
        return manager.installed.compactMap { item in
            guard item.enabled, item.pinned, item.context.isLoaded,
                  let action = item.context.action(for: tab) else { return nil }
            return (item, action)
        }
    }

    /// Rebuild the buttons for the current tab.
    func reload() {
        let entries = visibleActions(for: pane?.activeTab)
        while actionButtons.count > entries.count {
            actionButtons.removeLast().removeFromSuperview()
        }
        while actionButtons.count < entries.count {
            let button = BrowserExtensionActionButton()
            button.badgeForeground = foreground
            button.target = self
            button.action = #selector(performExtensionAction(_:))
            addSubview(button)
            actionButtons.append(button)
        }
        for (button, entry) in zip(actionButtons, entries) {
            button.configure(item: entry.item, action: entry.action)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        reloadCountForTesting += 1
    }

    /// For tests: how many times `reload()` has run. It must re-read after navigation; see the `\.url`
    /// observation in BrowserPaneView.
    private(set) var reloadCountForTesting = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(actionButtons.count + 1) * Self.step, height: Self.buttonSize)
    }

    /// When squeezed below the intrinsic width (the address bar's 200pt floor squeezes the toolbar),
    /// place only as many buttons as fit, left to right, and hide the rest: they can still be invoked
    /// from the puzzle menu. The puzzle button is always rightmost and always visible.
    func fittingActionButtonCount(width: CGFloat) -> Int {
        let room = width - Self.buttonSize
        guard room > 0 else { return 0 }
        return min(actionButtons.count, max(0, Int((room / Self.step).rounded(.down))))
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.buttonSize) / 2
        let shown = fittingActionButtonCount(width: bounds.width)
        for (i, button) in actionButtons.enumerated() {
            button.isHidden = i >= shown
            button.frame = NSRect(x: CGFloat(i) * Self.step, y: y,
                                  width: Self.buttonSize, height: Self.buttonSize)
        }
        // When everything fits, the puzzle sits right after the buttons (the old behavior); once any
        // button is hidden, the puzzle hugs the right edge. That matches Chrome, and it means dragging
        // the pane's edge moves the puzzle along with it instead of leaving a 0-23pt gap behind and
        // then jumping a whole slot at a time.
        let menuX = shown < actionButtons.count
            ? max(0, bounds.width - Self.buttonSize)
            : CGFloat(shown) * Self.step
        menuButton.frame = NSRect(x: menuX, y: y, width: Self.buttonSize, height: Self.buttonSize)
    }

    /// Anchor for the popover: this extension's **visible** button, falling back to the puzzle button.
    /// Anchoring to a hidden button would attach the popover to a zero-sized frame.
    func anchorButton(for context: WKWebExtensionContext) -> NSButton {
        actionButtons.first { $0.item?.context === context && !$0.isHidden } ?? menuButton
    }

    /// For tests.
    var actionButtonsForTesting: [NSButton] { actionButtons }
    var menuButtonForTesting: NSButton { menuButton }

    // MARK: - Actions

    @objc private func performExtensionAction(_ sender: BrowserExtensionActionButton) {
        guard let item = sender.item else { return }
        perform(item)
    }

    /// Invoke an extension action. Everything cached is recomputed at the moment of the click:
    /// the current tab (tabs may have been opened, closed or switched since the button was built), the
    /// action object (WebKit hands out a different action per tab), and which window the extension
    /// thinks is current (`tabs.query({currentWindow:true})` reads a cached value, and clicking a
    /// button does not change the first responder, so without announcing it the message would be
    /// delivered to a different pane).
    private func perform(_ item: BrowserExtensionManager.Installed) {
        pane?.makeCurrentForExtensions()
        let tab = pane?.activeTab
        guard item.enabled, item.context.isLoaded,
              let action = item.context.action(for: tab), action.isEnabled else { return }
        manager.performAction(of: item, tab: tab)
        // The action may have changed the badge or the icon. Rebuild on the next turn of the run loop:
        // reload() pulls the button out of the view hierarchy, which must not happen inside that
        // button's own action dispatch.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// The puzzle menu; also where the web-extensions WM action lands.
    @objc func showMenu() {
        let menu = buildMenu()
        let point = NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: menuButton)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if !manager.isEnabled {
            let off = NSMenuItem(title: L("browser.extension.menu.turned-off"), action: nil, keyEquivalent: "")
            off.isEnabled = false
            menu.addItem(off)
            menu.addItem(.separator())
        } else if manager.installed.isEmpty {
            let empty = NSMenuItem(title: L("browser.extension.menu.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
        } else {
            for item in manager.installed {
                let title = item.enabled
                    ? item.displayName
                    : L("browser.extension.menu.disabled-suffix", item.displayName)
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.submenu = submenu(for: item)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }
        menu.addItem(command(title: L("browser.extension.menu.import-from-chrome"),
                             selector: #selector(importFromChrome)))
        menu.addItem(command(title: L("browser.extension.menu.open-web-store"),
                             selector: #selector(openWebStore)))
        menu.addItem(command(title: L("browser.extension.menu.open-folder"),
                             selector: #selector(openStoreFolder)))
        return menu
    }

    private func submenu(for item: BrowserExtensionManager.Installed) -> NSMenu {
        let menu = NSMenu()
        // "Open" is the equivalent of clicking the extension's toolbar button: whether it is unpinned,
        // or pinned but squeezed out of the toolbar, it can still be invoked from here.
        if item.enabled, item.context.isLoaded, item.context.action(for: pane?.activeTab) != nil {
            menu.addItem(command(title: L("browser.extension.menu.open"),
                                 selector: #selector(performActionFromMenu(_:)), represented: item))
        }
        let pin = command(title: L("browser.extension.menu.pin"),
                          selector: #selector(togglePinned(_:)), represented: item)
        pin.state = item.pinned ? .on : .off
        menu.addItem(pin)
        let enable = command(title: L("browser.extension.menu.enable"),
                             selector: #selector(toggleEnabled(_:)), represented: item)
        enable.state = item.enabled ? .on : .off
        menu.addItem(enable)
        if item.hasOptionsPage {
            menu.addItem(command(title: L("browser.extension.menu.options"),
                                 selector: #selector(openOptions(_:)), represented: item))
        }
        menu.addItem(.separator())
        menu.addItem(command(title: L("browser.extension.menu.remove"),
                             selector: #selector(removeExtension(_:)), represented: item))
        return menu
    }

    private func command(title: String, selector: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    @objc private func performActionFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserExtensionManager.Installed else { return }
        perform(item)
    }

    @objc private func togglePinned(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserExtensionManager.Installed else { return }
        manager.setPinned(!item.pinned, for: item)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserExtensionManager.Installed else { return }
        manager.setEnabled(!item.enabled, for: item)
    }

    @objc private func openOptions(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserExtensionManager.Installed else { return }
        manager.openOptions(for: item)
    }

    @objc private func removeExtension(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BrowserExtensionManager.Installed else { return }
        let alert = NSAlert()
        alert.messageText = L("browser.extension.remove.title", item.displayName)
        alert.informativeText = L("browser.extension.remove.body")
        alert.addButton(withTitle: L("browser.extension.remove.confirm"))
        alert.addButton(withTitle: L("browser.button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.remove(item)
    }

    @objc private func importFromChrome() {
        Task { @MainActor in
            let result = await manager.importFromChrome()
            let alert = NSAlert()
            alert.messageText = L("browser.extension.import.title")
            var lines = [L("browser.extension.import.summary", result.imported, result.skipped)]
            if !result.failed.isEmpty {
                lines.append(L("browser.extension.import.failed", result.failed.count,
                               result.failed.joined(separator: ", ")))
            }
            if result.imported == 0, result.skipped == 0, result.failed.isEmpty {
                lines = [L("browser.extension.import.none")]
            }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: L("browser.button.ok"))
            alert.runModal()
        }
    }

    @objc private func openWebStore() {
        guard let url = URL(string: "https://chromewebstore.google.com/") else { return }
        if let pane { pane.addTab(url: url, activate: true) } else { NSWorkspace.shared.open(url) }
    }

    @objc private func openStoreFolder() {
        try? FileManager.default.createDirectory(at: manager.storeDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(manager.storeDirectory)
    }
}

/// One extension action button: the icon plus a badge in the top-right corner.
final class BrowserExtensionActionButton: NSButton {
    private(set) var item: BrowserExtensionManager.Installed?
    private var badge = ""
    var badgeForeground: NSColor = .white

    init() {
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(item: BrowserExtensionManager.Installed, action: WKWebExtension.Action) {
        self.item = item
        image = action.icon(for: NSSize(width: 16, height: 16))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: item.displayName)
        toolTip = action.label.isEmpty ? item.displayName : action.label
        // The button always stays clickable: NSButton's isEnabled = false swallows clicks **silently**,
        // and the enabled state here is only a snapshot from the last reload, which the extension can
        // change at any time. Being disabled only dims it; whether the action can actually run is
        // decided at the moment of the click.
        isEnabled = true
        alphaValue = action.isEnabled ? 1 : 0.45
        badge = action.badgeText
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !badge.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = badge as NSString
        let size = text.size(withAttributes: attributes)
        let width = max(size.width + 4, 11)
        let rect = NSRect(x: bounds.maxX - width, y: bounds.maxY - 11, width: width, height: 11)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5).fill()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                  withAttributes: attributes)
    }
}

/// The "Add to QuickTerm" button injected into a Chrome Web Store detail page, plus the handler for
/// the messages it posts back.
enum BrowserExtensionWebStore {
    /// Name of the page-to-native message channel.
    static let messageHandlerName = "quicktermExtension"

    /// The injected script and the message channel both live in a private content world, so the page's
    /// own JS cannot reach `window.webkit.messageHandlers.quicktermExtension`. Otherwise any page at
    /// all could raise the install prompt.
    static let contentWorld = WKContentWorld.world(name: "QuickTermExtensionInstall")

    /// The Web Store's two hostnames; only detail pages on these can trigger an install.
    static let storeHosts = ["chromewebstore.google.com", "chrome.google.com"]

    /// Built on every read: the button's labels come from the app catalog, so the injected
    /// button follows the language QuickTerm is drawn in rather than the page's navigator.language.
    static var userScript: WKUserScript {
        WKUserScript(source: script(label: L("browser.webstore.add"),
                                    installing: L("browser.webstore.installing")),
                     injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld)
    }

    /// A Swift string as a single-quoted JavaScript literal.
    private static func javaScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'" + escaped + "'"
    }

    /// Whether a message posted back by the page may trigger an install: it has to come from the main
    /// frame of a Web Store detail page, and its id has to match that detail page's id.
    /// Kept a pure function so it is easy to unit-test; pass `WKScriptMessage.frameInfo.request.url`
    /// as `frameURL`.
    nonisolated static func acceptedInstallID(body: Any, isMainFrame: Bool,
                                              frameURL: URL?, originHost: String?) -> String? {
        guard isMainFrame,
              let body = body as? [String: Any], let id = body["id"] as? String,
              let frameURL, BrowserExtensionManager.extensionID(fromWebStoreURL: frameURL) == id
        else { return nil }
        // securityOrigin is the real origin of the script that posted the message: iframes,
        // about:blank and sandboxed pages are all rejected.
        if let originHost, !storeHosts.contains(originHost.lowercased()) { return nil }
        return id
    }

    /// The injected script: it puts "Add to QuickTerm" next to the store's own "Add to Chrome" button,
    /// which the store greys out for non-Chrome browsers. The store is an SPA and renders that button
    /// from JS some time later, so the injected button starts pinned to the bottom-right corner as a
    /// fallback and a MutationObserver moves it next to the store button once that appears.
    /// In-site navigation between detail pages does not re-inject, so the id is re-read from
    /// `location` at click time, and the button hides itself whenever this is not a detail page.
    private static func script(label: String, installing: String) -> String {
        """
        (function () {
          if (\(storeHosts.map { "location.hostname !== '\($0)'" }.joined(separator: " && "))) return;
          if (document.getElementById('quickterm-install-button')) return;
          var label = \(javaScriptLiteral(label));
          var installing = \(javaScriptLiteral(installing));
          var storeButtonText = /^(添加至 Chrome|添加到 Chrome|Add to Chrome|加入 Chrome|安裝到 Chrome)$/i;
          function currentID() {
            if (!location.pathname.includes('/detail/')) return null;
            var m = location.pathname.match(/([a-p]{32})/);
            return m ? m[1] : null;
          }
          var button = document.createElement('button');
          button.id = 'quickterm-install-button';
          button.type = 'button';
          button.textContent = label;
          var base = 'z-index:2147483647;padding:10px 20px;border:0;border-radius:20px;background:#1a73e8;color:#fff;' +
            'font:500 14px -apple-system,system-ui,sans-serif;cursor:pointer;white-space:nowrap;';
          function styleFloating() {
            button.style.cssText = base + 'position:fixed;right:20px;bottom:20px;box-shadow:0 2px 10px rgba(0,0,0,.35);';
          }
          function styleInline() {
            button.style.cssText = base + 'position:static;margin-left:12px;vertical-align:middle;';
          }
          function storeButton() {
            var buttons = document.querySelectorAll('button');
            for (var i = 0; i < buttons.length; i++) {
              if (buttons[i] === button) continue;
              if (storeButtonText.test((buttons[i].textContent || '').trim())) return buttons[i];
            }
            return null;
          }
          function place() {
            var id = currentID();
            button.hidden = !id;
            if (!id) return;
            var anchor = storeButton();
            if (anchor && anchor.parentNode) {
              if (button.previousElementSibling !== anchor) {
                anchor.insertAdjacentElement('afterend', button);
                styleInline();
              }
            } else if (button.parentNode !== document.body) {
              document.body.appendChild(button);
              styleFloating();
            }
          }
          button.addEventListener('click', function () {
            var id = currentID();
            if (!id) return;
            try {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage({ id: id });
              button.textContent = installing;
            } catch (e) {}
          });
          styleFloating();
          document.body.appendChild(button);
          place();
          // The observer callback only touches the DOM when it has to (place() guards itself):
          // mutating the DOM unconditionally from the callback re-triggers the observer and the
          // resulting endless microtask loop wedges the page's JS thread. The store's DOM churns
          // constantly, so coalesce with setTimeout - not requestAnimationFrame, which never fires
          // in a background tab or an unrendered WebView.
          var scheduled = false;
          var observer = new MutationObserver(function () {
            if (scheduled) return;
            scheduled = true;
            setTimeout(function () {
              scheduled = false;
              if (!button.isConnected) { document.body.appendChild(button); styleFloating(); }
              place();
            }, 50);
          });
          observer.observe(document.documentElement, { childList: true, subtree: true });
          window.addEventListener('popstate', place);
        })();
        """
    }
}

/// Weak-reference proxy: WKUserContentController retains its message handlers strongly, so registering
/// the pane itself would create a cycle.
final class BrowserExtensionScriptHandler: NSObject, WKScriptMessageHandler {
    weak var pane: BrowserPaneView?

    init(pane: BrowserPaneView) { self.pane = pane }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard let id = BrowserExtensionWebStore.acceptedInstallID(body: message.body,
                                                                 isMainFrame: frame.isMainFrame,
                                                                 frameURL: frame.request.url,
                                                                 originHost: frame.securityOrigin.host)
        else { return }
        pane?.beginWebStoreInstall(id: id)
    }
}
