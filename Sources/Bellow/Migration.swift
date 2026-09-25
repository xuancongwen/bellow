import AppKit

/// One-time carry-over of everything an install wrote under the app's old name, BellowFlow: the data
/// directory with its models and configuration, and the preferences saved under the old bundle identifier.
enum LegacyMigration {
    static let oldName = "BellowFlow"
    static let oldBundleID = "org.bellowflow.app"
    static let preferenceKeys = ["onboarded", "shortcutKey", "shortcutKeyCode", "shortcutModifiers", TierChoice.key]

    /// Runs both migrations for the default data directory, unless the old app still holds its files.
    static func run(support: URL) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).isEmpty else { return }
        migrateDirectory(legacy: support.deletingLastPathComponent().appendingPathComponent(oldName), support: support)
        migratePreferences(from: UserDefaults(suiteName: oldBundleID))
    }

    /// Moves `legacy` to `support` and rewrites what inside it refers to the old location or name.
    /// Does nothing when there is no old directory or the new one already exists. Returns whether it moved.
    @discardableResult
    static func migrateDirectory(legacy: URL, support: URL, fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: support.path) else { return false }
        do { try fm.moveItem(at: legacy, to: support) } catch { return false }
        // The generated VoxType configuration holds absolute paths into the data directory (the speech
        // model and the cleanup helper) and comments naming the app. Point both at the new location.
        let config = support.appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            let rewritten = text.replacingOccurrences(of: legacy.path, with: support.path).replacingOccurrences(of: oldName, with: "Bellow")
            if rewritten != text { try? rewritten.write(to: config, atomically: true, encoding: .utf8) }
        }
        // The cleanup-model stamp carries the app name; keeping it avoids rebuilding the wrapper.
        let store = support.appendingPathComponent("models-v1")
        try? fm.moveItem(at: store.appendingPathComponent(".bellowflow-wrapper"), to: store.appendingPathComponent(".bellow-wrapper"))
        // Runtime state belongs to the daemon that wrote it; the next launch recreates it.
        try? fm.removeItem(at: support.appendingPathComponent("run"))
        return true
    }

    /// Copies the preferences the old bundle identifier saved (onboarding, shortcut, cleanup model) into
    /// the new domain, once, without overwriting anything already set there.
    static func migratePreferences(from old: UserDefaults?, to defaults: UserDefaults = .standard) {
        let marker = "migratedFromBellowFlow"
        guard !defaults.bool(forKey: marker), let old = old else { return }
        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
