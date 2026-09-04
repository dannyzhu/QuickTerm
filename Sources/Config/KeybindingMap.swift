import AppKit

/// 组合键：规范化键名 + 修饰键集合（仅比较 cmd/alt/ctrl/shift 四位）。
struct KeyCombo: Hashable {
    let key: String              // "w" / "return" / "up" / "[" / "=" / "tab" …
    let modifiers: UInt          // NSEvent.ModifierFlags 与 relevantMask 交集的 rawValue

    static let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantMask).rawValue
    }
}

/// WM 级默认键位表（spec §5.1，已确认的两处偏移含在内）。
/// 不在表内的组合一律放行给终端 surface——绝不拦截 Cmd+C/V、字号键等。
struct KeybindingMap {
    private let map: [KeyCombo: WMAction]

    init(map: [KeyCombo: WMAction]) {
        self.map = map
    }

    /// 从默认表 + config 覆盖构建（spec §4.7 [keybinds]）。
    /// workspaceCount > 5 时追加 Cmd+6…9,0（及 Shift 变体）。
    init(workspaceCount: Int = 5,
         overrides: [WMAction: KeyCombo] = [:],
         unbound: Set<WMAction> = []) {
        var m = KeybindingMap.defaults
        if workspaceCount > 5 {
            let keys = ["6", "7", "8", "9", "0"]
            let gotos: [WMAction] = [.gotoWorkspace6, .gotoWorkspace7, .gotoWorkspace8,
                                     .gotoWorkspace9, .gotoWorkspace10]
            let moves: [WMAction] = [.moveToWorkspace6, .moveToWorkspace7, .moveToWorkspace8,
                                     .moveToWorkspace9, .moveToWorkspace10]
            for i in 0..<min(workspaceCount - 5, 5) {
                m[KeyCombo(key: keys[i], .command)] = gotos[i]
                m[KeyCombo(key: keys[i], [.command, .shift])] = moves[i]
            }
        }
        for (action, combo) in overrides {
            m = m.filter { $0.value != action }  // 一个动作只保留一个组合
            m[combo] = action
        }
        for action in unbound {
            m = m.filter { $0.value != action }
        }
        self.map = m
    }

    static let defaults: [KeyCombo: WMAction] = [
        KeyCombo(key: "return", .command): .newTerminal,
        KeyCombo(key: "b", [.command, .shift]): .fileManager,   // Omarchy Super+Shift+F；Cmd+F 已是 toggle-zoom
        KeyCombo(key: "b", .command): .newBrowser,              // Omarchy Super+B
        KeyCombo(key: "[", [.command, .shift]): .webBack,
        KeyCombo(key: "]", [.command, .shift]): .webForward,
        KeyCombo(key: "r", .command): .webReload,
        KeyCombo(key: "l", [.command, .shift]): .webFocusAddress,
        KeyCombo(key: "o", [.command, .shift]): .webOpenExternal,
        KeyCombo(key: "=", .command): .webZoomIn,
        KeyCombo(key: "-", .command): .webZoomOut,
        KeyCombo(key: "0", .command): .webZoomReset,
        KeyCombo(key: "w", .command): .closePane,
        KeyCombo(key: "left", .command): .focusLeft,
        KeyCombo(key: "right", .command): .focusRight,
        KeyCombo(key: "up", .command): .focusUp,
        KeyCombo(key: "down", .command): .focusDown,
        KeyCombo(key: "left", [.command, .shift]): .swapLeft,
        KeyCombo(key: "right", [.command, .shift]): .swapRight,
        KeyCombo(key: "up", [.command, .shift]): .swapUp,
        KeyCombo(key: "down", [.command, .shift]): .swapDown,
        KeyCombo(key: "j", .command): .toggleSplitDirection,
        KeyCombo(key: "f", .command): .toggleZoom,
        KeyCombo(key: "=", [.command, .control]): .equalize,
        KeyCombo(key: "left", [.command, .control]): .resizeLeft,
        KeyCombo(key: "right", [.command, .control]): .resizeRight,
        KeyCombo(key: "up", [.command, .control]): .resizeUp,
        KeyCombo(key: "down", [.command, .control]): .resizeDown,
        KeyCombo(key: "tab", .option): .cyclePaneNext,
        KeyCombo(key: "tab", [.option, .shift]): .cyclePanePrev,
        KeyCombo(key: "]", .command): .cyclePaneNext,
        KeyCombo(key: "[", .command): .cyclePanePrev,
        KeyCombo(key: "1", .command): .gotoWorkspace1,
        KeyCombo(key: "2", .command): .gotoWorkspace2,
        KeyCombo(key: "3", .command): .gotoWorkspace3,
        KeyCombo(key: "4", .command): .gotoWorkspace4,
        KeyCombo(key: "5", .command): .gotoWorkspace5,
        KeyCombo(key: "1", [.command, .shift]): .moveToWorkspace1,
        KeyCombo(key: "2", [.command, .shift]): .moveToWorkspace2,
        KeyCombo(key: "3", [.command, .shift]): .moveToWorkspace3,
        KeyCombo(key: "4", [.command, .shift]): .moveToWorkspace4,
        KeyCombo(key: "5", [.command, .shift]): .moveToWorkspace5,
        KeyCombo(key: "space", [.command, .shift]): .toggleBar,
        KeyCombo(key: "space", [.command, .control, .shift]): .themePicker,
        KeyCombo(key: "space", [.command, .control]): .backgroundMenu,
        KeyCombo(key: "backspace", .command): .toggleOpacity,
        KeyCombo(key: "backspace", [.command, .shift]): .toggleGaps,
        KeyCombo(key: "k", .command): .keybindingHelp,
        KeyCombo(key: "space", [.command, .option]): .mainMenu,
        KeyCombo(key: "s", .command): .scratchpad,
        KeyCombo(key: "f", [.command, .control]): .toggleFullscreen,
        KeyCombo(key: "l", .command): .toggleLayout,
        KeyCombo(key: ",", .command): .openSettings,
        KeyCombo(key: "escape", .command): .exitFullscreen,
        KeyCombo(key: "t", .command): .toggleFloat,
    ]

    /// 事件 → 动作。resize 系列附加 Shift = 10px 微调（precise）。
    func action(for event: NSEvent) -> (action: WMAction, precise: Bool)? {
        guard let key = KeybindingMap.normalizedKey(for: event) else { return nil }
        return action(key: key, modifiers: event.modifierFlags)
    }

    func action(key: String, modifiers: NSEvent.ModifierFlags) -> (action: WMAction, precise: Bool)? {
        if let hit = map[KeyCombo(key: key, modifiers)] {
            return (hit, false)
        }
        // resize 微调：去掉 shift 再查一次，命中 resize* 则 precise
        if modifiers.contains(.shift) {
            let withoutShift = modifiers.subtracting(.shift)
            if let hit = map[KeyCombo(key: key, withoutShift)],
               [.resizeLeft, .resizeRight, .resizeUp, .resizeDown].contains(hit) {
                return (hit, true)
            }
        }
        return nil
    }

    /// 键名速查（Cmd+K 面板数据源）：action → 显示用组合键描述
    func displayBindings() -> [(combo: String, action: WMAction)] {
        map.map { (Self.describe($0.key), $0.value) }
            .sorted { $0.1.rawValue < $1.1.rawValue }
    }

    private static func describe(_ combo: KeyCombo) -> String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let names = ["return": "↩", "tab": "⇥", "space": "␣",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        parts.append(names[combo.key] ?? combo.key.uppercased())
        return parts.joined()
    }

    /// NSEvent → 规范化键名（方向/回车/Tab 用 keyCode，其余用忽略修饰键的字符）
    static func normalizedKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "backspace"
        case 53: return "escape"
        default:
            // Cmd 组合里的 Shift 不能进键名：charactersIgnoringModifiers 对符号/数字键保留 Shift 转换
            // （Cmd+Shift+[ → "{"、Cmd+Shift+1 → "!"），而表里登记的是基础键。取无修饰字符；
            // 合成事件（无 CGEvent 背书）拿不到时退回 charactersIgnoringModifiers
            let base = event.characters(byApplyingModifiers: []).flatMap { $0.isEmpty ? nil : $0 }
                ?? event.charactersIgnoringModifiers
            guard let chars = base, !chars.isEmpty else { return nil }
            return chars.lowercased()
        }
    }
}
