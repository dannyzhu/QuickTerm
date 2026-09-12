import Foundation

/// `quickterm install-cli`: symlink ourselves onto PATH, the same trick VS Code's `code` uses.
/// **Never asks for administrator privileges**: if /usr/local/bin is not writable, fall back to
/// ~/.local/bin and print a PATH hint.
enum InstallCLI {
    struct Result: Codable {
        var installed: [String]
        var source: String
        var directory: String
        var pathHint: String?
        var note: String?
    }

    static func run(alias: String?, directory override: String?) throws -> Result {
        let source = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().standardizedFileURL.path
        // Gatekeeper's App Translocation: a randomized read-only path, so the symlink dangles the
        // moment the app quits.
        if source.contains("/AppTranslocation/") {
            throw Failure("""
            QuickTerm is running from a read-only quarantined path (App Translocation).
            Move QuickTerm.app into /Applications, open it once from there, then try again.
            """)
        }
        let candidates = override.map { [($0 as NSString).expandingTildeInPath] }
            ?? ["/usr/local/bin",
                (("~/.local/bin") as NSString).expandingTildeInPath]
        var chosen: String?
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) {
                // We only create ~/.local/bin ourselves. If /usr/local/bin does not exist, skip
                // it: creating that one needs administrator privileges.
                guard candidate.hasPrefix(NSHomeDirectory()) else { continue }
                try? FileManager.default.createDirectory(atPath: candidate,
                                                         withIntermediateDirectories: true)
            }
            if FileManager.default.isWritableFile(atPath: candidate) { chosen = candidate; break }
        }
        guard let directory = chosen else {
            throw Failure("No writable install directory (tried: \(candidates.joined(separator: ", "))). "
                          + "Pass --dir <dir> to name a directory you can write to.")
        }

        var installed: [String] = []
        for name in ["quickterm"] + (alias.map { [$0] } ?? []) {
            let destination = (directory as NSString).appendingPathComponent(name)
            if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: destination),
               existing == source {
                installed.append(destination)
                continue
            }
            if FileManager.default.fileExists(atPath: destination)
                || (try? FileManager.default.attributesOfItem(atPath: destination)) != nil {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
            installed.append(destination)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let onPath = path.split(separator: ":").contains { $0 == Substring(directory) }
        return Result(
            installed: installed,
            source: source,
            directory: directory,
            pathHint: onPath ? nil
                : "Add \(directory) to PATH: echo 'export PATH=\"\(directory):$PATH\"' >> ~/.zshrc",
            note: "Run this again after upgrading or moving QuickTerm.app; the symlink goes stale.")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
