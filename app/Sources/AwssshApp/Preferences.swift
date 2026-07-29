import Foundation

enum Preferences {
    static let showSSOKey = "showSSO"

    nonisolated(unsafe) static var store: UserDefaults = .standard

    static let collapsedGroupsKey = "collapsedGroups"

    static var showSSO: Bool {
        get { store.object(forKey: showSSOKey) as? Bool ?? true }
        set { store.set(newValue, forKey: showSSOKey) }
    }

    static var collapsedGroups: Set<String> {
        get { Set(store.stringArray(forKey: collapsedGroupsKey) ?? []) }
        set { store.set(newValue.sorted(), forKey: collapsedGroupsKey) }
    }
}
