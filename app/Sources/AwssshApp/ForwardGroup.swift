import Foundation

struct ForwardGroup: Identifiable, Equatable {
    var name: String
    var forwards: [Forward]

    var id: String { name }

    static func build(from forwards: [Forward]) -> [ForwardGroup] {
        var order: [String] = []
        var buckets: [String: [Forward]] = [:]

        for forward in forwards {
            if buckets[forward.group] == nil {
                order.append(forward.group)
                buckets[forward.group] = []
            }
            buckets[forward.group]?.append(forward)
        }

        let named =
            order
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        var out = named.map { ForwardGroup(name: $0, forwards: buckets[$0] ?? []) }
        if let loose = buckets[""] {
            out.append(ForwardGroup(name: "", forwards: loose))
        }
        return out
    }

    static func names(in forwards: [Forward]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for forward in forwards where !forward.group.isEmpty {
            if seen.insert(forward.group).inserted {
                out.append(forward.group)
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func title(soleGroup: Bool) -> String {
        if !name.isEmpty { return name }
        return soleGroup ? "All forwards" : "Ungrouped"
    }
}
