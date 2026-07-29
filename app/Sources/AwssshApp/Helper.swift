import Foundation

struct HelperForward: Codable {
    var profile: String
    var region: String
    var instance: String
    var local: String
    var host: String
    var remote: String
}

struct HelperCommand: Codable {
    var cmd: String
    var id: Int?
    var forward: HelperForward?
    var login: String?
}

struct HelperLogin: Codable {
    var label: String
    var profiles: [String]?
    var expires: String?
}

struct HelperMessage: Codable {
    var event: String
    var id: Int?
    var detail: String?
    var error: String?
    var profiles: [String]?
    var logins: [HelperLogin]?
}

final class Helper {
    var onMessage: ((HelperMessage) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let encoder = JSONEncoder()

    func start() {
        let proc = Process()
        proc.executableURL = Helper.resolveBinary()

        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extra + (env["PATH"].map { ":" + $0 } ?? "")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(
                    HelperMessage(event: "error", error: "helper failed to start: \(error.localizedDescription)"))
            }
            return
        }
        process = proc
        stdin = inPipe.fileHandleForWriting
    }

    func send(_ command: HelperCommand) {
        guard let stdin, var data = try? encoder.encode(command) else { return }
        data.append(0x0A)
        stdin.write(data)
    }

    func shutdown() {
        send(HelperCommand(cmd: "stopAll"))
        process?.terminate()
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                let msg = try? JSONDecoder().decode(HelperMessage.self, from: line)
            else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(msg) }
        }
    }

    private static func resolveBinary() -> URL {
        if let override = ProcessInfo.processInfo.environment["AWSSSH_HELPER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "awsssh-helper", withExtension: nil) {
            return bundled
        }
        let dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".")
        return dir.appendingPathComponent("awsssh-helper")
    }
}
