import Foundation

/// The engine's fallback config (spec §4.10, layer ①½ of the config chain): when the user has
/// no ghostty config file at all, load the app's bundled `Resources/ghostty-default.conf`; the
/// moment a user file exists, this whole layer steps aside.
/// The candidate paths and their order match libghostty 1.3's `loadDefaultFiles`: XDG old name
/// `config` -> new name `config.ghostty` -> Application Support old name -> new name. Only
/// **regular files that exist and are non-empty** count (libghostty treats a 0-byte file as
/// FileIsEmpty and does not load it).
/// QuickTerm loads these files itself rather than calling `ghostty_config_load_default_files`:
/// with no config present, 1.3.1 writes a template (0 bytes, never flushed) into
/// ~/Library/Application Support/com.mitchellh.ghostty, which both litters the user's directory
/// and makes the "the user has a config" test true forever after.
enum GhosttyDefaultConfig {
    static let resourceName = "ghostty-default"

    /// The fallback file bundled with the app (nil if the resource is missing = load nothing).
    static var bundledPath: String? {
        Bundle.main.path(forResource: resourceName, ofType: "conf")
    }

    /// Home directory, resolved as libghostty does it (src/os/homedir.zig): `$HOME` first,
    /// falling back to the passwd entry.
    static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The user config paths libghostty would read.
    static func userConfigCandidates(
        home: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = home ?? defaultHome(environment: environment)
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let appSupport = home.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        return [  // old name before new name (as in libghostty: the later one overrides)
            xdg.appendingPathComponent("ghostty/config"),
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            appSupport.appendingPathComponent("config"),
            appSupport.appendingPathComponent("config.ghostty"),
        ]
    }

    /// The user config files that would actually be loaded (existing, regular, non-empty), in
    /// load order.
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

    /// The fallback path to use for this load (nil = the user has their own config, or the
    /// resource is missing from the bundle). Re-decided every time the engine (re)loads its
    /// config, so a config file the user creates later takes over on its own.
    static func activeFallbackPath() -> String? {
        guard !userConfigExists() else { return nil }
        return bundledPath
    }
}
