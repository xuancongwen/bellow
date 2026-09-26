import Foundation
import CryptoKit

/// The models this release was tested with. Pinned in Resources/models.json; nothing else is ever loaded.
/// Tiers are listed largest first; a tier whose `cleanup` is null is staged but has no model pinned yet.
struct ModelSpec: Decodable {
    struct Whisper: Decodable, Equatable { let name: String; let url: String; let sha256: String; let bytes: Int64 }
    struct Cleanup: Decodable, Equatable {
        let name: String
        /// The base weights: a text-only GGUF fetched from Hugging Face and verified like Whisper.
        let url: String; let sha256: String; let bytes: Int64
        /// The Ollama model built from `modelfile` (a resource, byte-identical to voxtype-llm-wrapper,
        /// whose FROM line names the GGUF) on top of those weights.
        let wrapper: String; let modelfile: String
        /// Hard floor of physical memory for this model, and the admission estimate: a working-set
        /// allowance plus a reserve that must be reclaimable before the models are loaded.
        let needsGiB: Double; let workingSetGiB: Double; let reserveGiB: Double
        var file: String { URL(string: url)?.lastPathComponent ?? "cleanup.gguf" }
    }
    struct Tier: Decodable, Equatable {
        let name: String
        /// What the user sees ("Max", "Standard", "Light") and why they would choose it.
        let label: String; let summary: String
        let startsAtGiB: Double; let cleanup: Cleanup?
    }
    let whisper: Whisper
    let tiers: [Tier]
    /// The largest pinned tier; what the setup window describes before a Mac is admitted.
    var largestPinned: Tier { tiers.first { $0.cleanup != nil }! }
    func tier(named name: String?) -> Tier? { tiers.first { $0.name == name } }
    static func load(_ url: URL) throws -> ModelSpec {
        let spec = try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: url))
        guard !spec.tiers.isEmpty, spec.tiers.contains(where: { $0.cleanup != nil }),
              zip(spec.tiers, spec.tiers.dropFirst()).allSatisfy({ $0.startsAtGiB > $1.startsAtGiB }) else {
            throw ModelError("models.json must list tiers largest first with at least one pinned cleanup model.")
        }
        return spec
    }
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

/// The executable a process is running, or nil once the process is gone.
func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// The private Ollama server: spawned by this launch, or left running by an earlier launch that
/// died without stopping it (a crash) and adopted with its model still warm.
enum OllamaServer {
    case spawned(Process), adopted(pid_t)
    var pid: pid_t { switch self { case .spawned(let p): return p.processIdentifier; case .adopted(let pid): return pid } }
    var isRunning: Bool { switch self { case .spawned(let p): return p.isRunning; case .adopted(let pid): return kill(pid, 0) == 0 } }
    func terminate() { switch self { case .spawned(let p): p.terminate(); case .adopted(let pid): kill(pid, SIGTERM) } }
}

/// Fetches, verifies, and prepares the models in Application Support. Nothing here touches the UI;
/// `report` receives a status line and, while a download runs, its fraction complete.
final class ModelStore {
    typealias Report = (_ status: String, _ fraction: Double?) -> Void
    let whisper: ModelSpec.Whisper
    /// The tier being served; switchable from the setup window, always one with a pinned model.
    var tier: ModelSpec.Tier { didSet { precondition(tier.cleanup != nil) } }
    var cleanup: ModelSpec.Cleanup { tier.cleanup! }
    let support: URL
    let resources: URL
    var modelfile: URL { resources.appendingPathComponent(cleanup.modelfile) }
    let endpoint: String
    private let fm = FileManager.default
    private var downloader: Process?

    init(whisper: ModelSpec.Whisper, tier: ModelSpec.Tier, support: URL, resources: URL, endpoint: String) {
        precondition(tier.cleanup != nil)
        self.whisper = whisper; self.tier = tier; self.support = support; self.resources = resources; self.endpoint = endpoint
    }

    var whisperFile: URL { support.appendingPathComponent("whisper.bin") }
    var ggufFile: URL { support.appendingPathComponent(cleanup.file) }
    var store: URL { support.appendingPathComponent("models-v1") }
    /// The pid of the Ollama server the last launch spawned, so a launch after a crash can find it.
    var ollamaPidFile: URL { support.appendingPathComponent("run/ollama.pid") }
    private var whisperStamp: URL { support.appendingPathComponent("whisper.bin.sha256") }
    private var ggufStamp: URL { support.appendingPathComponent(cleanup.file + ".sha256") }
    private var wrapperStamp: URL { store.appendingPathComponent(".bellow-wrapper") }
    /// What the wrapper in the store was built from: the shipped Modelfile and the weights.
    private var wrapperFingerprint: String? { (try? sha256Hex(of: modelfile)).map { $0 + "+" + cleanup.sha256 } }

    private func manifest(_ reference: String) -> URL {
        let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
        return store.appendingPathComponent("manifests/registry.ollama.ai/library").appendingPathComponent(parts[0]).appendingPathComponent(parts.count > 1 ? parts[1] : "latest")
    }
    /// A regular file of the pinned size whose checksum was verified when it was downloaded.
    private func verified(_ file: URL, stamp: URL, bytes: Int64, sha256: String) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int64) == bytes else { return false }
        return (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == sha256
    }
    var whisperReady: Bool { verified(whisperFile, stamp: whisperStamp, bytes: whisper.bytes, sha256: whisper.sha256) }
    var cleanupReady: Bool { verified(ggufFile, stamp: ggufStamp, bytes: cleanup.bytes, sha256: cleanup.sha256) }
    /// The wrapper was created from the Modelfile this build ships, on the pinned weights.
    var wrapperReady: Bool {
        guard fm.fileExists(atPath: manifest(cleanup.wrapper).path), let fingerprint = wrapperFingerprint else { return false }
        return (try? String(contentsOf: wrapperStamp, encoding: .utf8)) == fingerprint
    }
    var bytesToDownload: Int64 { (whisperReady ? 0 : whisper.bytes) + (cleanupReady ? 0 : cleanup.bytes) }

    /// Refuses a download that would not fit. Ollama also needs scratch space while verifying.
    func checkDiskSpace() throws {
        let needed = bytesToDownload
        guard needed > 0, let free = (try? fm.attributesOfFileSystem(forPath: support.path))?[.systemFreeSize] as? Int64 else { return }
        if free < needed + 2_000_000_000 {
            throw ModelError("Bellow needs \(gigabytes(needed + 2_000_000_000)) free to download its models; this disk has \(gigabytes(free)). Free some space and click Start.")
        }
    }

    func fetchWhisper(report: Report) async throws {
        try await fetch(label: "the speech model", url: whisper.url, sha256: whisper.sha256, bytes: whisper.bytes, to: whisperFile, stamp: whisperStamp, report: report)
    }
    func fetchCleanup(report: Report) async throws {
        try await fetch(label: "the \(tier.label) model", url: cleanup.url, sha256: cleanup.sha256, bytes: cleanup.bytes, to: ggufFile, stamp: ggufStamp, report: report)
    }

    /// Downloads a model file with curl (resumable, retried), then verifies the pinned checksum.
    private func fetch(label: String, url: String, sha256: String, bytes: Int64, to file: URL, stamp: URL, report: Report) async throws {
        try? fm.removeItem(at: file); try? fm.removeItem(at: stamp)
        let partial = support.appendingPathComponent(file.lastPathComponent + ".partial")
        for attempt in 0..<2 {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--retry-all-errors",
                              "--continue-at", "-", "--output", partial.path, url]
            let stderr = Pipe()
            curl.standardInput = FileHandle.nullDevice; curl.standardOutput = FileHandle.nullDevice; curl.standardError = stderr
            try curl.run(); downloader = curl
            defer { downloader = nil }
            while curl.isRunning {
                let done = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                report("Downloading \(label) · \(gigabytes(done)) of \(gigabytes(bytes))", Double(done) / Double(bytes))
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if curl.terminationStatus == 0 { break }
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 33: the server ignored the resume range. Start over once.
            if attempt == 0 && curl.terminationStatus == 33 { try? fm.removeItem(at: partial); continue }
            if curl.terminationStatus == 15 { throw CancellationError() }
            throw ModelError("Downloading \(label) failed (\(message.isEmpty ? "curl exit \(curl.terminationStatus)" : message)). Check the connection and click Start to resume.")
        }
        report("Checking \(label)…", nil)
        let hash = try await Task.detached { try sha256Hex(of: partial) }.value
        guard hash == sha256 else {
            try? fm.removeItem(at: partial)
            throw ModelError("The \(label) download was damaged. Click Start to download it again.")
        }
        try fm.moveItem(at: partial, to: file)
        try sha256.write(to: stamp, atomically: true, encoding: .utf8)
    }

    /// The server an earlier launch left on the port, if the pid it recorded is still running the
    /// bundled binary. It was started with our environment, so it serves our store; anything else
    /// answering on the port is someone else's.
    func leftoverOllama(binary: URL) -> OllamaServer? {
        guard let text = try? String(contentsOf: ollamaPidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let path = executablePath(of: pid),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == binary.resolvingSymlinksInPath().path else { return nil }
        return .adopted(pid)
    }

    /// Starts the private Ollama server on our store and waits until it answers, or adopts the one a
    /// crashed launch left behind rather than failing on the busy port.
    func startOllama(binary: URL, environment: [String: String], log: FileHandle?) async throws -> OllamaServer {
        if await ollamaResponds(endpoint, "/api/version") {
            if let leftover = leftoverOllama(binary: binary) { return leftover }
            throw ModelError("Port 11439 is already in use by something other than Bellow's engine. Quit that listener and retry.")
        }
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = binary; p.arguments = ["serve"]; p.environment = environment
        p.standardOutput = log ?? FileHandle.nullDevice; p.standardError = log ?? FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        try? fm.createDirectory(at: ollamaPidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(p.processIdentifier).write(to: ollamaPidFile, atomically: true, encoding: .utf8)
        for _ in 0..<120 {
            guard p.isRunning else { throw ModelError("The bundled Ollama engine exited. See engine.log.") }
            if await ollamaResponds(endpoint, "/api/version") { return .spawned(p) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stopOllama(.spawned(p))
        throw ModelError("Ollama did not become ready within 30 seconds.")
    }

    /// Asks the server to quit, forces it after three seconds, and forgets its pid.
    func stopOllama(_ server: OllamaServer) {
        try? fm.removeItem(at: ollamaPidFile)
        guard server.isRunning else { return }
        server.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if server.isRunning { kill(server.pid, SIGKILL) } }
    }

    /// Builds the wrapper from the bundled Modelfile on the verified weights. The GGUF is hard-linked
    /// into the store under its own digest first, so `ollama create` finds the blob in place instead of
    /// copying 1 to 3 GB; the Modelfile it imports is the shipped one with only its FROM line pointed
    /// at that file.
    func prepareCleanup(binary: URL, environment: [String: String], log: FileHandle?, report: Report) async throws {
        guard cleanupReady else { throw ModelError("The \(tier.label) model is not in place. Click Start to download it.") }
        guard !wrapperReady else { return }
        report("Preparing the \(tier.label) model…", nil)
        let blobs = store.appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("sha256-" + cleanup.sha256)
        if !fm.fileExists(atPath: blob.path) { try? fm.linkItem(at: ggufFile, to: blob) }
        let shipped = try String(contentsOf: modelfile, encoding: .utf8)
        let imported = shipped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("FROM ") ? "FROM " + ggufFile.path : String($0) }.joined(separator: "\n")
        let importFile = support.appendingPathComponent("Modelfile.import")
        try imported.write(to: importFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: importFile.path)
        defer { try? fm.removeItem(at: importFile) }
        let create = Process(); create.executableURL = binary
        create.arguments = ["create", cleanup.wrapper, "-f", importFile.path]; create.environment = environment
        create.standardOutput = log ?? FileHandle.nullDevice; create.standardError = log ?? FileHandle.nullDevice; create.standardInput = FileHandle.nullDevice
        try create.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in create.terminationHandler = { _ in c.resume() } }
        guard create.terminationStatus == 0 else { throw ModelError("The \(tier.label) model could not be prepared from its Modelfile. See engine.log.") }
        guard let fingerprint = wrapperFingerprint else { throw ModelError("The bundled Modelfile could not be read.") }
        try fingerprint.write(to: wrapperStamp, atomically: true, encoding: .utf8)
    }

    func cancel() { downloader?.terminate() }
}
