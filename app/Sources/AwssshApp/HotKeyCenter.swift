import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onFire: ((Int) -> Void)?

    private var registered: [Int: EventHotKeyRef] = [:]
    private var idsBySignature: [UInt32: Int] = [:]
    private var handler: EventHandlerRef?
    private var nextSignature: UInt32 = 1

    private init() {}

    func sync(_ forwards: [Forward]) {
        installHandlerIfNeeded()
        unregisterAll()
        for forward in forwards {
            guard let hotKey = forward.hotKey else { continue }
            register(hotKey, for: forward.id)
        }
    }

    func unregisterAll() {
        for ref in registered.values {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
        idsBySignature.removeAll()
    }

    nonisolated static func conflict(for hotKey: HotKey, in forwards: [Forward], excluding id: Int) -> Forward? {
        forwards.first { $0.id != id && $0.hotKey == hotKey }
    }

    private func register(_ hotKey: HotKey, for id: Int) {
        let signature = nextSignature
        nextSignature += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(signature), id: signature)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return }
        registered[id] = ref
        idsBySignature[signature] = id
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    guard let id = center.idsBySignature[hotKeyID.id] else { return }
                    center.onFire?(id)
                }
                return noErr
            }, 1, &spec, context, &handler)
    }
}
