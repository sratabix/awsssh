import Foundation

struct ReleaseNotes {
    struct Section: Equatable, Identifiable {
        let version: String
        let entries: [String]

        var id: String { version }
        var displayVersion: String { "v" + version }
    }

    static let resource = "CHANGELOG"
    static let maxEntryLength = 400

    static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        var version: String?
        var entries: [String] = []

        func flush() {
            guard let version, !entries.isEmpty else { return }
            sections.append(Section(version: version, entries: entries))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let heading = heading(line) {
                flush()
                version = heading
                entries = []
                continue
            }
            guard version != nil, let entry = bullet(line) else { continue }
            entries.append(entry)
        }
        flush()
        return sections
    }

    private static func heading(_ line: String) -> String? {
        guard let rest = line.hasPrefix("## ") ? line.dropFirst(3) : nil else { return nil }
        let name = rest.trimmingCharacters(in: .whitespaces)
        let version = name.hasPrefix("v") ? String(name.dropFirst()) : name
        guard let first = version.first, first.isNumber else { return nil }
        return version
    }

    private static func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        let entry = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        return String(entry.prefix(maxEntryLength))
    }

    static func forUpdate(from seen: String, to current: String, in text: String) -> [Section] {
        parse(text).filter {
            UpdateChecker.isNewer(remote: $0.version, current: seen)
                && !UpdateChecker.isNewer(remote: $0.version, current: current)
        }
    }

    static func forCurrent(_ current: String, in text: String) -> [Section] {
        let all = parse(text)
        if let exact = all.first(where: { $0.version == current }) { return [exact] }
        return Array(all.prefix(1))
    }

    static func bundled() -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}
