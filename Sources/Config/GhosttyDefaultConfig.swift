import Foundation

/// 引擎兜底配置（spec §4.10 配置链第 ①½ 层）：用户没有任何 ghostty 配置文件时，
/// 加载 app 内置的 `Resources/ghostty-default.conf`；用户文件一旦存在，本层整体让位。
/// 候选路径与加载顺序同 libghostty 1.3 `loadDefaultFiles`：XDG 旧名 `config` → 新名
/// `config.ghostty` → Application Support 旧名 → 新名；只算**存在且非空的常规文件**
/// （libghostty 对 0 字节文件按 FileIsEmpty 不加载）。
/// QuickTerm 自己加载这些文件而不调 `ghostty_config_load_default_files`：1.3.1 在无配置时
/// 会往 ~/Library/Application Support/com.mitchellh.ghostty 写出（未 flush 的 0 字节）模板，
/// 既污染用户目录，又会让"用户有配置"的判定永久为真。
enum GhosttyDefaultConfig {
    static let resourceName = "ghostty-default"

    /// bundle 内置兜底文件（缺资源返回 nil = 不加载）
    static var bundledPath: String? {
        Bundle.main.path(forResource: resourceName, ofType: "conf")
    }

    /// 主目录：与 libghostty（src/os/homedir.zig）一致，优先 `$HOME`，再退回 passwd
    static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// libghostty 会读取的用户配置文件候选路径
    static func userConfigCandidates(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = home ?? defaultHome(environment: environment)
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let appSupport = home.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        return [  // 旧名先于新名（与 libghostty 一致：后者覆盖前者）
            xdg.appendingPathComponent("ghostty/config"),
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            appSupport.appendingPathComponent("config"),
            appSupport.appendingPathComponent("config.ghostty"),
        ]
    }

    /// 实际会被加载的用户配置文件（存在、常规文件、非空），按加载顺序
    static func userConfigFiles(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        userConfigCandidates(home: home, environment: environment).filter { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? NSNumber else { return false }
            return size.intValue > 0
        }
    }

    static func userConfigExists(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        !userConfigFiles(home: home, environment: environment, fileManager: fileManager).isEmpty
    }

    /// 本次加载应使用的兜底文件路径（nil = 用户有自己的配置，或 bundle 缺资源）。
    /// 每次引擎（重）加载配置时重新判定，用户后来创建配置文件即自动让位。
    static func activeFallbackPath() -> String? {
        guard !userConfigExists() else { return nil }
        return bundledPath
    }
}
