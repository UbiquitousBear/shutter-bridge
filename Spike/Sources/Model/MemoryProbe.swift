import Foundation
import Darwin

/// Memory high-water mark during a transfer (spike day 3 and 8; budget ≤ 150 MB). Reads the same
/// `phys_footprint` figure Xcode's memory gauge and Instruments' Allocations top line show, so the logged number
/// can be compared with them.
enum MemoryProbe {
    /// Current physical footprint in bytes, or 0 if the kernel call fails.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

extension SpikeLog {
    /// Runs `body`, sampling the footprint every 100 ms, and records `<name>.memory.peak` in MB.
    func withMemoryPeak<T>(_ name: String, context: String = "", _ body: () async throws -> T) async rethrows -> T {
        let sampled = try await samplingMemoryPeak(body)
        measure("\(name).memory.peak", Double(sampled.peak) / 1_000_000, "MB",
                context: "baseline \(sampled.baseline / 1_000_000) MB" + (context.isEmpty ? "" : ", \(context)"))
        return sampled.value
    }

    /// Build 14: runs `body`, sampling as withMemoryPeak does, and returns the peak and the baseline footprint (bytes)
    /// without recording them: a copy that pauses records one peak for the whole copy, when it ends (CopyAllRun).
    func samplingMemoryPeak<T>(_ body: () async throws -> T) async rethrows -> (value: T, peak: UInt64, baseline: UInt64) {
        let baseline = MemoryProbe.footprint()
        let sampler = Task.detached(priority: .utility) { () -> UInt64 in
            var peak = MemoryProbe.footprint()
            while !Task.isCancelled {
                peak = max(peak, MemoryProbe.footprint())
                try? await Task.sleep(for: .milliseconds(100))
            }
            return peak
        }
        defer { sampler.cancel() }
        let value = try await body()
        sampler.cancel()
        let peak = max(await sampler.value, MemoryProbe.footprint())
        return (value, peak, baseline)
    }
}
