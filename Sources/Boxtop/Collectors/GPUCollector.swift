import CSysInfo
import Foundation
import IOKit

/// GPU statistics.
///
/// Every Mac exposes `IOAccelerator` services with a public "PerformanceStatistics"
/// dictionary (utilization, memory), which covers Intel iGPUs, AMD dGPUs and Apple GPUs.
/// On Apple Silicon this is combined with btop's IOReport sampler for frequency and power.
final class GPUCollector {
    private let ioreportAvailable: Bool
    private let chipName: String

    /// Whether any GPU with statistics exists (decides if the default layout includes the gpu pane).
    private(set) var hasGPU = false

    init(chipName: String) {
        self.chipName = chipName
        ioreportAvailable = bt_gpu_ioreport_init()
        hasGPU = !collect(temperature: nil).isEmpty
    }

    func collect(temperature: Double?) -> [GPUSample] {
        var gpus: [GPUSample] = []
        IORegistry.forEach(matching: "IOAccelerator") { entry in
            guard let stats = IORegistry.property(entry, "PerformanceStatistics", as: [String: Any].self) else { return }
            // Real GPUs always report utilization; this skips shims such as the
            // IOServiceCompatibility accelerator macOS exposes to Rosetta processes.
            guard let utilization = DriverValue.number(stats, "Device Utilization %", in: 0...100)
                    ?? DriverValue.number(stats, "GPU Activity(%)", in: 0...100)
                    ?? DriverValue.number(stats, "Renderer Utilization %", in: 0...100) else { return }
            let className = Self.className(entry)
            let isApple = className.hasPrefix("AGX")
            let model = Self.pciModel(entry).flatMap { $0.isEmpty || $0 == "Unknown Unknown" ? nil : $0 }

            var gpu = GPUSample(id: "\(className)-\(gpus.count)", name: isApple ? "\(chipName) GPU" : model ?? className)
            gpu.utilization = utilization
            // Discrete GPUs report VRAM (AMD: inUseVidMemoryBytes + vramFreeBytes, VRAM,totalMB on the
            // PCI device); integrated ones report shared system memory (Apple / Intel).
            if let used = DriverValue.bytes(stats, "vramUsedBytes") ?? DriverValue.bytes(stats, "inUseVidMemoryBytes").flatMap({ $0 > 0 ? $0 : nil }) {
                gpu.memoryUsed = used
                if let vramMB = Self.pciVRAM(entry) {
                    gpu.memoryTotal = vramMB * 1024 * 1024
                } else if let free = DriverValue.bytes(stats, "vramFreeBytes") {
                    gpu.memoryTotal = used + free
                }
            } else if let used = DriverValue.bytes(stats, "In use system memory") ?? DriverValue.bytes(stats, "inUseSysMemoryBytes") {
                gpu.memoryUsed = used
            }
            // AMD drivers also publish sensors in the same dictionary.
            gpu.temperature = DriverValue.number(stats, "Temperature(C)", in: 1...150)
            gpu.powerWatts = DriverValue.number(stats, "Total Power(W)", in: 0...2000)
            gpu.frequencyMHz = DriverValue.number(stats, "Core Clock(MHz)", in: 1...10000)
            gpu.fanRPM = DriverValue.number(stats, "Fan Speed(RPM)", in: 0...20000)
            if isApple {
                gpu.coreCount = IORegistry.property(entry, "gpu-core-count", as: NSNumber.self)?.intValue
                gpu.temperature = temperature
            }
            gpus.append(gpu)
        }

        // Apple Silicon: prefer btop's IOReport residency-based utilization, add clock and power.
        if ioreportAvailable, let index = gpus.firstIndex(where: { $0.id.hasPrefix("AGX") }) {
            var sample = bt_gpu_sample()
            if bt_gpu_ioreport_sample(&sample) {
                if sample.has_utilization, let value = sample.utilization.sane(0...100) { gpus[index].utilization = value }
                if sample.has_freq, let value = sample.freq_mhz.sane(1...10000) { gpus[index].frequencyMHz = value }
                if sample.has_power, let value = sample.power_w.sane(0...2000) { gpus[index].powerWatts = value }
            }
        } else if let temperature, let index = gpus.lastIndex(where: { $0.temperature == nil }), gpus.count == 1 || !gpus[index].id.hasPrefix("Intel") {
            gpus[index].temperature = temperature
        }
        return gpus
    }


    private static func className(_ entry: io_object_t) -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buffer.deallocate() }
        guard IOObjectGetClass(entry, buffer) == KERN_SUCCESS else { return "GPU" }
        return String(cString: buffer)
    }

    /// Walks up to the PCI device for "model" (e.g. "AMD Radeon Pro 5500M", "Intel UHD Graphics 630").
    private static func pciModel(_ entry: io_object_t) -> String? {
        parentProperty(entry, "model", as: Data.self)?.registryString
    }

    private static func pciVRAM(_ entry: io_object_t) -> UInt64? {
        guard let mb = parentProperty(entry, "VRAM,totalMB", as: NSNumber.self)?.int64Value, mb > 0, mb < 1 << 24 else { return nil }
        return UInt64(mb)
    }

    private static func parentProperty<T>(_ entry: io_object_t, _ key: String, as type: T.Type) -> T? {
        guard let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) else { return nil }
        return value as? T
    }
}
