import Foundation

/// 文件管理器 pane（TUI，跑在终端 pane 里；默认 yazi）的启动计划——纯逻辑，可测。
/// 对应 Omarchy 的 Super+Shift+F 文件管理器：新 pane 里以焦点 pane 的目录启动；
/// 退出时若目录已变，原位开一个终端（yazi 官方 `y` 包装函数的 cd 语义）。
struct FileManagerLaunch {
    /// 运行期会话：退出时读 cwd 文件决定是否原位开终端
    struct Session: Equatable {
        let startDirectory: String
        /// 程序支持"退出写最后目录"时的临时文件路径；不支持则 nil
        let cwdFile: String?
    }

    /// 传给 libghostty `command` 的字符串。macOS 上引擎以 `login -flp <user> /bin/bash --noprofile --norc
    /// -c "exec -l <command>"` 启动，所以整条命令必须是**单个 exec 目标**：这里统一为
    /// `"${SHELL:-/bin/zsh}" -l -c '<脚本>'`——经用户登录 shell（读 zprofile/bash_profile：Homebrew PATH、
    /// EDITOR 等，yazi 的预览/打开器才能找到 ffmpeg、pdftoppm、nvim…）再 `exec` 成单进程。
    let command: String
    /// 会话：程序未找到时 cwdFile 为 nil（command 是提示信息 + 交互登录 shell）
    let session: Session
    /// 程序是否找到
    let found: Bool
    /// 额外环境（PATH 先补上常见安装目录；登录 shell 的 path_helper 会保留它们）
    let environment: [String: String]

    static let defaultProgram = "yazi"
    /// GUI 进程的 PATH 只有系统目录，Homebrew/cargo 装的程序要按常见安装目录补找
    static let extraSearchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin", "~/.local/bin",
                                  "/opt/local/bin", "/usr/bin", "/bin"]

    /// 找程序：含 "/" 视为路径（展开 ~）；否则按 PATH + 常见安装目录查可执行文件
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

    /// 各 TUI 文件管理器"退出时写最后目录"的参数；不支持的程序不传（退出只关 pane）
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
            // 内层由用户登录 shell 解析：只用裸 "$SHELL"（fish 不认 ${…:-…}；login(1) 总会设置 SHELL）
            let script = "printf '%s\\n' \(Ghostty.Shell.quote(hint)); exec \"$SHELL\" -l"
            return FileManagerLaunch(command: viaLoginShell(script),
                                     session: Session(startDirectory: startDirectory, cwdFile: nil),
                                     found: false, environment: environment)
        }
        let args = cwdFileArguments(executable: exe, cwdFile: cwdFile)
        // shlex.quote 风格单引号包裹（带空格/特殊字符的路径安全）；exec 成单进程，退出即子进程退出
        let script = "exec " + ([exe] + args + [startDirectory]).map(Ghostty.Shell.quote).joined(separator: " ")
        return FileManagerLaunch(command: viaLoginShell(script),
                                 session: Session(startDirectory: startDirectory,
                                                  cwdFile: args.isEmpty ? nil : cwdFile),
                                 found: true, environment: environment)
    }

    /// 用户登录 shell（login(1) 会按 passwd 设置 SHELL；缺省 zsh）
    static let loginShell = "\"${SHELL:-/bin/zsh}\""

    /// `"${SHELL:-/bin/zsh}" -l -c '<script>'`：对引擎的 `exec -l` 包装而言是单个目标
    static func viaLoginShell(_ script: String) -> String {
        "\(loginShell) -l -c \(Ghostty.Shell.quote(script))"
    }

    /// 退出后应在原位开终端的目录：cwd 文件存在、内容是目录、且与起始目录不同；否则 nil（只关 pane）
    static func nextDirectory(session: Session, read: (String) -> String?,
                              isDirectory: (String) -> Bool) -> String? {
        guard let file = session.cwdFile, let raw = read(file) else { return nil }
        let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty, isDirectory(dir) else { return nil }
        let a = (dir as NSString).standardizingPath
        let b = (session.startDirectory as NSString).standardizingPath
        return a == b ? nil : dir
    }

    // MARK: 真实环境便捷入口

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
