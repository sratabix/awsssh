import Foundation

@MainActor
final class DNSCheck {
    static let fallbackHost = "amazonaws.com"
    static let passes = 2

    var resolvedOverride: Bool?
    var lookup: (String) async -> Bool = DNSCheck.resolve
    var onResolve: (() -> Void)?

    private let settle: Duration
    private var confirmed: String?
    private var probing: Task<Void, Never>?

    init(settle: Duration = .seconds(2)) {
        self.settle = settle
    }

    func resolves(_ host: String) -> Bool {
        if let resolvedOverride { return resolvedOverride }
        return confirmed == host
    }

    func confirm(_ host: String) {
        guard resolvedOverride == nil, !host.isEmpty else { return }
        guard confirmed != host, probing == nil else { return }
        probing = Task { @MainActor [weak self] in
            guard let self else { return }
            var passes = 0
            while passes < Self.passes {
                guard await self.lookup(host) else { break }
                passes += 1
                if passes < Self.passes { try? await Task.sleep(for: self.settle) }
                if Task.isCancelled { return }
            }
            if passes == Self.passes { self.adopt(host) }
            self.probing = nil
        }
    }

    func adopt(_ host: String) {
        confirmed = host
        onResolve?()
    }

    func invalidate() {
        probing?.cancel()
        probing = nil
        confirmed = nil
    }

    static func resolve(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(
                    ai_flags: 0,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var found: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &found)
                let resolved = status == 0 && found != nil
                if let found { freeaddrinfo(found) }
                continuation.resume(returning: resolved)
            }
        }
    }
}
