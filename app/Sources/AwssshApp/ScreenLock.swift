import AppKit
import CoreGraphics

@MainActor
final class ScreenLock {
    static let lockedKey = "CGSSessionScreenIsLocked"
    static let lockedNotification = "com.apple.screenIsLocked"
    static let unlockedNotification = "com.apple.screenIsUnlocked"

    var onUnlock: (() -> Void)?
    var lockedOverride: Bool?

    private var observers: [NSObjectProtocol] = []
    private var observedLock = false

    var locked: Bool {
        lockedOverride ?? (observedLock || ScreenLock.sessionIsLocked())
    }

    static func sessionIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any],
            let flag = info[lockedKey]
        else { return false }
        if let boolean = flag as? Bool { return boolean }
        if let number = flag as? Int { return number == 1 }
        return false
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(
            center.addObserver(
                forName: Notification.Name(ScreenLock.lockedNotification),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.observedLock = true }
            })
        observers.append(
            center.addObserver(
                forName: Notification.Name(ScreenLock.unlockedNotification),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.observedLock = false
                    self?.onUnlock?()
                }
            })
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
    }
}
