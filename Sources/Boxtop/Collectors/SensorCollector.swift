import CSysInfo
import Foundation

/// CPU / GPU temperatures and fan speeds.
///
/// Apple Silicon: IOHIDEventSystem thermal sensors grouped exactly like btop's
/// `ThermalSensors::getSensors` (eACC/pACC, then "PMU tdie<N>", then SOC MTR).
/// Intel: SMC keys like btop's `SMCConnection::getTemp` (TC0P package, TC<n>c/TC<n>C cores).
/// Fans come from the SMC on both architectures.
final class SensorCollector {
    private enum Source { case hid, smc, none }

    private let logicalCores: Int
    private let physicalCores: Int
    private let source: Source
    private let smcAvailable: Bool
    private var smcCoreOffset = 0
    private var fanCount = 0
    private var fanMax: [Int: Double] = [:]
    private var buffer = [bt_hid_sensor](repeating: bt_hid_sensor(), count: 256)

    init(logicalCores: Int, physicalCores: Int) {
        self.logicalCores = logicalCores
        self.physicalCores = max(1, physicalCores)
        smcAvailable = bt_smc_open()

        let hidCount = bt_hid_temperatures(&buffer, Int32(buffer.count))
        if hidCount > 0, Self.hasCPUSensors(buffer.prefix(Int(hidCount))) {
            source = .hid
        } else if smcAvailable, Self.smc("TC0P") != nil || Self.smc("TC0D") != nil || Self.smc("TC0F") != nil {
            source = .smc
            // Some Macs number cores from 1 (btop's core_offset).
            if Self.smc("TC0c") == nil, Self.smc("TC0C") == nil,
               Self.smc("TC1c") != nil || Self.smc("TC1C") != nil {
                smcCoreOffset = 1
            }
        } else {
            source = .none
        }

        if smcAvailable, let count = Self.smc("FNum")?.sane(0...8) {
            fanCount = Int(count)
            for i in 0..<fanCount {
                if let max = Self.smc("F\(i)Mx")?.sane(1...20000) { fanMax[i] = max }
            }
        }
    }

    var hasTemperatures: Bool { source != .none }

    var sourceDescription: String {
        switch source {
        case .hid: "IOHIDEventSystem (Apple Silicon)"
        case .smc: "SMC" + (smcCoreOffset == 1 ? " (cores numbered from 1)" : "")
        case .none: "none found"
        }
    }

    private var lastTemperatures = SensorSample()
    private var lastTemperatureRead: Date?

    func collect() -> SensorSample {
        // Each HID sensor read is a round trip to the HID server, so temperatures are refreshed
        // at most every 1.5 s even when the update interval is shorter.
        var sample: SensorSample
        if let last = lastTemperatureRead, Date().timeIntervalSince(last) < 1.5 {
            sample = lastTemperatures
        } else {
            sample = SensorSample()
            switch source {
            case .hid: collectHID(into: &sample)
            case .smc: collectSMC(into: &sample)
            case .none: break
            }
            lastTemperatures = sample
            lastTemperatureRead = Date()
        }
        sample.fans = []
        for i in 0..<fanCount {
            if let rpm = Self.smc("F\(i)Ac")?.sane(0...20000) {
                sample.fans.append(FanReading(index: i, rpm: rpm, maxRPM: fanMax[i]))
            }
        }
        return sample
    }

    // MARK: Apple Silicon

    private static func hasCPUSensors<S: Sequence>(_ sensors: S) -> Bool where S.Element == bt_hid_sensor {
        sensors.contains { sensor in
            let name = string(fromCTuple: sensor.name)
            return name.hasPrefix("eACC") || name.hasPrefix("pACC") || name.hasPrefix("PMU tdie") || name.hasPrefix("SOC MTR Temp Sensor")
        }
    }

    private func collectHID(into sample: inout SensorSample) {
        let count = Int(bt_hid_temperatures(&buffer, Int32(buffer.count)))
        var acc: [Double] = [], tdie: [Double] = [], soc: [Double] = [], gpu: [Double] = []
        var accNamed: [String: [Double]] = [:]
        var tdieIndexed: [Int: [Double]] = [:]

        for sensor in buffer.prefix(count) {
            let name = string(fromCTuple: sensor.name)
            let temp = sensor.celsius
            if name.hasPrefix("eACC") || name.hasPrefix("pACC") {
                acc.append(temp)
                accNamed[name, default: []].append(temp)
            } else if name.hasPrefix("PMU tdie") {
                tdie.append(temp)
                if let index = Int(name.dropFirst("PMU tdie".count).prefix(while: \.isNumber)) {
                    tdieIndexed[index, default: []].append(temp)
                }
            } else if name.hasPrefix("SOC MTR Temp Sensor") {
                soc.append(temp)
            }
            // GPU: legacy "GPU MTR Temp Sensor*" or newer "PMU TP*g" (from btop's GPU collector).
            if name.contains("GPU") || (name.hasPrefix("PMU TP") && name.hasSuffix("g")) {
                gpu.append(temp)
            }
        }

        let perSensor: [Double]
        if !tdieIndexed.isEmpty {
            perSensor = tdieIndexed.keys.sorted().compactMap { average(tdieIndexed[$0]) }
        } else {
            perSensor = accNamed.keys.sorted().compactMap { average(accNamed[$0]) }
        }
        sample.cpuPackage = average(!acc.isEmpty ? acc : (!tdie.isEmpty ? tdie : soc))
        if !perSensor.isEmpty {
            // Spread the available sensors across logical cores (btop: core * sensors / cores).
            sample.cpuCores = (0..<logicalCores).map { perSensor[$0 * perSensor.count / logicalCores] }
        }
        sample.gpu = average(gpu)
    }

    // MARK: Intel (SMC)

    private func collectSMC(into sample: inout SensorSample) {
        sample.cpuPackage = Self.smc("TC0P") ?? Self.smc("TC0D") ?? Self.smc("TC0F")
        let threadsPerCore = max(1, logicalCores / physicalCores)
        var cores: [Double] = []
        for core in 0..<logicalCores {
            let physical = core / threadsPerCore + smcCoreOffset
            guard let key = Self.coreKey(physical) else { break }
            guard let temp = Self.smc("TC\(key)c") ?? Self.smc("TC\(key)C") else { break }
            cores.append(temp)
        }
        if cores.count == logicalCores { sample.cpuCores = cores }
        sample.gpu = Self.smc("TG0P") ?? Self.smc("TG0D") ?? Self.smc("TGDD")
    }

    private static func coreKey(_ index: Int) -> Character? {
        let keys = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < keys.count ? keys[index] : nil
    }

    private static func smc(_ key: String) -> Double? {
        var value = 0.0
        guard bt_smc_read(key, &value), value.isFinite else { return nil }
        // Unpopulated temperature keys read as 0 or garbage.
        if key.hasPrefix("T"), !(value > 0 && value < 150) { return nil }
        return value
    }

    private func average(_ values: [Double]?) -> Double? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
