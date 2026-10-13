import SwiftUI

struct CPUPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize

    var body: some View {
        let monitor = app.monitor
        let info = monitor.cpuInfo
        Pane(.cpu, subtitle: "\(info.model) · \(info.logicalCores) cores") {
            accessory
        } content: {
            GeometryReader { geo in
                if geo.size.width >= 660 {
                    HStack(spacing: 10) {
                        summary.frame(width: 170)
                        history
                        cores.frame(width: min(380, max(200, CGFloat(info.logicalCores) * 15 + 40)))
                    }
                } else if geo.size.height >= 280 {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            summary.frame(width: 150)
                            history
                        }
                        .frame(height: geo.size.height * 0.56)
                        cores
                    }
                } else {
                    HStack(spacing: 10) {
                        summary.frame(width: min(150, geo.size.width * 0.4))
                        history
                    }
                }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var accessory: some View {
        let sample = app.monitor.latest
        let unit = app.preferences.temperatureUnit
        HStack(spacing: 12) {
            if app.preferences.showTemperatures, let temp = sample?.sensors.cpuPackage {
                Meta(symbol: "thermometer.medium", text: unit.format(temp),
                     color: palette.temperature.color(at: (temp - 30) / 70))
                    .help("CPU temperature")
            }
            if let fans = sample?.sensors.fans, !fans.isEmpty {
                Meta(symbol: "fan", text: fans.map { Fmt.count(Int($0.rpm)) }.joined(separator: " / ") + " rpm")
                    .help("Fan speed")
            }
            if app.preferences.showBattery, let battery = sample?.battery {
                Meta(symbol: batterySymbol(battery), text: Fmt.percent(battery.percent)
                     + (battery.minutesRemaining.map { " · " + Fmt.minutes($0) } ?? ""))
                    .help(battery.isCharging ? "Charging" : (battery.isOnAC ? "On power adapter" : "On battery"))
            }
        }
    }

    private func batterySymbol(_ battery: BatterySample) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    // MARK: Cards

    private var summary: some View {
        let monitor = app.monitor
        let total = monitor.cpuTotal.last
        let system = monitor.cpuSystem.last
        let tint = Palette.tint(palette.cpu)
        return Card {
            VStack(spacing: 10) {
                RingGauge(value: total, color: tint) {
                    VStack(spacing: 0) {
                        Text(Fmt.percent(total))
                            .font(.system(size: fontSize * 1.55, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.primaryText)
                        Text("in use")
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                .frame(maxWidth: 120, maxHeight: .infinity)
                VStack(spacing: 4) {
                    LegendItem(color: tint, label: "User", value: Fmt.percent(max(0, total - system)))
                    LegendItem(color: palette.cpuSystem, label: "System", value: Fmt.percent(system))
                }
                .font(.system(size: fontSize - 1))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var history: some View {
        let monitor = app.monitor
        let load = monitor.latest?.cpu.loadAverage ?? [0, 0, 0]
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Usage") {
                    Text("Load " + load.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                        .monospacedDigit()
                        .help("Load average over 1, 5 and 15 minutes")
                }
                ZStack {
                    GraphView(values: monitor.cpuTotal.values, gradient: palette.cpu, gridLines: true)
                    GraphView(values: monitor.cpuSystem.values, color: palette.cpuSystem, gridLines: false, lineWidth: 1)
                }
                HStack {
                    Text("Up \(Fmt.uptime(monitor.latest?.cpu.uptime ?? 0))")
                    Spacer()
                    if let ghz = monitor.latest?.cpu.frequencyGHz {
                        Text(String(format: "%.2f GHz", ghz))
                    }
                }
                .font(.system(size: fontSize - 2))
                .foregroundStyle(Color.tertiaryText)
            }
        }
    }

    private var cores: some View {
        let monitor = app.monitor
        let info = monitor.cpuInfo
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Cores") {
                    if !info.clusterSummary.isEmpty {
                        Text(info.clusterSummary.replacingOccurrences(of: " + ", with: " · "))
                    }
                }
                CoreBars(
                    values: monitor.cpuCores.map(\.last),
                    kinds: info.coreKinds,
                    names: info.clusterNames,
                    temps: app.preferences.showTemperatures ? (monitor.latest?.sensors.cpuCores ?? []) : [],
                    unit: app.preferences.temperatureUnit,
                    color: Palette.tint(palette.cpu)
                )
            }
        }
    }
}

/// Per-core usage as vertical bars, grouped by cluster on Apple Silicon.
private struct CoreBars: View {
    @Environment(\.baseFontSize) private var fontSize
    let values: [Double]
    let kinds: [String]
    let names: [String: String]
    let temps: [Double]
    let unit: TemperatureUnit
    let color: Color

    private struct Group: Identifiable {
        var id: String
        var label: String
        var cores: [Int]
    }

    private var groups: [Group] {
        guard kinds.count == values.count, !kinds.isEmpty else {
            return [Group(id: "all", label: "", cores: Array(values.indices))]
        }
        var result: [Group] = []
        for (index, kind) in kinds.enumerated() {
            if let last = result.indices.last, result[last].id == kind {
                result[last].cores.append(index)
            } else {
                result.append(Group(id: kind, label: names[kind] ?? kind, cores: [index]))
            }
        }
        return result
    }

    var body: some View {
        let groups = groups
        GeometryReader { geo in
            let gap: CGFloat = 3, groupGap: CGFloat = 14
            let count = CGFloat(max(1, values.count))
            let available = geo.size.width - groupGap * CGFloat(groups.count - 1) - gap * (count - CGFloat(groups.count))
            let barWidth = max(3, min(18, available / count))
            HStack(alignment: .bottom, spacing: groupGap) {
                ForEach(groups) { group in
                    VStack(spacing: 5) {
                        HStack(alignment: .bottom, spacing: gap) {
                            ForEach(group.cores, id: \.self) { core in
                                bar(core).frame(width: barWidth)
                            }
                        }
                        if groups.count > 1 {
                            Text(group.label)
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(Color.tertiaryText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func bar(_ core: Int) -> some View {
        let value = core < values.count ? values[core] : 0
        let temp = core < temps.count ? " · " + unit.format(temps[core]) : ""
        let kind = core < kinds.count ? names[kinds[core]].map { " (\($0))" } ?? "" : ""
        return GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.track)
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * min(1, value / 100)))
                    .frame(height: max(geo.size.width, geo.size.height * min(1, value / 100)))
            }
        }
        .help("Core \(core)\(kind) · \(Fmt.percent(value))\(temp)")
    }
}
