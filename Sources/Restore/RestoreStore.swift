import CryptoKit
import Foundation

/// **Per-pane screen content kept between launches: private, and read exactly once.**
///
/// One file per pane, `<pane uuid>.qtr` (encrypted) or `<pane uuid>.vt` (plain, when the user
/// turned encryption off). A `.qtr` file is the magic `QTR1` followed by an AES-GCM combined box.
///
/// - **Read-once.** `take` deletes the file *before* it decrypts, so a crash while restoring can
///   never replay the same content on every launch, and a file that fails to open is gone too.
/// - **Never through a link.** Every open uses `O_NOFOLLOW`; a symlink in the directory is
///   removed (the link, not its target) and treated as a dropped file.
/// - **Private.** Directory `0700`, files `0600`, directory excluded from backups on every write.
@MainActor
final class RestoreStore {
    struct StoreError: Error, CustomStringConvertible {
        let description: String
    }

    static let magic = Data("QTR1".utf8)

    static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuickTerm/restore", isDirectory: true)

    private let directory: URL
    private let keyStore: RestoreKeyStore

    init(directory: URL, keyStore: RestoreKeyStore) {
        self.directory = directory
        self.keyStore = keyStore
    }

    // MARK: Paths

    private func url(_ pane: UUID, ext: String) -> URL {
        directory.appendingPathComponent("\(pane.uuidString).\(ext)")
    }

    // MARK: Write

    /// Store `text` for `pane`, replacing whatever was there in either format.
    func write(_ text: Data, pane: UUID, encrypt: Bool) throws {
        try prepareDirectory()

        var payload = text
        if encrypt {
            guard let key = try keyStore.key(createIfMissing: true) else {
                throw StoreError(description: "no content key available")
            }
            guard let combined = try AES.GCM.seal(text, using: key).combined else {
                throw StoreError(description: "could not seal content")
            }
            payload = Self.magic + combined
        }

        let target = url(pane, ext: encrypt ? "qtr" : "vt")
        let other = url(pane, ext: encrypt ? "vt" : "qtr")
        // A temp file made with O_EXCL|O_NOFOLLOW, then rename(2): rename replaces a symlink at
        // the target rather than following it, and nobody ever sees a half-written file.
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError(description: "open failed (errno \(errno))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: payload)
            try handle.close()
        } catch {
            unlink(temp.path)
            throw error
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw StoreError(description: "rename failed (errno \(code))")
        }
        unlink(other.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its old mode through createDirectory; force it.
        chmod(directory.path, 0o700)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }

    // MARK: Read

    /// The stored content, once. Any failure returns nil and logs why; the file is gone either way.
    func take(pane: UUID) -> Data? {
        var result: Data?
        for ext in ["qtr", "vt"] {
            let file = url(pane, ext: ext)
            guard let raw = readAndDelete(file, pane: pane) else { continue }
            if result != nil { continue }
            result = decode(raw, encrypted: ext == "qtr", pane: pane)
        }
        return result
    }

    /// Open without following links, read, then delete. nil when absent or unreadable.
    private func readAndDelete(_ file: URL, pane: UUID) -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { unlink(file.path) }
            Self.drop(pane, "not readable (errno \(code))")
            return nil
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            unlink(file.path)
            Self.drop(pane, "not a regular file")
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try? handle.readToEnd()
        // Delete before anything can fail or crash.
        unlink(file.path)
        try? handle.close()
        guard let data else {
            Self.drop(pane, "read failed")
            return nil
        }
        return data
    }

    private func decode(_ raw: Data, encrypted: Bool, pane: UUID) -> Data? {
        guard encrypted else { return raw }
        guard raw.count > Self.magic.count, raw.prefix(Self.magic.count) == Self.magic else {
            Self.drop(pane, "bad magic or truncated")
            return nil
        }
        do {
            guard let key = try keyStore.key(createIfMissing: false) else {
                Self.drop(pane, "no content key")
                return nil
            }
            let box = try AES.GCM.SealedBox(combined: raw.dropFirst(Self.magic.count))
            return try AES.GCM.open(box, using: key)
        } catch {
            Self.drop(pane, "decrypt failed: \(error)")
            return nil
        }
    }

    private static func drop(_ pane: UUID, _ reason: String) {
        DiagnosticLog.shared.note("restore", "dropped \(pane.uuidString.prefix(8)): \(reason)")
    }

    // MARK: Housekeeping

    func remove(pane: UUID) {
        for ext in ["qtr", "vt"] { unlink(url(pane, ext: ext).path) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Delete every file whose pane is not in `keeping`.
    func prune(keeping: Set<UUID>) {
        for file in files() {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id == nil || !keeping.contains(id!) { unlink(file.path) }
        }
    }

    /// The `.qtr` / `.vt` files currently in the directory.
    func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { ["qtr", "vt"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
