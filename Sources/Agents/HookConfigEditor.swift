import Foundation

/// **The JSON editor** (plan §2.6): the only code in QuickTerm that writes into another program's
/// configuration file.
///
/// Everything here follows from one sentence — *we are a guest in that file*:
///
/// - **read, edit, write back**; never regenerate. Every key, every value and every hook entry the
///   user wrote themselves survives, including their own entry in the same event group as ours.
/// - **the top level must be an object.** A file holding an array, a string, or nothing that
///   parses is refused with `bad_request` and *not one byte is written* — an agent's settings file
///   that we cannot read is a file we must not replace.
/// - **our entries are the ones carrying the marker** (`HookScript.isOurs`), so uninstall takes
///   away exactly what install put there and nothing else.
/// - **the write is atomic and preserves the file's mode**; a config file that is itself a symlink
///   is followed to its destination, because dotfiles repositories symlink `settings.json` and an
///   atomic rename onto the link would quietly replace the link with a plain file.
/// - **no backup file.** `hooks uninstall` is the revert, and a `settings.json.bak` left in a
///   directory another program scans is its own kind of damage.
struct HookConfigEditor {
    /// The file as the user names it (the symlink, when it is one).
    let url: URL
    let shape: HookConfigShape
    /// Our command string — `'<script>' <agent id>` — the thing written and the thing matched.
    let command: String

    static let writeOptions: JSONSerialization.WritingOptions =
        [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    // MARK: Reading

    /// The file's top-level object, or nil when the file does not exist yet.
    func read() throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        // An empty file is a file somebody's editor has just created: treat it as "no hooks yet"
        // rather than as corruption, because refusing it would leave the user with no way forward
        // except deleting a file they can see is empty.
        if data.isEmpty { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            throw ControlErrorBody(
                .badRequest, "\(url.path) is not a JSON object, so QuickTerm will not edit it",
                hint: "Fix or move the file and run quickterm hooks install again — nothing was written.")
        }
        // A flat file whose `hooks` is not a list is not the shape we know how to edit, and
        // replacing it with one would throw the user's hooks away.
        if shape.layout == .flat, let hooks = object["hooks"], !(hooks is [Any]) {
            throw ControlErrorBody(
                .badRequest, "\(url.path) has a hooks value that is not a list, so QuickTerm will not edit it",
                hint: "Fix or move the file and run quickterm hooks install again — nothing was written.")
        }
        return object
    }

    /// Which hook events currently hold an entry of ours. Unordered — the caller sorts by the
    /// rule file's own order, so `hooks status` reads the way the rule file reads.
    func ownedEvents(in root: [String: Any]) -> Set<String> {
        var out: Set<String> = []
        if shape.layout == .flat {
            for entry in root["hooks"] as? [Any] ?? [] where Self.isOursFlat(entry) {
                if let trigger = (entry as? [String: Any])?["trigger"] as? String { out.insert(trigger) }
            }
            return out
        }
        for (event, value) in root["hooks"] as? [String: Any] ?? [:] {
            for group in value as? [Any] ?? [] {
                let entries = (group as? [String: Any])?["hooks"] as? [Any] ?? []
                if entries.contains(where: Self.isOurs) { out.insert(event) }
            }
        }
        return out
    }

    private static func isOurs(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any], let command = entry["command"] as? String else { return false }
        return HookScript.isOurs(command: command)
    }

    /// A flat entry carries its command one level down, in `action.command`.
    private static func isOursFlat(_ entry: Any) -> Bool {
        guard let action = (entry as? [String: Any])?["action"] as? [String: Any],
              let command = action["command"] as? String else { return false }
        return HookScript.isOurs(command: command)
    }

    // MARK: Editing (pure: a document in, a document out)

    /// Our entries on exactly `events` and nowhere else.
    ///
    /// An event that already holds one of ours has it **replaced in place**, which is what makes a
    /// changed `hook-detail`, a moved app bundle or a second install a rewrite rather than a
    /// second copy. An event of the other tier loses ours, which is what makes
    /// `tools` -> `lifecycle` actually take the tool hooks away.
    func installing(events: [String], into root: [String: Any]) -> [String: Any] {
        if shape.layout == .flat { return installingFlat(events: events, into: root) }
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let wanted = Set(events)
        let fresh = shape.entry(command: command)

        // Events of the tier keep our entry **where it already is** — a rewrite, not a second
        // copy, so the order of the user's groups never shuffles under them and `hook-detail`
        // changes do not accumulate. Events outside the tier lose ours entirely, which is what
        // makes `tools` -> `lifecycle` actually take the tool hooks away.
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            if wanted.contains(event) {
                hooks[event] = Self.replacing(groups, with: fresh)
            } else {
                let left = Self.stripped(groups)
                if left.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = left }
            }
        }
        for event in events {
            var groups = hooks[event] as? [Any] ?? []
            if !Self.holdsOurs(groups) {
                groups.append(["hooks": [fresh]] as [String: Any])
            }
            hooks[event] = groups
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return root
    }

    private static func holdsOurs(_ groups: [Any]) -> Bool {
        groups.contains { group in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOurs)
        }
    }

    /// The first of our entries replaced in place; any further one dropped (a file that already
    /// held two of ours is tidied rather than grown).
    private static func replacing(_ groups: [Any], with fresh: [String: Any]) -> [Any] {
        var out: [Any] = []
        var replaced = false
        for group in groups {
            guard var group = group as? [String: Any], let entries = group["hooks"] as? [Any] else {
                out.append(group)
                continue
            }
            var left: [Any] = []
            for entry in entries {
                guard isOurs(entry) else {
                    left.append(entry)
                    continue
                }
                if !replaced {
                    left.append(fresh)
                    replaced = true
                }
            }
            if left.isEmpty { continue }
            group["hooks"] = left
            out.append(group)
        }
        return out
    }

    /// The flat form of `installing`: the same rules over one list. Our entry for a trigger of the
    /// tier is replaced where it stands, a second one for the same trigger is dropped, ours for a
    /// trigger outside the tier is dropped, and a trigger still missing is appended. Everything
    /// that is not ours keeps its place, and a `version` the file already names is left alone.
    private func installingFlat(events: [String], into root: [String: Any]) -> [String: Any] {
        var root = root
        let wanted = Set(events)
        var placed: Set<String> = []
        var out: [Any] = []
        for entry in root["hooks"] as? [Any] ?? [] {
            guard Self.isOursFlat(entry) else {
                out.append(entry)
                continue
            }
            guard let trigger = (entry as? [String: Any])?["trigger"] as? String,
                  wanted.contains(trigger), !placed.contains(trigger) else { continue }
            out.append(shape.flatEntry(command: command, trigger: trigger))
            placed.insert(trigger)
        }
        for event in events where !placed.contains(event) {
            out.append(shape.flatEntry(command: command, trigger: event))
            placed.insert(event)
        }
        root["hooks"] = out
        if root["version"] == nil, let version = shape.version { root["version"] = version }
        return root
    }

    /// Ours removed from every event; the user's own entries, groups and events untouched.
    func uninstalling(from root: [String: Any]) -> [String: Any] {
        if shape.layout == .flat {
            var root = root
            guard let hooks = root["hooks"] as? [Any] else { return root }
            root["hooks"] = hooks.filter { !Self.isOursFlat($0) }
            return root
        }
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let left = Self.stripped(groups)
            if left.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = left
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return root
    }

    /// One event's groups with our entries taken out, and any group that held nothing but ours
    /// dropped. A group of the user's own that also held one of ours keeps everything else it had
    /// — matcher included.
    private static func stripped(_ groups: [Any]) -> [Any] {
        var out: [Any] = []
        for group in groups {
            guard var group = group as? [String: Any], let entries = group["hooks"] as? [Any] else {
                out.append(group)
                continue
            }
            let left = entries.filter { !isOurs($0) }
            if left.count == entries.count {
                out.append(group)
            } else if !left.isEmpty {
                group["hooks"] = left
                out.append(group)
            }
            // else: the group held only ours — drop it rather than leave `{"hooks": []}` behind.
        }
        return out
    }

    /// After `uninstalling`, should the file go rather than be written back? Only for the flat
    /// layout, whose file is a standalone one QuickTerm created (kiro-cli's
    /// `~/.kiro/hooks/quickterm-agent-state.json`), and only when it holds nothing at all any more:
    /// no hook entry and no top-level key besides `version`. A file that still holds anything
    /// that is not ours is written back instead, never deleted.
    func isLeftEmpty(_ root: [String: Any]) -> Bool {
        guard shape.layout == .flat else { return false }
        guard (root["hooks"] as? [Any] ?? []).isEmpty else { return false }
        return Set(root.keys).isSubset(of: ["version", "hooks"])
    }

    /// Delete the file. A config path that is a symlink is never removed here: the link (and the
    /// file it names, which may live in a dotfiles repository) belongs to the user, so the caller
    /// writes the emptied document through it instead. Returns false when nothing was removed.
    @discardableResult
    func remove() throws -> Bool {
        guard !HookScript.isSymlink(url.path) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ControlErrorBody(.failed, "Could not remove \(url.path) (\(error.localizedDescription))")
        }
        return true
    }

    // MARK: Writing

    static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: writeOptions)
        // A settings file is a text file people open in an editor: end it with a newline.
        if data.last != 0x0A { data.append(0x0A) }
        return data
    }

    /// Write `data` over the file: same directory, `rename(2)`, original mode preserved.
    ///
    /// Returns false when the bytes on disk are already exactly these — which is how "install
    /// twice changes nothing" becomes a property of the file rather than a promise of the caller.
    @discardableResult
    func write(_ data: Data) throws -> Bool {
        let manager = FileManager.default
        let target = Self.resolvingLink(url)
        if let existing = manager.contents(atPath: target.path), existing == data { return false }

        let directory = target.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        let temp = directory.appendingPathComponent(".quickterm-hooks.\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        try manager.setAttributes([.posixPermissions: mode ?? 0o644], ofItemAtPath: temp.path)
        guard rename(temp.path, target.path) == 0 else {
            try? manager.removeItem(at: temp)
            throw ControlErrorBody(.failed, "Could not write \(target.path) (errno \(errno))")
        }
        return true
    }

    /// Follow the file's own symlink (bounded, so a link that points at itself is not a hang).
    /// Only the **file** is followed; the hook script refuses to be written through a link at all
    /// (`HookScript.write`), because that one is executed rather than read.
    static func resolvingLink(_ url: URL) -> URL {
        var current = url
        for _ in 0..<8 {
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: current.path) else { return current }
            current = URL(fileURLWithPath: destination,
                          relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return current
    }
}
