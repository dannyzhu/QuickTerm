import AppKit
import WebKit

/// 地址栏右侧的扩展工具条：每个启用且对当前标签有动作的扩展一个按钮，末尾一个拼图菜单。
///
/// 手工布局：pane 由 SwiftUI 托管、没有外部宽度约束，pane 内部任何**必需**的宽度约束都会反过来
/// 把 pane 撑成工具条的宽度（见 porting-notes）。这里只对外报 intrinsicContentSize（非必需优先级），
/// 内部按钮的帧在 layout() 里自己算。
final class BrowserExtensionToolbar: NSView {
    /// 按钮边长与相邻按钮的步进（步进 = 边长 + 间隙）
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
                                   accessibilityDescription: "扩展")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        menuButton.toolTip = "扩展（⌘⇧E）"
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

    // MARK: - 内容

    private var manager: BrowserExtensionManager { .current }

    /// 当前标签下应该显示的扩展动作（启用 + 对该标签有动作）
    private func visibleActions(for tab: BrowserPaneView.Tab?)
        -> [(item: BrowserExtensionManager.Installed, action: WKWebExtension.Action)] {
        guard manager.isEnabled else { return [] }
        return manager.installed.compactMap { item in
            guard item.enabled, item.context.isLoaded,
                  let action = item.context.action(for: tab) else { return nil }
            return (item, action)
        }
    }

    /// 按当前标签重建按钮
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
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(actionButtons.count + 1) * Self.step, height: Self.buttonSize)
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.buttonSize) / 2
        for (i, button) in actionButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(i) * Self.step, y: y,
                                  width: Self.buttonSize, height: Self.buttonSize)
        }
        menuButton.frame = NSRect(x: CGFloat(actionButtons.count) * Self.step, y: y,
                                  width: Self.buttonSize, height: Self.buttonSize)
    }

    /// 弹出层的锚点：该扩展的按钮，没有就用拼图按钮
    func anchorButton(for context: WKWebExtensionContext) -> NSButton {
        actionButtons.first { $0.item?.context === context } ?? menuButton
    }

    /// 测试用
    var actionButtonsForTesting: [NSButton] { actionButtons }
    var menuButtonForTesting: NSButton { menuButton }

    // MARK: - 动作

    @objc private func performExtensionAction(_ sender: BrowserExtensionActionButton) {
        guard let item = sender.item else { return }
        item.context.performAction(for: pane?.activeTab)
    }

    /// 拼图菜单（也是 WM 动作 web-extensions 的落点）
    @objc func showMenu() {
        let menu = buildMenu()
        let point = NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: menuButton)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if !manager.isEnabled {
            let off = NSMenuItem(title: "扩展已在配置里关闭（browser-extensions = false）", action: nil, keyEquivalent: "")
            off.isEnabled = false
            menu.addItem(off)
            menu.addItem(.separator())
        } else if manager.installed.isEmpty {
            let empty = NSMenuItem(title: "没有已安装的扩展", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
        } else {
            for item in manager.installed {
                let entry = NSMenuItem(title: item.displayName, action: nil, keyEquivalent: "")
                entry.state = item.enabled ? .on : .off
                entry.submenu = submenu(for: item)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }
        menu.addItem(command(title: "从 Chrome 导入已安装扩展…", selector: #selector(importFromChrome)))
        menu.addItem(command(title: "打开 Chrome Web Store", selector: #selector(openWebStore)))
        menu.addItem(command(title: "打开扩展文件夹", selector: #selector(openStoreFolder)))
        return menu
    }

    private func submenu(for item: BrowserExtensionManager.Installed) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command(title: item.enabled ? "停用" : "启用",
                             selector: #selector(toggleEnabled(_:)), represented: item))
        if item.hasOptionsPage {
            menu.addItem(command(title: "选项…", selector: #selector(openOptions(_:)), represented: item))
        }
        menu.addItem(.separator())
        menu.addItem(command(title: "移除…", selector: #selector(removeExtension(_:)), represented: item))
        return menu
    }

    private func command(title: String, selector: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
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
        alert.messageText = "移除扩展「\(item.displayName)」？"
        alert.informativeText = "扩展文件会从 QuickTerm 的扩展文件夹里删除。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.remove(item)
    }

    @objc private func importFromChrome() {
        Task { @MainActor in
            let result = await manager.importFromChrome()
            let alert = NSAlert()
            alert.messageText = "从 Chrome 导入完成"
            var lines = ["导入 \(result.imported) 个，跳过 \(result.skipped) 个（已安装 / 主题 / 应用）。"]
            if !result.failed.isEmpty { lines.append("失败 \(result.failed.count) 个：\(result.failed.joined(separator: "、"))") }
            if result.imported == 0, result.skipped == 0, result.failed.isEmpty {
                lines = ["没有在本机 Chrome 的默认配置目录里找到可导入的扩展。"]
            }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "好")
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

/// 一个扩展动作按钮：图标 + 右上角 badge
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
        isEnabled = action.isEnabled
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

/// Chrome Web Store 详情页注入的「添加到 QuickTerm」按钮，以及它回传消息用的处理器。
enum BrowserExtensionWebStore {
    /// 页面 → 原生的消息通道名
    static let messageHandlerName = "quicktermExtension"

    /// 注入脚本与消息通道都待在私有世界里：页面自己的 JS 拿不到
    /// `window.webkit.messageHandlers.quicktermExtension`（否则任意页面都能拉起安装弹窗）
    static let contentWorld = WKContentWorld.world(name: "QuickTermExtensionInstall")

    /// Web Store 的两个域名（只有它们的详情页能触发安装）
    static let storeHosts = ["chromewebstore.google.com", "chrome.google.com"]

    static let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                         forMainFrameOnly: true, in: contentWorld)

    /// 页面回传的消息能不能触发安装：必须是 Web Store 详情页的主框架，且 id 与该详情页的 id 一致。
    /// （纯函数，便于单测；`frameURL` 传 `WKScriptMessage.frameInfo.request.url`）
    nonisolated static func acceptedInstallID(body: Any, isMainFrame: Bool,
                                              frameURL: URL?, originHost: String?) -> String? {
        guard isMainFrame,
              let body = body as? [String: Any], let id = body["id"] as? String,
              let frameURL, BrowserExtensionManager.extensionID(fromWebStoreURL: frameURL) == id
        else { return nil }
        // securityOrigin 是发消息那段脚本的真实来源：iframe / about:blank / 沙盒页一律挡掉
        if let originHost, !storeHosts.contains(originHost.lowercased()) { return nil }
        return id
    }

    /// 注入脚本：把「添加到 QuickTerm」放在商店自己那颗（对非 Chrome 浏览器灰掉的）「添加至 Chrome」按钮旁边；
    /// 商店是 SPA、按钮由 JS 晚些渲染，所以先放右下角兜底，MutationObserver 等到商店按钮出现再挪过去；
    /// 详情页之间的站内跳转不会重新注入，id 在点击时从 location 重新取，不在详情页时把按钮藏起来
    private static let script = """
    (function () {
      if (\(storeHosts.map { "location.hostname !== '\($0)'" }.joined(separator: " && "))) return;
      if (document.getElementById('quickterm-install-button')) return;
      var zh = (navigator.language || '').toLowerCase().indexOf('zh') === 0;
      var label = zh ? '添加到 QuickTerm' : 'Add to QuickTerm';
      var installing = zh ? '正在安装…' : 'Installing…';
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
      // 观察回调里只做"必要时才动 DOM"的事（place 自带守卫）：回调里无条件改 DOM 会再次触发观察者，
      // 微任务死循环把页面 JS 线程卡死。商店 DOM 变动很频繁，用 setTimeout 合并
      // （不用 requestAnimationFrame：后台标签 / 未渲染的 WebView 里 rAF 不触发）
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

/// 弱引用代理：WKUserContentController 会强引用消息处理器，直接注册 pane 会成环
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
