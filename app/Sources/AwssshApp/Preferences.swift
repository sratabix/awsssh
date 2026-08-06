import Foundation

enum Preferences {
    static let showSSOKey = "showSSO"
    static let autoSignInKey = "autoSignIn"
    static let lastSeenVersionKey = "lastSeenVersion"

    nonisolated(unsafe) static var store: UserDefaults = .standard

    static let collapsedGroupsKey = "collapsedGroups"

    static var showSSO: Bool {
        get { store.object(forKey: showSSOKey) as? Bool ?? true }
        set { store.set(newValue, forKey: showSSOKey) }
    }

    static var autoSignIn: Bool {
        get { store.object(forKey: autoSignInKey) as? Bool ?? false }
        set { store.set(newValue, forKey: autoSignInKey) }
    }

    static var lastSeenVersion: String {
        get { store.string(forKey: lastSeenVersionKey) ?? "" }
        set { store.set(newValue, forKey: lastSeenVersionKey) }
    }

    static var collapsedGroups: Set<String> {
        get { Set(store.stringArray(forKey: collapsedGroupsKey) ?? []) }
        set { store.set(newValue.sorted(), forKey: collapsedGroupsKey) }
    }
}
