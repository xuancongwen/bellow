import AppKit
import Carbon
import SwiftUI

/// The global dictation shortcut. Stored in user defaults; the default is Control-Option-X.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
    let key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: [.control, .option], key: "X")
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// "⌃⌥X", in the order macOS shows modifiers.
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// A key press becomes a shortcut only with Control, Option, or Command held, so ordinary
    /// typing can never trigger dictation. Shift alone is not enough.
    init?(event: NSEvent) {
        let held = event.modifierFlags.intersection(Shortcut.relevant)
        guard !held.isDisjoint(with: [.control, .option, .command]) else { return nil }
        guard let name = Shortcut.name(for: event) else { return nil }
        keyCode = UInt32(event.keyCode); modifiers = held; key = name
    }
    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    private static func name(for event: NSEvent) -> String? {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(first), !chars.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return chars.uppercased()
    }

    static func load() -> Shortcut {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: "shortcutKey"), defaults.object(forKey: "shortcutKeyCode") != nil else { return .default }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: "shortcutKeyCode")),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "shortcutModifiers"))), key: key)
    }
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: "shortcutKeyCode")
        defaults.set(Int(modifiers.rawValue), forKey: "shortcutModifiers")
        defaults.set(key, forKey: "shortcutKey")
    }
}

/// Owns the Carbon hot key registration and re-registers it whenever the shortcut changes.
final class HotkeyRegistrar {
    private var ref: EventHotKeyRef?
    private let signature: OSType = 0x42464C57 // "BFLW"
    var onPress: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
    /// False when another app already owns the combination.
    @discardableResult func register(_ shortcut: Shortcut) -> Bool {
        if let ref = ref { UnregisterEventHotKey(ref); self.ref = nil }
        let id = EventHotKeyID(signature: signature, id: 1)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
    deinit { if let ref = ref { UnregisterEventHotKey(ref) } }
}

/// "⌃⌥X  [Change…]": click Change, press the new combination, Escape to keep the old one.
struct ShortcutRecorder: View {
    @ObservedObject var model: AppModel
    @State private var monitor: Any?
    @State private var hint = ""
    var recording: Bool { monitor != nil }
    var body: some View {
        HStack {
            Label("\(model.shortcut.label) to start and finish", systemImage: "keyboard")
            Spacer()
            if !hint.isEmpty { Text(hint).font(.callout).foregroundStyle(.secondary) }
            if model.shortcut != .default && !recording { Button("Reset") { model.setShortcut(.default) } }
            Button(recording ? "Press keys… (Esc cancels)" : "Change…") { recording ? stop() : start() }
        }
    }
    private func start() {
        hint = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty { stop(); return nil }
            if let shortcut = Shortcut(event: event) { model.setShortcut(shortcut); stop() }
            else { hint = "Hold Control, Option, or Command with a key" }
            return nil
        }
    }
    private func stop() { if let monitor = monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
