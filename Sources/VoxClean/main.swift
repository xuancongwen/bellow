import Foundation

// No transcript is ever placed in argv, a shell command, or a log file.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8), !text.isEmpty else { exit(0) }
let env = ProcessInfo.processInfo.environment
let endpoint = env["BELLOW_OLLAMA"] ?? "http://127.0.0.1:11439"
// The wrapper name the app created for this Mac's memory tier (Resources/models.json).
let model = env["BELLOW_MODEL"] ?? "voxtype-llm-wrapper"
let runtime = env["XDG_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
let state = runtime?.appendingPathComponent("cleanup-state")
if let state = state { try? "cleaning".write(to: state, atomically: true, encoding: .utf8) }
defer { if let state = state { try? FileManager.default.removeItem(at: state) } }
var request = URLRequest(url: URL(string: endpoint + "/api/chat")!)
request.httpMethod = "POST"
request.timeoutInterval = 55
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONSerialization.data(withJSONObject: [
    // Qwen3.5 would otherwise reason at length before answering, and Ollama uses the GGUF's own
    // chat template (thinking on) rather than the Modelfile's, so thinking is switched off here.
    "model": model, "stream": false, "keep_alive": -1, "think": false,
    "messages": [["role": "user", "content": text]],
    "options": ["temperature": 0.0, "num_ctx": 4096, "num_predict": 2048]
])
let done = DispatchSemaphore(value: 0)
final class ResultBox {
    private let lock = NSLock()
    private var value: String?
    func set(_ text: String) { lock.lock(); defer { lock.unlock() }; value = text }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
let output = ResultBox()
let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { done.signal() }
    guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
          let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["done"] as? Bool == true, json["done_reason"] as? String != "length",
          let message = json["message"] as? [String: Any], let result = message["content"] as? String else { return }
    output.set(result.trimmingCharacters(in: .whitespacesAndNewlines))
}
task.resume()
if done.wait(timeout: .now() + 56) == .timedOut { task.cancel() }
// Failure and empty output preserve raw text, matching the repository's configuration.
let result = output.get().flatMap { $0.isEmpty ? nil : $0 } ?? text
FileHandle.standardOutput.write(Data(result.utf8))
