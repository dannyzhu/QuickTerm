import XCTest
@testable import QuickTerm

final class FileManagerLaunchTests: XCTestCase {
    private let home = "/Users/me"

    func testResolveSearchesPathThenCommonInstallDirs() {
        let existing: Set<String> = ["/opt/homebrew/bin/yazi", "/Users/me/.cargo/bin/lf"]
        let exists: (String) -> Bool = { existing.contains($0) }
        XCTAssertEqual(FileManagerLaunch.resolve(program: "yazi", pathEnv: "/usr/bin:/bin", home: home, isExecutable: exists),
                       "/opt/homebrew/bin/yazi", "GUI 进程 PATH 没有 Homebrew：按常见安装目录补找")
        XCTAssertEqual(FileManagerLaunch.resolve(program: "lf", pathEnv: nil, home: home, isExecutable: exists),
                       "/Users/me/.cargo/bin/lf", "~ 展开")
        XCTAssertEqual(FileManagerLaunch.resolve(program: "yazi", pathEnv: "/custom/bin", home: home,
                                                 isExecutable: { $0 == "/custom/bin/yazi" || existing.contains($0) }),
                       "/custom/bin/yazi", "PATH 优先于内置目录")
        XCTAssertNil(FileManagerLaunch.resolve(program: "nope", pathEnv: "/usr/bin", home: home, isExecutable: exists))
        XCTAssertNil(FileManagerLaunch.resolve(program: "   ", pathEnv: "/usr/bin", home: home, isExecutable: exists))
    }

    func testResolveTreatsSlashAsPath() {
        let exists: (String) -> Bool = { $0 == "/Users/me/bin/fm" }
        XCTAssertEqual(FileManagerLaunch.resolve(program: "~/bin/fm", pathEnv: nil, home: home, isExecutable: exists),
                       "/Users/me/bin/fm")
        XCTAssertNil(FileManagerLaunch.resolve(program: "/nowhere/fm", pathEnv: nil, home: home, isExecutable: exists))
    }

    func testCwdFileArgumentsPerProgram() {
        XCTAssertEqual(FileManagerLaunch.cwdFileArguments(executable: "/x/yazi", cwdFile: "/t/f"), ["--cwd-file=/t/f"])
        XCTAssertEqual(FileManagerLaunch.cwdFileArguments(executable: "/x/lf", cwdFile: "/t/f"), ["-last-dir-path", "/t/f"])
        XCTAssertEqual(FileManagerLaunch.cwdFileArguments(executable: "/x/ranger", cwdFile: "/t/f"), ["--choosedir=/t/f"])
        XCTAssertEqual(FileManagerLaunch.cwdFileArguments(executable: "/x/nnn", cwdFile: "/t/f"), [], "不支持的程序不传")
    }

    func testPlanBuildsEscapedCommandAndSession() {
        let plan = FileManagerLaunch.plan(program: "yazi", startDirectory: "/Users/me/my dir", cwdFile: "/tmp/f",
                                          pathEnv: "/x/bin", home: home, isExecutable: { $0 == "/x/bin/yazi" })
        XCTAssertTrue(plan.found)
        // 经登录 shell：整条命令对引擎的 exec -l 包装是单个目标；脚本 exec 成单进程
        XCTAssertTrue(plan.command.hasPrefix("\"${SHELL:-/bin/zsh}\" -l -c "), plan.command)
        XCTAssertTrue(plan.command.contains("exec /x/bin/yazi --cwd-file=/tmp/f "), plan.command)
        XCTAssertTrue(plan.command.contains("my dir"), "含空格的目录按 shlex.quote 包裹后原文保留：\(plan.command)")
        XCTAssertEqual(plan.session, .init(startDirectory: "/Users/me/my dir", cwdFile: "/tmp/f"))
        XCTAssertTrue(plan.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/Users/me/.cargo/bin") ?? false)
        XCTAssertTrue(plan.environment["PATH"]?.hasSuffix(":/x/bin") ?? false, "原 PATH 保留在后")
        let plain = FileManagerLaunch.plan(program: "nnn", startDirectory: "/tmp", cwdFile: "/tmp/f",
                                           pathEnv: "/x/bin", home: home, isExecutable: { $0 == "/x/bin/nnn" })
        XCTAssertEqual(plain.command, "\"${SHELL:-/bin/zsh}\" -l -c 'exec /x/bin/nnn /tmp'")
        XCTAssertNil(plain.session.cwdFile, "不支持 cwd 文件的程序：退出只关 pane")
    }

    func testPlanFallsBackToInstallHintWhenMissing() {
        let plan = FileManagerLaunch.plan(program: "yazi", startDirectory: "/tmp", cwdFile: "/tmp/f",
                                          pathEnv: nil, home: home, isExecutable: { _ in false })
        XCTAssertFalse(plan.found)
        XCTAssertNil(plan.session.cwdFile)
        XCTAssertTrue(plan.command.contains("brew install yazi"), plan.command)
        XCTAssertTrue(plan.command.hasPrefix("\"${SHELL:-/bin/zsh}\" -l -c "), plan.command)
        XCTAssertTrue(plan.command.contains("exec \"$SHELL\" -l"), "提示后进入交互登录 shell，pane 不立即关闭")
        XCTAssertFalse(plan.command.contains("-c '${SHELL"), "内层脚本不能用 ${…:-…}（fish 不认）")
    }

    func testNextDirectoryOnlyWhenChangedAndExists() {
        let session = FileManagerLaunch.Session(startDirectory: "/Users/me/proj", cwdFile: "/tmp/f")
        let dirs: (String) -> Bool = { ["/Users/me/proj", "/Users/me/other"].contains($0) }
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in nil }, isDirectory: dirs), "无文件")
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/Users/me/proj/\n" }, isDirectory: dirs), "目录未变")
        XCTAssertEqual(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/Users/me/other\n" }, isDirectory: dirs),
                       "/Users/me/other")
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/gone" }, isDirectory: dirs), "目录不存在")
        let noFile = FileManagerLaunch.Session(startDirectory: "/tmp", cwdFile: nil)
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: noFile, read: { _ in "/Users/me/other" }, isDirectory: dirs))
    }
}
