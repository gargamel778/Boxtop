import SwiftUI

struct GPUPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize
    @State private var selectedID: String?

    var body: some View {
        let gpus = app.monitor.latest?.gpus ?? []
        let gpu = gpus.first { $0.id == selectedID } ?? gpus.first
        let history = gpu.flatMap { app.monitor.gpuUtilization[$0.id] } ?? History()

        Pane(.gpu, subtitle: gpus.count > 1 ? nil : gpu.map(subtitle)) {
            HStack(spacing: 12) {
                if gpus.count > 1, let gpu {
                    HeaderMenu(title: gpu.name) {
                        Picker("GPU", selection: Binding(get: { gpu.id }, set: { selectedID = $0 })) {
                            ForEach(gpus) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    }
                }
                if let temp = gpu?.temperature {
                    Meta(symbol: "thermometer.medium", text: app.preferences.temperatureUnit.format(temp),
                         color: palette.temperature.color(at: (temp - 30) / 70))
                }
            }
        } content: {
            if let gpu {
                GeometryReader { geo in
                    if geo.size.width >= 600 {
                        HStack(spacing: 10) {
                            ring(gpu).frame(width: 150)
                            chart(history)
                            stats(gpu).frame(width: 190)
                        }
                    } else if geo.size.width < 330 {
                        // Narrow: the gauge, plus the details underneath when there is height for them.
                        VStack(spacing: 10) {
                            ring(gpu).frame(maxHeight: 150)
                            if geo.size.height >= 280 { stats(gpu).fixedSize(horizontal: false, vertical: true) }
                        }
                    } else {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                ring(gpu).frame(width: min(150, geo.size.width * 0.42))
                                stats(gpu)
                            }
                            .frame(height: min(170, geo.size.height * 0.55))
                            if geo.size.height >= 230 { chart(history) }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No GPU Detected", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func subtitle(_ gpu: GPUSample) -> String {
        gpu.coreCount.map { "\(gpu.name) · \($0) cores" } ?? gpu.name
    }

    private func ring(_ gpu: GPUSample) -> some View {
        let value = gpu.utilization ?? 0
        return Card {
            RingGauge(value: value, color: Palette.tint(palette.gpu)) {
                VStack(spacing: 0) {
                    Text(Fmt.percent(value))
                        .font(.system(size: fontSize * 1.55, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primaryText)
                    Text("in use")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .frame(maxWidth: 120, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private func chart(_ history: History) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Utilization")
                GraphView(values: history.values, gradient: palette.gpu, gridLines: true)
            }
        }
    }

    private func stats(_ gpu: GPUSample) -> some View {
        let rows: [(String, String)] = [
            gpu.frequencyMHz.map { ("Clock", Fmt.frequency(mhz: $0)) },
            gpu.powerWatts.map { ("Power", String(format: "%.2f W", $0)) },
            gpu.memoryUsed.map { used in ("Memory", Fmt.memory(used) + (gpu.memoryTotal.map { " of " + Fmt.memory($0) } ?? "")) },
            gpu.fanRPM.map { ("Fan", "\(Fmt.count(Int($0))) rpm") },
            gpu.coreCount.map { ("Cores", "\($0)") },
        ].compactMap { $0 }
        return Card {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).foregroundStyle(Color.secondaryText).lineLimit(1).layoutPriority(-1)
                        Spacer(minLength: 6)
                        Text(row.1).foregroundStyle(Color.primaryText).monospacedDigit().lineLimit(1).fixedSize()
                    }
                }
            }
            .font(.system(size: fontSize - 1))
        }
    }
}
