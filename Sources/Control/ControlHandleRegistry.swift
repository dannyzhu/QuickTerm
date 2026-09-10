import AppKit

/// 短句柄注册表：`t7` / `b3`（Zellij 的类型前缀 id）。
/// 进程内稳定、单调递增、**永不复用**——复用会让 agent 手里的旧句柄悄悄指向别的 pane。
/// UUID 仍然在每条 JSON 里，是跨重启唯一稳定的身份；短句柄是人和模型实际会打出来的那一个。
@MainActor
final class ControlHandleRegistry {
    static let shared = ControlHandleRegistry()

    private var handles: [UUID: String] = [:]
    private var owners: [String: UUID] = [:]
    /// 共享计数器（不是每种一个）：句柄在全进程唯一，`t1 t2 b3 t4` 也能看出创建次序
    private var counter = 0

    private init() {}

    static func prefix(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "t"
        case .browser: "b"
        }
    }

    /// 取（或首次分配）一个 pane 的句柄
    func handle(for pane: PaneView) -> String {
        if let existing = handles[pane.id] { return existing }
        counter += 1
        let handle = "\(Self.prefix(for: pane.kind))\(counter)"
        handles[pane.id] = handle
        owners[handle] = pane.id
        return handle
    }

    /// 已分配过的句柄（不分配新的）——编码"这个 pane 现在的句柄是什么"以外的场合用
    func existingHandle(for id: UUID) -> String? { handles[id] }

    func paneID(forHandle handle: String) -> UUID? { owners[handle.lowercased()] }

    /// 只给用例：清空并复位计数器
    func reset() {
        handles.removeAll()
        owners.removeAll()
        counter = 0
    }
}
