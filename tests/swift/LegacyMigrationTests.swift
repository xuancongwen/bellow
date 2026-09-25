import XCTest
@testable import Bellow

/// Carry-over from an install made under the old name, BellowFlow.
final class LegacyMigrationTests: XCTestCase {
    let fm = FileManager.default
    var root: URL!
    var legacy: URL { root.appendingPathComponent("BellowFlow") }
    var support: URL { root.appendingPathComponent("Bellow") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    /// A data directory as the old app left it: models, the generated configuration, and runtime state.
    private func makeLegacy() throws {
        try fm.createDirectory(at: legacy.appendingPathComponent("models-v1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy.appendingPathComponent("run/voxtype"), withIntermediateDirectories: true)
        try "whisper".write(to: legacy.appendingPathComponent("whisper.bin"), atomically: true, encoding: .utf8)
        try "stamp".write(to: legacy.appendingPathComponent("models-v1/.bellowflow-wrapper"), atomically: true, encoding: .utf8)
        try "12345".write(to: legacy.appendingPathComponent("run/voxtype/voxtype.lock"), atomically: true, encoding: .utf8)
        try """
        # BellowFlow managed VoxType configuration. Edit, then quit and restart BellowFlow.
        [whisper]
        model = "\(legacy.path)/whisper.bin"
        [output.post_process]
        command = "exec '\(legacy.path)/VoxClean'"
        """.write(to: legacy.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    func testOldDirectoryIsMovedAndItsConfigurationPointsAtTheNewLocation() throws {
        try makeLegacy()
        XCTAssertTrue(LegacyMigration.migrateDirectory(legacy: legacy, support: support))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("whisper.bin").path))
        let config = try String(contentsOf: support.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("model = \"\(support.path)/whisper.bin\""), config)
        XCTAssertTrue(config.contains("command = \"exec '\(support.path)/VoxClean'\""), config)
        XCTAssertFalse(config.contains("BellowFlow"), "no reference to the old name may survive: \(config)")
        XCTAssertTrue(config.contains("# Bellow managed VoxType configuration"), config)
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("models-v1/.bellow-wrapper").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("models-v1/.bellowflow-wrapper").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("run").path), "stale daemon state is not carried over")
    }

    func testFreshInstallIsLeftAlone() {
        XCTAssertFalse(LegacyMigration.migrateDirectory(legacy: legacy, support: support))
        XCTAssertFalse(fm.fileExists(atPath: support.path))
    }

    func testExistingNewDirectoryIsNeverOverwritten() throws {
        try makeLegacy()
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try "keep".write(to: support.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertFalse(LegacyMigration.migrateDirectory(legacy: legacy, support: support))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("whisper.bin").path))
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("config.toml"), encoding: .utf8), "keep")
    }

    func testPreferencesAreCopiedOnceWithoutOverwriting() {
        let old = UserDefaults(suiteName: "LegacyMigrationTests.old.\(UUID().uuidString)")!
        let new = UserDefaults(suiteName: "LegacyMigrationTests.new.\(UUID().uuidString)")!
        old.set(true, forKey: "onboarded"); old.set("J", forKey: "shortcutKey"); old.set(38, forKey: "shortcutKeyCode")
        old.set(1048576, forKey: "shortcutModifiers"); old.set("light", forKey: TierChoice.key)
        new.set("max", forKey: TierChoice.key)
        LegacyMigration.migratePreferences(from: old, to: new)
        XCTAssertTrue(new.bool(forKey: "onboarded"))
        XCTAssertEqual(new.string(forKey: "shortcutKey"), "J")
        XCTAssertEqual(new.integer(forKey: "shortcutKeyCode"), 38)
        XCTAssertEqual(new.integer(forKey: "shortcutModifiers"), 1048576)
        XCTAssertEqual(new.string(forKey: TierChoice.key), "max", "a choice already made in the new app wins")
        old.set("Q", forKey: "shortcutKey"); new.removeObject(forKey: "shortcutKey")
        LegacyMigration.migratePreferences(from: old, to: new)
        XCTAssertNil(new.string(forKey: "shortcutKey"), "the copy happens once")
    }

    func testNoOldPreferencesIsFine() {
        let new = UserDefaults(suiteName: "LegacyMigrationTests.empty.\(UUID().uuidString)")!
        LegacyMigration.migratePreferences(from: nil, to: new)
        LegacyMigration.migratePreferences(from: UserDefaults(suiteName: "LegacyMigrationTests.none.\(UUID().uuidString)"), to: new)
        XCTAssertNil(new.object(forKey: "shortcutKey"))
    }
}
