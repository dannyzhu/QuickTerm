import Foundation

/// Phase 3 的**公开** schema：`quickterm.workspace/1`（+ `quickterm.screen/1` /
/// `quickterm.session/1` 两个信封，它们原样复用工作区那一份词汇）。
///
/// **刻意不是内部存档 `PersistedState` v5**，这是本阶段最该守住的一条界线：
/// - v5 已经翻过 v2→v3→v4→v5，解码器**拒读比自己新的版本**——把它当公开格式发出去，
///   等于让用户提交进 dotfiles 的每一份工作区文件都在下一次布局重构时作废；
/// - v5 的终端叶子只有 `pwd` / `title`：**没有** command、没有 env、没有 hold-on-exit，
///   而这三样正是"让 agent 一次性组合出一个工作区"必须能写的字段；
/// - 反过来，公开 schema 也不该背上 v5 的信封字段（窗口 frame 的坐标系、legacy 列宽归一…）。
///
/// 两者之间只有一处联系：`Sources/Control/Spec/SpecCodec.swift` 里的投影对
/// （活模型 → spec 的 dump，spec → 活模型的 plan）。于是两个格式**各自独立演进**。
///
/// 本文件在 `Sources/Control/Wire`：同时编进 app 与 `quickterm` 工具 target，
/// 因此只能 `import Foundation`。
enum SpecSchema {
    static let workspace = "quickterm.workspace/1"
    static let screen = "quickterm.screen/1"
    static let session = "quickterm.session/1"
    static let all = [workspace, screen, session]
}

/// spec 里所有数值字段的取值范围。**必须盖住引擎真的能持有的值**——
/// `ControlSpecTests.testSpecLimitsMatchTheEngine` 逐条钉死（Wire 只能 import Foundation，
/// 引用不到 `ScrollingStrip`，所以只能各写一份 + 用例锁死）。
/// 窄了的后果是 dump 出来的文件自己 validate 不过，宽了的后果是 apply 落下去一个引擎摆不出来的值
enum SpecLimits {
    /// 列宽因子。**比 `pane set --width`（0.25–0.90，那是给手动调宽定的）两头都宽**：
    /// 「每屏可见 N 列」会把整条 strip 等分成 `ScrollingStrip.factor(forVisibleColumns:)`
    /// = (1−2×peek)/N —— N=1 是 0.97、N=6 是 0.1617，都在 0.25–0.90 之外。
    /// 公开 schema 比引擎能持有的窄一点点，后果就是 `spec dump` 出来的文件被 `spec validate`
    /// 当场拒掉（QuickTerm 读不了 QuickTerm 刚写的东西）
    static let widthRange = 0.15...0.98
    /// 分裂比例。同样**比 `pane set --ratio`（0.1–0.9）宽**：鼠标拖分隔条只夹到 10pt，
    /// 一块 1600pt 宽的 pane 拖到底就是 0.006，而 dump 必须如实写出那个数——
    /// 静默夹紧的话，这份 dump 描述的就不是这个工作区，apply 回去分隔条还会自己跳一下
    static let ratioRange = 0.001...0.999
    /// == `screen set --visible-columns`
    static let visibleColumns = 1...6
    /// == `ControlRateLimiter.maxPanesPerWorkspace`
    static let maxPanes = 32
    /// 一份 spec 的字节上限（NDJSON 单行上限是 1 MiB，转义之后还要留出余量）
    static let maxBytes = 256 * 1024
}

/// spec 里的一个 pane。**每个字段都可省**，省掉时的默认值写在各自的注释里——
/// 于是一个模型可以只写 `{"panes":[{}]}` 就得到一个正常的终端 pane
struct PaneSpec: Codable, Equatable {
    /// `terminal`（默认）/ `browser` / `file-manager`
    var kind: String?
    /// 起始目录（支持 `~`）。**默认继承锚点 pane 的目录**（见 `SpecApplier.anchorDirectory`）
    var cwd: String?
    /// 要跑的命令。**只进不出**：活着的 surface 不记得自己是被什么命令拉起来的
    /// （v5 存档里也没有这个字段），所以 `spec dump` 永远不会回吐 `cmd`
    var cmd: String?
    /// 命令退出后**不**关闭 pane（默认关闭）。只对 `cmd` 有意义
    var hold: Bool?
    /// 额外环境变量。同样只进不出
    var env: [String: String]?
    /// 浏览器 pane 打开的网址（= 活动标签）
    var url: String?
    /// 浏览器 pane 的全部标签（顺序即标签顺序）；`url` 决定哪一个是活动标签
    var tabs: [String]?
    /// `dump --include-ids` 才有：pane 的 UUID。`apply --reuse` 用它做最强匹配，其余模式忽略
    var id: String?
    /// `dump --include-ids` 才有：短句柄（只在本次运行期间稳定）
    var handle: String?
    /// `dump --include-ids` 才有：当下的标题（易变，仅供人读；apply 一律忽略）
    var title: String?
    /// 这个浏览器 pane 的 url / title 因为调用方没有 token 而被打码（apply 会把它当作"没写 url"）
    var redacted: Bool?
}

/// 位置引用：scrolling 用 `{column,row}`，dwindle 用 `{path}`，浮动层用 `{floating}`。
/// `focus` 与 `zoom` 共用它——两者指的都是"布局里的某一格"，而不是某个 pane 的身份
/// （身份是 apply 时才产生的，spec 本身必须能在 pane 还不存在时写出来）
struct PaneRef: Codable, Equatable {
    var column: Int?
    var row: Int?
    /// dwindle 树路径：`a` = 左 / 上，`b` = 右 / 下，点号连接，根是空串
    var path: String?
    /// 浮动层里的第几个（0 起）
    var floating: Int?
}

struct ColumnSpec: Codable, Equatable {
    /// 列宽因子（0.15–0.98）。默认 = 屏幕当前的"每屏可见列数"折算出来的列宽
    var width: Double?
    /// 列内自上而下的 pane 栈。默认 `[{}]`（一个终端）
    var panes: [PaneSpec]?
}

/// dwindle 的树节点：要么是一片叶子（`pane`），要么是一次分裂（`a` / `b`）。
/// 空对象 `{}` = 一片默认叶子（终端）——两行 spec 也能写出一棵树
indirect enum NodeSpec: Equatable {
    case leaf(PaneSpec)
    case split(Split)

    struct Split: Equatable {
        /// `horizontal` = a 左 b 右（默认）；`vertical` = a 上 b 下。
        /// 与内部 `SplitTree.Direction` 同名同义，绝不各起一套词
        var direction: String?
        /// 分裂比例（0.001–0.999；手打的话 0.1–0.9 就够用了），默认 0.5
        var ratio: Double?
        var a: NodeSpec
        var b: NodeSpec
    }

    private enum CodingKeys: String, CodingKey { case pane, split, ratio, a, b }
}

extension NodeSpec: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.a) || c.contains(.b) {
            let a = try c.decodeIfPresent(NodeSpec.self, forKey: .a) ?? .leaf(PaneSpec())
            let b = try c.decodeIfPresent(NodeSpec.self, forKey: .b) ?? .leaf(PaneSpec())
            self = .split(Split(direction: try c.decodeIfPresent(String.self, forKey: .split),
                                ratio: try c.decodeIfPresent(Double.self, forKey: .ratio),
                                a: a, b: b))
            return
        }
        self = .leaf(try c.decodeIfPresent(PaneSpec.self, forKey: .pane) ?? PaneSpec())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try c.encode(pane, forKey: .pane)
        case .split(let split):
            try c.encodeIfPresent(split.direction, forKey: .split)
            try c.encodeIfPresent(split.ratio, forKey: .ratio)
            try c.encode(split.a, forKey: .a)
            try c.encode(split.b, forKey: .b)
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: 1
        case .split(let s): s.a.leafCount + s.b.leafCount
        }
    }
}

/// 浮动层的一项：一个 pane + 可选的几何（内容区比例 `[x,y,w,h]`）。
/// 不写几何 = 应用自己那份"居中、列宽 ×0.75、高 45%"的默认值
struct FloatingSpec: Codable, Equatable {
    var rect: [Double]?
    var pane: PaneSpec?
}

/// `quickterm.workspace/1`
struct WorkspaceSpec: Codable, Equatable {
    var schema: String?
    /// 1 起的工作区序号。只在 `quickterm.screen/1` 的 `workspaces[]` 里有意义
    /// （不写就按数组下标落位）
    var index: Int?
    /// `scrolling`（默认）/ `dwindle`
    var layout: String?
    /// scrolling 每屏可见列数（1–6）。**作用于整块屏幕**，不写就不动它
    var visibleColumns: Int?
    /// scrolling：列 × 列内纵栈
    var columns: [ColumnSpec]?
    /// dwindle：分裂树
    var tree: NodeSpec?
    /// 哪一格被 zoom（不写 / null = 没有）
    var zoom: PaneRef?
    /// 哪一格拿焦点（不写 = 第一个 pane）
    var focus: PaneRef?
    /// 浮动层（不写 = 空）
    var floating: [FloatingSpec]?

    init(schema: String? = nil, index: Int? = nil, layout: String? = nil,
         visibleColumns: Int? = nil, columns: [ColumnSpec]? = nil, tree: NodeSpec? = nil,
         zoom: PaneRef? = nil, focus: PaneRef? = nil, floating: [FloatingSpec]? = nil) {
        self.schema = schema
        self.index = index
        self.layout = layout
        self.visibleColumns = visibleColumns
        self.columns = columns
        self.tree = tree
        self.zoom = zoom
        self.focus = focus
        self.floating = floating
    }

    /// 展开默认值之后的布局名
    var layoutName: String { layout ?? (tree != nil ? "dwindle" : "scrolling") }

    /// 这份 spec 一共要多少个 pane（平铺 + 浮动）
    var paneCount: Int {
        let tiled: Int
        switch layoutName {
        case "dwindle": tiled = tree?.leafCount ?? 0
        default: tiled = (columns ?? []).reduce(0) { $0 + ($1.panes?.count ?? 1) }
        }
        return tiled + (floating ?? []).count
    }
}

struct DisplaySpec: Codable, Equatable {
    var uuid: String?
    var name: String?
}

/// `quickterm.screen/1`：工作区那一份词汇的信封
struct ScreenSpec: Codable, Equatable {
    var schema: String?
    /// 1 起的屏幕序号（dump 回显；apply 以 `-t` 为准）
    var index: Int?
    var display: DisplaySpec?
    /// `[x, y, w, h]`（全局坐标）
    var frame: [Double]?
    var fullscreen: Bool?
    var joinAllSpaces: Bool?
    var visibleColumns: Int?
    /// 1 起
    var activeWorkspace: Int?
    var workspaces: [WorkspaceSpec]?
}

/// `quickterm.session/1`
struct SessionSpec: Codable, Equatable {
    var schema: String?
    var screens: [ScreenSpec]?
    /// 1 起的 key 屏幕序号
    var keyScreen: Int?
}

enum SpecKind: String, Codable, CaseIterable {
    case workspace, screen, session
}

/// 一份 spec 文件解出来的东西（三种作用域同一套词汇）
enum SpecDocument: Equatable {
    case workspace(WorkspaceSpec)
    case screen(ScreenSpec)
    case session(SessionSpec)

    var kind: SpecKind {
        switch self {
        case .workspace: .workspace
        case .screen: .screen
        case .session: .session
        }
    }

    /// 里面一共描述了多少个 pane（限流与 `--dry-run` 的摘要都要用）
    var paneCount: Int {
        switch self {
        case .workspace(let w): w.paneCount
        case .screen(let s): (s.workspaces ?? []).reduce(0) { $0 + $1.paneCount }
        case .session(let s): (s.screens ?? []).reduce(0) { sum, screen in
            sum + (screen.workspaces ?? []).reduce(0) { $0 + $1.paneCount } }
        }
    }

    func json() throws -> JSONValue {
        let data: Data
        switch self {
        case .workspace(let w): data = try ControlJSON.encoder.encode(w)
        case .screen(let s): data = try ControlJSON.encoder.encode(s)
        case .session(let s): data = try ControlJSON.encoder.encode(s)
        }
        return try ControlJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// 稳定的字节形式（`dump → apply → dump` 的不动点用例比的就是它）
    func canonicalJSONString() throws -> String {
        String(decoding: try ControlJSON.encoder.encode(json()), as: UTF8.self)
    }
}

/// 校验出来的一条问题：`path` 与 spec 里的写法同形（`columns[1].panes[0].cwd`），
/// 这样模型读到的位置就是它要去改的那个键
struct SpecIssue: Codable, Equatable {
    var path: String
    var message: String

    var text: String { path.isEmpty ? message : "\(path)：\(message)" }
}

/// 解析 + 校验。**先在原始 JSON 上走一遍**（认得的键、类型、取值范围），再做类型化解码——
/// 只靠 `JSONDecoder` 的话，写错一个键名（`colums`）会被静默当成"没写"，
/// 而 agent 拿到的是一个"成功但什么都没发生"的结果，那是最难查的一类错
enum SpecParser {
    static func parse(_ text: String) throws -> SpecDocument {
        guard text.utf8.count <= SpecLimits.maxBytes else {
            throw ControlErrorBody(.badRequest,
                                   "spec 太大了（\(text.utf8.count) 字节，上限 \(SpecLimits.maxBytes)）")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlErrorBody(.badRequest, "spec 是空的",
                                   hint: "quickterm spec dump > w.json 先拿一份样板")
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? ControlJSON.decoder.decode(JSONValue.self, from: data) else {
            throw ControlErrorBody(.badRequest, "spec 不是合法的 JSON",
                                   hint: "quickterm spec validate 会逐条指出问题所在")
        }
        // 信封形态也认：`quickterm spec dump --json` 的输出被整份存进文件时（{v,ok,data:{spec:…}}），
        // 直接喂回来也能用——否则用户要先 jq 一遍才能 apply，而那正是最容易出错的一步
        let body = value["data"]?["spec"] ?? value
        guard let object = body.objectValue else {
            throw ControlErrorBody(.badRequest, "spec 的最外层必须是一个 JSON 对象")
        }
        let kind = try kind(of: object)
        var issues: [SpecIssue] = []
        switch kind {
        case .workspace: SpecValidator.workspace(object, at: "", into: &issues)
        case .screen: SpecValidator.screen(object, at: "", into: &issues)
        case .session: SpecValidator.session(object, at: "", into: &issues)
        }
        guard issues.isEmpty else { throw error(issues) }

        let encoded = try ControlJSON.encoder.encode(body)
        do {
            switch kind {
            case .workspace: return .workspace(try ControlJSON.decoder.decode(WorkspaceSpec.self, from: encoded))
            case .screen: return .screen(try ControlJSON.decoder.decode(ScreenSpec.self, from: encoded))
            case .session: return .session(try ControlJSON.decoder.decode(SessionSpec.self, from: encoded))
            }
        } catch {
            throw ControlErrorBody(.badRequest, "spec 解码失败：\(error)")
        }
    }

    /// `schema` 说了算；没写就按形状认（有 `screens` = 会话，有 `workspaces` = 屏幕，否则工作区）
    static func kind(of object: [String: JSONValue]) throws -> SpecKind {
        if let schema = object["schema"]?.stringValue {
            switch schema {
            case SpecSchema.workspace: return .workspace
            case SpecSchema.screen: return .screen
            case SpecSchema.session: return .session
            default:
                throw ControlErrorBody(.badRequest, "未知的 schema「\(schema)」",
                                       hint: "本版认得：\(SpecSchema.all.joined(separator: " / "))",
                                       candidates: SpecSchema.all)
            }
        }
        if object["screens"] != nil { return .session }
        if object["workspaces"] != nil { return .screen }
        return .workspace
    }

    static func error(_ issues: [SpecIssue]) -> ControlErrorBody {
        let head = issues.prefix(8).map(\.text).joined(separator: "；")
        let more = issues.count > 8 ? "（还有 \(issues.count - 8) 条）" : ""
        return ControlErrorBody(.badRequest, "spec 不合法：\(head)\(more)",
                                hint: "quickterm spec validate -f <文件> 会一次列全")
    }
}

/// 结构校验（纯函数，不碰任何活的东西）。
/// 规则有意写死："认得的键"是白名单——写错键名一律报错，绝不静默忽略
enum SpecValidator {
    static let workspaceKeys: Set<String> = ["schema", "index", "layout", "visibleColumns",
                                             "columns", "tree", "zoom", "focus", "floating"]
    static let screenKeys: Set<String> = ["schema", "index", "display", "frame", "fullscreen",
                                          "joinAllSpaces", "visibleColumns", "activeWorkspace",
                                          "workspaces"]
    static let sessionKeys: Set<String> = ["schema", "screens", "keyScreen"]
    static let paneKeys: Set<String> = ["kind", "cwd", "cmd", "hold", "env", "url", "tabs",
                                        "id", "handle", "title", "redacted"]
    static let columnKeys: Set<String> = ["width", "panes"]
    static let nodeKeys: Set<String> = ["pane", "split", "ratio", "a", "b"]
    static let refKeys: Set<String> = ["column", "row", "path", "floating"]
    static let floatingKeys: Set<String> = ["rect", "pane"]
    static let displayKeys: Set<String> = ["uuid", "name"]

    static let paneKinds = ["terminal", "browser", "file-manager"]
    static let layouts = ["scrolling", "dwindle"]
    static let directions = ["horizontal", "vertical"]

    // MARK: 三种作用域

    static func session(_ object: [String: JSONValue], at path: String, into issues: inout [SpecIssue]) {
        unknownKeys(object, allowed: sessionKeys, at: path, into: &issues)
        schema(object, expected: SpecSchema.session, at: path, into: &issues)
        if let key = object["keyScreen"] { positiveInt(key, at: join(path, "keyScreen"), into: &issues) }
        guard let screens = object["screens"] else { return }
        guard let list = screens.arrayValue else {
            issues.append(.init(path: join(path, "screens"), message: "必须是数组"))
            return
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "screens"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "必须是对象"))
                continue
            }
            screen(child, at: p, into: &issues, nested: true)
        }
    }

    static func screen(_ object: [String: JSONValue], at path: String,
                       into issues: inout [SpecIssue], nested: Bool = false) {
        unknownKeys(object, allowed: screenKeys, at: path, into: &issues)
        if !nested { schema(object, expected: SpecSchema.screen, at: path, into: &issues) }
        if let index = object["index"] { positiveInt(index, at: join(path, "index"), into: &issues) }
        if let active = object["activeWorkspace"] {
            positiveInt(active, at: join(path, "activeWorkspace"), into: &issues)
        }
        if let columns = object["visibleColumns"] {
            intInRange(columns, SpecLimits.visibleColumns, at: join(path, "visibleColumns"), into: &issues)
        }
        for key in ["fullscreen", "joinAllSpaces"] where object[key] != nil {
            boolean(object[key]!, at: join(path, key), into: &issues)
        }
        if let display = object["display"] {
            if let child = display.objectValue {
                unknownKeys(child, allowed: displayKeys, at: join(path, "display"), into: &issues)
            } else if display != .null {
                issues.append(.init(path: join(path, "display"), message: "必须是对象 {uuid,name}"))
            }
        }
        if let frame = object["frame"], frame != .null {
            guard let list = frame.arrayValue, list.count == 4, list.allSatisfy({ $0.doubleValue != nil }) else {
                issues.append(.init(path: join(path, "frame"), message: "必须是 4 个数字 [x,y,w,h]"))
                return
            }
        }
        guard let workspaces = object["workspaces"] else { return }
        guard let list = workspaces.arrayValue else {
            issues.append(.init(path: join(path, "workspaces"), message: "必须是数组"))
            return
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "workspaces"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "必须是对象"))
                continue
            }
            workspace(child, at: p, into: &issues, nested: true)
        }
    }

    static func workspace(_ object: [String: JSONValue], at path: String,
                          into issues: inout [SpecIssue], nested: Bool = false) {
        unknownKeys(object, allowed: workspaceKeys, at: path, into: &issues)
        if !nested { schema(object, expected: SpecSchema.workspace, at: path, into: &issues) }
        if let index = object["index"] { positiveInt(index, at: join(path, "index"), into: &issues) }
        var layoutName = "scrolling"
        if let layout = object["layout"], layout != .null {
            guard let name = layout.stringValue, layouts.contains(name) else {
                issues.append(.init(path: join(path, "layout"),
                                    message: "只接受 \(layouts.joined(separator: " / "))"))
                return
            }
            layoutName = name
        } else if object["tree"] != nil, object["columns"] == nil {
            layoutName = "dwindle"
        }
        if let columns = object["visibleColumns"] {
            intInRange(columns, SpecLimits.visibleColumns, at: join(path, "visibleColumns"), into: &issues)
        }
        if layoutName == "scrolling", object["tree"] != nil, object["tree"] != .null {
            issues.append(.init(path: join(path, "tree"), message: "只对 layout=dwindle 有意义"))
        }
        if layoutName == "dwindle", object["columns"] != nil, object["columns"] != .null {
            issues.append(.init(path: join(path, "columns"), message: "只对 layout=scrolling 有意义"))
        }
        var paneCount = 0
        if let columns = object["columns"], columns != .null {
            guard let list = columns.arrayValue else {
                issues.append(.init(path: join(path, "columns"), message: "必须是数组"))
                return
            }
            for (i, item) in list.enumerated() {
                let p = "\(join(path, "columns"))[\(i)]"
                guard let child = item.objectValue else {
                    issues.append(.init(path: p, message: "必须是对象 {width,panes}"))
                    continue
                }
                paneCount += column(child, at: p, into: &issues)
            }
        }
        if let tree = object["tree"], tree != .null {
            paneCount += node(tree, at: join(path, "tree"), into: &issues)
        }
        if let floating = object["floating"], floating != .null {
            guard let list = floating.arrayValue else {
                issues.append(.init(path: join(path, "floating"), message: "必须是数组"))
                return
            }
            paneCount += list.count
            for (i, item) in list.enumerated() {
                let p = "\(join(path, "floating"))[\(i)]"
                guard let child = item.objectValue else {
                    issues.append(.init(path: p, message: "必须是对象 {rect,pane}"))
                    continue
                }
                unknownKeys(child, allowed: floatingKeys, at: p, into: &issues)
                if let rect = child["rect"], rect != .null {
                    guard let numbers = rect.arrayValue, numbers.count == 4,
                          numbers.allSatisfy({ $0.doubleValue != nil }) else {
                        issues.append(.init(path: join(p, "rect"),
                                            message: "必须是 4 个 0–1 的数字 [x,y,w,h]（内容区比例）"))
                        continue
                    }
                }
                if let child2 = child["pane"]?.objectValue { pane(child2, at: join(p, "pane"), into: &issues) }
            }
        }
        for key in ["zoom", "focus"] {
            guard let value = object[key], value != .null else { continue }
            guard let child = value.objectValue else {
                issues.append(.init(path: join(path, key),
                                    message: "必须是位置引用：{column,row} / {path} / {floating}"))
                continue
            }
            unknownKeys(child, allowed: refKeys, at: join(path, key), into: &issues)
            for k in ["column", "row", "floating"] where child[k] != nil {
                nonNegativeInt(child[k]!, at: join(join(path, key), k), into: &issues)
            }
            if let p = child["path"], p != .null {
                guard let text = p.stringValue,
                      text.isEmpty || text.split(separator: ".").allSatisfy({ $0 == "a" || $0 == "b" }) else {
                    issues.append(.init(path: join(join(path, key), "path"),
                                        message: "树路径只能由 a / b 用点号连接（根是空串）"))
                    continue
                }
            }
        }
        if paneCount > SpecLimits.maxPanes {
            issues.append(.init(path: path,
                                message: "一个工作区最多 \(SpecLimits.maxPanes) 个 pane，这份写了 \(paneCount)"))
        }
    }

    /// 返回这一列里的 pane 数
    private static func column(_ object: [String: JSONValue], at path: String,
                               into issues: inout [SpecIssue]) -> Int {
        unknownKeys(object, allowed: columnKeys, at: path, into: &issues)
        if let width = object["width"], width != .null {
            doubleInRange(width, SpecLimits.widthRange, at: join(path, "width"), into: &issues)
        }
        guard let panes = object["panes"], panes != .null else { return 1 }
        guard let list = panes.arrayValue else {
            issues.append(.init(path: join(path, "panes"), message: "必须是数组"))
            return 0
        }
        if list.isEmpty {
            issues.append(.init(path: join(path, "panes"), message: "列里至少要有一个 pane（空列没有意义）"))
        }
        for (i, item) in list.enumerated() {
            let p = "\(join(path, "panes"))[\(i)]"
            guard let child = item.objectValue else {
                issues.append(.init(path: p, message: "必须是对象"))
                continue
            }
            pane(child, at: p, into: &issues)
        }
        return list.count
    }

    /// 返回这棵子树的叶子数
    private static func node(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) -> Int {
        guard let object = value.objectValue else {
            issues.append(.init(path: path, message: "树节点必须是对象：{pane:…} 或 {split,ratio,a,b}"))
            return 0
        }
        unknownKeys(object, allowed: nodeKeys, at: path, into: &issues)
        let isSplit = object["a"] != nil || object["b"] != nil
        if isSplit {
            if let direction = object["split"], direction != .null {
                guard let name = direction.stringValue, directions.contains(name) else {
                    issues.append(.init(path: join(path, "split"),
                                        message: "只接受 horizontal（a 左 b 右）/ vertical（a 上 b 下）"))
                    return 0
                }
            }
            if let ratio = object["ratio"], ratio != .null {
                doubleInRange(ratio, SpecLimits.ratioRange, at: join(path, "ratio"), into: &issues)
            }
            if object["pane"] != nil {
                issues.append(.init(path: path, message: "一个节点不能既是分裂（a/b）又是叶子（pane）"))
            }
            var count = 0
            for key in ["a", "b"] {
                guard let child = object[key] else {
                    issues.append(.init(path: join(path, key), message: "分裂节点的两侧都要写（缺的那侧不会被脑补）"))
                    continue
                }
                count += node(child, at: join(path, key), into: &issues)
            }
            return count
        }
        if let leaf = object["pane"] {
            guard let child = leaf.objectValue else {
                issues.append(.init(path: join(path, "pane"), message: "必须是对象"))
                return 1
            }
            pane(child, at: join(path, "pane"), into: &issues)
        }
        return 1
    }

    static func pane(_ object: [String: JSONValue], at path: String, into issues: inout [SpecIssue]) {
        unknownKeys(object, allowed: paneKeys, at: path, into: &issues)
        var kind = "terminal"
        if let value = object["kind"], value != .null {
            guard let name = value.stringValue, paneKinds.contains(name) else {
                issues.append(.init(path: join(path, "kind"),
                                    message: "只接受 \(paneKinds.joined(separator: " / "))"))
                return
            }
            kind = name
        }
        if let cwd = object["cwd"], cwd != .null {
            guard let text = cwd.stringValue else {
                issues.append(.init(path: join(path, "cwd"), message: "必须是字符串"))
                return
            }
            if let bad = pathProblem(text) {
                issues.append(.init(path: join(path, "cwd"), message: bad))
            }
        }
        if let cmd = object["cmd"], cmd != .null {
            guard let text = cmd.stringValue else {
                issues.append(.init(path: join(path, "cmd"), message: "必须是字符串"))
                return
            }
            if text.isEmpty {
                issues.append(.init(path: join(path, "cmd"), message: "不能是空串（不写就是不跑命令）"))
            } else if hasControlCharacters(text) {
                issues.append(.init(path: join(path, "cmd"), message: "不能含控制字符"))
            }
            if kind == "browser" {
                issues.append(.init(path: join(path, "cmd"), message: "对浏览器 pane 没有意义"))
            }
        }
        if let hold = object["hold"], hold != .null {
            boolean(hold, at: join(path, "hold"), into: &issues)
        }
        if let env = object["env"], env != .null {
            if let map = env.objectValue {
                for (key, value) in map {
                    let p = join(join(path, "env"), key)
                    guard let text = value.stringValue else {
                        issues.append(.init(path: p, message: "环境变量的值必须是字符串"))
                        continue
                    }
                    if key.isEmpty || key.contains("=") || key.contains(" ") || hasControlCharacters(key) {
                        issues.append(.init(path: p, message: "环境变量名不合法"))
                    }
                    if hasControlCharacters(text) {
                        issues.append(.init(path: p, message: "环境变量的值不能含控制字符"))
                    }
                }
            } else {
                issues.append(.init(path: join(path, "env"), message: "必须是对象 {KEY: VALUE}"))
            }
        }
        for key in ["url", "id", "handle", "title"] {
            guard let value = object[key], value != .null else { continue }
            guard let text = value.stringValue else {
                issues.append(.init(path: join(path, key), message: "必须是字符串"))
                continue
            }
            if hasControlCharacters(text) {
                issues.append(.init(path: join(path, key), message: "不能含控制字符"))
            }
        }
        if object["url"] != nil, kind != "browser" {
            issues.append(.init(path: join(path, "url"), message: "只对 kind=browser 有意义"))
        }
        if let tabs = object["tabs"], tabs != .null {
            if kind != "browser" {
                issues.append(.init(path: join(path, "tabs"), message: "只对 kind=browser 有意义"))
            }
            guard let list = tabs.arrayValue else {
                issues.append(.init(path: join(path, "tabs"), message: "必须是字符串数组"))
                return
            }
            for (i, item) in list.enumerated() where item.stringValue == nil || hasControlCharacters(item.stringValue ?? "") {
                issues.append(.init(path: "\(join(path, "tabs"))[\(i)]", message: "必须是不含控制字符的网址"))
            }
        }
    }

    // MARK: 零件

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    static func unknownKeys(_ object: [String: JSONValue], allowed: Set<String>, at path: String,
                            into issues: inout [SpecIssue]) {
        for key in object.keys.sorted() where !allowed.contains(key) {
            issues.append(.init(path: join(path, key),
                                message: "认不得这个键（可用：\(allowed.sorted().joined(separator: " "))）"))
        }
    }

    static func schema(_ object: [String: JSONValue], expected: String, at path: String,
                       into issues: inout [SpecIssue]) {
        guard let schema = object["schema"] else { return }   // 不写就按形状认
        guard schema.stringValue == expected else {
            issues.append(.init(path: join(path, "schema"), message: "这一层的 schema 应该是 \(expected)"))
            return
        }
    }

    static func boolean(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        if case .bool = value { return }
        if value == .null { return }
        issues.append(.init(path: path, message: "必须是 true / false"))
    }

    static func positiveInt(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), int >= 1 else {
            issues.append(.init(path: path, message: "必须是 ≥1 的整数（序号一律 1 起）"))
            return
        }
    }

    static func nonNegativeInt(_ value: JSONValue, at path: String, into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), int >= 0 else {
            issues.append(.init(path: path, message: "必须是 ≥0 的整数"))
            return
        }
    }

    static func intInRange(_ value: JSONValue, _ range: ClosedRange<Int>, at path: String,
                           into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let int = strictInt(value), range.contains(int) else {
            issues.append(.init(path: path,
                                message: "必须是 \(range.lowerBound)–\(range.upperBound) 之间的整数"))
            return
        }
    }

    static func doubleInRange(_ value: JSONValue, _ range: ClosedRange<Double>, at path: String,
                              into issues: inout [SpecIssue]) {
        guard value != .null else { return }
        guard let number = strictDouble(value) else {
            issues.append(.init(path: path, message: "必须是数字"))
            return
        }
        guard range.contains(number) else {
            // **绝不静默夹紧**：夹紧之后 agent 读回来的值和它写下去的对不上，却没有任何提示
            issues.append(.init(path: path,
                                message: "必须在 \(range.lowerBound)–\(range.upperBound) 之间，收到 \(number)"))
            return
        }
    }

    /// 只认真正的 JSON 数字（`"3"` 这种字符串不算——静默接受它等于鼓励写出下一版会失败的 spec）
    static func strictInt(_ value: JSONValue) -> Int? {
        if case .int(let v) = value { return v }
        if case .double(let v) = value, v == v.rounded() { return Int(v) }
        return nil
    }

    static func strictDouble(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// 路径本身合不合法（存不存在留给 apply 前的预检：validate 要能离线校验一份写给别的机器的 spec）
    static func pathProblem(_ raw: String) -> String? {
        if raw.isEmpty { return "不能是空串" }
        if hasControlCharacters(raw) { return "不能含控制字符（包括 NUL）" }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("~") { return "认不出这个 ~ 开头的路径：\(raw)" }
        guard expanded.hasPrefix("/") else { return "必须是绝对路径或 ~ 开头（收到 \(raw)）" }
        return nil
    }

    /// 展开 `~` 并归一化 `..`（`/a/b/../c` → `/a/c`）。**不是安全边界**——
    /// 调用方本来就能直接写任何绝对路径；归一化只是让 dump 出来的路径可比、可读
    static func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

// MARK: - 命令负载

/// `spec dump` 的负载。`spec` 就是那份文件本身——CLI 在 JSON 模式下**只打印它**
/// （`quickterm spec dump > w.json` 要能直接喂回 `spec apply -f w.json`）
struct ControlSpecDumpPayload: Codable, Equatable {
    var scope: String
    var schema: String
    var panes: Int
    var spec: JSONValue
}

/// `spec validate` 的负载
struct ControlSpecValidatePayload: Codable, Equatable {
    var valid: Bool
    var scope: String
    var schema: String
    var panes: Int
    /// 校验通过但值得说一句的事（比如 dump 不会回吐 cmd）
    var notes: [String]
}

/// `spec apply` 的报告（挂在统一变更信封的 `spec` 字段上）
struct ControlSpecApplyReport: Codable, Equatable {
    var mode: String
    var scope: String
    /// 新建出来的 pane 句柄
    var created: [String]
    /// `--reuse` 留下来没动的 pane 句柄
    var reused: [String]
    /// 被顶掉、走了真正关闭路径的 pane 句柄
    var closed: [String]
    /// **落刀之后**才失败：工作区已经被改了一半，如实说出来，绝不假装什么都没发生
    var partial: Bool?
    /// 落地时被跳过的部分（比如会话里多出来的屏幕）
    var skipped: [String]?
}
