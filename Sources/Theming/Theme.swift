import SwiftUI

/// One Omarchy-shaped theme bundle: `<dir>/{colors.toml, backgrounds/*}`.
struct Theme: Identifiable, Equatable {
    let name: String              // directory name, e.g. "tokyo-night"
    let isLight: Bool             // colors.toml says mode = "light"
    let colors: [String: String]  // key -> "#RRGGBB"
    let backgroundURLs: [URL]     // wallpapers, sorted

    var id: String { name }
    var displayName: String {
        name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    func hex(_ key: String) -> String? { colors[key] }

    func color(_ key: String) -> Color? {
        guard let hex = colors[key] else { return nil }
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0)
    }

    /// Parse colors.toml (a minimal TOML subset: flat `key = "value"` lines plus # comments).
    static func parseColors(toml: String) -> (colors: [String: String], isLight: Bool) {
        var colors: [String: String] = [:]
        var isLight = false
        for rawLine in toml.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                // Quoted value: read up to the closing quote, which drops a trailing comment
                // for free.
                let inner = value.dropFirst()
                if let endQuote = inner.firstIndex(of: "\"") {
                    value = String(inner[..<endQuote])
                }
            } else if let hash = value.firstIndex(of: "#") {
                // Trailing comment on a bare value.
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if key == "mode" { isLight = (value == "light") } else { colors[key] = value }
        }
        return (colors, isLight)
    }

    /// Load from a theme directory; nil when it has no colors.toml.
    static func load(from dir: URL) -> Theme? {
        let tomlURL = dir.appendingPathComponent("colors.toml")
        guard let toml = try? String(contentsOf: tomlURL, encoding: .utf8) else { return nil }
        let parsed = parseColors(toml: toml)
        let bgDir = dir.appendingPathComponent("backgrounds")
        let backgrounds = ((try? FileManager.default.contentsOfDirectory(
            at: bgDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Theme(
            name: dir.lastPathComponent,
            isLight: parsed.isLight,
            colors: parsed.colors,
            backgroundURLs: backgrounds)
    }
}
