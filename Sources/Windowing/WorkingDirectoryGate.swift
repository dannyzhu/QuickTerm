import Darwin
import Foundation
import OSLog

/// TCC（隐私）守卫：确认一个工作目录**真的能打开**，再把它交给 libghostty。
///
/// 为什么需要（2026-09-11 启动挂死）：
/// macOS 把 `~/Desktop` `~/Documents` `~/Downloads` 划成受保护目录。授权是按**代码签名身份**
/// （ad-hoc 签名 = 按 cdhash）记在 TCC 里的，所以任何一次重新构建出来的二进制都不在授权之列。
/// 这时候如果进程是被 LaunchServices 拉起来的（`open` / Dock / Finder），
/// tccd 既不弹窗也不拒绝——`open(2)` 就那样**永远**挂在那里（0% CPU）。
/// 复原会话时 `Ghostty.SurfaceView.init` 同步走 `ghostty_surface_new`，引擎在里面 `openat` 存档里的
/// cwd，于是整个 app 卡死在 `applicationDidFinishLaunching` 里，一个窗口都出不来。
/// （从终端直接跑同一个二进制不会挂：TCC 记的是「负责进程」，也就是已授权的终端。）
///
/// 便宜的探针是没有的：对受保护目录 `stat` / `access` 都立刻返回 0，只有真正的 `open` 才会触发
/// TCC，而它一旦触发就再也不返回。所以只能：把 `open` 丢到一条**独立线程**上，主线程带超时地等。
/// 超时 = 这个根目录不可用，记下来（每个根只探一次），pane 退回默认目录照常起 shell。
/// 有授权时（发布版）`open` 是微秒级的，什么都不变。
enum WorkingDirectoryGate {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "WorkingDirectoryGate")

    /// 探测超时。每个受保护根目录只付一次；三个根最坏合计 0.9s，之后启动照常往下走
    static var deadline: TimeInterval = 0.3

    /// 可注入（用例）：`root` 能在 `deadline` 内打开吗
    static var prober: (_ root: String, _ deadline: TimeInterval) -> Bool = probeByOpening

    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    /// TCC 保护的根目录。命中这里才需要探测——其余路径原样放行
    static func protectedRoots(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"]
    }

    /// `path` 落在哪个受保护根目录下（纯函数，便于用例覆盖）
    static func protectedRoot(for path: String, home: String = NSHomeDirectory()) -> String? {
        let standardized = (path as NSString).standardizingPath
        return protectedRoots(home: home).first {
            standardized == $0 || standardized.hasPrefix($0 + "/")
        }
    }

    /// 唯一入口：能用就原样返回；探不通就返回 nil（调用方 = 交给引擎的默认目录）
    static func usable(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return path }
        guard let root = protectedRoot(for: path) else { return path }
        guard isRootUsable(root) else {
            logger.error("工作目录不可用（TCC 未授权且无应答）：\(path, privacy: .public) → 退回默认目录")
            return nil
        }
        return path
    }

    /// 每个根目录只探一次（结果缓存到进程结束；晚到的成功会把缓存改回可用，见 `noteLateSuccess`）
    static func isRootUsable(_ root: String) -> Bool {
        lock.lock()
        if let cached = cache[root] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let ok = prober(root, deadline)
        lock.lock()
        // 超时之后那次 `open` 才成功（授权窗开着，用户过了一会儿才点「允许」）：
        // 它已经把结果写进来了，别用刚才那个 false 盖掉
        let result = cache[root] ?? ok
        cache[root] = result
        lock.unlock()
        return result
    }

    /// 探测线程在超时之后才成功：把这个根目录改记成可用。
    /// 超时不等于「拒绝」——授权窗可能正开着，用户点「允许」是几秒之后的事。
    /// 之后新建的 pane 就能用真实目录了（这一次启动复原出来的那批已经退回默认目录，
    /// 但它们的存档路径被 `SurfaceView.deniedWorkingDirectory` 原样留着，不会丢）
    static func noteLateSuccess(_ root: String) {
        lock.lock()
        cache[root] = true
        lock.unlock()
    }

    /// 默认探针：独立线程上 `open`，主线程带超时地等。
    /// 超时后那条线程**没法取消**（它卡在内核里），会一直留着——最多三条，且只在没授权时发生
    static func probeByOpening(_ root: String, _ deadline: TimeInterval) -> Bool {
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            let fd = open(root, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                Darwin.close(fd)
                box.ok = true
                noteLateSuccess(root)   // 可能是超时之后才回来的：见那里的注释
            }
            semaphore.signal()
        }
        thread.name = "dev.danny.quickterm.tcc-probe"
        thread.stackSize = 64 << 10
        thread.start()
        guard semaphore.wait(timeout: .now() + deadline) == .success else { return false }
        return box.ok
    }

    /// 用例之间复位（缓存 + 探针 + 超时）
    static func resetForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        prober = probeByOpening
        deadline = 0.3
    }
}
