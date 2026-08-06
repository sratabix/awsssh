import Foundation
import Network

struct PathSnapshot: Equatable {
    var satisfied: Bool
    var interfaces: [String]
    var gateways: [String]

    static func changed(from previous: PathSnapshot?, to current: PathSnapshot) -> Bool {
        guard current.satisfied, let previous else { return false }
        return previous != current
    }
}

@MainActor
final class NetworkMonitor {
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let settle: Duration
    private var snapshot: PathSnapshot?
    private var pending: Task<Void, Never>?
    private var running = false

    var reachable: Bool { snapshot?.satisfied ?? true }

    init(settle: Duration = .seconds(3)) {
        self.settle = settle
    }

    func start() {
        guard !running else { return }
        running = true
        monitor.pathUpdateHandler = { [weak self] path in
            let observed = PathSnapshot(
                satisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map(\.name).sorted(),
                gateways: path.gateways.map(String.init(describing:)).sorted()
            )
            Task { @MainActor in self?.observe(observed) }
        }
        monitor.start(queue: .main)
    }

    func observe(_ current: PathSnapshot) {
        let changed = PathSnapshot.changed(from: snapshot, to: current)
        snapshot = current
        guard changed else { return }

        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settle)
            guard !Task.isCancelled else { return }
            self.onChange?()
        }
    }

    deinit {
        monitor.cancel()
    }
}
