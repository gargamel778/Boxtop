import AppKit
import SwiftUI
import CSysInfo
import Foundation

/// `Boxtop --diagnose`: prints what every collector sees, without starting the GUI.
/// Meant for checking hardware support over SSH (Intel Macs, hackintoshes, VMs).
enum Diagnostics {
    static func run() {
        var timings: [(String, Double)] = []
        func timed<T>(_ name: String, _ body: () -> T) -> T {
            let start = Date()
            let value = body()
            timings.append((name, Date().timeIntervalSince(start) * 1000))
            return value
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = (Sysctl.int("sysctl.proc_translated") ?? 0) == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        print("Boxtop \(version) diagnostics")
        print("macOS \(os) · \(arch) · \(Sysctl.string("hw.model") ?? "?")")

        let cpu = CPUCollector()
        let sensors = SensorCollector(logicalCores: cpu.info.logicalCores, physicalCores: cpu.info.physicalCores)
        let memory = MemoryCollector(), disks = DiskCollector(), network = NetworkCollector()
        let gpu = GPUCollector(chipName: cpu.info.model), battery = BatteryCollector(), processes = ProcessCollector()

        // Prime the delta-based collectors, then take a real sample a second later.
        _ = cpu.collect(); _ = processes.collect(); _ = network.collect(); _ = disks.collect(showHidden: false)
        Thread.sleep(forTimeInterval: 1)

        let c = timed("cpu") { cpu.collect() }
        let s = timed("sensors") { sensors.collect() }
        let m = timed("memory") { memory.collect() }
        let d = timed("disks") { disks.collect(showHidden: false) }
        let n = timed("network") { network.collect() }
        let primary = timed("primary interface") { network.primaryInterface() }
        let g = timed("gpu") { gpu.collect(temperature: s.gpu) }
        let b = timed("battery") { battery.collect() }
        let p = timed("processes") { processes.collect() }

        section("CPU")
        print("model: \(cpu.info.model)")
        print("cores: \(cpu.info.logicalCores) logical, \(cpu.info.physicalCores) physical")
        if !cpu.info.clusterSummary.isEmpty {
            print("clusters: \(cpu.info.clusterSummary)  tags: \(cpu.info.coreKinds.joined())")
        }
        print(String(format: "usage: %.1f%% (user %.1f%%, system %.1f%%)", c.total, c.user, c.system))
        print("per core: " + c.cores.map { String(format: "%.0f", $0) }.joined(separator: " "))
        print("load: " + c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ") + "  uptime: \(Fmt.uptime(c.uptime))")
        print("frequency: " + (c.frequencyGHz.map { String(format: "%.2f GHz", $0) } ?? "not exposed"))

        section("Sensors")
        print("temperature source: \(sensors.sourceDescription)")
        print("package: " + (s.cpuPackage.map { String(format: "%.1f °C", $0) } ?? "n/a"))
        print("cores: " + (s.cpuCores.isEmpty ? "n/a" : s.cpuCores.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        print("gpu: " + (s.gpu.map { String(format: "%.1f °C", $0) } ?? "n/a"))
        let fans = s.fans.map { fan in
            "#\(fan.index) \(Int(fan.rpm)) rpm" + (fan.maxRPM.map { " (max \(Int($0)))" } ?? "")
        }
        print("fans: " + (fans.isEmpty ? "none" : fans.joined(separator: ", ")))
        print("SMC: " + (bt_smc_open() ? "available" : "unavailable"))
        let keys = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0c", "TC0C", "TC1c", "TC1C", "TCXC", "TG0P", "TG0D", "TGDD", "Tp09", "FNum", "F0Ac", "F0Mx"]
        print("SMC keys: " + keys.map { key in
            var value = 0.0
            return bt_smc_read(key, &value) ? "\(key)=\(String(format: "%.1f", value))" : "\(key)=–"
        }.joined(separator: " "))
        var hid = [bt_hid_sensor](repeating: bt_hid_sensor(), count: 256)
        let hidCount = Int(bt_hid_temperatures(&hid, Int32(hid.count)))
        let hidNames = Set(hid.prefix(hidCount).map { string(fromCTuple: $0.name) }).sorted()
        print("HID thermal sensors: \(hidCount)" + (hidNames.isEmpty ? "" : " — " + hidNames.prefix(24).joined(separator: ", ")))

        section("Memory")
        print("total \(Fmt.bytes(m.total)) · used \(Fmt.bytes(m.used)) (app \(Fmt.bytes(m.app)), wired \(Fmt.bytes(m.wired)), compressed \(Fmt.bytes(m.compressed)))")
        print("available \(Fmt.bytes(m.available)) · cached \(Fmt.bytes(m.cached)) · free \(Fmt.bytes(m.free)) · swap \(Fmt.bytes(m.swapUsed))/\(Fmt.bytes(m.swapTotal)) · pressure \(m.pressure.label)")

        section("Disks")
        for disk in d {
            let io = disk.readRate.map { "  R \(Fmt.rate($0, bits: false)) W \(Fmt.rate(disk.writeRate ?? 0, bits: false))" } ?? "  (no I/O counters)"
            print("\(disk.mountPoint) [\(disk.fsType), \(disk.device)] \(Fmt.bytes(disk.used))/\(Fmt.bytes(disk.total))\(io)")
        }

        section("Network")
        print("primary: \(primary ?? "none")")
        for iface in n where iface.isUp && !iface.isLoopback && (iface.ipv4 != nil || iface.rxRate + iface.txRate > 0) {
            print("\(iface.name) \(iface.ipv4 ?? iface.ipv6 ?? "") ↓\(Fmt.rate(iface.rxRate, bits: false)) ↑\(Fmt.rate(iface.txRate, bits: false))")
        }

        section("GPU")
        if g.isEmpty { print("none detected") }
        for item in g {
            var parts = ["\(item.name)"]
            if let u = item.utilization { parts.append(String(format: "util %.0f%%", u)) }
            if let f = item.frequencyMHz { parts.append(Fmt.frequency(mhz: f)) }
            if let w = item.powerWatts { parts.append(String(format: "%.2f W", w)) }
            if let t = item.temperature { parts.append(String(format: "%.0f °C", t)) }
            if let fan = item.fanRPM { parts.append("fan \(Int(fan)) rpm") }
            if let mem = item.memoryUsed { parts.append("mem \(Fmt.bytes(mem))" + (item.memoryTotal.map { "/\(Fmt.bytes($0))" } ?? "")) }
            print(parts.joined(separator: " · ") + "  [\(item.id)]")
        }

        section("Battery")
        if let b {
            print(String(format: "%.0f%%", b.percent) + (b.isCharging ? " charging" : (b.isOnAC ? " on AC" : " on battery"))
                  + (b.minutesRemaining.map { " · \(Fmt.minutes($0)) remaining" } ?? ""))
        } else {
            print("no internal battery")
        }

        section("Processes")
        let unreadable = p.filter { $0.threads == 0 }.count
        print("\(p.count) processes, \(unreadable) without task info (other users / root)")
        for proc in p.sorted(by: { $0.cpuPerCore > $1.cpuPerCore }).prefix(5) {
            let name = proc.name.count > 28 ? String(proc.name.prefix(27)) + "…" : proc.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            print(String(format: "%7d ", proc.pid) + name + String(format: " %5.1f%%  ", proc.cpuPerCore) + Fmt.bytes(proc.residentBytes))
        }

        section("Collector timings")
        for (name, ms) in timings { print(name.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "%8.2f ms", ms)) }
    }

    /// `Boxtop --render-dock-previews <dir>`: renders every Dock icon mode with synthetic data (for docs/design).
    @MainActor
    static func renderDockPreviews(to directory: String) {
        let palette = Palette.standard
        func colors(_ gradient: Gradient) -> [NSColor] { gradient.stops.map { NSColor($0.color) } }
        let wave = (0..<30).map { i in min(1, max(0, 0.35 + 0.3 * sin(Double(i) / 3.2) + Double(i % 5) * 0.04)) }
        let cores = [0.92, 0.75, 0.6, 0.55, 0.4, 0.33, 0.2, 0.15, 0.1, 0.08, 0.05, 0.04, 0.7, 0.5, 0.3, 0.2, 0.1, 0.05]
        let models: [(String, DockTileModel)] = [
            ("cpu-history", DockTileModel(title: "CPU", value: "42%", graph: .history(wave, colors(palette.cpu)))),
            ("cpu-cores", DockTileModel(title: "CPU", value: "35%", graph: .columns(cores, NSColor(Palette.tint(palette.cpu))))),
            ("memory", DockTileModel(title: "Memory", value: "82%",
                                     graph: .history(wave.map { 0.6 + $0 * 0.3 }, [NSColor(palette.memApp), NSColor(palette.memApp)]))),
            ("network", DockTileModel(title: "Network", value: "1.2 MB",
                                      graph: .mirrored(wave, colors(palette.download), wave.reversed().map { $0 * 0.5 }, colors(palette.upload)))),
        ]
        let view = DockTileView(frame: NSRect(x: 0, y: 0, width: 512, height: 512))
        for (name, model) in models {
            view.model = model
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("dock-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
    }

    private static func section(_ title: String) {
        print("\n== \(title)")
    }
}
