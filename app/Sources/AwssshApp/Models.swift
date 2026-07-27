import Foundation

struct Forward: Identifiable, Codable, Equatable {
    var id: Int
    var name: String = ""
    var profile: String = ""
    var region: String = ""
    var instance: String = ""
    var localPort: String = ""
    var host: String = ""
    var remotePort: String = ""
    var hotKey: HotKey?

    init(id: Int) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        instance = try c.decodeIfPresent(String.self, forKey: .instance) ?? ""
        localPort = try c.decodeIfPresent(String.self, forKey: .localPort) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        remotePort = try c.decodeIfPresent(String.self, forKey: .remotePort) ?? ""
        hotKey = (try? c.decodeIfPresent(HotKey.self, forKey: .hotKey)) ?? nil
    }

    var profileLabel: String { profile.isEmpty ? "default" : profile }
    var target: String { host.isEmpty ? "instance:\(remotePort)" : "\(host):\(remotePort)" }
    var route: String { "\(localPort) → \(target)" }
    var title: String { name.isEmpty ? route : name }

    func validate() -> String? {
        if instance.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Instance name is required."
        }
        guard let l = Int(localPort), (1...65535).contains(l) else {
            return "Local port must be a number 1–65535."
        }
        guard let r = Int(remotePort), (1...65535).contains(r) else {
            return "Remote port must be a number 1–65535."
        }
        return nil
    }
}

enum RunState: Equatable {
    case stopped, starting, running, stopping, error
}

struct EntryState: Equatable {
    var run: RunState = .stopped
    var detail: String = ""
    var error: String = ""
}
