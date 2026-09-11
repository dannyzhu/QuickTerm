import AppKit
import GhosttyKit

/// `pane capture-text` —— 把一个终端 pane **当前屏幕上的文字**读回来。
///
/// 为什么它和 `input send-text` 分在同一个安全等级（`sensitive`）而不是 `read`：
/// 一个 shell 的可视区里可以有任何东西——刚 `export` 的 token、贴在提示符上还没回车的密码、
/// `git diff` 出来的私有代码、一条正在跑的 ssh 会话的输出。这比"浏览器 pane 的网址"
/// （控制面早就默认打码的那一项）敏感得多。所以它身上叠的闸门与 send-text 同级，
/// 而且每一道都独立生效：
///
/// 1. **默认关闭**：`[control] capture-text = true` 之前，命令连执行的机会都没有；
/// 2. **必须带本次启动的 token**：没有 `QUICKTERM_TOKEN` 的调用方一律拒——
///    这正是浏览器网址打码用的那一枚。读不到浏览器网址的人，更不该读到别人的 tty；
/// 3. **每个调用进程确认一次**（`(pid, 命令)` 粒度，见 `ControlConsent`）：
///    用户在 QuickTerm 里看到"某某进程要读 t7 的屏幕内容"并点过"允许"，才会有第一次；
/// 4. **正文一个字都不留痕**：不进活动日志（读命令本来就不记）、不进事件流
///    （事件从设计上就不携带 pane 的输出）、不进 OSLog。它只在那一条响应里出现一次。
///
/// 刻意**没有**"读自己那个 pane 免确认"的口子。`send-text` 有那个口子是因为
/// 调用进程本来就能往自己的 tty 上写（不经过 QuickTerm 也能）；而**读**不一样：
/// 一个进程没有任何正常办法读到自己 tty 的回滚缓冲，那里躺着的可能是用户在把这个 pane
/// 交给 agent 之前敲的东西。没有先例可循的时候，安全的那一侧是"问"。
@MainActor
extension ControlCommandRunner {
    func paneCaptureText(_ ctx: ControlContext) throws -> (ResolvedTarget?, any Encodable) {
        let hit = try requirePane(ctx, ctx.target)
        try verifyPinned(ctx, controller: hit.controller, workspace: hit.workspace, pane: hit.pane)
        guard let surface = hit.pane as? Ghostty.SurfaceView else {
            throw ControlErrorBody(
                .wrongPaneKind,
                "\(handleName(hit.pane)) 是 \(hit.pane.kind.rawValue) pane，没有终端屏幕可读",
                hint: "只有 kind=terminal 的 pane 能 capture-text（quickterm list panes）")
        }
        let scrollback = ctx.int("scrollback") ?? 0
        guard (0...ControlCaptureLimits.maxScrollback).contains(scrollback) else {
            throw ControlErrorBody(
                .badRequest,
                "--scrollback 必须在 0–\(ControlCaptureLimits.maxScrollback) 之间，收到 \(scrollback)",
                hint: "要更多历史请在那个 pane 里自己落盘（tee / script），"
                    + "整份回滚缓冲塞进一次响应会把 agent 的上下文吃光")
        }
        guard let capture = Self.capture(surface, scrollback: scrollback) else {
            throw ControlErrorBody(.busy, "终端还没准备好（引擎 surface 尚未创建）",
                                   hint: "稍后重试；本次什么都没做", retryAfterMs: 200)
        }

        let payload = ControlCaptureTextPayload(
            command: ctx.spec.name,
            pane: paneInfo(hit, encoder: ctx.encoder),
            cols: surface.surfaceSize.map { Int($0.columns) },
            rows: surface.surfaceSize.map { Int($0.rows) },
            lines: capture.lines,
            scrollback: capture.scrollbackLines,
            truncated: capture.truncated ? true : nil,
            text: capture.text)
        return (hit.echo, payload)
    }

    struct Capture {
        var text: String
        var lines: Int
        var scrollbackLines: Int
        var truncated: Bool
    }

    /// 读可视区（`--scrollback N` 时再往上补 N 行）。
    ///
    /// **不走 `cachedVisibleContents`**：那份缓存有 500ms 的寿命，是给辅助功能用的。
    /// 调用方要的是"现在屏幕上是什么"——把一份最多半秒前的快照说成现在，
    /// 正是"我发了命令、读回来的还是上一屏"这类错觉的来源。
    static func capture(_ surface: Ghostty.SurfaceView, scrollback: Int) -> Capture? {
        guard let viewport = surface.controlReadText(tag: GHOSTTY_POINT_VIEWPORT) else { return nil }
        let screen = scrollback > 0 ? surface.controlReadText(tag: GHOSTTY_POINT_SCREEN) : nil
        return assemble(viewport: viewport, screen: screen, scrollback: scrollback)
    }

    /// 拼装那一段单独拿出来（纯函数，不碰引擎）：截断之后那几个计数容易算错，
    /// 而算错的代价是调用方按 `scrollback` 去切 `text` 时把可视区当成历史
    static func assemble(viewport: String, screen: String?, scrollback: Int) -> Capture {
        var lines = Self.trimmed(viewport)
        // 可视区本身有多少行——**截断之后要靠它反推还剩多少历史**
        let viewportLines = lines.count
        var scrollbackLines = 0

        if scrollback > 0, let screen {
            let all = Self.trimmed(screen)
            // 引擎给的"screen"含回滚缓冲，末尾正常就是可视区那几行。对得上就把它切掉，
            // 上面那一段才是**可视区之上**的历史；对不上（用户正往上滚）就如实退回
            // "整份历史的最后 N 行"——绝不假装那 N 行一定紧挨着可视区
            if lines.count <= all.count, Array(all.suffix(lines.count)) == lines {
                let history = all.dropLast(lines.count).suffix(scrollback)
                scrollbackLines = history.count
                lines = Array(history) + lines
            } else {
                let tail = Array(all.suffix(scrollback + lines.count))
                scrollbackLines = max(tail.count - lines.count, 0)
                lines = tail
            }
        }

        var text = lines.joined(separator: "\n")
        var truncated = false
        if text.utf8.count > ControlCaptureLimits.maxBytes {
            // **从头部截**：屏幕上最新的那几行永远是调用方最想要的
            var kept: [String] = []
            var bytes = 0
            for line in lines.reversed() {
                bytes += line.utf8.count + 1
                if bytes > ControlCaptureLimits.maxBytes { break }
                kept.append(line)
            }
            lines = kept.reversed()
            text = lines.joined(separator: "\n")
            truncated = true
            // 留下来的是**最后** N 行 = 可视区那几行，加上紧挨着它的一小截历史。
            // `min(原来的历史行数, 总行数)` 会把可视区那几行也算成历史
            // （极端情况直接报出 scrollback == lines，于是"可视区 = lines - scrollback"算出 0）。
            // 剩下的历史只可能是"留下来的行数减去可视区行数"
            scrollbackLines = max(0, lines.count - viewportLines)
        }
        return Capture(text: text, lines: lines.count,
                       scrollbackLines: scrollbackLines, truncated: truncated)
    }

    /// 行尾空白去掉（终端会把每行填满空格），**行本身一个都不丢**——
    /// 中间的空行是输出的一部分，抹掉它读回来的就不是屏幕上那个样子了。
    /// 只掐掉末尾那一串完全空的行（提示符之下的空白屏幕）
    static func trimmed(_ raw: String) -> [String] {
        var lines = raw.components(separatedBy: "\n").map {
            String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }
}

extension Ghostty.SurfaceView {
    /// 引擎里读一段文本（`GHOSTTY_POINT_VIEWPORT` = 可视区，`GHOSTTY_POINT_SCREEN` = 含回滚）。
    /// `ghostty_surface_read_text` 分配的内存必须还给引擎（`free_text`），所以这里 defer 掉
    func controlReadText(tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        // 空屏幕时引擎可能给回一个空指针：`String(cString:)` 吃到 nil 是当场崩，
        // 而"屏幕上什么都没有"是个完全正常的答案
        guard let pointer = text.text else { return "" }
        return String(cString: pointer)
    }
}
