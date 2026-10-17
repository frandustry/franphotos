import Foundation

enum ParquetBridgeError: LocalizedError {
    case helperNotFound
    case helperFailed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound: "The fpparquet helper was not found (not built?)."
        case .helperFailed(let m): "fpparquet error: \(m)"
        case .launchFailed(let m): "Failed to launch fpparquet: \(m)"
        }
    }
}

enum PartitionKind: String, Sendable {
    case asset
    case timelineIndex = "timeline_index"
    case albumIndex = "album_index"
}

/// Locates the embedded (or dev-built) fpparquet helper binary.
enum ParquetHelperLocator {
    static func locate() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FRANPHOTOS_FPPARQUET"],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "bin/fpparquet"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Dev checkout: this file lives at <repo>/FranPhotos/Parquet/…
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Parquet
            .deletingLastPathComponent()  // FranPhotos
            .deletingLastPathComponent()  // <repo>
        let dev = repo.appending(path: "go/fpparquet/bin/fpparquet")
        if fm.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    /// Builds the helper via scripts/build-go-helper.sh when missing (dev flow).
    @discardableResult
    static func ensureBuilt() -> URL? {
        if let existing = locate() { return existing }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repo.appending(path: "scripts/build-go-helper.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        try? process.run()
        process.waitUntilExit()
        return locate()
    }
}

/// Serialized stdio JSON-lines client for the fpparquet helper process.
/// The helper stays alive for the session; the actor serializes requests.
actor ParquetBridge {
    private let helperURL: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var stdoutHandle: FileHandle?

    /// Dedicated queue for blocking pipe reads, keeping cooperative threads free.
    private let ioQueue = DispatchQueue(label: "franphotos.fpparquet.io")

    init(helperURL: URL) {
        self.helperURL = helperURL
    }

    static func `default`() throws -> ParquetBridge {
        guard let url = ParquetHelperLocator.ensureBuilt() else {
            throw ParquetBridgeError.helperNotFound
        }
        return ParquetBridge(helperURL: url)
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        let process = Process()
        process.executableURL = helperURL
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ParquetBridgeError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
        self.stdoutBuffer = Data()
    }

    /// Sends one request and reads one JSON-line response.
    /// Blocking pipe IO happens on `ioQueue`.
    private func send(_ request: [String: JSONValue]) async throws -> [String: JSONValue] {
        try ensureStarted()
        let payload = try JSONSerialization.data(
            withJSONObject: request.mapValues(\.anyValue))
        guard let newline = "\n".data(using: .utf8) else {
            throw ParquetBridgeError.helperFailed("encoding")
        }
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                guard let stdin, let stdoutHandle else {
                    continuation.resume(throwing: ParquetBridgeError.helperFailed("not started"))
                    return
                }
                do {
                    try stdin.write(contentsOf: payload)
                    try stdin.write(contentsOf: newline)
                } catch {
                    continuation.resume(throwing: ParquetBridgeError.helperFailed("write: \(error)"))
                    return
                }
                // Read until newline.
                var line = Data()
                while true {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty { break }  // EOF: process died
                    line.append(chunk)
                    if let nl = line.firstIndex(of: 0x0A) {
                        line = Data(line[..<nl])
                        break
                    }
                }
                guard !line.isEmpty,
                      let any = try? JSONSerialization.jsonObject(with: line),
                      let obj = any as? [String: Any]
                else {
                    continuation.resume(
                        throwing: ParquetBridgeError.helperFailed("bad response"))
                    return
                }
                continuation.resume(returning: obj.mapValues(JSONValue.from(any:)))
            }
        }
    }

    // MARK: - Public API

    func ping() async throws -> Bool {
        let response = try await send(["cmd": .string("ping")])
        return response["ok"]?.boolValue == true
    }

    /// Writes a partition file; returns (rowCount, sha256 of file).
    @discardableResult
    func writePartition(
        path: URL, kind: PartitionKind, rows: [[String: JSONValue]]
    ) async throws -> (rows: Int, sha256: String) {
        let response = try await send([
            "cmd": .string("write"),
            "path": .string(path.path),
            "kind": .string(kind.rawValue),
            "rows": .array(rows.map { .object($0) }),
        ])
        guard response["ok"]?.boolValue == true else {
            throw ParquetBridgeError.helperFailed(response["error"]?.stringValue ?? "write failed")
        }
        let count = Int(response["rows"]?.intValue ?? Int64(rows.count))
        let sha = response["sha256"]?.stringValue ?? ""
        return (count, sha)
    }

    func readPartition(
        path: URL, kind: PartitionKind, offset: Int = 0, limit: Int = 0
    ) async throws -> [[String: JSONValue]] {
        let response = try await send([
            "cmd": .string("read"),
            "path": .string(path.path),
            "kind": .string(kind.rawValue),
            "offset": .int(Int64(offset)),
            "limit": .int(Int64(limit)),
        ])
        guard response["ok"]?.boolValue == true else {
            throw ParquetBridgeError.helperFailed(response["error"]?.stringValue ?? "read failed")
        }
        guard case .array(let rows) = response["rows"] else { return [] }
        return rows.compactMap { value in
            if case .object(let row) = value { return row }
            return nil
        }
    }

    func terminate() {
        process?.terminate()
        process = nil
    }
}
