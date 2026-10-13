import Darwin
import Foundation
import IOKit

/// Per-core and total CPU usage from `host_processor_info`, ported from btop's `Cpu::collect` (src/osx).
final class CPUCollector {
    let info: CPUInfo
    private var previousTicks: [[UInt64]] = []  // per core: user, system, idle, nice

    init() {
        var info = CPUInfo()
        info.model = Self.modelName()
        info.logicalCores = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        info.physicalCores = Sysctl.int("hw.physicalcpu") ?? info.logicalCores
        #if arch(arm64)
        info.isAppleSilicon = true
        #else
        // An x86_64 slice can still run on Apple Silicon under Rosetta.
        info.isAppleSilicon = (Sysctl.int("sysctl.proc_translated") ?? 0) == 1
        #endif
        (info.coreKinds, info.clusterSummary, info.clusterNames) = Self.clusterLayout(cores: info.logicalCores)
        self.info = info
    }

    func collect() -> CPUSample {
        var sample = CPUSample()

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { sample.loadAverage = load }

        if let boot = Sysctl.value("kern.boottime", as: timeval.self) {
            sample.uptime = Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        }

        // Intel Macs expose a nominal frequency; Apple Silicon does not (same as btop).
        if let hz = Sysctl.int("hw.cpufrequency"), hz > 0 {
            sample.frequencyGHz = Double(hz) / 1_000_000_000
        }

        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return sample }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt64]] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * states
            current.append([
                UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])),
                UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])),
                UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])),
                UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])),
            ])
        }

        if previousTicks.count == current.count {
            var sumUser = 0.0, sumSystem = 0.0, sumNice = 0.0, sumIdle = 0.0, sumAll = 0.0
            sample.cores = zip(current, previousTicks).map { now, before in
                // Counters are 32-bit and can wrap; treat a decrease as a wrap.
                let delta = (0..<4).map { i in Double((now[i] &- before[i]) & 0xFFFF_FFFF) }
                let total = delta.reduce(0, +)
                sumUser += delta[0]; sumSystem += delta[1]; sumIdle += delta[2]; sumNice += delta[3]
                sumAll += total
                guard total > 0 else { return 0 }
                return min(100, max(0, (total - delta[2]) * 100 / total))
            }
            if sumAll > 0 {
                sample.total = min(100, max(0, (sumAll - sumIdle) * 100 / sumAll))
                sample.user = sumUser * 100 / sumAll
                sample.system = sumSystem * 100 / sumAll
                sample.nice = sumNice * 100 / sumAll
            }
        } else {
            sample.cores = Array(repeating: 0, count: current.count)
        }
        previousTicks = current
        return sample
    }

    private static func modelName() -> String {
        var name = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        // Trim the noise btop also strips from Intel brand strings.
        for noise in ["(R)", "(TM)", "CPU ", "Processor"] {
            name = name.replacingOccurrences(of: noise, with: "")
        }
        if let at = name.range(of: " @") { name = String(name[..<at.lowerBound]) }
        return name.split(separator: " ").joined(separator: " ")
    }

    /// Labels each logical core with its cluster on Apple Silicon by matching the
    /// IODeviceTree `cluster-type` of every cpu node with `hw.perflevelN` names.
    private static func clusterLayout(cores: Int) -> ([String], String, [String: String]) {
        let levels = Sysctl.int("hw.nperflevels") ?? 0
        guard levels > 1 else { return ([], "", [:]) }

        var perfLevels: [(name: String, count: Int)] = []
        for level in 0..<levels {
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            let count = Sysctl.int("hw.perflevel\(level).logicalcpu") ?? 0
            perfLevels.append((name, count))
        }
        let summary = perfLevels.map { "\($0.count) \($0.name)" }.joined(separator: " + ")

        // cpu index -> cluster letter from the device tree.
        var clusterByCPU: [Int: String] = [:]
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if root != 0 {
            defer { IOObjectRelease(root) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let child = IOIteratorNext(iterator), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard let type = IORegistry.property(child, "cluster-type", as: Data.self)?.registryString,
                          let id = IORegistry.property(child, "logical-cpu-id", as: NSNumber.self)?.intValue else { continue }
                    clusterByCPU[id] = type
                }
            }
        }
        guard clusterByCPU.count == cores else { return ([], summary, [:]) }

        // Match each cluster letter to a perf level with the same core count.
        var countsByLetter: [String: Int] = [:]
        for letter in clusterByCPU.values { countsByLetter[letter, default: 0] += 1 }
        var tagForLetter: [String: String] = [:]
        var names: [String: String] = [:]
        var unused = perfLevels
        for (letter, count) in countsByLetter.sorted(by: { $0.key < $1.key }) {
            // Core count is the reliable key (M5's "P" cluster is the "Super" level);
            // the name initial only breaks ties such as M1's 4 E + 4 P.
            let candidates = unused.indices.filter { unused[$0].count == count }
            let match = candidates.first { unused[$0].name.uppercased().hasPrefix(letter) } ?? candidates.first
            if let match {
                let tag = String(unused[match].name.prefix(1)).uppercased()
                tagForLetter[letter] = tag
                names[tag] = unused[match].name
                unused.remove(at: match)
            } else {
                tagForLetter[letter] = letter
            }
        }
        let tags = (0..<cores).map { tagForLetter[clusterByCPU[$0] ?? ""] ?? "" }
        return (tags, summary, names)
    }
}
