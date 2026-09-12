import Foundation

/// Launch plan for a file manager pane (a TUI running inside a terminal pane; yazi by default) -
/// pure logic, so it is testable.
/// This is the counterpart of Omarchy's Super+Shift+F file manager: it starts in a new pane at the
/// focused pane's directory, and on exit, if the directory has changed, a terminal opens in its
/// place (the cd semantics of yazi's official `y` wrapper function).
struct FileManagerLaunch {
    /// The live session: on exit we read the cwd file to decide whether to open a terminal in its
    /// place
    struct Session: Equatable {
        let startDirectory: String
        /// Path of the temp file, when the program supports "write the last directory on exit";
        /// nil when it does not
        let cwdFile: String?
    }

    /// The string handed to libghostty's `command`. On macOS the engine starts it as
    /// `login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`, so the whole
    /// command has to be a **single exec target**. We always shape it as
    /// `"${SHELL:-/bin/zsh}" -l -c '<script>'`: go through the user's login shell (which reads
    /// zprofile/bash_profile - the Homebrew PATH, EDITOR and so on, without which yazi's previewers
    /// and openers cannot find ffmpeg, pdftoppm, nvim, ...) and then `exec` down to a single
    /// process.
    let command: String
    /// The session: when the program was not found, cwdFile is nil (the command is then the hint
    /// message plus an interactive login shell)
    let session: Session
    /// Whether the program was found
    let found: Bool
    /// Extra environment (PATH is pre-seeded with the usual install directories; the login shell's
    /// path_helper keeps them)
    let environment: [String: String]

    static let defaultProgram = "yazi"
    /// A GUI process's PATH contains only the system directories, so programs installed by
    /// Homebrew or cargo have to be looked up in the usual install directories as well.
    static let extraSearchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin", "~/.local/bin",
                                  "/opt/local/bin", "/usr/bin", "/bin"]

    /// Resolve the program: anything containing "/" is treated as a path (with ~ expanded);
    /// otherwise search PATH plus the usual install directories for an executable.
    static func resolve(program: String, pathEnv: String?, home: String,
                        isExecutable: (String) -> Bool) -> String? {
        let expand: (String) -> String = { $0.hasPrefix("~/") ? home + $0.dropFirst(1) : $0 }
        let name = program.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            let path = expand(name)
            return isExecutable(path) ? path : nil
        }
        var dirs = (pathEnv ?? "").split(separator: ":").map(String.init)
        dirs += extraSearchDirs.map(expand)
        var seen = Set<String>()
        for dir in dirs where !dir.isEmpty && seen.insert(dir).inserted {
            let path = dir + "/" + name
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// The per-TUI flag for "write the last directory on exit"; a program that does not support it
    /// gets nothing (quitting then just closes the pane).
    static func cwdFileArguments(executable: String, cwdFile: String) -> [String] {
        switch (executable as NSString).lastPathComponent {
        case "yazi": return ["--cwd-file=" + cwdFile]
        case "lf": return ["-last-dir-path", cwdFile]
        case "ranger": return ["--choosedir=" + cwdFile]
        default: return []
        }
    }

    static func plan(program: String, startDirectory: String, cwdFile: String,
                     pathEnv: String?, home: String, isExecutable: (String) -> Bool) -> FileManagerLaunch {
        let expand: (String) -> String = { $0.hasPrefix("~/") ? home + $0.dropFirst(1) : $0 }
        let pathDirs = extraSearchDirs.map(expand) + (pathEnv.map { [$0] } ?? [])
        let environment = ["PATH": pathDirs.joined(separator: ":")]
        guard let exe = resolve(program: program, pathEnv: pathEnv, home: home, isExecutable: isExecutable) else {
            let hint = L("window.file-manager.not-found", program)
            // The inner level is parsed by the user's login shell, so use a bare "$SHELL" here:
            // fish does not understand ${...:-...}, and login(1) always sets SHELL anyway.
            let script = "printf '%s\\n' \(Ghostty.Shell.quote(hint)); exec \"$SHELL\" -l"
            return FileManagerLaunch(command: viaLoginShell(script),
                                     session: Session(startDirectory: startDirectory, cwdFile: nil),
                                     found: false, environment: environment)
        }
        let args = cwdFileArguments(executable: exe, cwdFile: cwdFile)
        // shlex.quote-style single quoting, which keeps paths with spaces or special characters
        // safe; `exec` collapses to a single process, so quitting it is the child exiting.
        let script = "exec " + ([exe] + args + [startDirectory]).map(Ghostty.Shell.quote).joined(separator: " ")
        return FileManagerLaunch(command: viaLoginShell(script),
                                 session: Session(startDirectory: startDirectory,
                                                  cwdFile: args.isEmpty ? nil : cwdFile),
                                 found: true, environment: environment)
    }

    /// The user's login shell (login(1) sets SHELL from passwd; zsh is the fallback)
    static let loginShell = "\"${SHELL:-/bin/zsh}\""

    /// `"${SHELL:-/bin/zsh}" -l -c '<script>'`: a single target as far as the engine's `exec -l`
    /// wrapper is concerned
    static func viaLoginShell(_ script: String) -> String {
        "\(loginShell) -l -c \(Ghostty.Shell.quote(script))"
    }

    /// The directory a terminal should open in after the file manager exits: the cwd file exists,
    /// its content is a directory, and it differs from the starting directory. Otherwise nil, and
    /// the pane simply closes.
    static func nextDirectory(session: Session, read: (String) -> String?,
                              isDirectory: (String) -> Bool) -> String? {
        guard let file = session.cwdFile, let raw = read(file) else { return nil }
        let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, isDirectory(dir) else { return nil }
        let a = (dir as NSString).standardizingPath
        let b = (session.startDirectory as NSString).standardizingPath
        return a == b ? nil : dir
    }

    // MARK: Convenience entry points for the real environment

    static func plan(program: String, startDirectory: String, cwdFile: String) -> FileManagerLaunch {
        plan(program: program, startDirectory: startDirectory, cwdFile: cwdFile,
             pathEnv: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory(),
             isExecutable: { path in
                 var isDir: ObjCBool = false
                 return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                     && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
             })
    }

    static func nextDirectory(session: Session) -> String? {
        nextDirectory(session: session,
                      read: { try? String(contentsOfFile: $0, encoding: .utf8) },
                      isDirectory: { path in
                          var isDir: ObjCBool = false
                          return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                      })
    }

    static func cleanup(_ session: Session) {
        if let file = session.cwdFile { try? FileManager.default.removeItem(atPath: file) }
    }
}
