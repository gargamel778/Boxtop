import Foundation

/// Runs every collector on one serial background queue at the configured interval
/// (btop's Runner thread) and hands immutable `SystemSample`s to the main actor.
final class Sampler: @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        var interval: TimeInterval = 1.0
        var showHiddenDisks = false
        var detailPID: Int32?
        var paused = false
    }

    let cpuInfo: CPUInfo
    let hasTemperatures: Bool
    let hasGPU: Bool

    private let queue = DispatchQueue(label: "boxtop.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var configuration = Configuration()   // queue-confined
    private let deliver: @Sendable (SystemSample) -> Void

    // Collectors are only touched on `queue` after init.
    private let cpu: CPUCollector
    private let sensors: SensorCollector
    private let memory = MemoryCollector()
    private let disks = DiskCollector()
    private let network = NetworkCollector()
    private let gpu: GPUCollector
    private let battery = BatteryCollector()
    private let processes = ProcessCollector()

    init(deliver: @escaping @Sendable (SystemSample) -> Void) {
        self.deliver = deliver
        cpu = CPUCollector()
        cpuInfo = cpu.info
        sensors = SensorCollector(logicalCores: cpu.info.logicalCores, physicalCores: cpu.info.physicalCores)
        hasTemperatures = sensors.hasTemperatures
        gpu = GPUCollector(chipName: cpu.info.model)
        hasGPU = gpu.hasGPU
    }

    func start(with configuration: Configuration) {
        queue.async { [self] in
            self.configuration = configuration
            // Prime delta-based collectors so the first delivered sample has real rates.
            _ = cpu.collect()
            _ = processes.collect()
            _ = network.collect()
            _ = disks.collect(showHidden: configuration.showHiddenDisks)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.schedule(deadline: .now() + 0.3, repeating: configuration.interval, leeway: .milliseconds(20))
            self.timer = timer
            timer.resume()
        }
    }

    func update(_ change: @escaping @Sendable (inout Configuration) -> Void) {
        queue.async { [self] in
            let old = configuration
            change(&configuration)
            if configuration.interval != old.interval {
                timer?.schedule(deadline: .now() + configuration.interval, repeating: configuration.interval, leeway: .milliseconds(20))
            }
            if old.paused, !configuration.paused { tick() }
        }
    }

    func resetNetworkTotals() {
        queue.async { [self] in network.resetTotals() }
    }

    private func tick() {
        guard !configuration.paused else { return }
        let sensorSample = sensors.collect()
        let processList = processes.collect()
        let sample = SystemSample(
            timestamp: Date(),
            interval: configuration.interval,
            cpu: cpu.collect(),
            sensors: sensorSample,
            memory: memory.collect(),
            disks: disks.collect(showHidden: configuration.showHiddenDisks),
            network: network.collect(),
            primaryInterface: network.primaryInterface(),
            gpus: gpu.collect(temperature: sensorSample.gpu),
            battery: battery.collect(),
            processes: processList,
            processDetail: configuration.detailPID.flatMap { processes.detail(for: $0) }
        )
        deliver(sample)
    }
}
