import SwiftUI

/// 仿 waybar 顶栏（spec §4.4）：26pt · Monaco 12 · SF Symbols 单色 · 无圆角。
/// 左 logo+工作区胶囊 / 中时钟 / 右 cpu·网络·音量·电池。
struct StatusBarView: View {
    /// 条高（MainWindowController 换算内容区坐标时引用）
    static let height: CGFloat = 26

    @EnvironmentObject var theme: ThemeManager
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var stats: SystemStatsService
    let onSelectWorkspace: (Int) -> Void
    /// 右键工作区胶囊：给这个槽位起名 / 改名（左键仍旧是切工作区）
    let onRenameWorkspace: (Int) -> Void
    let onToggleMute: () -> Void

    @State private var altClock = false
    /// 内容区宽度（不含左右各 8pt 内边距）：胶囊要不要显示名字全看它，见 `WorkspacePill`
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                leftSection
                Spacer(minLength: 0)
                rightSection
            }
            clock  // 独立居中，不受两侧宽度影响（waybar center 模块语义）
        }
        .font(.custom("Monaco", size: 12))
        .foregroundStyle(theme.foreground)
        .frame(height: Self.height)
        // 量的是**内边距之内**那一段（`padding` 在下一行才加）：胶囊、时钟、右侧统计量都排在这里面。
        // 用 `onGeometryChange` 而不是 `background(GeometryReader)` + preference：
        // 背景里的 preference 传不上来（试过，量到的永远是 0），而这一段宽度是
        // "名字放不放得下"的唯一输入，量不到就等于整个功能不生效
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .padding(.horizontal, 8)
        .background(theme.background.opacity(theme.effectiveChromeOpacity))
        .contentShape(Rectangle())
        // 标准标题栏行为：空白处双击 = zoom 铺满屏幕可视区域，再双击还原。
        // 胶囊/时钟/音量等子控件的手势优先，不受影响。
        .onTapGesture(count: 2) {
            (NSApp.mainWindow ?? NSApp.keyWindow)?.zoom(nil)
        }
    }

    private var leftSection: some View {
        // **画哪几个胶囊、按哪几个算宽度，取的必须是同一个数组。** `model.titles` 缩容时不裁
        // （名字是槽位的，工作区数调回来名字还得在），拿它原样去量就会替几个根本不画的胶囊
        // 买单——那几个名字凭空吃掉预算，真正画出来的这一排明明放得下，却整排退回了序号。
        // 整排的答案也**每帧只算一次**：它要量一遍时钟与每个名字，
        // 而且几个胶囊必须拿到同一个答案（半排名字半排序号读起来就是个 bug）
        let titles = model.visibleTitles
        let showingTitles = showsWorkspaceTitles(titles)
        return HStack(spacing: WorkspacePill.sectionSpacing) {
            Text("◆")
                .foregroundStyle(theme.accent)
                .accessibilityLabel("QuickTerm")
            HStack(spacing: WorkspacePill.spacing) {
                ForEach(titles.indices, id: \.self) { i in
                    workspacePill(i, title: titles[i], showingTitles: showingTitles)
                }
            }
            controlFlash
        }
    }

    /// 这一排胶囊现在显示名字还是序号。**整排一起**：配置关掉、一个名字都没起、
    /// 或者左边这一段放不进"时钟左沿之前"，三种情况一律回到序号。
    /// 名字由调用方传进来（就是它画出去的那一排），免得量的与画的各读各的
    private func showsWorkspaceTitles(_ titles: [String?]) -> Bool {
        theme.workspaceTitleEnabled
            && WorkspacePill.showsTitles(contentWidth: contentWidth, titles: titles,
                                         activeIndex: model.activeIndex,
                                         clockWidth: clockWidth, flash: model.controlFlash?.text)
    }

    /// 控制面活动提示（spec 控制面 §安全）：`mutate` 类命令不弹框、不问人——
    /// 它被允许这么静默的**前提**就是事后有一眼能看见的痕迹。
    /// 停留 2.5s 后自行消失；完整记录在「控制面活动…」里
    @ViewBuilder
    private var controlFlash: some View {
        if let flash = model.controlFlash {
            Text(flash.text)
                .lineLimit(1)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(theme.accent.opacity(0.15))
                .transition(.opacity)
                .accessibilityLabel("控制面活动：\(flash.text)")
                .help("外部程序刚刚通过 quickterm 控制面执行了这条命令")
        }
    }

    private func workspacePill(_ i: Int, title: String?, showingTitles: Bool) -> some View {
        let active = model.activeIndex == i
        return Button {
            onSelectWorkspace(i)
        } label: {
            // 起了名就把名字画在序号 / ■ 的位置上：活动态照旧是重音色（那本来就是"活动"的标记），
            // 非活动态照旧是前景色 + 空工作区的半透明。
            // 排版（字号、下限宽、留白）在 `WorkspacePill.pill` 里——宽度也是在那个文件里算的
            WorkspacePill.pill(title: title, index: i, active: active,
                               showingTitles: showingTitles)
                .foregroundStyle(active ? theme.accent : theme.foreground)
                .opacity(active || !model.isEmpty(i) ? 1 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 右键改名。名字放不下（或配置关掉）时也照样能改——改名是槽位的事，与显示无关
        .overlay(RightClickCatcher { onRenameWorkspace(i) })
        .accessibilityLabel(title.map { "工作区 \(i + 1)：\($0)" } ?? "工作区 \(i + 1)")
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(clockText(context.date, alt: altClock))
                .foregroundStyle(theme.foreground)
                .onTapGesture { altClock.toggle() }
        }
    }

    private func clockText(_ date: Date, alt: Bool) -> String {
        let fmt = DateFormatter()
        // Omarchy："Sunday 14:32"；点击换 "31 August W36 2026"
        fmt.dateFormat = alt ? "d MMMM 'W'ww yyyy" : "EEEE HH:mm"
        return fmt.string(from: date)
    }

    /// 时钟占多宽。**两种格式都量，取宽的那个**：点一下时钟会换格式，
    /// 只按当前那个算的话，用户点一下日期就可能把整排工作区名字点没了
    private var clockWidth: CGFloat {
        let now = Date()
        return max(WorkspacePill.width(of: clockText(now, alt: false)),
                   WorkspacePill.width(of: clockText(now, alt: true)))
    }

    private var rightSection: some View {
        HStack(spacing: 14) {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                Text("\(stats.cpuPercent)%")
                    .monospacedDigit()
            }
            Image(systemName: stats.networkUp
                  ? (stats.networkWifi ? "wifi" : "network")
                  : "wifi.slash")
            Button { onToggleMute() } label: {
                Image(systemName: stats.muted ? "speaker.slash" : "speaker.wave.2")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stats.muted ? "取消静音" : "静音")
            if let percent = stats.batteryPercent {
                battery(percent)
            }
        }
    }

    @ViewBuilder
    private func battery(_ percent: Int) -> some View {
        let low = percent <= 20 && !stats.batteryCharging
        HStack(spacing: 3) {
            // 充/放电时仅图标；其余 `85%`+图标（Omarchy 语义）；低电量红色预警
            if !stats.batteryCharging || low {
                Text("\(percent)%").monospacedDigit()
            }
            Image(systemName: batterySymbol(percent))
        }
        .foregroundStyle(low ? theme.alert : theme.foreground)
    }

    private func batterySymbol(_ percent: Int) -> String {
        if stats.batteryCharging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// **只吃右键**的一层透明视图。左键（以及别的一切）原样穿过去落到下面那个 `Button` 上——
/// 胶囊的左键语义是"切到这个工作区"，这条一个字都不能变。
/// SwiftUI 没有"右键点了一下"这个手势（`contextMenu` 要的是一份菜单，这里要的是一个对话框），
/// 所以借一块 NSView：`hitTest` 只在当前事件真是右键时才认领自己
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    /// 认领不认领这一下点击。**判据只有事件类型**，单独拎出来是为了测得动：
    /// 这里多认一种类型，胶囊的左键（切工作区）就当场哑掉，而那是要用眼睛才看得出来的回归
    static func claims(_ type: NSEvent.EventType?) -> Bool {
        type == .rightMouseDown || type == .rightMouseUp
    }

    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ nsView: Catcher, context: Context) { nsView.action = action }

    final class Catcher: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) 用不上") }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard RightClickCatcher.claims(NSApp.currentEvent?.type) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action() }
    }
}
