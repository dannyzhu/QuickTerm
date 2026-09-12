import SwiftUI

/// The kinds of centered floating panel (Walker style, spec §1.4/§4.5/§4.6).
enum OverlayPanel: Equatable {
    case themes
    case backgrounds
    case keybindings   // Cmd+K cheat sheet
    case menu          // Cmd+Alt+Space main menu
}

/// Main menu entries (the spec §4.6 v1 list).
enum MenuEntry: Int, CaseIterable {
    case newTerminal, fileManager, browser, themes, backgrounds, visibleColumns
    case toggleBar, toggleGaps, toggleOpacity
    case keybindings, settings, about

    /// Looked up on every read rather than stored: `OverlayPanelView` observes `Localization`,
    /// so a language change re-renders the panel and every row picks up the new wording.
    var title: String {
        switch self {
        case .newTerminal: L("palette.menu.new-terminal")
        case .fileManager: L("palette.menu.file-manager")
        case .browser: L("palette.menu.new-browser")
        case .themes: L("palette.menu.themes")
        case .backgrounds: L("palette.menu.backgrounds")
        case .visibleColumns: L("palette.menu.visible-columns")
        case .toggleBar: L("palette.menu.toggle-bar")
        case .toggleGaps: L("palette.menu.toggle-gaps")
        case .toggleOpacity: L("palette.menu.toggle-opacity")
        case .keybindings: L("palette.menu.keybindings")
        case .settings: L("palette.menu.settings")
        case .about: L("palette.menu.about")
        }
    }

    var symbol: String {
        switch self {
        case .newTerminal: "plus.rectangle"
        case .fileManager: "folder"
        case .browser: "globe"
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

/// The generic Walker-style centered panel: Monaco 18, a 2px accent border, square corners, and a
/// background at 0.95 alpha.
/// Keyboard navigation (↑↓ / Return / Esc) comes from MainWindowController's monitor driving
/// model.panelSelection.
struct OverlayPanelView: View {
    /// Fixed column count for the backgrounds grid (shared by the layout and by the row step of
    /// keyboard navigation).
    static let backgroundsColumns = 3

    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject private var i18n: Localization
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

    // MARK: Theme picker (name + an 8-color swatch strip + a light marker, spec §4.5)

    private var themeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(theme.themes.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Text(item.displayName)
                            if item.isLight {
                                Text(i18n("palette.theme.light-badge"))
                                    .font(.custom("Monaco", size: 11)).opacity(0.6)
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

    // MARK: Background picker (a grid of thumbnails, spec §4.3)

    private var backgroundGrid: some View {
        let choices = theme.backgroundChoices
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: Self.backgroundsColumns), spacing: 8) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, url in
                        WallpaperThumb(url: url)
                            .frame(height: 76)
                            .clipped()
                            .overlay(Rectangle().stroke(
                                model.panelSelection == index ? theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { onChoose(index) }
                    }
                    // Entry point for picking your own image (copied into
                    // ~/.config/quickterm/backgrounds, shared by every theme)
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(i18n("palette.background.choose-image"))
                            .font(.custom("Monaco", size: 11))
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
                Text(i18n("palette.background.empty"))
                    .font(.custom("Monaco", size: 11)).opacity(0.6)
                    .padding([.horizontal, .bottom], 12)
            }
        }
    }

    // MARK: Main menu (Cmd+Alt+Space, spec §4.6)

    private var menuList: some View {
        VStack(spacing: 0) {
            ForEach(MenuEntry.allCases, id: \.rawValue) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.symbol).frame(width: 20)
                    if entry == .visibleColumns {
                        Text(i18n("palette.menu.visible-columns-value",
                                  model.visibleColumnsDisplay))
                        Text(i18n("palette.menu.visible-columns-hint"))
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

    // MARK: Keybinding cheat sheet (the data comes from the binding table itself)

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

/// A wallpaper thumbnail or full-size image loaded from a local file (with simple caching).
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
