import Foundation
import OSLog

/// **The one shell script every agent's hook entry runs** (plan §2.6).
///
/// One script for all three agents, with the agent id passed as `$1`, because what an agent's
/// config file holds must stay a single line that a human can read and delete. Everything the
/// script decides, it decides from the environment QuickTerm injects into a pane:
///
/// - **outside QuickTerm it does nothing.** No socket, no pane, no pane token in the environment
///   and it exits 0 before spawning anything, so the very same entry in `~/.claude/settings.json`
///   is harmless in Terminal.app, VS Code, tmux, a CI runner or an ssh session. That is what makes
///   installing it a user-level decision rather than a per-project one.
/// - **it never fails the agent.** Every branch exits 0 — a missing binary, a binary that exits 2
///   because QuickTerm is not running, a socket nobody is listening on. A hook that can fail is a
///   hook that can stop somebody's turn, and no state report is worth that.
/// - **the binary path is baked in.** `QT_BIN` is written at install time from the running app's
///   own bundle and is never read from the environment: a hook entry is trusted, user-level
///   configuration, and a path taken from `$QUICKTERM_BIN` would let a project `.envrc`,
///   `nix develop` or a Makefile choose which binary runs on every single prompt.
enum HookScript {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "AgentHooks")

    /// The file name, and — because the command string written into an agent's config is
    /// `'<path to this>' <agent id>` — **the marker that says an entry is ours**. There is
    /// deliberately no extra JSON key carrying "quickterm": Claude Code and Codex validate their
    /// settings files and an unknown key can make them refuse the whole thing.
    static let fileName = "quickterm-agent-state.sh"

    /// What `isOurs` looks for. The leading slash matters: it is the path separator that makes
    /// this a path of ours rather than a word that happens to appear in somebody's own command.
    static let marker = "/" + fileName

    /// Written as the second line and read back by the launch self-heal. Bump it (v2, …) only
    /// together with a rewrite rule: a script without a marker we recognise is somebody else's
    /// file and is never overwritten.
    static let versionMarker = "# quickterm-hook-script v1"

    // MARK: The text

    /// The script, with `binary` baked in. Throws when the path cannot be single-quoted safely —
    /// see `quoted(_:)`.
    static func text(binary: String) throws -> String {
        guard let quoted = quoted(binary) else {
            throw ControlErrorBody(
                .badRequest, "The app path contains a quote (\(binary)), which cannot be written into a shell script",
                hint: "Move QuickTerm.app to a path without an apostrophe and install the hooks again.")
        }
        return """
        #!/bin/sh
        \(versionMarker)
        # Installed by QuickTerm. Reports the agent's lifecycle event to the QuickTerm pane it runs in.
        # Outside QuickTerm (no socket in the environment) it does nothing and exits 0 immediately,
        # so the same hook entry is harmless in Terminal.app, VS Code, tmux or CI.
        # The CLI path is baked in on purpose. This script runs from a trusted, user-level hook entry;
        # a path taken from the environment would let a project .envrc, `nix develop` or a Makefile
        # choose which binary runs on every prompt. Never read QUICKTERM_BIN here.
        QT_BIN=\(quoted)
        [ -n "${QUICKTERM_SOCKET:-}" ] && [ -n "${QUICKTERM_PANE:-}" ] && [ -n "${QUICKTERM_PANE_TOKEN:-}" ] || exit 0
        [ -x "$QT_BIN" ] || exit 0
        "$QT_BIN" agent-event --agent "$1" </dev/stdin >/dev/null 2>&1
        exit 0

        """
    }

    /// `/Applications/QuickTerm.app/…` -> `'/Applications/QuickTerm.app/…'`, or nil when the path
    /// holds a `'`.
    ///
    /// The usual `'\''` escape would work in `sh`, but **refusing is the honest answer**: the same
    /// path is also written into another program's config file, quoted by rules we do not own
    /// (Claude Code runs the command through `sh -c`), and a path we cannot quote once we cannot
    /// quote twice. A home directory with an apostrophe is rare; silently mis-quoting it is not
    /// something the user would ever find.
    static func quoted(_ path: String) -> String? {
        guard !path.contains("'") else { return nil }
        return "'" + path + "'"
    }

    /// The command string written into an agent's config: the script, single-quoted (a home
    /// directory with a space is not rare at all), then the agent id as `$1`.
    static func command(scriptPath: String, agent: String) -> String? {
        guard let quoted = quoted(scriptPath) else { return nil }
        return quoted + " " + agent
    }

    /// Is this config entry ours? **The path inside the command string is the whole marker.** A
    /// user who wrote the same line by hand is therefore treated as having installed it — which
    /// is true, and means `hooks uninstall` cleans up after them too.
    static func isOurs(command: String) -> Bool { command.contains(marker) }

    /// The binary baked into an existing script, or nil when the file is not one of ours.
    static func bakedBinary(in text: String) -> String? {
        guard text.contains(versionMarker) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix("QT_BIN='") && line.hasSuffix("'") {
            return String(line.dropFirst("QT_BIN='".count).dropLast())
        }
        return nil
    }

    // MARK: On disk

    /// The `quickterm` CLI of the **running** app — what a fresh install bakes in.
    static var bundledBinary: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport/quickterm").path
    }

    /// Write the script (directory `0700`, file `0755`), and answer whether anything changed.
    ///
    /// Refuses a symlink outright: writing through a link means writing wherever somebody else
    /// pointed it, and this file is executed on every prompt of every agent.
    @discardableResult
    static func write(to path: String, binary: String) throws -> Bool {
        let text = try text(binary: binary)
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default

        if isSymlink(path) {
            throw ControlErrorBody(
                .badRequest, "The hook script path \(path) is a symlink; QuickTerm will not write through it",
                hint: "Remove the link and install again — QuickTerm writes the script itself.")
        }
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text,
           isExecutable(path) {
            return false
        }

        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // Same directory, then rename: a half-written script is a script that runs on the next
        // prompt, and `rename(2)` is the only way to be sure nobody ever sees one.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temp, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        guard rename(temp.path, path) == 0 else {
            try? manager.removeItem(at: temp)
            throw ControlErrorBody(.failed, "Could not write the hook script to \(path) (errno \(errno))")
        }
        return true
    }

    /// What `hooks status` reports about the script.
    static func status(path: String, expectedBinary: String? = nil) -> HookScriptStatus {
        let link = isSymlink(path)
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return HookScriptStatus(path: path, exists: false, isSymlink: link)
        }
        let baked = bakedBinary(in: text)
        let bakedExists = baked.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
        // `ok` is the whole question a user has: will the next hook actually report anything?
        // Ours, executable, not a link, and pointing at a binary that is still there.
        let ok = !link && baked != nil && bakedExists && isExecutable(path)
        return HookScriptStatus(path: path, exists: true, isSymlink: link, bakedBinary: baked,
                                bakedBinaryExists: bakedExists, ok: ok)
    }

    /// **The launch self-heal** (plan §2.6). Rewrite the baked path only when the script is there,
    /// is ours, and the binary it names has *gone* — an app moved to the Trash, a `/Applications`
    /// copy replaced by a Homebrew cask, a DerivedData build deleted.
    ///
    /// Deliberately **not** "rewrite whenever a different build is running": a developer's Debug
    /// build starting up must not repoint the hooks of the user's installed QuickTerm, which is
    /// the copy their agents will still be talking to a minute later. A stale-but-present path is
    /// somebody's real choice; a path that is gone is nobody's.
    @discardableResult
    static func healIfStale(path: String, binary: String) -> Bool {
        let current = status(path: path)
        guard current.exists, !current.isSymlink, let baked = current.bakedBinary,
              !current.bakedBinaryExists, baked != binary else { return false }
        do {
            let changed = try write(to: path, binary: binary)
            if changed {
                logger.notice("hook script repointed: \(baked, privacy: .public) is gone, now \(binary, privacy: .public)")
            }
            return changed
        } catch {
            logger.error("hook script self-heal failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Small file questions

    static func isSymlink(_ path: String) -> Bool {
        var buffer = stat()
        guard lstat(path, &buffer) == 0 else { return false }
        return (buffer.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
