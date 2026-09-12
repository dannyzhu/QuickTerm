import XCTest
@testable import QuickTerm

final class FileManagerLaunchTests: XCTestCase {
    private let home = "/Users/me"

    func testResolveSearchesPathThenCommonInstallDirs() {
        let existing: Set<String> = ["/opt/homebrew/bin/yazi", "/Users/me/.cargo/bin/lf"]
        let exists: (String) -> Bool = { existing.contains($0) }
        XCTAssertEqual(FileManagerLaunch.resolve(program: "yazi", pathEnv: "/usr/bin:/bin", home: home, isExecutable: exists),
                       "/opt/homebrew/bin/yazi",
                       "a GUI process's PATH has no Homebrew: fall back to the common install dirs")
        XCTAssertEqual(FileManagerLaunch.resolve(program: "lf", pathEnv: nil, home: home, isExecutable: exists),
                       "/Users/me/.cargo/bin/lf", "~ expansion")
        XCTAssertEqual(FileManagerLaunch.resolve(program: "yazi", pathEnv: "/custom/bin", home: home,
                                                 isExecutable: { $0 == "/custom/bin/yazi" || existing.contains($0) }),
                       "/custom/bin/yazi", "PATH wins over the built-in dirs")
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
        XCTAssertEqual(FileManagerLaunch.cwdFileArguments(executable: "/x/nnn", cwdFile: "/t/f"), [],
                       "an unsupported program gets no cwd-file flag")
    }

    func testPlanBuildsEscapedCommandAndSession() {
        let plan = FileManagerLaunch.plan(program: "yazi", startDirectory: "/Users/me/my dir", cwdFile: "/tmp/f",
                                          pathEnv: "/x/bin", home: home, isExecutable: { $0 == "/x/bin/yazi" })
        XCTAssertTrue(plan.found)
        // Through a login shell: the whole command is one target for the engine's exec -l wrapper, and
        // the script execs, so it stays a single process.
        XCTAssertTrue(plan.command.hasPrefix("\"${SHELL:-/bin/zsh}\" -l -c "), plan.command)
        XCTAssertTrue(plan.command.contains("exec /x/bin/yazi --cwd-file=/tmp/f "), plan.command)
        XCTAssertTrue(plan.command.contains("my dir"),
                      "a directory with spaces survives verbatim inside the shlex.quote wrapper: \(plan.command)")
        XCTAssertEqual(plan.session, .init(startDirectory: "/Users/me/my dir", cwdFile: "/tmp/f"))
        XCTAssertTrue(plan.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/Users/me/.cargo/bin") ?? false)
        XCTAssertTrue(plan.environment["PATH"]?.hasSuffix(":/x/bin") ?? false, "the original PATH is kept, appended last")
        let plain = FileManagerLaunch.plan(program: "nnn", startDirectory: "/tmp", cwdFile: "/tmp/f",
                                           pathEnv: "/x/bin", home: home, isExecutable: { $0 == "/x/bin/nnn" })
        XCTAssertEqual(plain.command, "\"${SHELL:-/bin/zsh}\" -l -c 'exec /x/bin/nnn /tmp'")
        XCTAssertNil(plain.session.cwdFile, "a program without cwd-file support: quitting just closes the pane")
    }

    func testPlanFallsBackToInstallHintWhenMissing() {
        let plan = FileManagerLaunch.plan(program: "yazi", startDirectory: "/tmp", cwdFile: "/tmp/f",
                                          pathEnv: nil, home: home, isExecutable: { _ in false })
        XCTAssertFalse(plan.found)
        XCTAssertNil(plan.session.cwdFile)
        XCTAssertTrue(plan.command.contains("brew install yazi"), plan.command)
        XCTAssertTrue(plan.command.hasPrefix("\"${SHELL:-/bin/zsh}\" -l -c "), plan.command)
        XCTAssertTrue(plan.command.contains("exec \"$SHELL\" -l"),
                      "after the hint it drops into an interactive login shell, so the pane does not close immediately")
        XCTAssertFalse(plan.command.contains("-c '${SHELL"),
                       "the inner script must not use ${...:-...}: fish does not understand it")
    }

    func testNextDirectoryOnlyWhenChangedAndExists() {
        let session = FileManagerLaunch.Session(startDirectory: "/Users/me/proj", cwdFile: "/tmp/f")
        let dirs: (String) -> Bool = { ["/Users/me/proj", "/Users/me/other"].contains($0) }
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in nil }, isDirectory: dirs), "no file")
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/Users/me/proj/\n" }, isDirectory: dirs),
                     "directory unchanged")
        XCTAssertEqual(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/Users/me/other\n" }, isDirectory: dirs),
                       "/Users/me/other")
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: session, read: { _ in "/gone" }, isDirectory: dirs),
                     "directory does not exist")
        let noFile = FileManagerLaunch.Session(startDirectory: "/tmp", cwdFile: nil)
        XCTAssertNil(FileManagerLaunch.nextDirectory(session: noFile, read: { _ in "/Users/me/other" }, isDirectory: dirs))
    }
}
