import AppKit
import SwiftUI

struct MemoryPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize

    var body: some View {
        let mem = app.monitor.latest?.memory ?? MemorySample()
        Pane(.mem, subtitle: Fmt.memory(mem.total)) {
            HStack(spacing: 5) {
                Circle().fill(pressureColor(mem.pressure)).frame(width: 7, height: 7)
                Text("Pressure: \(mem.pressure.label.capitalized)")
            }
            .help("macOS memory pressure")
        } content: {
            GeometryReader { geo in
                let showSwap = app.preferences.showSwap && mem.swapTotal > 0
                if geo.size.width >= 560, geo.size.height < 300 {
                    HStack(spacing: 10) {
                        VStack(spacing: 10) {
                            usage(mem, columns: 2)
                            if showSwap { swap(mem) }
                        }
                        .frame(width: geo.size.width * 0.48)
                        history(mem)
                    }
                } else {
                    VStack(spacing: 10) {
                        usage(mem, columns: geo.size.width >= 330 ? 2 : 1)
                        if geo.size.height >= 300 { history(mem) }
                        if showSwap { swap(mem) }
                    }
                }
            }
        }
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: palette.usage.color(at: 0)
        case .warning: palette.usage.color(at: 0.5)
        case .critical: palette.usage.color(at: 1)
        }
    }

    private func usage(_ mem: MemorySample, columns: Int) -> some View {
        let total = Double(max(1, mem.total))
        let segments: [(String, UInt64, Color)] = [
            ("App", mem.app, palette.memApp),
            ("Wired", mem.wired, palette.memWired),
            ("Compressed", mem.compressed, palette.memCompressed),
            ("Cached", mem.cached, palette.memCached),
        ]
        let legend: [(String, UInt64, Color)] = segments + [("Free", mem.free, .track)]
        return Card(fill: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    BigValue(value: Fmt.memory(mem.used), caption: "used of \(Fmt.memory(mem.total))")
                    Spacer()
                    Text(Fmt.percent(Double(mem.used) * 100 / total))
                        .font(.system(size: fontSize + 1, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .monospacedDigit()
                }
                CapacityBar(segments: segments.map { (Double($0.1) / total, $0.2) }, height: 10)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 5) {
                    ForEach(legend, id: \.0) { item in
                        LegendItem(color: item.2, label: item.0, value: Fmt.memory(item.1))
                    }
                }
                .font(.system(size: fontSize - 1))
            }
        }
    }

    private func history(_ mem: MemorySample) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Memory used") {
                    Text(Fmt.percent(app.monitor.memUsed.last)).monospacedDigit()
                }
                GraphView(values: app.monitor.memUsed.values, color: pressureColor(mem.pressure), gridLines: true)
            }
        }
    }

    private func swap(_ mem: MemorySample) -> some View {
        Card(fill: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Swap").foregroundStyle(Color.secondaryText)
                    Spacer()
                    Text("\(Fmt.memory(mem.swapUsed)) of \(Fmt.memory(mem.swapTotal))")
                        .foregroundStyle(Color.primaryText)
                        .monospacedDigit()
                }
                CapacityBar(segments: [(Double(mem.swapUsed) / Double(max(1, mem.swapTotal)), palette.memWired)], height: 6)
            }
            .font(.system(size: fontSize - 1))
        }
    }
}

struct DisksPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize

    var body: some View {
        let disks = app.monitor.latest?.disks ?? []
        let local = disks.filter { $0.readRate != nil }
        Pane(.disks, subtitle: disks.count == 1 ? "1 volume" : "\(disks.count) volumes") {
            if !local.isEmpty {
                HStack(spacing: 10) {
                    Meta(symbol: "arrow.down", text: Fmt.rate(local.reduce(0) { $0 + ($1.readRate ?? 0) }, bits: false),
                         color: palette.read)
                    Meta(symbol: "arrow.up", text: Fmt.rate(local.reduce(0) { $0 + ($1.writeRate ?? 0) }, bits: false),
                         color: palette.write)
                }
                .help("Total read / write")
            }
        } content: {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(disks) { disk in
                        DiskCard(disk: disk, activity: app.monitor.diskActivity[disk.id] ?? History())
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct DiskCard: View {
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize
    let disk: DiskSample
    let activity: History

    var body: some View {
        Card(fill: false) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: fontSize + 5))
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(disk.name).foregroundStyle(Color.primaryText).lineLimit(1).fixedSize()
                            Spacer(minLength: 8)
                            sizeText.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.name).foregroundStyle(Color.primaryText).lineLimit(1)
                            sizeText
                        }
                    }
                    CapacityBar(segments: [(disk.usedPercent / 100, palette.usage.color(at: max(0, disk.usedPercent - 50) / 50))], height: 6)
                    if let read = disk.readRate, let write = disk.writeRate {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                io(read, write)
                                Spacer(minLength: 8)
                                GraphView(values: activity.values, maxValue: max(1024 * 1024, activity.values.max() ?? 0),
                                          color: palette.read, style: .line, pitch: 2.5, lineWidth: 1)
                                    .frame(width: 80, height: 16)
                            }
                            HStack(spacing: 12) { io(read, write) }
                            VStack(alignment: .leading, spacing: 2) {
                                Meta(symbol: "arrow.down", text: Fmt.rate(read, bits: false), color: palette.read)
                                Meta(symbol: "arrow.up", text: Fmt.rate(write, bits: false), color: palette.write)
                            }
                        }
                        .font(.system(size: fontSize - 2))
                    } else {
                        Text(disk.isLocal ? "No I/O counters" : "Network volume · \(disk.fsType)")
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(Color.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .help("\(disk.mountPoint)\n\(disk.device) · \(disk.fsType)\n\(Fmt.size(disk.free)) available")
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: disk.mountPoint)
            }
            Button("Copy Mount Point") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(disk.mountPoint, forType: .string)
            }
        }
    }

    private var sizeText: some View {
        Text("\(Fmt.size(disk.used)) of \(Fmt.size(disk.total))")
            .font(.system(size: fontSize - 1))
            .foregroundStyle(Color.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func io(_ read: Double, _ write: Double) -> some View {
        HStack(spacing: 12) {
            Meta(symbol: "arrow.down", text: Fmt.rate(read, bits: false), color: palette.read)
            Meta(symbol: "arrow.up", text: Fmt.rate(write, bits: false), color: palette.write)
        }
    }

    private var symbol: String {
        if disk.mountPoint == "/" { return "internaldrive" }
        if !disk.isLocal { return "server.rack" }
        return "externaldrive"
    }
}
