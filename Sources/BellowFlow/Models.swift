import Foundation
import CryptoKit

/// The models this release was tested with. Pinned in Resources/models.json; nothing else is ever loaded.
struct ModelSpec: Decodable {
    struct Whisper: Decodable { let name: String; let url: String; let sha256: String; let bytes: Int64 }
    struct Cleanup: Decodable { let name: String; let model: String; let wrapper: String; let bytes: Int64; let digests: [String] }
    let whisper: Whisper
    let cleanup: Cleanup
    static func load(_ url: URL) throws -> ModelSpec { try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: url)) }
}

struct ModelError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

func gigabytes(_ bytes: Int64) -> String {
    bytes < 1_000_000_000 ? String(format: "%.0f MB", Double(bytes) / 1e6) : String(format: "%.1f GB", Double(bytes) / 1e9)
}

func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func ollamaResponds(_ endpoint: String, _ path: String) async -> Bool {
    var req = URLRequest(url: URL(string: endpoint + path)!); req.timeoutInterval = 1
    guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
}

/// Fetches, verifies, and prepares the models in Application Support. Nothing here touches the UI;
/// `report` receives a status line and, while a download runs, its fraction complete.
final class ModelStore {
    typealias Report = (_ status: String, _ fraction: Double?) -> Void
    let spec: ModelSpec
    let support: URL
    let modelfile: URL
    let endpoint: String
    private let fm = FileManager.default
    private var downloader: Process?

    init(spec: ModelSpec, support: URL, modelfile: URL, endpoint: String) {
        self.spec = spec; self.support = support; self.modelfile = modelfile; self.endpoint = endpoint
    }

    var whisper: URL { support.appendingPathComponent("whisper.bin") }
    var store: URL { support.appendingPathComponent("models-v1") }
    private var whisperStamp: URL { support.appendingPathComponent("whisper.bin.sha256") }
    private var wrapperStamp: URL { store.appendingPathComponent(".bellowflow-wrapper") }

    private func manifest(_ reference: String) -> URL {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        return store.appendingPathComponent("manifests/registry.ollama.ai/library").appendingPathComponent(parts[0]).appendingPathComponent(parts.count > 1 ? parts[1] : "latest")
    }
    private func digests(of manifest: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: manifest), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any], let layers = json["layers"] as? [[String: Any]] else { return nil }
        return Set(([config] + layers).compactMap { $0["digest"] as? String })
    }
    private func blobExists(_ digest: String) -> Bool {
        fm.fileExists(atPath: store.appendingPathComponent("blobs").appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-")).path)
    }

    /// A regular file of the pinned size whose checksum was verified when it was downloaded.
    var whisperReady: Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: whisper.path), attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int64) == spec.whisper.bytes else { return false }
        return (try? String(contentsOf: whisperStamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == spec.whisper.sha256
    }
    /// The base model's manifest lists exactly the pinned blobs, and every blob is present.
    var cleanupReady: Bool {
        digests(of: manifest(spec.cleanup.model)) == Set(spec.cleanup.digests) && spec.cleanup.digests.allSatisfy(blobExists)
    }
    /// The wrapper was created from the Modelfile this build ships.
    var wrapperReady: Bool {
        guard fm.fileExists(atPath: manifest(spec.cleanup.wrapper).path), let modelfileHash = try? sha256Hex(of: modelfile) else { return false }
        return (try? String(contentsOf: wrapperStamp, encoding: .utf8)) == modelfileHash
    }
    var bytesToDownload: Int64 { (whisperReady ? 0 : spec.whisper.bytes) + (cleanupReady ? 0 : spec.cleanup.bytes) }

    /// Refuses a download that would not fit. Ollama also needs scratch space while verifying.
    func checkDiskSpace() throws {
        let needed = bytesToDownload
        guard needed > 0, let free = (try? fm.attributesOfFileSystem(forPath: support.path))?[.systemFreeSize] as? Int64 else { return }
        if free < needed + 2_000_000_000 {
            throw ModelError("BellowFlow needs \(gigabytes(needed + 2_000_000_000)) free to download its models; this disk has \(gigabytes(free)). Free some space and click Start.")
        }
    }

    /// Downloads Whisper with curl (resumable, retried), then verifies the pinned checksum.
    func fetchWhisper(report: Report) async throws {
        try? fm.removeItem(at: whisper); try? fm.removeItem(at: whisperStamp)
        let partial = support.appendingPathComponent("whisper.bin.partial")
        for attempt in 0..<2 {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--retry-all-errors",
                              "--continue-at", "-", "--output", partial.path, spec.whisper.url]
            let stderr = Pipe()
            curl.standardInput = FileHandle.nullDevice; curl.standardOutput = FileHandle.nullDevice; curl.standardError = stderr
            try curl.run(); downloader = curl
            defer { downloader = nil }
            while curl.isRunning {
                let done = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                report("Downloading \(spec.whisper.name) · \(gigabytes(done)) of \(gigabytes(spec.whisper.bytes))", Double(done) / Double(spec.whisper.bytes))
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if curl.terminationStatus == 0 { break }
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 33: the server ignored the resume range. Start over once.
            if attempt == 0 && curl.terminationStatus == 33 { try? fm.removeItem(at: partial); continue }
            if curl.terminationStatus == 15 { throw CancellationError() }
            throw ModelError("Downloading \(spec.whisper.name) failed (\(message.isEmpty ? "curl exit \(curl.terminationStatus)" : message)). Check the connection and click Start to resume.")
        }
        report("Verifying \(spec.whisper.name)…", nil)
        let hash = try await Task.detached { try sha256Hex(of: partial) }.value
        guard hash == spec.whisper.sha256 else {
            try? fm.removeItem(at: partial)
            throw ModelError("The downloaded \(spec.whisper.name) failed its checksum. Click Start to download it again.")
        }
        try fm.moveItem(at: partial, to: whisper)
        try spec.whisper.sha256.write(to: whisperStamp, atomically: true, encoding: .utf8)
    }

    /// Starts the private Ollama server on our store and waits until it answers.
    func startOllama(binary: URL, environment: [String: String], log: FileHandle?) async throws -> Process {
        if await ollamaResponds(endpoint, "/api/version") { throw ModelError("Port 11439 is already in use. Quit the other BellowFlow instance or listener and retry.") }
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = binary; p.arguments = ["serve"]; p.environment = environment
        p.standardOutput = log ?? FileHandle.nullDevice; p.standardError = log ?? FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        for _ in 0..<120 {
            guard p.isRunning else { throw ModelError("The bundled Ollama engine exited. See engine.log.") }
            if await ollamaResponds(endpoint, "/api/version") { return p }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        p.terminate()
        throw ModelError("Ollama did not become ready within 30 seconds.")
    }

    /// Pulls the base model through the running server (Ollama resumes and verifies its own blobs),
    /// checks it against the pinned digests, then builds the wrapper from the bundled Modelfile.
    func prepareCleanup(binary: URL, environment: [String: String], log: FileHandle?, report: Report) async throws {
        if !cleanupReady {
            var req = URLRequest(url: URL(string: endpoint + "/api/pull")!)
            req.httpMethod = "POST"; req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": spec.cleanup.model, "stream": true])
            report("Downloading \(spec.cleanup.name) · \(gigabytes(spec.cleanup.bytes))", 0)
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelError("Ollama refused the model download. See engine.log.") }
            var finished = false
            for try await line in bytes.lines {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let error = json["error"] as? String {
                    throw ModelError("Downloading \(spec.cleanup.name) failed (\(error)). Check the connection and click Start to resume.")
                }
                let status = json["status"] as? String ?? ""
                if let total = json["total"] as? Int64, let completed = json["completed"] as? Int64, total > 0 {
                    report("Downloading \(spec.cleanup.name) · \(gigabytes(completed)) of \(gigabytes(total))", Double(completed) / Double(total))
                } else if status.hasPrefix("verifying") || status.hasPrefix("writing") {
                    report("Verifying \(spec.cleanup.name)…", nil)
                }
                if status == "success" { finished = true }
            }
            guard finished else { throw ModelError("The \(spec.cleanup.name) download stopped early. Click Start to resume.") }
            guard cleanupReady else {
                throw ModelError("The downloaded \(spec.cleanup.model) is not the version this release was tested with. Update BellowFlow.")
            }
        }
        if !wrapperReady {
            report("Preparing the cleanup model…", nil)
            let create = Process(); create.executableURL = binary
            create.arguments = ["create", spec.cleanup.wrapper, "-f", modelfile.path]; create.environment = environment
            create.standardOutput = log ?? FileHandle.nullDevice; create.standardError = log ?? FileHandle.nullDevice; create.standardInput = FileHandle.nullDevice
            try create.run()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in create.terminationHandler = { _ in c.resume() } }
            guard create.terminationStatus == 0 else { throw ModelError("The cleanup model could not be created from the Modelfile. See engine.log.") }
            try sha256Hex(of: modelfile).write(to: wrapperStamp, atomically: true, encoding: .utf8)
        }
    }

    func cancel() { downloader?.terminate() }
}
