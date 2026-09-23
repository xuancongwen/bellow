import AppKit
import SwiftUI
import AVFoundation
import Carbon
import Combine

let fm = FileManager.default
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BellowFlow")
let runtime = support.appendingPathComponent("run")
let resources = Bundle.main.resourceURL!
let endpoint = "http://127.0.0.1:11439"

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func tomlQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}

final class Overlay {
    private let label = NSTextField(labelWithString: "")
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    init() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let visual = NSVisualEffectView(frame: panel.contentView!.bounds)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 20
        visual.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: 16, width: 248, height: 22)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        visual.addSubview(label)
        panel.contentView = visual
    }
    func show(_ text: String) {
        label.stringValue = text
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - 140, y: frame.minY + 65)) }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class AppModel: ObservableObject {
    @Published var status = "Welcome"
    @Published var busy = false
    @Published var ready = false
    @Published var failed = false
    private var engine: Process?
    private var ollama: Process?
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var stopping = false
    private var pressure: DispatchSourceMemoryPressure?
    private var memoryBlocked = false
    private let overlay = Overlay()
    private var log: FileHandle?
    private var lastState = ""
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["XDG_RUNTIME_DIR"] = runtime.path
        env["RUST_LOG"] = "warn"
        env["OLLAMA_HOST"] = "127.0.0.1:11439"
        env["OLLAMA_MODELS"] = support.appendingPathComponent("models-v1").path
        env["OLLAMA_KEEP_ALIVE"] = "-1"
        env["OLLAMA_NUM_PARALLEL"] = "1"
        env["OLLAMA_FLASH_ATTENTION"] = "1"
        env["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
        env["OLLAMA_MAX_LOADED_MODELS"] = "1"
        // The private store holds exactly the shipped blobs; never let startup pruning touch it.
        env["OLLAMA_NOPRUNE"] = "1"
        env["BELLOWFLOW_OLLAMA"] = endpoint
        return env
    }
    var config: URL { support.appendingPathComponent("config.toml") }
    var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var accessibility: Bool { AXIsProcessTrusted() }

    var onSetupNeeded: (() -> Void)?
    private var permissionTimer: Timer?
    func permissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.objectWillChange.send(); self.onSetupNeeded?() } }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        watchPermissions()
    }
    /// Accessibility grants arrive silently from System Settings; poll until both are in place.
    func watchPermissions() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.objectWillChange.send()
            if self.microphone && self.accessibility {
                timer.invalidate(); self.permissionTimer = nil
                if !self.ready && !self.busy { self.status = "Permissions granted. Click Start."; self.onSetupNeeded?() }
            }
        }
    }
    func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openFiles() { NSWorkspace.shared.open(support) }
    func start() {
        guard !busy, !ready else { return }
        guard microphone, accessibility else {
            status = "Allow Microphone and Accessibility; Start becomes available once both are granted."
            permissions(); return
        }
        if let reason = MemoryBudget.refusal() { status = reason; failed = true; return }
        busy = true; failed = false; stopping = false
        Task { await launch() }
    }
    @MainActor private func launch() async {
        do {
            status = "Preparing local models…"
            try fm.createDirectory(at: runtime.appendingPathComponent("voxtype"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            let logURL = support.appendingPathComponent("engine.log")
            // Reset diagnostic log each launch; suppress upstream info/debug transcript logging.
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            log = try FileHandle(forWritingTo: logURL)
            guard fm.isExecutableFile(atPath: resources.appendingPathComponent("bin/voxtype").path),
                  fm.fileExists(atPath: resources.appendingPathComponent("whisper.bin").path) else { throw problem("This app is missing its bundled engine or Whisper model. Rebuild with scripts/build-macos.sh.") }
            // Copy only once, outside the main thread. The signed app bundle remains immutable.
            let destination = support.appendingPathComponent("models-v1")
            let source = resources.appendingPathComponent("models")
            try await Task.detached {
                if !fm.fileExists(atPath: destination.path) {
                    let staging = support.appendingPathComponent("models-staging")
                    try? fm.removeItem(at: staging)
                    try fm.copyItem(at: source, to: staging)
                    try fm.moveItem(at: staging, to: destination)
                }
            }.value
            // Refuse to take over a listener belonging to another process.
            if await responds("/api/version") { throw problem("Port 11439 is already in use. Quit the other BellowFlow instance or listener and retry.") }
            ollama = try spawn(resources.appendingPathComponent("ollama/ollama"), ["serve"])
            status = "Loading Qwen 2.5 7B…"
            var listening = false
            for _ in 0..<120 {
                guard ollama?.isRunning == true else { throw problem("The bundled Ollama engine exited. See engine.log.") }
                if await responds("/api/version") { listening = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard listening else { throw problem("Ollama did not become ready within 30 seconds.") }
            var warm = URLRequest(url: URL(string: endpoint + "/api/generate")!)
            warm.httpMethod = "POST"; warm.timeoutInterval = 180
            warm.setValue("application/json", forHTTPHeaderField: "Content-Type")
            warm.httpBody = try JSONSerialization.data(withJSONObject: ["model": "voxtype-llm-wrapper", "prompt": "", "stream": false, "keep_alive": -1])
            let (_, response) = try await URLSession.shared.data(for: warm)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw problem("The bundled cleanup model could not be loaded. See engine.log.") }
            // Stable support paths avoid breaking the config if the app bundle moves.
            for (name, target) in [("whisper.bin", resources.appendingPathComponent("whisper.bin")),
                                   ("VoxClean", Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/VoxClean"))] {
                let link = support.appendingPathComponent(name)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
            if !fm.fileExists(atPath: config.path) { try initialConfig().write(to: config, atomically: true, encoding: .utf8) }
            try? fm.removeItem(at: runtime.appendingPathComponent("cleanup-state"))
            try? fm.removeItem(at: runtime.appendingPathComponent("voxtype/state"))
            engine = try spawn(resources.appendingPathComponent("bin/voxtype"), ["--config", config.path, "daemon"])
            status = "Loading Whisper…"
            var engineReady = false
            for _ in 0..<720 {
                guard engine?.isRunning == true else { throw problem("VoxType exited. Check engine.log and the helper's macOS permissions.") }
                if readState() == "idle" { engineReady = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard engineReady else { throw problem("Whisper did not become ready within three minutes.") }
            startWatching()
            watchMemory()
            ready = true; busy = false; status = "Ready · ⌃⌥Space to dictate"
            UserDefaults.standard.set(true, forKey: "onboarded")
            // Health check only: no subprocess or frequent filesystem polling at idle.
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self, !self.stopping else { return }
                if self.engine?.isRunning != true || self.ollama?.isRunning != true {
                    self.stop(); self.failed = true; self.status = "An engine stopped. Open setup to restart."
                }
            }
        } catch {
            stop(); busy = false; failed = true; status = error.localizedDescription
        }
    }
    private func problem(_ text: String) -> NSError { NSError(domain: "BellowFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func responds(_ path: String) async -> Bool {
        var req = URLRequest(url: URL(string: endpoint + path)!); req.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    private func spawn(_ binary: URL, _ args: [String]) throws -> Process {
        let p = Process(); p.executableURL = binary; p.arguments = args; p.environment = environment
        p.standardOutput = log ?? FileHandle.nullDevice; p.standardError = log ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run(); return p
    }
    private func initialConfig() -> String {
        // Generated once; stable symlinks above track the installed bundle.
        // Every key below exists in the pinned VoxType. Upstream ignores unknown keys silently,
        // so tests/test_config_template.py guards this template.
        """
        # BellowFlow managed VoxType configuration. Edit, then quit and restart BellowFlow.
        engine = "whisper"
        state_file = "auto"

        [hotkey]
        # BellowFlow owns the global shortcut; the built-in hotkey would need Input Monitoring.
        enabled = false

        [osd]
        # BellowFlow draws its own overlay.
        enabled = false

        [audio]
        device = "default"
        sample_rate = 16000
        max_duration_secs = 120

        [whisper]
        mode = "local"
        model = \(tomlQuote(support.appendingPathComponent("whisper.bin").path))
        language = "en"
        translate = false
        flash_attention = true
        gpu_isolation = false
        on_demand_loading = false
        max_loaded_models = 1
        cold_model_timeout_secs = 0

        [output]
        mode = "type"
        fallback_to_clipboard = true
        auto_submit = false

        [output.notification]
        # Upstream defaults to a macOS notification containing the transcript. Keep dictation private.
        on_recording_start = false
        on_recording_stop = false
        on_transcription = false

        [output.post_process]
        command = \(tomlQuote("exec " + shellQuote(support.appendingPathComponent("VoxClean").path)))
        timeout_ms = 60000
        trim = true
        fallback_on_empty = true
        """
    }
    func control(_ action: String) {
        guard ready else { return }
        // Do not start a second capture while a transcript is in flight.
        let state = readState()
        if memoryBlocked && state != "recording" && action != "cancel" { return }
        guard state == "idle" || state == "recording" || action == "cancel" else { return }
        do { _ = try spawn(resources.appendingPathComponent("bin/voxtype"), ["--config", config.path, "record", action]) }
        catch { status = error.localizedDescription }
    }
    private func readState() -> String {
        (try? String(contentsOf: runtime.appendingPathComponent("voxtype/state"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private func startWatching() {
        // Pinned VoxType writes this file in place; watch the file, not its directory.
        watchFD = open(runtime.appendingPathComponent("voxtype/state").path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let fd = watchFD
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.updateOverlay() }
        source.setCancelHandler { close(fd) }
        watcher = source; source.resume()
        updateOverlay()
    }
    private func watchMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if source.data.contains(.critical) || source.data.contains(.warning) {
                self.memoryBlocked = true
                self.status = "Memory pressure: new recordings paused. Close other apps, or quit BellowFlow to release its models."
                self.overlay.show("Memory pressure · dictation paused")
            } else {
                self.memoryBlocked = false
                self.status = "Ready · ⌃⌥Space to dictate"
                self.updateOverlay()
            }
        }
        pressure = source; source.resume()
    }
    private var activeTimer: Timer?
    private func updateOverlay() {
        let state = readState()
        if memoryBlocked && state == "idle" { overlay.show("Memory pressure · dictation paused"); return }
        if state == "idle" { overlay.hide(); activeTimer?.invalidate(); activeTimer = nil }
        else if state == "recording" { overlay.show("●  Listening · ⌃⌥Space to finish") }
        else if state == "transcribing" {
            let cleaning = fm.fileExists(atPath: runtime.appendingPathComponent("cleanup-state").path)
            overlay.show(cleaning ? "✦  Cleaning up…" : "•••  Transcribing…")
        }
        if state != "idle" && activeTimer == nil {
            activeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.updateOverlay() }
        }
        lastState = state
    }
    func stop() {
        stopping = true; ready = false
        pressure?.setEventHandler {}; pressure?.cancel(); pressure = nil; memoryBlocked = false
        timer?.invalidate(); timer = nil
        activeTimer?.invalidate(); activeTimer = nil
        watcher?.cancel(); watcher = nil
        for p in [engine, ollama].compactMap({ $0 }) where p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        engine = nil; ollama = nil; overlay.hide()
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundStyle(.mint)
            Text("Your voice. Your Mac.").font(.system(size: 30, weight: .bold))
            Text("Local dictation, with your words cleaned up and typed wherever you're working.").font(.title3).foregroundStyle(.secondary)
            Divider()
            Label("Whisper large-v3-turbo Q5 · English", systemImage: "mic")
            Label("Qwen 2.5 7B · your original Modelfile", systemImage: "sparkles")
            Label("Control + Option + Space to start and finish", systemImage: "keyboard")
            Divider()
            Label("Microphone " + (model.microphone ? "granted" : "not granted"), systemImage: model.microphone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.microphone ? Color.green : Color.secondary)
            Label("Accessibility " + (model.accessibility ? "granted" : "not granted (needed to type into other apps)"), systemImage: model.accessibility ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.accessibility ? Color.green : Color.secondary)
            Text("First launch prepares the bundled models and asks for macOS permissions. Models stay warm until you quit. This bundle needs 16 GB RAM or more; 24 GB+ is recommended.").font(.callout).foregroundStyle(.secondary)
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.callout).foregroundStyle(model.failed ? Color.red : Color.secondary).textSelection(.enabled)
            HStack {
                Button("Permissions") { model.permissions() }
                Button("Privacy Settings") { model.openPrivacy() }
                Spacer()
                Button(model.ready ? "Ready" : "Start") { model.start() }.buttonStyle(.borderedProminent).disabled(model.busy || model.ready)
            }
            Button("Open configuration and diagnostic log") { model.openFiles() }.buttonStyle(.link)
        }.padding(30).frame(width: 530)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    var window: NSWindow!
    var hotkey: EventHotKeyRef?
    var readyObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.bellowflow.app")
        if siblings.count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "BellowFlow")
        let menu = NSMenu()
        for (title, selector) in [("Start / finish dictation  ⌃⌥Space", #selector(toggle)), ("Cancel recording", #selector(cancel)), ("Setup and status…", #selector(showSetup)), ("Quit BellowFlow", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "BellowFlow"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.setContentSize(NSSize(width: 530, height: 640)); window.center()
        // The app has no Dock icon, so the setup window must stay reachable while the user is
        // in System Settings; otherwise it drops behind everything and looks like it closed.
        window.level = .floating
        window.hidesOnDeactivate = false
        model.onSetupNeeded = { [weak self] in self?.showSetup() }
        readyObserver = model.$ready.sink { [weak self] ready in self?.window.level = ready ? .normal : .floating }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.model.ready else { return }
            self.window.makeKeyAndOrderFront(nil)
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Delegate>.fromOpaque(userData).takeUnretainedValue().model.control("toggle")
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x42464C57 /* "BFLW" */, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr { model.status = "The shortcut is in use by another app. Free Control–Option–Space, then relaunch."; showSetup() }
        else if UserDefaults.standard.bool(forKey: "onboarded") { model.start() }
        else { showSetup() }
    }
    @objc func toggle() { model.control("toggle") }
    @objc func cancel() { model.control("cancel") }
    @objc func showSetup() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !model.ready { model.watchPermissions() }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.stop(); if let hotkey = hotkey { UnregisterEventHotKey(hotkey) } }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
