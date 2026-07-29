import Foundation

enum Preferences {
    static let showSSOKey = "showSSO"

    nonisolated(unsafe) static var store: UserDefaults = .standard

    static var showSSO: Bool {
        get { store.object(forKey: showSSOKey) as? Bool ?? true }
        set { store.set(newValue, forKey: showSSOKey) }
    }
}
