import AppKit
import SwiftUI
import AVFoundation
import Carbon
import Combine

let fm = FileManager.default
// BELLOW_SUPPORT relocates the data directory (tests and scripted installs); default is Application Support.
let support = ProcessInfo.processInfo.environment["BELLOW_SUPPORT"].map { URL(fileURLWithPath: $0) }
    ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bellow")
let runtime = support.appendingPathComponent("run")
// Installs made under the app's old name keep their models, configuration, and preferences.
if ProcessInfo.processInfo.environment["BELLOW_SUPPORT"] == nil { LegacyMigration.run(support: support) }
let resources = Bundle.main.resourceURL!
let endpoint = "http://127.0.0.1:11439"
let spec = try! ModelSpec.load(resources.appendingPathComponent("models.json"))
let hardware = Hardware.current()
// Physical memory picks the tier and therefore the cleanup model, unless the user chose one in the
// setup window. A Mac whose tier has no model pinned yet is served by the next larger one when it
// meets that model's floor; otherwise start() refuses, and the largest model only labels the window.
func currentSelection(_ choice: String? = TierChoice.load()) -> Selection? {
    MemoryBudget.select(in: spec, physicalGiB: hardware.physicalGiB, preferred: choice)
}
let models = ModelStore(whisper: spec.whisper, tier: currentSelection()?.serving ?? spec.largestPinned, support: support, resources: resources, endpoint: endpoint)

func engineEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["XDG_RUNTIME_DIR"] = runtime.path
    env["RUST_LOG"] = "warn"
    env["OLLAMA_HOST"] = "127.0.0.1:11439"
    env["OLLAMA_MODELS"] = models.store.path
    env["OLLAMA_KEEP_ALIVE"] = "-1"
    env["OLLAMA_NUM_PARALLEL"] = "1"
    env["OLLAMA_FLASH_ATTENTION"] = "1"
    env["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
    env["OLLAMA_MAX_LOADED_MODELS"] = "1"
    // The private store holds exactly the pinned blobs; never let startup pruning touch it.
    env["OLLAMA_NOPRUNE"] = "1"
    env["BELLOW_OLLAMA"] = endpoint
    env["BELLOW_MODEL"] = models.cleanup.wrapper
    return env
}

/// `Bellow --prepare-models`: download and prepare the models without the UI, for scripts and tests.
func prepareModelsHeadless() -> Int32 {
    let ollamaBinary = resources.appendingPathComponent("ollama/ollama")
    var server: OllamaServer?
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    var last = ""
    let report: ModelStore.Report = { text, fraction in
        let line = fraction.map { text + String(format: "  (%.0f%%)", $0 * 100) } ?? text
        if line != last { print(line); last = line }
    }
    Task {
        do {
            try fm.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try models.checkDiskSpace()
            if models.whisperReady { print("Speech model: ready") } else { try await models.fetchWhisper(report: report) }
            if !models.cleanupReady { try await models.fetchCleanup(report: report) }
            if models.wrapperReady { print("\(models.tier.label) model: ready") } else {
                server = try await models.startOllama(binary: ollamaBinary, environment: engineEnvironment(), log: nil)
                try await models.prepareCleanup(binary: ollamaBinary, environment: engineEnvironment(), log: nil, report: report)
            }
            print("Models ready in \(support.path)")
        } catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); status = 1 }
        // A server adopted from a running Bellow stays up; it is that app's engine.
        if let server = server, case .spawned = server { models.stopOllama(server) }
        done.signal()
    }
    done.wait()
    return status
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func tomlQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}

final class Overlay {
    private static let width: CGFloat = 300
    private static let oneLine: CGFloat = 52
    private static let twoLines: CGFloat = 88
    private let label = NSTextField(labelWithString: "")
    private let meter = LevelView(frame: NSRect(x: 16, y: 14, width: 268, height: 24))
    private let visual: NSVisualEffectView
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Overlay.width, height: Overlay.oneLine), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    init() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        visual = NSVisualEffectView(frame: panel.contentView!.bounds)
        visual.autoresizingMask = [.width, .height]
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 20
        visual.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        visual.addSubview(label)
        meter.isHidden = true
        visual.addSubview(meter)
        panel.contentView = visual
        layout()
    }
    /// One line of text, or the text above a full-width level meter while recording. The panel keeps its
    /// bottom edge in place and grows upward so the switch does not shift it on screen.
    private func layout() {
        let height = meter.isHidden ? Overlay.oneLine : Overlay.twoLines
        if panel.frame.height != height { panel.setContentSize(NSSize(width: Overlay.width, height: height)) }
        label.frame = NSRect(x: 16, y: height - 36, width: Overlay.width - 32, height: 22)
    }
    /// Live microphone level while recording; nil hides the meter and drops back to a single line.
    func level(_ value: Float?) {
        if let value = value {
            if meter.isHidden { meter.reset(); meter.isHidden = false; layout() }
            meter.push(value)
        } else if !meter.isHidden { meter.isHidden = true; layout() }
    }
    func show(_ text: String) {
        label.stringValue = text
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - Overlay.width / 2, y: frame.minY + 65)) }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class AppModel: ObservableObject {
    @Published var status = "Welcome"
    @Published var busy = false
    @Published var ready = false
    @Published var failed = false
    @Published var progress: Double?
    @Published var shortcut = Shortcut.load()
    /// The chosen cleanup tier, or nil for automatic. Saved in UserDefaults.
    @Published var choice: String? = TierChoice.load()
    var selection: Selection? { currentSelection(choice) }
    /// "Max model · Qwen 2.5 7B" for the setup window.
    var modelLine: String {
        guard let selection = selection else { return "No cleanup model for this Mac yet" }
        return "\(selection.serving.label) model · \(selection.cleanup.name)"
    }
    var memoryLine: String {
        let floor = spec.tiers.compactMap(\.cleanup).map(\.needsGiB).min() ?? 0
        return "This Mac has \(MemoryBudget.gb(hardware.physicalGiB)) of memory; this version needs \(MemoryBudget.gb(floor)) or more."
    }
    private var restartPending = false
    /// Switches the cleanup model. A running or loading setup is restarted so the choice takes effect now.
    func choose(_ name: String?) {
        guard name != choice else { return }
        choice = name; TierChoice.save(name)
        guard let serving = selection?.serving, serving.cleanup != nil else { return }
        guard serving.name != models.tier.name else { return }
        models.tier = serving
        if ready { stop(); start() }
        else if busy { restartPending = true; stop() }
    }
    /// Set by the delegate: re-registers the hot key and reports whether the combination was free.
    var registerShortcut: ((Shortcut) -> Bool)?
    func setShortcut(_ new: Shortcut) {
        guard registerShortcut?(new) ?? true else {
            status = "\(new.label) is taken by another app. The shortcut is still \(shortcut.label)."
            _ = registerShortcut?(shortcut); return
        }
        shortcut = new; new.save()
        if ready { status = "Ready · \(new.label) to dictate" }
    }
    private var engine: Process?
    private var ollama: OllamaServer?
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var stopping = false
    private var pressure: DispatchSourceMemoryPressure?
    private var memoryBlocked = false
    private let overlay = Overlay()
    private let meter = LevelMeter()
    private var log: FileHandle?
    private var lastState = ""
    var environment: [String: String] { engineEnvironment() }
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
        if let reason = MemoryBudget.refusal(spec: spec, hardware: hardware, preferred: choice) { status = reason; failed = true; return }
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
            log?.write(Data((MemoryBudget.report(spec: spec, hardware: hardware, preferred: choice) + "\n").utf8))
            let ollamaBinary = resources.appendingPathComponent("ollama/ollama")
            guard fm.isExecutableFile(atPath: resources.appendingPathComponent("bin/voxtype").path),
                  fm.isExecutableFile(atPath: ollamaBinary.path) else { throw problem("This app is missing its bundled engines. Rebuild with scripts/build-macos.sh.") }
            // Models are downloaded once into Application Support and verified against the pinned
            // checksums in models.json. Later launches only check that they are in place.
            let report: ModelStore.Report = { [weak self] text, fraction in
                DispatchQueue.main.async { self?.status = text; self?.progress = fraction }
            }
            try models.checkDiskSpace()
            if !models.whisperReady { try await models.fetchWhisper(report: report) }
            if !models.cleanupReady { try await models.fetchCleanup(report: report) }
            progress = nil
            ollama = try await models.startOllama(binary: ollamaBinary, environment: environment, log: log)
            try await models.prepareCleanup(binary: ollamaBinary, environment: environment, log: log, report: report)
            progress = nil
            status = "Loading the \(models.tier.label) model…"
            var warm = URLRequest(url: URL(string: endpoint + "/api/generate")!)
            warm.httpMethod = "POST"; warm.timeoutInterval = 180
            warm.setValue("application/json", forHTTPHeaderField: "Content-Type")
            warm.httpBody = try JSONSerialization.data(withJSONObject: ["model": models.cleanup.wrapper, "prompt": "", "stream": false, "keep_alive": -1, "think": false])
            let (_, response) = try await URLSession.shared.data(for: warm)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw problem("The bundled cleanup model could not be loaded. See engine.log.") }
            // A stable support path avoids breaking the config if the app bundle moves.
            let link = support.appendingPathComponent("VoxClean")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/VoxClean"))
            if !fm.fileExists(atPath: config.path) { try initialConfig().write(to: config, atomically: true, encoding: .utf8) }
            try? fm.removeItem(at: runtime.appendingPathComponent("cleanup-state"))
            try? fm.removeItem(at: runtime.appendingPathComponent("voxtype/state"))
            engine = try spawn(resources.appendingPathComponent("bin/voxtype"), ["--config", config.path, "daemon"])
            status = "Loading the speech model…"
            var engineReady = false
            for _ in 0..<720 {
                guard engine?.isRunning == true else { throw problem("VoxType exited. Check engine.log and the helper's macOS permissions.") }
                if readState() == "idle" { engineReady = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard engineReady else { throw problem("The speech model did not become ready within three minutes.") }
            startWatching()
            watchMemory()
            ready = true; busy = false; status = "Ready · \(shortcut.label) to dictate"
            UserDefaults.standard.set(true, forKey: "onboarded")
            // Health check only: no subprocess or frequent filesystem polling at idle.
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self, !self.stopping else { return }
                if self.engine?.isRunning != true || self.ollama?.isRunning != true {
                    self.stop(); self.failed = true; self.status = "An engine stopped. Open setup to restart."
                }
            }
        } catch is CancellationError {
            stop(); busy = false; progress = nil; status = "Download cancelled. Click Start to resume."
        } catch {
            stop(); busy = false; failed = true; progress = nil; status = error.localizedDescription
        }
        if restartPending { restartPending = false; stop(); busy = false; start() }
    }
    private func problem(_ text: String) -> NSError { NSError(domain: "Bellow", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
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
        # Bellow managed VoxType configuration. Edit, then quit and restart Bellow.
        engine = "whisper"
        state_file = "auto"

        [hotkey]
        # Bellow owns the global shortcut; the built-in hotkey would need Input Monitoring.
        enabled = false

        [osd]
        # Bellow draws its own overlay.
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
                self.status = "Memory pressure: new recordings paused. Close other apps, or quit Bellow to release its models."
                self.overlay.show("Memory pressure · dictation paused")
            } else {
                self.memoryBlocked = false
                self.status = "Ready · \(self.shortcut.label) to dictate"
                self.updateOverlay()
            }
        }
        pressure = source; source.resume()
    }
    private var activeTimer: Timer?
    private func updateOverlay() {
        let state = readState()
        if memoryBlocked && state == "idle" { overlay.show("Memory pressure · dictation paused"); return }
        if state == "recording" {
            if lastState != "recording" { meter.onLevel = { [weak self] level in self?.overlay.level(level) }; meter.start() }
        } else if lastState == "recording" { meter.stop(); overlay.level(nil) }
        if state == "idle" { overlay.hide(); activeTimer?.invalidate(); activeTimer = nil }
        else if state == "recording" { overlay.show("●  Listening · \(shortcut.label) to finish") }
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
        models.cancel()
        pressure?.setEventHandler {}; pressure?.cancel(); pressure = nil; memoryBlocked = false
        timer?.invalidate(); timer = nil
        activeTimer?.invalidate(); activeTimer = nil
        watcher?.cancel(); watcher = nil
        meter.stop(); overlay.level(nil); lastState = ""
        if let p = engine, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        if let server = ollama { models.stopOllama(server) }
        engine = nil; ollama = nil; overlay.hide()
    }
}

/// The sheet behind "Change…": every tier with why you would pick it, and Automatic on top.
struct ModelChooser: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var automatic: ModelSpec.Tier? { currentSelection(nil)?.serving }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup model").font(.title2.bold())
            Text("After each dictation a language model on this Mac tidies the transcript. Larger models edit more carefully but need more memory and take longer to answer. Automatic picks the largest one this Mac runs comfortably.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row(nil, "Automatic", automatic.map { "Recommended. On this Mac that is the \($0.label) model." } ?? "No model fits this Mac yet.", nil)
            ForEach(spec.tiers, id: \.name) { tier in
                let reason = MemoryBudget.unavailable(tier, physicalGiB: hardware.physicalGiB)
                let need = tier.cleanup.map { " Needs \(MemoryBudget.gb($0.needsGiB)) of memory, best with \(MemoryBudget.gb(tier.startsAtGiB)) or more; a \(gigabytes($0.bytes)) download." } ?? ""
                row(tier.name, tier.label, tier.summary + need, reason)
            }
            Text("This Mac: \(hardware.chip), \(MemoryBudget.gb(hardware.physicalGiB)) of memory. Changing the model downloads it once and restarts dictation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480)
    }
    private func row(_ name: String?, _ title: String, _ detail: String, _ reason: String?) -> some View {
        let selected = model.choice == name
        return Button { model.choose(name) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let reason = reason { Text(reason).font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(reason != nil).opacity(reason == nil ? 1 : 0.55)
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var showModels = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 48)).foregroundStyle(.mint)
            Text("Your voice. Your Mac.").font(.system(size: 30, weight: .bold))
            Text("Local dictation, with your words cleaned up and typed wherever you're working.").font(.title3).foregroundStyle(.secondary)
            Divider()
            Label("Whisper large-v3-turbo Q5 · English", systemImage: "mic")
            HStack {
                Label(model.modelLine, systemImage: "sparkles")
                Spacer()
                Button("Change…") { showModels = true }
            }.sheet(isPresented: $showModels) { ModelChooser(model: model) }
            ShortcutRecorder(model: model)
            Divider()
            Label("Microphone " + (model.microphone ? "granted" : "not granted"), systemImage: model.microphone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.microphone ? Color.green : Color.secondary)
            Label("Accessibility " + (model.accessibility ? "granted" : "not granted (needed to type into other apps)"), systemImage: model.accessibility ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.accessibility ? Color.green : Color.secondary)
            Text("First start downloads the speech and cleanup models (about \(gigabytes(spec.whisper.bytes + models.cleanup.bytes)), once; an interrupted download resumes) and asks for macOS permissions. Models stay warm until you quit. \(model.memoryLine)").font(.callout).foregroundStyle(.secondary)
            if let progress = model.progress { ProgressView(value: progress) } else if model.busy { ProgressView().controlSize(.small) }
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
    let hotkey = HotkeyRegistrar()
    var toggleItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.bellow.app")
        if siblings.count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Bellow")
        let menu = NSMenu()
        for (title, selector) in [("Start / finish dictation  \(model.shortcut.label)", #selector(toggle)), ("Cancel recording", #selector(cancel)), ("Setup and status…", #selector(showSetup)), ("Quit Bellow", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
            if selector == #selector(toggle) { toggleItem = entry }
        }
        item.menu = menu
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Bellow"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.setContentSize(NSSize(width: 530, height: 640)); window.center()
        // Ordinary window level: a floating window sits above the system's permission prompts and
        // hides them. The app has no Dock icon, so the window may drop behind System Settings, but
        // it comes back through the menu bar item and whenever the app is activated (below).
        window.hidesOnDeactivate = false
        model.onSetupNeeded = { [weak self] in self?.showSetup() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.model.ready else { return }
            self.window.makeKeyAndOrderFront(nil)
        }
        hotkey.onPress = { [weak self] in self?.model.control("toggle") }
        model.registerShortcut = { [weak self] shortcut in
            guard let self = self, self.hotkey.register(shortcut) else { return false }
            self.toggleItem?.title = "Start / finish dictation  \(shortcut.label)"
            return true
        }
        if !hotkey.register(model.shortcut) { model.status = "\(model.shortcut.label) is taken by another app. Change the shortcut below."; showSetup() }
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
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
if CommandLine.arguments.contains("--prepare-models") { exit(prepareModelsHeadless()) }
// `Bellow --hardware`: print what this Mac has and which tier and model it gets, then exit.
if CommandLine.arguments.contains("--hardware") { print(MemoryBudget.report(spec: spec, hardware: hardware, preferred: TierChoice.load())); exit(0) }
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
