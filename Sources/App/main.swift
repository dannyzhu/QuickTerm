import AppKit
import GhosttyKit

// libghostty's global init has to run before NSApplicationMain (same as Ghostty's own entry point).
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write(Data("ghostty_init failed\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
