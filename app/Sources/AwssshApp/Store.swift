import Foundation

struct LoadOutcome: Equatable {
    var forwards: [Forward]
    var version: Int
    var notice: String?
    var backupTag: String?
    var stamp: Date?
}

private struct Envelope: Encodable {
    var version: Int
    var forwards: [Forward]
}

private struct VersionProbe: Decodable {
    var version: Int
}

private struct ForwardList: Decodable {
    var forwards: [Lenient<Forward>]
}

struct Lenient<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

enum Store {
    static let currentVersion = 1

    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        let base =
            directoryOverride
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Awsssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var fileURL: URL { directory.appendingPathComponent("forwards.json") }

    static func revealTarget() -> URL {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : directory
    }

    static func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadOutcome(forwards: [], version: currentVersion, stamp: nil)
        }
        var outcome = decode(data)
        if let tag = outcome.backupTag {
            backup(tag: tag)
        }
        outcome.stamp = stamp()
        return outcome
    }

    static func stamp() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    static func save(_ forwards: [Forward], expecting expected: Date?) -> Date? {
        if let onDisk = stamp(), onDisk != expected {
            backup(tag: "conflict")
        }
        save(forwards)
        return stamp()
    }

    static func decode(_ data: Data) -> LoadOutcome {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) {
            if probe.version > currentVersion {
                return finish(
                    decodeList(data),
                    version: probe.version,
                    lead:
                        "These forwards were saved by a newer Awsssh (format \(probe.version)). A backup was kept; update Awsssh before editing.",
                    backupTag: "v\(probe.version)"
                )
            }
            if probe.version < currentVersion {
                return finish(
                    migrate(decodeList(data), from: probe.version),
                    version: currentVersion,
                    backupTag: "v\(probe.version)"
                )
            }
            return finish(decodeList(data), version: currentVersion)
        }

        if let legacy = try? JSONDecoder().decode([Lenient<Forward>].self, from: data) {
            return finish(
                migrate(legacy.compactMap(\.value), from: 0),
                version: currentVersion,
                backupTag: "v0"
            )
        }

        return LoadOutcome(
            forwards: [],
            version: currentVersion,
            notice: "Saved forwards could not be read. The file was kept as a backup and not overwritten.",
            backupTag: "unreadable"
        )
    }

    private static func finish(
        _ forwards: [Forward],
        version: Int,
        lead: String? = nil,
        backupTag: String? = nil
    ) -> LoadOutcome {
        let checked = sanitise(forwards)
        let messages = [lead].compactMap { $0 } + checked.problems
        return LoadOutcome(
            forwards: checked.forwards,
            version: version,
            notice: messages.isEmpty ? nil : messages.joined(separator: ". "),
            backupTag: backupTag ?? (checked.changed ? "repaired" : nil)
        )
    }

    static func migrate(_ forwards: [Forward], from _: Int) -> [Forward] {
        forwards
    }

    static func save(_ forwards: [Forward]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: currentVersion, forwards: forwards)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func backup(tag: String) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let target = directory.appendingPathComponent("forwards.\(tag).backup.json")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: fileURL, to: target)
    }

    private static func decodeList(_ data: Data) -> [Forward] {
        guard let list = try? JSONDecoder().decode(ForwardList.self, from: data) else { return [] }
        return list.forwards.compactMap(\.value)
    }

    static func sanitise(_ forwards: [Forward]) -> (forwards: [Forward], problems: [String], changed: Bool) {
        var problems: [String] = []
        var out: [Forward] = []
        var usedIDs = Set<Int>()
        var usedHotKeys = Set<HotKey>()
        var nextID = (forwards.map(\.id).max() ?? 0) + 1
        var changed = false
        var invalid = 0

        for var forward in forwards {
            if forward.id <= 0 || usedIDs.contains(forward.id) {
                forward.id = nextID
                nextID += 1
                changed = true
            }
            usedIDs.insert(forward.id)

            if let hotKey = forward.hotKey, !usedHotKeys.insert(hotKey).inserted {
                problems.append("\(hotKey.displayString) was set on more than one forward, so only the first keeps it")
                forward.hotKey = nil
                changed = true
            }

            if forward.validate() != nil {
                invalid += 1
            }
            out.append(forward)
        }

        if invalid > 0 {
            problems.append(
                invalid == 1
                    ? "1 saved forward has incomplete settings — open it to fix"
                    : "\(invalid) saved forwards have incomplete settings — open them to fix")
        }
        return (out, problems, changed)
    }
}
