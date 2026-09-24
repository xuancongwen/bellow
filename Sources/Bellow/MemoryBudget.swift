import Foundation
import Darwin

/// What this Mac has. Physical memory decides the tier; the chip is recorded for diagnostics only,
/// because on Apple Silicon every generation shares the same unified-memory rules (macOS lets the GPU
/// wire about two thirds of RAM up to 36 GB, three quarters above) and the chip changes speed, not fit.
struct Hardware {
    static let gib: UInt64 = 1_073_741_824
    let physical: UInt64
    let chip: String
    var physicalGiB: Double { Double(physical) / Double(Hardware.gib) }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Hardware {
        // BELLOW_MEMORY_GIB pretends this Mac has that much RAM, to exercise the other tiers.
        let physical = environment["BELLOW_MEMORY_GIB"].flatMap(Double.init).map { UInt64($0 * Double(gib)) }
            ?? ProcessInfo.processInfo.physicalMemory
        return Hardware(physical: physical, chip: sysctlString("machdep.cpu.brand_string") ?? "unknown")
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Pages macOS can hand out without compressing or swapping: free plus inactive. Wired, active,
    /// and compressed pages are excluded.
    static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_page_size)
    }
}

/// The user's cleanup-model choice: a tier name, or nil for automatic. BELLOW_TIER overrides
/// the saved preference for scripts and tests.
enum TierChoice {
    static let key = "cleanupTier"
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> String? {
        if let forced = environment["BELLOW_TIER"] { return forced.isEmpty || forced == "auto" ? nil : forced }
        return defaults.string(forKey: key)
    }
    static func save(_ name: String?, defaults: UserDefaults = .standard) {
        if let name = name { defaults.set(name, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Which tier a Mac lands in and which pinned cleanup model serves it.
struct Selection: Equatable {
    /// The tier this Mac's memory places it in.
    let native: ModelSpec.Tier
    /// The tier whose model is actually loaded: the user's choice when it is pinned and fits; otherwise
    /// `native`, or the nearest larger tier when the native one has no model pinned yet and this Mac
    /// still meets that model's floor.
    let serving: ModelSpec.Tier
    /// True when `serving` is the user's explicit choice rather than the automatic pick.
    let chosen: Bool
    var cleanup: ModelSpec.Cleanup { serving.cleanup! }
    var isFallback: Bool { !chosen && native.name != serving.name }
}

enum MemoryBudget {
    static func gb(_ gib: Double) -> String { String(format: gib == gib.rounded() ? "%.0f GB" : "%.1f GB", gib) }

    /// The tier for a Mac with this much RAM, or nil below the smallest tier.
    static func tier(in spec: ModelSpec, physicalGiB: Double) -> ModelSpec.Tier? {
        spec.tiers.first { physicalGiB >= $0.startsAtGiB }
    }

    /// Whether a tier can be chosen on this Mac, or the reason it cannot.
    static func unavailable(_ tier: ModelSpec.Tier, physicalGiB: Double) -> String? {
        guard let cleanup = tier.cleanup else { return "Coming in a later version." }
        guard physicalGiB >= cleanup.needsGiB else { return "Needs \(gb(cleanup.needsGiB)) of memory; this Mac has \(gb(physicalGiB))." }
        return nil
    }

    static func select(in spec: ModelSpec, physicalGiB: Double, preferred: String? = nil) -> Selection? {
        guard let native = tier(in: spec, physicalGiB: physicalGiB), let index = spec.tiers.firstIndex(of: native) else { return nil }
        if let wanted = spec.tier(named: preferred), unavailable(wanted, physicalGiB: physicalGiB) == nil {
            return Selection(native: native, serving: wanted, chosen: true)
        }
        // Tiers are listed largest first, so walking backwards from the native one only reaches larger models.
        for candidate in spec.tiers[...index].reversed() where unavailable(candidate, physicalGiB: physicalGiB) == nil {
            return Selection(native: native, serving: candidate, chosen: false)
        }
        return nil
    }

    /// Why this Mac cannot load models right now, or nil to proceed. Conservative admission estimates,
    /// not an enforceable cap: nothing is mlocked, and macOS can still page model memory under pressure.
    static func refusal(spec: ModelSpec, hardware: Hardware, preferred: String? = nil, available: UInt64? = Hardware.availableBytes()) -> String? {
        let physical = hardware.physicalGiB
        guard tier(in: spec, physicalGiB: physical) != nil else {
            return "Bellow needs at least \(gb(spec.tiers.last?.startsAtGiB ?? 0)) of memory; this Mac has \(gb(physical)). Models have not been loaded."
        }
        guard let selection = select(in: spec, physicalGiB: physical, preferred: preferred) else {
            let smallest = spec.tiers.compactMap(\.cleanup).map(\.needsGiB).min() ?? 0
            return "This version has no cleanup model for Macs with \(gb(physical)) yet; the smallest one needs \(gb(smallest)). Models have not been loaded."
        }
        let cleanup = selection.cleanup
        guard let available = available else { return "Could not check available memory. Restart the app before loading models." }
        let needed = UInt64((cleanup.workingSetGiB + cleanup.reserveGiB) * Double(Hardware.gib))
        guard available >= needed else {
            return String(format: "About %.1f GB of memory is free. The %@ model needs %@ free to load (%@ for the models plus %@ in reserve). Close some apps and retry.",
                          Double(available) / Double(Hardware.gib), selection.serving.label, gb(cleanup.workingSetGiB + cleanup.reserveGiB), gb(cleanup.workingSetGiB), gb(cleanup.reserveGiB))
        }
        return nil
    }

    /// One line per fact, for `Bellow --hardware` and engine.log.
    static func report(spec: ModelSpec, hardware: Hardware, preferred: String? = nil, available: UInt64? = Hardware.availableBytes()) -> String {
        var lines = ["Chip: \(hardware.chip)", "Memory: \(gb(hardware.physicalGiB)) physical"]
        if let available = available { lines.append(String(format: "Reclaimable now: %.1f GB", Double(available) / Double(Hardware.gib))) }
        let tiers = spec.tiers.map { "\($0.name) (\($0.label)) from \(gb($0.startsAtGiB)): \($0.cleanup?.name ?? "no model pinned")" }
        lines.append("Tiers: " + tiers.joined(separator: "; "))
        lines.append("Choice: " + (preferred ?? "automatic"))
        if let selection = select(in: spec, physicalGiB: hardware.physicalGiB, preferred: preferred) {
            var tier = "Tier: \(selection.native.name)"
            if selection.chosen { tier += " (serving the chosen \(selection.serving.name) tier)" }
            else if selection.isFallback { tier += " (serving the \(selection.serving.name) tier's model until one is pinned)" }
            lines.append(tier)
            lines.append("Cleanup model: \(selection.cleanup.name) (\(selection.cleanup.file)), needs \(gb(selection.cleanup.needsGiB)), reserves \(gb(selection.cleanup.workingSetGiB + selection.cleanup.reserveGiB))")
        } else {
            lines.append("Tier: " + (tier(in: spec, physicalGiB: hardware.physicalGiB)?.name ?? "below the smallest tier"))
        }
        lines.append("Speech model: \(spec.whisper.name)")
        lines.append("Admission: " + (refusal(spec: spec, hardware: hardware, preferred: preferred, available: available) ?? "ok"))
        return lines.joined(separator: "\n")
    }
}
