import Foundation

// Instantaneous readings produced by the collectors on the sampling queue.
// Histories are accumulated on the main actor by `SystemMonitor`.

struct CPUSample: Sendable {
    var total: Double = 0          // 0-100
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    var cores: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var frequencyGHz: Double?
}

struct CPUInfo: Sendable {
    var model: String = "CPU"
    var logicalCores: Int = 1
    var physicalCores: Int = 1
    /// Short cluster tag per logical core ("S", "P", "E"), empty when unknown.
    var coreKinds: [String] = []
    /// Human readable cluster summary, e.g. "6 Super + 12 Performance".
    var clusterSummary: String = ""
    /// Cluster tag -> perf level name ("S" -> "Super").
    var clusterNames: [String: String] = [:]
    var isAppleSilicon: Bool = false
}

struct SensorSample: Sendable {
    var cpuPackage: Double?
    /// One temperature per logical core (mapped like btop does), may be empty.
    var cpuCores: [Double] = []
    var gpu: Double?
    var fans: [FanReading] = []
}

struct FanReading: Sendable, Hashable {
    var index: Int
    var rpm: Double
    var maxRPM: Double?
}

struct MemorySample: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var available: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var app: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
}

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

struct DiskSample: Sendable, Identifiable, Hashable {
    var id: String { mountPoint }
    var name: String
    var mountPoint: String
    var device: String
    var fsType: String
    var isLocal: Bool
    var total: UInt64
    var free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var usedPercent: Double { total > 0 ? Double(used) * 100 / Double(total) : 0 }
    /// Bytes per second, nil when the filesystem exposes no I/O counters.
    var readRate: Double?
    var writeRate: Double?
}

struct NetInterfaceSample: Sendable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var ipv4: String?
    var ipv6: String?
    var isUp: Bool
    var isLoopback: Bool
    var rxRate: Double = 0      // bytes / s
    var txRate: Double = 0
    var rxTotal: UInt64 = 0     // since Boxtop started
    var txTotal: UInt64 = 0
    var rxTop: Double = 0
    var txTop: Double = 0
}

struct GPUSample: Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var utilization: Double?    // 0-100
    var frequencyMHz: Double?
    var powerWatts: Double?
    var temperature: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var coreCount: Int?
    var fanRPM: Double?
}

struct BatterySample: Sendable, Hashable {
    var percent: Double
    var isCharging: Bool
    var isOnAC: Bool
    var isCharged: Bool
    var minutesRemaining: Int?
}

struct ProcessSample: Sendable, Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var ppid: Int32
    var name: String
    var command: String
    var path: String
    var user: String
    var uid: UInt32
    var threads: Int
    var residentBytes: UInt64
    /// CPU usage as a share of one core (100 = one full core).
    var cpuPerCore: Double
    /// Lifetime average CPU usage (share of one core).
    var cpuLifetime: Double
    var cpuTimeSeconds: Double
    var state: ProcessState
    var nice: Int
    var startTime: Date
}

enum ProcessState: String, Sendable {
    case running = "R", sleeping = "S", idle = "I", stopped = "T", zombie = "Z", unknown = "?"

    var label: String {
        switch self {
        case .running: "Running"
        case .sleeping: "Sleeping"
        case .idle: "Idle"
        case .stopped: "Stopped"
        case .zombie: "Zombie"
        case .unknown: "Unknown"
        }
    }
}

struct ProcessDetailSample: Sendable, Hashable {
    var pid: Int32
    var diskRead: UInt64
    var diskWritten: UInt64
    var openFiles: Int?
}

struct SystemSample: Sendable {
    var timestamp: Date
    var interval: TimeInterval
    var cpu: CPUSample
    var sensors: SensorSample
    var memory: MemorySample
    var disks: [DiskSample]
    var network: [NetInterfaceSample]
    /// Interface carrying the default IPv4 route, used for btop's auto interface selection.
    var primaryInterface: String?
    var gpus: [GPUSample]
    var battery: BatterySample?
    var processes: [ProcessSample]
    var processDetail: ProcessDetailSample?
}
