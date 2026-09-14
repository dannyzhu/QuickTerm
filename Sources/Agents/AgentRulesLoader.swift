import Foundation
import OSLog

/// **Where rule files come from** (plan §2.3): the three bundled ones, then the user's own.
///
/// A user file whose `id` matches a bundled one **replaces it whole** rather than merging into
/// it: a half-overridden rule file would be a file the user reads as the whole truth while the
/// bundle quietly supplies the events they deleted. A new id adds an agent.
///
/// A bad file is logged and skipped — one typo must not take the other agents down with it.
enum AgentRulesLoader {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "AgentRules")

    /// The rule files that ship inside the app.
    static let bundledIDs = ["claude-code", "codex", "gemini"]

    /// `~/.config/quickterm/agents`. **Always passed explicitly by a test**: resolving `~` in a
    /// test host would read the developer's own files.
    static var defaultUserDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quickterm/agents", isDirectory: true)
    }

    struct Result {
        var rules: [AgentRules] = []
        /// `(path or id, why)` for every file that was skipped.
        var failures: [(String, String)] = []
    }

    /// Load the bundled rules, then let the user's directory override or extend them.
    static func load(bundle: Bundle = .main, userDirectory: URL?) -> Result {
        var result = Result()
        var byID: [String: AgentRules] = [:]
        var order: [String] = []

        for id in bundledIDs {
            guard let url = bundledURL(id, bundle: bundle) else {
                result.failures.append((id, "not in the app bundle"))
                continue
            }
            switch parse(url, expectedID: id) {
            case .success(let rules):
                byID[rules.id] = rules
                order.append(rules.id)
            case .failure(let error):
                result.failures.append((url.lastPathComponent, "\(error)"))
            }
        }

        if let userDirectory {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: userDirectory, includingPropertiesForKeys: nil)) ?? []
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "toml" {
                switch parse(url, expectedID: url.deletingPathExtension().lastPathComponent) {
                case .success(let rules):
                    if byID[rules.id] == nil { order.append(rules.id) }
                    byID[rules.id] = rules
                case .failure(let error):
                    result.failures.append((url.path, "\(error)"))
                }
            }
        }

        result.rules = order.compactMap { byID[$0] }
        for (file, why) in result.failures {
            logger.warning("agent rule file skipped: \(file, privacy: .public) — \(why, privacy: .public)")
        }
        return result
    }

    /// `Resources/agents/<id>.toml`. Looked up inside the `agents` subdirectory first and then
    /// without it: xcodegen enumerates `Resources` as a group, so the file may land either beside
    /// its folder or flattened into the bundle root depending on how the project was generated.
    static func bundledURL(_ id: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: id, withExtension: "toml", subdirectory: "agents")
            ?? bundle.url(forResource: id, withExtension: "toml")
    }

    private static func parse(_ url: URL, expectedID: String) -> Swift.Result<AgentRules, any Error> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(AgentRulesError.missing(key: "the file could not be read"))
        }
        do {
            let rules = try AgentRules.parse(text)
            guard rules.id == expectedID else {
                return .failure(AgentRulesError.invalid(
                    key: "id",
                    reason: "\(rules.id) does not match the file name \(expectedID).toml"))
            }
            return .success(rules)
        } catch {
            return .failure(error)
        }
    }
}
