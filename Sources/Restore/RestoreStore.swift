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

    /// The largest file `take` will read: the 4 MiB content cap plus room for the magic and the
    /// AES-GCM nonce and tag (32 bytes). Anything bigger is not ours and is dropped unread, so a
    /// huge file cannot stall the main thread at launch.
    static let maxFileBytes = 4 * 1024 * 1024 + 64

    /// The restore directory that belongs to a session archive: `restore/` next to it. The
    /// default archive gives `~/Library/Application Support/QuickTerm/restore/`; a second
    /// instance started with `--state-file` gets its own, so its quit never prunes (and its
    /// `content = false` never deletes) the files the user's QuickTerm wrote.
    static func directory(forState stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("restore", isDirectory: true)
    }

    let directory: URL
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
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
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

    /// Is `directory` itself a symlink? `O_NOFOLLOW` only guards the last path component of a file,
    /// so a linked restore directory would redirect every write, read and delete into its target.
    private var directoryIsLink: Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Remove a symlinked restore directory (the link only, never its target). True when it was one.
    @discardableResult
    private func removeDirectoryLink() -> Bool {
        guard directoryIsLink else { return false }
        if unlink(directory.path) != 0 {
            Self.log("restore directory is a symlink and could not be removed (errno \(errno))")
        } else {
            Self.log("restore directory was a symlink; removed the link, not its target")
        }
        return true
    }

    /// Unlink leftover `.<uuid>.tmp` files from a write that a crash interrupted. They can hold
    /// plaintext and are invisible to `files()`.
    private func removeStaleTemps() {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in all where file.pathExtension == "tmp"
            && UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.dropFirst())) != nil
            && file.lastPathComponent.hasPrefix(".") {
            unlink(file.path)
        }
    }

    private func prepareDirectory() throws {
        removeDirectoryLink()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its old mode through createDirectory; force it.
        if chmod(directory.path, 0o700) != 0 {
            Self.log("could not set the restore directory to 0700 (errno \(errno))")
        }
        removeStaleTemps()
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
        // O_NONBLOCK: opening a FIFO for reading would otherwise block the main thread at launch.
        // The fstat below rejects anything that is not a regular file.
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            unlink(file.path)
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
        guard info.st_size <= Self.maxFileBytes else {
            close(fd)
            unlink(file.path)
            Self.drop(pane, "file too large (\(info.st_size) bytes)")
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
        log("dropped \(pane.uuidString.prefix(8)): \(reason)")
    }

    private static func log(_ message: String) {
        DiagnosticLog.shared.note("restore", message)
    }

    // MARK: Housekeeping

    func remove(pane: UUID) {
        for ext in ["qtr", "vt"] { unlink(url(pane, ext: ext).path) }
    }

    func removeAll() {
        // Never follow a linked directory: removeItem would delete only the link and leave the
        // content in its target.
        if removeDirectoryLink() { return }
        // Only the files this store writes are deleted, then the directory if that left it empty.
        // With `--state-file` the directory is `restore/` next to a file the user chose, in a
        // folder QuickTerm does not own: a recursive delete there could take the user's own files.
        removeStaleTemps()
        for file in files() { unlink(file.path) }
        if rmdir(directory.path) != 0, errno != ENOENT, errno != ENOTEMPTY {
            Self.log("could not remove the restore directory (errno \(errno))")
        }
    }

    /// Delete every file whose pane is not in `keeping`.
    func prune(keeping: Set<UUID>) {
        if removeDirectoryLink() { return }
        removeStaleTemps()
        for file in files() {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if let id, !keeping.contains(id) { unlink(file.path) }
        }
    }

    /// The `<pane uuid>.qtr` / `<pane uuid>.vt` files currently in the directory: the names this
    /// store writes, and nothing else it might find there.
    func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter {
            ["qtr", "vt"].contains($0.pathExtension)
                && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
