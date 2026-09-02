import SwiftUI

/// 居中浮动面板类型（Walker 风格，spec §1.4/§4.5/§4.6）
enum OverlayPanel: Equatable {
    case themes
    case backgrounds
    case keybindings   // Cmd+K 速查
    case menu          // Cmd+Alt+Space 主菜单
}

/// 主菜单条目（spec §4.6 v1 清单）
enum MenuEntry: Int, CaseIterable {
    case newTerminal, themes, backgrounds, visibleColumns
    case toggleBar, toggleGaps, toggleOpacity
    case keybindings, settings, about

    var title: String {
        switch self {
        case .newTerminal: "新建终端"
        case .themes: "主题…"
        case .backgrounds: "背景…"
        case .visibleColumns: "每屏列数"
        case .toggleBar: "顶栏 显示/隐藏"
        case .toggleGaps: "Gaps 开关"
        case .toggleOpacity: "透明度开关"
        case .keybindings: "快捷键速查"
        case .settings: "设置（config.toml）"
        case .about: "关于 QuickTerm"
        }
    }

    var symbol: String {
        switch self {
        case .newTerminal: "plus.rectangle"
        case .themes: "paintpalette"
        case .backgrounds: "photo"
        case .visibleColumns: "rectangle.split.3x1"
        case .toggleBar: "menubar.rectangle"
        case .toggleGaps: "squareshape.split.2x2"
        case .toggleOpacity: "circle.lefthalf.filled"
        case .keybindings: "keyboard"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// Walker 风格通用居中面板：Monaco 18、2px accent 边框、直角、0.95 透明背景。
/// 键盘导航（↑↓/回车/Esc）由 MainWindowController 的监视器驱动 model.panelSelection。
struct OverlayPanelView: View {
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject var model: WorkspaceModel
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.activePanel {
            case .themes: themeList
            case .backgrounds: backgroundGrid
            case .keybindings: keybindingList
            case .menu: menuList
            case nil: EmptyView()
            }
        }
        .frame(maxWidth: panelWidth)
        .background(theme.background.opacity(0.95))
        .overlay(Rectangle().stroke(theme.accent, lineWidth: 2))
        .font(.custom("Monaco", size: 15))
        .foregroundStyle(theme.foreground)
    }

    private var panelWidth: CGFloat {
        model.activePanel == .keybindings ? 560 : 420
    }

    // MARK: 主题选择器（名称 + 8 色色板 + light 标记，spec §4.5）

    private var themeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(theme.themes.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text(item.displayName)
                            if item.isLight {
                                Text("light").font(.custom("Monaco", size: 11)).opacity(0.6)
                            }
                            Spacer()
                            swatches(item)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(model.panelSelection == index
                                    ? theme.foreground.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { onChoose(index) }
                        .id(index)
                    }
                }
            }
            .frame(maxHeight: 420)
            .onChange(of: model.panelSelection) { _, sel in
                proxy.scrollTo(sel)
            }
        }
    }

    private func swatches(_ item: Theme) -> some View {
        HStack(spacing: 2) {
            ForEach(["red", "yellow", "green", "cyan", "blue", "magenta", "foreground", "accent"],
                    id: \.self) { key in
                Rectangle()
                    .fill(item.color(key) ?? .clear)
                    .frame(width: 10, height: 14)
            }
        }
    }

    // MARK: 背景选择器（缩略图网格，spec §4.3）

    private var backgroundGrid: some View {
        let choices = theme.backgroundChoices
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, url in
                        WallpaperThumb(url: url)
                            .frame(height: 76)
                            .clipped()
                            .overlay(Rectangle().stroke(
                                model.panelSelection == index ? theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { onChoose(index) }
                    }
                    // 自选图片入口（拷入 ~/.config/quickterm/backgrounds，全主题共用）
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("选择图片…").font(.custom("Monaco", size: 11))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .background(theme.foreground.opacity(
                        model.panelSelection == choices.count ? 0.12 : 0.05))
                    .overlay(Rectangle().stroke(
                        model.panelSelection == choices.count ? theme.accent
                            : theme.foreground.opacity(0.3), lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { onChoose(choices.count) }
                }
                .padding(12)
            }
            .frame(maxHeight: 420)
            if choices.isEmpty {
                Text("当前主题没有背景图（显示纯色）——可选择自己的图片")
                    .font(.custom("Monaco", size: 11)).opacity(0.6)
                    .padding([.horizontal, .bottom], 12)
            }
        }
    }

    // MARK: 主菜单（Cmd+Alt+Space，spec §4.6）

    private var menuList: some View {
        VStack(spacing: 0) {
            ForEach(MenuEntry.allCases, id: \.rawValue) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.symbol).frame(width: 20)
                    if entry == .visibleColumns {
                        Text("每屏列数：\(model.visibleColumnsDisplay)")
                        Text("（回车循环 2→3→4）")
                            .font(.custom("Monaco", size: 11)).opacity(0.6)
                    } else {
                        Text(entry.title)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(model.panelSelection == entry.rawValue
                            ? theme.foreground.opacity(0.07) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { onChoose(entry.rawValue) }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: 快捷键速查（数据来自映射表本身）

    private var keybindingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.keybindingRows, id: \.action) { entry in
                    HStack {
                        Text(entry.combo).frame(width: 110, alignment: .leading)
                        Text(entry.action.help)
                        Spacer()
                    }
                    .font(.custom("Monaco", size: 13))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 460)
    }
}

/// 本地文件壁纸缩略图/全幅（带简单缓存）
struct WallpaperThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Color.clear.onAppear { image = NSImage(contentsOf: url) }
            }
        }
    }
}
