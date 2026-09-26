import XCTest
@testable import Bellow

/// Adopting the engine a crashed launch left on the port, and telling it apart from other listeners.
final class OllamaServerTests: XCTestCase {
    let fm = FileManager.default
    let specURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/models.json")
    let sleeper = URL(fileURLWithPath: "/bin/sleep")
    var support: URL!
    var store: ModelStore!
    /// Stands in for a leftover server: a process we know the pid and executable of.
    var child: Process!

    override func setUpWithError() throws {
        support = fm.temporaryDirectory.appendingPathComponent("OllamaServerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: support.appendingPathComponent("run"), withIntermediateDirectories: true)
        let spec = try ModelSpec.load(specURL)
        store = ModelStore(whisper: spec.whisper, tier: spec.largestPinned, support: support, resources: support, endpoint: "http://127.0.0.1:1")
        child = Process(); child.executableURL = sleeper; child.arguments = ["30"]; try child.run()
    }
    override func tearDownWithError() throws {
        if child.isRunning { child.terminate() }
        try? fm.removeItem(at: support)
    }
    func record(_ pid: Int32) throws { try String(pid).write(to: store.ollamaPidFile, atomically: true, encoding: .utf8) }

    func testAdoptsTheRecordedPidWhileItStillRunsOurBinary() throws {
        try record(child.processIdentifier)
        guard case .adopted(let pid)? = store.leftoverOllama(binary: sleeper) else { return XCTFail("the leftover server was not adopted") }
        XCTAssertEqual(pid, child.processIdentifier)
    }

    func testIgnoresAnotherProgramOnTheRecordedPid() throws {
        try record(child.processIdentifier)
        XCTAssertNil(store.leftoverOllama(binary: URL(fileURLWithPath: "/bin/cat")))
    }

    func testIgnoresAPidThatHasExited() throws {
        child.terminate(); child.waitUntilExit()
        try record(child.processIdentifier)
        XCTAssertNil(store.leftoverOllama(binary: sleeper))
    }

    func testIgnoresAMissingOrGarbledPidFile() throws {
        XCTAssertNil(store.leftoverOllama(binary: sleeper))
        try "not a pid".write(to: store.ollamaPidFile, atomically: true, encoding: .utf8)
        XCTAssertNil(store.leftoverOllama(binary: sleeper))
    }

    func testStopEndsAnAdoptedServerAndForgetsItsPid() throws {
        try record(child.processIdentifier)
        let server = try XCTUnwrap(store.leftoverOllama(binary: sleeper))
        XCTAssertTrue(server.isRunning)
        store.stopOllama(server)
        child.waitUntilExit()
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(fm.fileExists(atPath: store.ollamaPidFile.path))
    }
}
