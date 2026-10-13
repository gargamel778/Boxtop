import Foundation
import Observation

/// Fixed-capacity series used by graphs (btop keeps similar deques per stat).
struct History: Sendable, Equatable {
    private(set) var values: [Double] = []
    var capacity: Int

    init(capacity: Int = 600) { self.capacity = capacity }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double { values.last ?? 0 }
    var isEmpty: Bool { values.isEmpty }
}

struct NetHistory: Equatable {
    var rx = History()
    var tx = History()
}

/// Main-actor model the views observe. Applies samples and accumulates graph histories.
@MainActor
@Observable
final class SystemMonitor {
    let cpuInfo: CPUInfo
    let hasTemperatures: Bool
    let hasGPU: Bool

    private(set) var latest: SystemSample?
    private(set) var cpuTotal = History()
    private(set) var cpuSystem = History()
    private(set) var cpuCores: [History]
    private(set) var cpuTemperature = History()
    private(set) var memUsed = History()
    private(set) var memAvailable = History()
    private(set) var memCached = History()
    private(set) var memFree = History()
    private(set) var swapUsed = History()
    private(set) var net: [String: NetHistory] = [:]
    private(set) var gpuUtilization: [String: History] = [:]
    private(set) var diskActivity: [String: History] = [:]
    private(set) var processCPU: [Int32: History] = [:]
    private(set) var processMemory: [Int32: History] = [:]
    private(set) var sampleCount = 0

    /// Screenshot mode: personal details are removed from every sample (see Redactor).
    @ObservationIgnored var redactsPersonalDetails = false
    @ObservationIgnored private var sampler: Sampler!
    @ObservationIgnored private var configuration = Sampler.Configuration()

    private final class WeakRef: @unchecked Sendable {
        weak var monitor: SystemMonitor?
    }

    init() {
        let ref = WeakRef()
        let sampler = Sampler { sample in
            Task { @MainActor in ref.monitor?.apply(sample) }
        }
        cpuInfo = sampler.cpuInfo
        hasTemperatures = sampler.hasTemperatures
        hasGPU = sampler.hasGPU
        cpuCores = Array(repeating: History(capacity: 120), count: sampler.cpuInfo.logicalCores)
        self.sampler = sampler
        ref.monitor = self
    }

    func start(interval: TimeInterval, showHiddenDisks: Bool) {
        configuration.interval = interval
        configuration.showHiddenDisks = showHiddenDisks
        sampler.start(with: configuration)
    }

    func configure(_ change: @escaping @Sendable (inout Sampler.Configuration) -> Void) {
        change(&configuration)
        sampler.update(change)
    }

    func resetNetworkTotals() { sampler.resetNetworkTotals() }

    private func apply(_ incoming: SystemSample) {
        let sample = redactsPersonalDetails ? Redactor.redact(incoming) : incoming
        latest = sample
        sampleCount += 1

        cpuTotal.append(sample.cpu.total)
        cpuSystem.append(sample.cpu.system)
        for (index, value) in sample.cpu.cores.enumerated() where index < cpuCores.count {
            cpuCores[index].append(value)
        }
        if let package = sample.sensors.cpuPackage { cpuTemperature.append(package) }

        let mem = sample.memory
        let total = Double(max(1, mem.total))
        memUsed.append(Double(mem.used) * 100 / total)
        memAvailable.append(Double(mem.available) * 100 / total)
        memCached.append(Double(mem.cached) * 100 / total)
        memFree.append(Double(mem.free) * 100 / total)
        swapUsed.append(mem.swapTotal > 0 ? Double(mem.swapUsed) * 100 / Double(mem.swapTotal) : 0)

        var newNet: [String: NetHistory] = [:]
        for iface in sample.network {
            var history = net[iface.name] ?? NetHistory()
            history.rx.append(iface.rxRate)
            history.tx.append(iface.txRate)
            newNet[iface.name] = history
        }
        net = newNet

        var newGPU: [String: History] = [:]
        for gpu in sample.gpus {
            var history = gpuUtilization[gpu.id] ?? History()
            history.append(gpu.utilization ?? 0)
            newGPU[gpu.id] = history
        }
        gpuUtilization = newGPU

        var newDisk: [String: History] = [:]
        for disk in sample.disks {
            var history = diskActivity[disk.id] ?? History(capacity: 120)
            history.append((disk.readRate ?? 0) + (disk.writeRate ?? 0))
            newDisk[disk.id] = history
        }
        diskActivity = newDisk

        var newCPU: [Int32: History] = [:]
        var newMem: [Int32: History] = [:]
        newCPU.reserveCapacity(sample.processes.count)
        for process in sample.processes {
            var cpu = processCPU[process.pid] ?? History(capacity: 120)
            cpu.append(process.cpuPerCore)
            newCPU[process.pid] = cpu
            if let existing = processMemory[process.pid] ?? (configuration.detailPID == process.pid ? History(capacity: 120) : nil) {
                var mem = existing
                mem.append(Double(process.residentBytes))
                newMem[process.pid] = mem
            }
        }
        processCPU = newCPU
        processMemory = newMem.filter { $0.key == configuration.detailPID }
    }
}
