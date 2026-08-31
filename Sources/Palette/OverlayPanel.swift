import SwiftUI

/// 居中浮动面板类型（Walker 风格，spec §1.4/§4.5/§4.6）
enum OverlayPanel: Equatable {
    case themes
    case backgrounds
    case keybindings   // M4：Cmd+K 速查
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
        VStack(alignment: .leading, spacing: 8) {
            if theme.current.backgroundURLs.isEmpty {
                Text("当前主题没有背景图（显示纯色）")
                    .padding(20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(Array(theme.current.backgroundURLs.enumerated()), id: \.offset) { index, url in
                        WallpaperThumb(url: url)
                            .frame(height: 76)
                            .clipped()
                            .overlay(Rectangle().stroke(
                                model.panelSelection == index ? theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { onChoose(index) }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: 快捷键速查（M4，数据来自映射表本身）

    private var keybindingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(KeybindingMap().displayBindings(), id: \.action) { entry in
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
