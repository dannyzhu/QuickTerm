import Foundation

/// The release notes an update sheet shows: fetched from the release's own assets in the UI
/// language and flattened from Markdown to plain text for the house scrollable text area.
enum ReleaseNotes {
    static let repository = "dannyzhu/QuickTerm"
    private static let versionPattern = #"^\d+\.\d+\.\d+$"#

    /// Only a three-part version is ever put into a URL.
    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: versionPattern, options: .regularExpression) != nil
    }

    /// `QuickTerm-<ver>-notes.md` / `-notes.zh-CN.md`, uploaded by make-release.sh next to the DMG
    /// (same host as the update itself, unlike raw.githubusercontent.com).
    static func assetURL(version: String, language: AppLanguage) -> URL? {
        guard isValidVersion(version) else { return nil }
        let suffix = language == .zh ? "-notes.zh-CN.md" : "-notes.md"
        return URL(string: "https://github.com/\(repository)/releases/download/v\(version)/QuickTerm-\(version)\(suffix)")
    }

    static func releasePageURL(version: String) -> URL? {
        guard isValidVersion(version) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")
    }

    /// The UI language first, then the other one.
    static func candidateURLs(version: String, language: AppLanguage) -> [URL] {
        let other: AppLanguage = language == .zh ? .en : .zh
        return [assetURL(version: version, language: language),
                assetURL(version: version, language: other)].compactMap { $0 }
    }

    /// Headings lose their `#`, list markers become `•`, inline code and emphasis lose their
    /// markers, links become `text (url)`, fenced code is kept verbatim.
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(raw)
                continue
            }
            var line = raw
            if let heading = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(heading)
            }
            if let marker = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = String(line[marker].prefix { $0 == " " || $0 == "\t" })
                line = indent + "• " + String(line[marker.upperBound...])
            }
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)",
                                             options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches and caches the notes per version; a failure never blocks the sheet.
    @MainActor
    final class Loader {
        var session: URLSession = .shared
        var timeout: TimeInterval = 10
        private var cache: [String: String] = [:]

        /// The notes in `language`, else the other language, else `fallback` (the appcast's
        /// description), else nil.
        func notes(version: String, language: AppLanguage, fallback: String?) async -> String? {
            let key = "\(version)|\(language.rawValue)"
            if let hit = cache[key] { return hit }
            for url in ReleaseNotes.candidateURLs(version: version, language: language) {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let plain = ReleaseNotes.plainText(fromMarkdown: text)
                cache[key] = plain
                return plain
            }
            if let fallback, !fallback.isEmpty { return ReleaseNotes.plainText(fromMarkdown: fallback) }
            return nil
        }
    }
}
