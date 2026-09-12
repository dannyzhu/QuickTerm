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
        /// 这个槽位的名字（右键胶囊 / `workspace set --title` 起的；没起过就整条字段不出现）。
        /// **不打码**：与 pane 标题同一条——那是用户自己写的字，不是网页给的
        var title: String?
        var layout: String
        var empty: Bool
        var active: Bool
        /// 该工作区的 pane 句柄（顺序 = 布局顺序）
        var panes: [String]
        var zoom: String?
        /// scrolling：列 → 宽度因子 + 列内句柄
        var columns: [ColumnInfo]?
        /// dwindle：分裂树（`{split,ratio,a,b}` / 叶子 `{pane:"t1"}`）
        var tree: TreeNode?
        var floating: [String]
    }

    struct ColumnInfo: Codable, Equatable {
        var width: Double
        var panes: [String]
    }

    /// dwindle 工作区的骨架。**与 `spec dump` 的 `tree` 同一套词**（`split` / `ratio` / `a` / `b`），
    /// 只是叶子装的是句柄而不是一份 pane 记录（pane 记录在扁平的 `panes[]` 里，不重复第二遍）。
    /// 早先这里是一串扁平的 `{pane,path}`：形状能读，**比例读不到**——
    /// agent 能拖动分隔条却看不见自己拖到了哪儿，只能盲调。
    /// 路径没有丢：`a`/`b` 的嵌套本身就是路径（`a.b` = 先左后右），
    /// 每个 pane 的 `at.path` 也照旧给出那一串
    indirect enum TreeNode: Codable, Equatable {
        /// 一片叶子：pane 句柄
        case leaf(String)
        case split(Split)

        struct Split: Equatable {
            /// `horizontal` = a 左 b 右；`vertical` = a 上 b 下
            var split: String
            /// a 那一侧占的比例（0–1）
            var ratio: Double
            var a: TreeNode
            var b: TreeNode
        }

        private enum CodingKeys: String, CodingKey { case pane, split, ratio, a, b }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.a) || c.contains(.b) {
                self = .split(Split(split: try c.decode(String.self, forKey: .split),
                                    ratio: try c.decode(Double.self, forKey: .ratio),
                                    a: try c.decode(TreeNode.self, forKey: .a),
                                    b: try c.decode(TreeNode.self, forKey: .b)))
                return
            }
            self = .leaf(try c.decode(String.self, forKey: .pane))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let handle):
                try c.encode(handle, forKey: .pane)
            case .split(let split):
                try c.encode(split.split, forKey: .split)
                try c.encode(split.ratio, forKey: .ratio)
                try c.encode(split.a, forKey: .a)
                try c.encode(split.b, forKey: .b)
            }
        }

        /// 叶子句柄（布局顺序）
        var handles: [String] {
            switch self {
            case .leaf(let handle): [handle]
            case .split(let split): split.a.handles + split.b.handles
            }
        }
    }

    struct PaneInfo: Codable, Equatable {
        var handle: String
        var id: String
        var kind: String
        var role: String?
        var screen: Int
        var workspace: Int
        var at: Position?
        /// 这个 pane 有多大（见 `PaneSize`）。浮动 / 平铺都给
        var size: PaneSize? = nil
        var title: String?
        var cwd: String?
        var url: String?
        /// 浏览器 pane 的标签**数量**（形状不变：一直是个整数）
        var tabs: Int?
        /// 浏览器 pane 的逐标签明细（顺序 = 标签顺序）。
        /// **打码规则与 pane 级的 url / title 逐字相同**：没有 token 的调用方
        /// 拿得到 index / id / active（寻址要用），拿不到任何标题与网址——
        /// 否则"pane 级打了码、tab 级照抄一份"就是同一个外泄面换了个字段名
        var tabList: [TabInfo]? = nil
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

        /// 浏览器 pane 里的一个标签。**`index` 与 `id` 就是 `--tab` 认的那两种写法**：
        /// 序号是给人看的（1 起，与标签栏顺序一致，会随开关标签移动），
        /// id 是稳定的（标签活着就不变，`--tab #<前缀>` 认它）——
        /// agent 先 `get` 再 `--tab #id`，中间别人开了新标签也不会打到别的页面上
        struct TabInfo: Codable, Equatable {
            /// 1 起的序号（= 标签栏从左到右）
            var index: Int
            /// 稳定的标签 id（`--tab #<uuid 或 ≥4 位前缀>`）
            var id: String
            /// 当前标签（`--tab @active` 指的就是它）
            var active: Bool
            /// 标题 / 网址：无 token 的调用方读到的是 `<redacted>`
            var title: String?
            var url: String?
            /// 正在加载
            var loading: Bool?
        }

        /// pane 的几何。**以模型为准**：`rect` 是由 dwindle 的 ratio / scrolling 的列宽因子
        /// 直接算出来的，与渲染用的是同一套公式；`points` / `cols` / `rows` 是尽力而为——
        /// pane 在 SwiftUI 重建期间会脱离窗口，那一瞬间没有 frame 可读，
        /// 报 nil 好过报一个上一帧的假数（读尺寸绝不该等一帧，更不该崩）
        struct PaneSize: Codable, Equatable {
            /// 工作区内容区里的归一化矩形 `[x, y, w, h]`，**左上角为原点**（与渲染同向）。
            /// scrolling 的横向单位是"一个视口宽"：条带溢出时 `x + w` 会大于 1，
            /// 多出来的那截正是要滚动才看得到的部分
            var rect: [Double]
            /// 这个 pane 的**槽位**点尺寸 `[w, h]`，底是工作区布局区
            /// （contentView 去掉顶部状态条与外圈留白，= `SplitView` 量到的那块地）。
            /// 槽位里还有 PaneChrome 一圈留白与终端 pane-padding，终端画布因此更小——
            /// 要网格看 `cols`/`rows`（引擎量的），别拿 points 去除字宽。
            /// 窗口没挂上、或这一片被 zoom 遮住（见 `hidden`）时省略
            var points: [Double]?
            /// 终端网格列数 / 行数（只有终端 pane、且引擎已经量过一次时才有）
            var cols: Int?
            var rows: Int?
            /// dwindle：最近父 split 的方向与比例（树根上的孤叶没有父 split）
            var split: String?
            var ratio: Double?
            /// scrolling：所在列的宽度因子
            var width: Double?
            /// scrolling：这个 pane 在列内占的份额（列内等分 = 1 / 列内 pane 数）
            var share: Double?
            /// 本工作区有 pane 被 zoom，而这一片不是它：**当前屏幕上没有它**。
            /// `rect` / `ratio` / `width` 仍是底下那层平铺（`pane resize` 调的是它，
            /// 取消 zoom 也回到它），但 `points` 这时候一概不给
            var hidden: Bool?
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
    /// 调用方二进制的版本。**应用侧一律留空**——它无从得知谁在调它；
    /// 由 CLI 自己填。填成应用版本会让「CLI 与应用不一致」永远显示一致，
    /// 而升级后 PATH 上留着旧 quickterm 正是要靠这一栏发现的
    var cli: String?
    var app: String?
    var protocolVersion: Int
    var appProtocolVersion: Int?
    var socket: String?
    var running: Bool
}
