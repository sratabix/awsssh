import Foundation

enum ShareError: LocalizedError {
    case notJSON
    case notAForward

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "That is not JSON. Copy a forward with the share button first."
        case .notAForward:
            return "That JSON is not an awsssh forward."
        }
    }
}

enum Share {
    static let currentVersion = 1
    static let maxFieldLength = 200

    private static let deceptiveScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    static func clean(_ value: String) -> String {
        let kept = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !deceptiveScalars.contains($0.value)
        }
        let trimmed = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxFieldLength))
    }

    struct Payload: Codable {
        var name: String = ""
        var profile: String = ""
        var region: String = ""
        var instance: String = ""
        var localPort: String = ""
        var host: String = ""
        var remotePort: String = ""
        var color: String = ""

        init(_ forward: Forward) {
            name = forward.name
            profile = forward.profile
            region = forward.region
            instance = forward.instance
            localPort = forward.localPort
            host = forward.host
            remotePort = forward.remotePort
            color = forward.color
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field(_ key: CodingKeys) throws -> String {
                Share.clean(try c.decodeIfPresent(String.self, forKey: key) ?? "")
            }
            name = try field(.name)
            profile = try field(.profile)
            region = try field(.region)
            instance = try field(.instance)
            localPort = try field(.localPort)
            host = try field(.host)
            remotePort = try field(.remotePort)
            color = ForwardColor.normalise(try field(.color))
        }
    }

    struct Envelope: Codable {
        var version: Int
        var forward: Payload
    }

    static func encode(_ forward: Forward) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = Envelope(version: currentVersion, forward: Payload(forward))
        guard let data = try? encoder.encode(envelope),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func decode(_ text: String) throws -> Payload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw ShareError.notJSON
        }
        let decoder = JSONDecoder()

        var payload: Payload
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            payload = envelope.forward
        } else if let bare = try? decoder.decode(Payload.self, from: data) {
            payload = bare
        } else if (try? JSONSerialization.jsonObject(with: data)) != nil {
            throw ShareError.notAForward
        } else {
            throw ShareError.notJSON
        }

        guard !payload.instance.isEmpty else {
            throw ShareError.notAForward
        }
        return payload
    }

    static func forward(from payload: Payload, id: Int) -> Forward {
        var forward = Forward(id: id)
        forward.name = payload.name
        forward.profile = payload.profile
        forward.region = payload.region
        forward.instance = payload.instance
        forward.localPort = payload.localPort
        forward.host = payload.host
        forward.remotePort = payload.remotePort
        forward.color = payload.color
        return forward
    }
}
