import Darwin
import Foundation

/// Memory and swap from `host_statistics64` and `vm.swapusage` (btop `Mem::collect`, src/osx).
///
/// btop reports used = active + wired. Boxtop uses Activity Monitor's definition instead
/// (app + wired + compressed) so the numbers line up with what macOS shows elsewhere.
final class MemoryCollector {
    let total: UInt64
    private let pageSize: UInt64

    init() {
        total = UInt64(Sysctl.int("hw.memsize") ?? 0)
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        pageSize = UInt64(size == 0 ? 16384 : size)
    }

    func collect() -> MemorySample {
        var sample = MemorySample()
        sample.total = total

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            sample.wired = UInt64(stats.wire_count) * pageSize
            sample.compressed = UInt64(stats.compressor_page_count) * pageSize
            sample.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            sample.used = min(total, sample.app + sample.wired + sample.compressed)
            sample.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
            sample.free = UInt64(stats.free_count) * pageSize
            sample.available = total > sample.used ? total - sample.used : 0
        }

        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            sample.swapTotal = swap.xsu_total
            sample.swapUsed = swap.xsu_used
        }

        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"),
           let pressure = MemoryPressure(rawValue: level) {
            sample.pressure = pressure
        }
        return sample
    }
}
