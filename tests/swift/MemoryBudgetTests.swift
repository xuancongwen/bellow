import XCTest
@testable import Bellow

/// Tier selection and admission against the shipped Resources/models.json.
final class MemoryBudgetTests: XCTestCase {
    let gib = Double(Hardware.gib)
    // Resources/models.json, found relative to this file so the shipped pins are what gets tested.
    let specURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/models.json")
    lazy var spec: ModelSpec = try! ModelSpec.load(specURL)
    /// The shipped spec with the Standard tier's model removed: the staging state before a tier is pinned.
    lazy var unpinnedSpec: ModelSpec = try! ModelSpec.load(rewritten { tiers in tiers[1]["cleanup"] = NSNull() })
    func rewritten(_ change: (inout [[String: Any]]) -> Void) -> URL {
        var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: specURL)) as! [String: Any]
        var tiers = json["tiers"] as! [[String: Any]]
        change(&tiers); json["tiers"] = tiers
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }
    func mac(_ gb: Double) -> Hardware { Hardware(physical: UInt64(gb * gib), chip: "test") }

    func testTiersComeFromTheSpecLargestFirst() {
        XCTAssertEqual(spec.tiers.map(\.name), ["max", "standard"])
        XCTAssertEqual(spec.tiers.map(\.startsAtGiB), [18, 8])
        XCTAssertEqual(spec.largestPinned.cleanup?.file, "Qwen3.5-4B-Q4_K_M.gguf")
        XCTAssertEqual(spec.tiers[1].cleanup?.file, "Qwen3.5-2B-Q4_K_M.gguf")
        XCTAssertEqual(spec.tiers.map(\.label), ["Max", "Standard"])
    }

    func testPhysicalMemoryPicksTheTier() {
        XCTAssertEqual(MemoryBudget.tier(in: spec, physicalGiB: 64)?.name, "max")
        XCTAssertEqual(MemoryBudget.tier(in: spec, physicalGiB: 24)?.name, "max")
        XCTAssertEqual(MemoryBudget.tier(in: spec, physicalGiB: 18)?.name, "max")
        XCTAssertEqual(MemoryBudget.tier(in: spec, physicalGiB: 16)?.name, "standard")
        XCTAssertEqual(MemoryBudget.tier(in: spec, physicalGiB: 8)?.name, "standard")
        XCTAssertNil(MemoryBudget.tier(in: spec, physicalGiB: 4))
    }

    func testEachTierServesItsOwnModel() {
        let max = MemoryBudget.select(in: spec, physicalGiB: 32)
        XCTAssertEqual(max?.serving.name, "max"); XCTAssertEqual(max?.isFallback, false)
        for gb in [8.0, 16.0] {
            let standard = MemoryBudget.select(in: spec, physicalGiB: gb)
            XCTAssertEqual(standard?.serving.name, "standard"); XCTAssertEqual(standard?.isFallback, false)
        }
    }

    func testUnpinnedTierFallsBackToTheNextLargerModelItCanHold() {
        // The Max model's floor is 16 GB, so a 16 GB Mac is served by Max while Standard is unpinned.
        let standard = MemoryBudget.select(in: unpinnedSpec, physicalGiB: 16)
        XCTAssertEqual(standard?.native.name, "standard"); XCTAssertEqual(standard?.serving.name, "max"); XCTAssertEqual(standard?.isFallback, true)
        // Nothing pinned fits an 8 GB Mac in that state.
        XCTAssertNil(MemoryBudget.select(in: unpinnedSpec, physicalGiB: 8))
        XCTAssertEqual(MemoryBudget.unavailable(unpinnedSpec.tiers[1], physicalGiB: 64), "Coming in a later version.")
        let unpinned = MemoryBudget.refusal(spec: unpinnedSpec, hardware: mac(8), available: UInt64(6 * gib))
        XCTAssertTrue(unpinned?.contains("Macs with 8 GB") == true && unpinned?.contains("needs 16 GB") == true, unpinned ?? "")
        let report = MemoryBudget.report(spec: unpinnedSpec, hardware: mac(16), available: UInt64(10 * gib))
        XCTAssertTrue(report.contains("Tier: standard (serving the max tier's model until one is pinned)"), report)
    }

    func testRefusalsExplainTheTierAndTheFloor() {
        XCTAssertNil(MemoryBudget.refusal(spec: spec, hardware: mac(32), available: UInt64(12 * gib)))
        XCTAssertNil(MemoryBudget.refusal(spec: spec, hardware: mac(16), available: UInt64(9 * gib)))
        let tooLittleFree = MemoryBudget.refusal(spec: spec, hardware: mac(32), available: UInt64(6.5 * gib))
        XCTAssertTrue(tooLittleFree?.contains("The Max model needs 7 GB free") == true, tooLittleFree ?? "")
        XCTAssertNil(MemoryBudget.refusal(spec: spec, hardware: mac(8), available: UInt64(5 * gib)))
        let standardShort = MemoryBudget.refusal(spec: spec, hardware: mac(8), available: UInt64(4 * gib))
        XCTAssertTrue(standardShort?.contains("The Standard model needs 4.5 GB free") == true, standardShort ?? "")
        let tiny = MemoryBudget.refusal(spec: spec, hardware: mac(4), available: UInt64(3 * gib))
        XCTAssertTrue(tiny?.contains("at least 8 GB") == true, tiny ?? "")
        XCTAssertEqual(MemoryBudget.refusal(spec: spec, hardware: mac(32), available: nil), "Could not check available memory. Restart the app before loading models.")
    }

    func testAnExplicitChoiceWinsOnlyWhenItIsPinnedAndFits() {
        // A chosen tier that is pinned and fits is served, even when automatic would pick otherwise.
        let chosen = MemoryBudget.select(in: spec, physicalGiB: 16, preferred: "max")
        XCTAssertEqual(chosen?.serving.name, "max"); XCTAssertEqual(chosen?.chosen, true); XCTAssertEqual(chosen?.isFallback, false)
        // A big Mac may choose Standard for speed.
        let smaller = MemoryBudget.select(in: spec, physicalGiB: 32, preferred: "standard")
        XCTAssertEqual(smaller?.serving.name, "standard"); XCTAssertEqual(smaller?.chosen, true)
        // An unpinned or ill-fitting choice quietly falls back to automatic.
        XCTAssertEqual(MemoryBudget.select(in: unpinnedSpec, physicalGiB: 32, preferred: "standard")?.chosen, false)
        XCTAssertEqual(MemoryBudget.select(in: spec, physicalGiB: 32, preferred: "nonsense")?.serving.name, "max")
        XCTAssertEqual(MemoryBudget.select(in: spec, physicalGiB: 8, preferred: "max")?.serving.name, "standard")
        XCTAssertEqual(MemoryBudget.unavailable(spec.tiers[0], physicalGiB: 8), "Needs 16 GB of memory; this Mac has 8 GB.")
        XCTAssertNil(MemoryBudget.unavailable(spec.tiers[0], physicalGiB: 16))
    }

    func testChoiceComesFromTheEnvironmentOrDefaults() {
        let defaults = UserDefaults(suiteName: "BellowTests.\(UUID().uuidString)")!
        XCTAssertNil(TierChoice.load(environment: [:], defaults: defaults))
        TierChoice.save("standard", defaults: defaults)
        XCTAssertEqual(TierChoice.load(environment: [:], defaults: defaults), "standard")
        XCTAssertEqual(TierChoice.load(environment: ["BELLOW_TIER": "max"], defaults: defaults), "max")
        XCTAssertNil(TierChoice.load(environment: ["BELLOW_TIER": "auto"], defaults: defaults))
        TierChoice.save(nil, defaults: defaults)
        XCTAssertNil(TierChoice.load(environment: [:], defaults: defaults))
    }

    func testMemoryOverrideExercisesOtherTiers() {
        XCTAssertEqual(Hardware.current(environment: ["BELLOW_MEMORY_GIB": "8"]).physicalGiB, 8)
        XCTAssertEqual(Hardware.current(environment: [:]).physical, ProcessInfo.processInfo.physicalMemory)
        XCTAssertFalse(Hardware.current().chip.isEmpty)
    }

    func testReportNamesTierModelAndVerdict() {
        let report = MemoryBudget.report(spec: spec, hardware: mac(16), available: UInt64(10 * gib))
        XCTAssertTrue(report.contains("Tier: standard\n"), report)
        XCTAssertTrue(report.contains("Cleanup model: Qwen3.5 2B (Qwen3.5-2B-Q4_K_M.gguf)"), report)
        XCTAssertTrue(report.contains("Choice: automatic"), report)
        XCTAssertTrue(MemoryBudget.report(spec: spec, hardware: mac(16), preferred: "max", available: UInt64(10 * gib)).contains("serving the chosen max tier"))
        XCTAssertTrue(MemoryBudget.report(spec: spec, hardware: mac(32), available: UInt64(10 * gib)).contains("Cleanup model: Qwen3.5 4B (Qwen3.5-4B-Q4_K_M.gguf)"))
        XCTAssertTrue(report.hasSuffix("Admission: ok"), report)
    }

    func testSpecRejectsMisorderedOrUnpinnedTiers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: specURL)) as! [String: Any]
        var tiers = json["tiers"] as! [[String: Any]]
        tiers.reverse(); json["tiers"] = tiers
        let misordered = dir.appendingPathComponent("misordered.json")
        try JSONSerialization.data(withJSONObject: json).write(to: misordered)
        XCTAssertThrowsError(try ModelSpec.load(misordered))
        json["tiers"] = tiers.map { var t = $0; t["cleanup"] = NSNull(); return t }
        let unpinned = dir.appendingPathComponent("unpinned.json")
        try JSONSerialization.data(withJSONObject: json).write(to: unpinned)
        XCTAssertThrowsError(try ModelSpec.load(unpinned))
    }
}
