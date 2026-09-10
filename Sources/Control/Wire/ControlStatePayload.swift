import Foundation

/// `state` / `list` / `get` 的负载形状（`quickterm.state/1`）。
/// 扁平 pane 数组（wezterm 的形状：jq 与模型都好读）+ **只引用句柄**的工作区骨架，
/// 而不是把 pane 记录再重复一遍——一个六屏会话的 JSON 否则会把 agent 的上下文吃光。
struct ControlStatePayload: Codable, Equatable {
    var schema = "quickterm.state/1"
    var app: AppInfo
    var screens: [ScreenInfo]
    var panes: [PaneInfo]

    struct AppInfo: Codable, Equatable {
        var version: String
        var protocolVersion: Int
        var workspaceCount: Int
        var mode: String
        /// 本次请求是否带了有效的来源 token（决定浏览器 URL / 标题是否被打码）
        var trusted: Bool
    }

    struct ScreenInfo: Codable, Equatable {
        var index: Int
        var id: String
        var title: String
        var key: Bool
        var activeWorkspace: Int
        var visibleColumns: Int
        var fullscreen: Bool
        var joinAllSpaces: Bool
        var display: DisplayInfo?
        var frame: [Double]?
        var workspaces: [WorkspaceInfo]
    }

    struct DisplayInfo: Codable, Equatable {
        var uuid: String?
        var name: String?
    }

    struct WorkspaceInfo: Codable, Equatable {
        var index: Int
        var layout: String
        var empty: Bool
        var active: Bool
        /// 该工作区的 pane 句柄（顺序 = 布局顺序）
        var panes: [String]
        var zoom: String?
        /// scrolling：列 → 宽度因子 + 列内句柄
        var columns: [ColumnInfo]?
        /// dwindle：每个 pane 的树路径（`a`/`b` 串）
        var tree: [TreeLeafInfo]?
        var floating: [String]
    }

    struct ColumnInfo: Codable, Equatable {
        var width: Double
        var panes: [String]
    }

    struct TreeLeafInfo: Codable, Equatable {
        var pane: String
        var path: String
    }

    struct PaneInfo: Codable, Equatable {
        var handle: String
        var id: String
        var kind: String
        var role: String?
        var screen: Int
        var workspace: Int
        var at: Position?
        var title: String?
        var cwd: String?
        var url: String?
        var tabs: Int?
        var focused: Bool
        var busy: Bool
        var float: Bool
        var zoom: Bool
        /// 浏览器 pane 的 title / url 是否被打码（无 token 的调用方一律打码）
        var redacted: Bool?

        struct Position: Codable, Equatable {
            var column: Int?
            var row: Int?
            var path: String?
        }

        /// `--fields handle,cwd,title` 的实现：投影成 JSON 对象（仍走 JSONEncoder）
        func projected(to fields: [String]) throws -> JSONValue {
            let data = try ControlJSON.encoder.encode(self)
            let value = try ControlJSON.decoder.decode(JSONValue.self, from: data)
            guard let object = value.objectValue else { return value }
            var out: [String: JSONValue] = [:]
            for field in fields {
                if let v = object[field] { out[field] = v }
            }
            // handle 永远保留，否则结果无法再被寻址
            if out["handle"] == nil, let h = object["handle"] { out["handle"] = h }
            return .object(out)
        }
    }
}

/// `list` 的负载（三种之一非空）
struct ControlListPayload: Codable, Equatable {
    var screens: [ControlStatePayload.ScreenInfo]?
    var workspaces: [ControlStatePayload.WorkspaceInfo]?
    var panes: [JSONValue]?
}

struct ControlPanePayload: Codable, Equatable {
    var pane: ControlStatePayload.PaneInfo
}

/// `action` 的负载
struct ControlActionPayload: Codable, Equatable {
    var action: String
    var cls: ControlCommandClass
    var applied: Bool
    /// close-pane 命中"仍有进程在运行"的确认框时为 true：这时 pane 还没关，等用户回答
    var confirmPending: Bool?
    /// 焦点交接是异步重试的（最长 0.75s）：命令返回时焦点可能还没真正落到 `resolved.pane` 上
    var focusPending: Bool?
    var panes: [ControlStatePayload.PaneInfo]?
}

struct ControlActionListPayload: Codable, Equatable {
    var actions: [ControlCommandTable.ActionDoc]
}

struct ControlVersionPayload: Codable, Equatable {
    var cli: String
    var app: String?
    var protocolVersion: Int
    var appProtocolVersion: Int?
    var socket: String?
    var running: Bool
}
