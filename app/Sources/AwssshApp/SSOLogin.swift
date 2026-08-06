import Foundation

enum LoginCheck: String {
    case unknown, valid, expired

    init(_ raw: String?) {
        self = LoginCheck(rawValue: raw ?? "") ?? .unknown
    }
}

struct SSOLogin: Identifiable, Equatable {
    var label: String
    var profiles: [String]
    var expires: Date?
    var refreshable: Bool
    var scoped: Bool

    var id: String { label }

    init(
        label: String,
        profiles: [String] = [],
        expires: Date? = nil,
        refreshable: Bool = false,
        scoped: Bool = false
    ) {
        self.label = label
        self.profiles = profiles
        self.expires = expires
        self.refreshable = refreshable
        self.scoped = scoped
    }

    init(_ wire: HelperLogin) {
        label = wire.label
        profiles = wire.profiles ?? []
        expires = wire.expires.flatMap(SSOLogin.parse)
        refreshable = wire.refreshable ?? false
        scoped = wire.scoped ?? false
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    func signedIn(at now: Date, check: LoginCheck = .unknown) -> Bool {
        guard expires != nil || refreshable else { return false }
        switch check {
        case .valid: return true
        case .expired: return false
        case .unknown: break
        }
        if refreshable { return true }
        guard let expires else { return false }
        return expires > now
    }

    func status(at now: Date, check: LoginCheck = .unknown) -> String {
        if check == .expired { return "sign-in needed" }
        guard signedIn(at: now, check: check) else { return "signed out" }
        guard !refreshable, let expires, expires > now else { return "signed in" }
        return "signed in · \(SSOLogin.remaining(expires.timeIntervalSince(now))) left"
    }

    var covers: String {
        switch profiles.count {
        case 0: return ""
        case 1: return profiles[0]
        default: return "\(profiles.count) profiles"
        }
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "under a minute"
    }
}
