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
    let onToggleMute: () -> Void

    @State private var altClock = false

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
        HStack(spacing: 8) {
            Text("◆")
                .foregroundStyle(theme.accent)
                .accessibilityLabel("QuickTerm")
            HStack(spacing: 3) {
                ForEach(0..<model.layouts.count, id: \.self) { i in
                    workspacePill(i)
                }
            }
            controlFlash
        }
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

    private func workspacePill(_ i: Int) -> some View {
        Button {
            onSelectWorkspace(i)
        } label: {
            Text(model.activeIndex == i ? "■" : "\(i + 1)")
                .frame(minWidth: 18, minHeight: 20)
                .foregroundStyle(model.activeIndex == i ? theme.accent : theme.foreground)
                .opacity(model.activeIndex == i || !model.isEmpty(i) ? 1 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("工作区 \(i + 1)")
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(clockText(context.date))
                .foregroundStyle(theme.foreground)
                .onTapGesture { altClock.toggle() }
        }
    }

    private func clockText(_ date: Date) -> String {
        let fmt = DateFormatter()
        // Omarchy："Sunday 14:32"；点击换 "31 August W36 2026"
        fmt.dateFormat = altClock ? "d MMMM 'W'ww yyyy" : "EEEE HH:mm"
        return fmt.string(from: date)
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
