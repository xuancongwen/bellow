import Foundation
import Darwin

struct MemoryBudget {
    static let gib: UInt64 = 1_073_741_824
    // Conservative admission estimates, not a claim of a hard process limit.
    static let estimatedWorkingSet: UInt64 = 7 * gib
    static let reserve: UInt64 = 2 * gib
    static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Inactive pages may be reclaimed; compressed/wired/active pages are excluded.
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_page_size)
    }
    static func refusal(physical: UInt64 = ProcessInfo.processInfo.physicalMemory, available: UInt64? = availableBytes()) -> String? {
        guard physical >= 16 * gib else {
            return "This Qwen 7B + Whisper bundle requires at least 16 GB RAM. A smaller-model edition is needed for this Mac; models have not been loaded."
        }
        guard let available = available else { return "Could not check available memory. Restart the app before loading models." }
        guard available >= estimatedWorkingSet + reserve else {
            return String(format: "About %.1f GB of reclaimable RAM is available. This bundle reserves 9 GB before loading both models. Close some apps and retry.", Double(available) / Double(gib))
        }
        return nil
    }
}
