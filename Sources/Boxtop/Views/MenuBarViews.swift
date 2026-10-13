import AppKit
import SwiftUI

/// Status item label: a tiny CPU sparkline plus the current percentage, drawn as a template image.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Image(nsImage: Self.render(values: Array(app.monitor.cpuTotal.values.suffix(24)),
                                   percent: app.monitor.cpuTotal.last))
    }

    static func render(values: [Double], percent: Double) -> NSImage {
        let text = String(format: "%3.0f%%", percent) as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attributes)
        let graphWidth: CGFloat = 26
        let size = NSSize(width: graphWidth + 4 + ceil(textSize.width), height: 18)

        let image = NSImage(size: size, flipped: false) { _ in
            let graph = NSRect(x: 0, y: 3, width: graphWidth, height: 12)
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let frame = NSBezierPath(roundedRect: graph.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            frame.lineWidth = 1
            frame.stroke()

            NSColor.black.setFill()
            let barWidth = (graph.width - 2) / 24
            let start = graph.maxX - 1 - CGFloat(values.count) * barWidth
            for (i, value) in values.enumerated() {
                let h = max(0.5, CGFloat(min(100, value) / 100) * (graph.height - 2))
                NSRect(x: start + CGFloat(i) * barWidth, y: graph.minY + 1, width: barWidth, height: h).fill()
            }
            text.draw(at: NSPoint(x: graphWidth + 4, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Compact popover: CPU / memory / network summary and the top processes.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let monitor = app.monitor
        let sample = monitor.latest
        let palette = app.palette
        let fontSize = 12.0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").foregroundStyle(Color.secondaryText)
                Text(monitor.cpuInfo.model).foregroundStyle(Color.tertiaryText).lineLimit(1)
                Spacer()
                Text(Fmt.percent(monitor.cpuTotal.last))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
            }
            Card(padding: 8, fill: false) {
                GraphView(values: monitor.cpuTotal.values, gradient: palette.cpu, style: .line, pitch: 2.5, gridLines: true)
                    .frame(height: 56)
            }

            if let mem = sample?.memory {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Memory").foregroundStyle(Color.secondaryText)
                        Spacer()
                        Text("\(Fmt.memory(mem.used)) of \(Fmt.memory(mem.total))").monospacedDigit()
                    }
                    let total = Double(max(1, mem.total))
                    CapacityBar(segments: [(Double(mem.app) / total, palette.memApp), (Double(mem.wired) / total, palette.memWired),
                                           (Double(mem.compressed) / total, palette.memCompressed)], height: 7)
                }
            }

            if let primary = sample?.primaryInterface, let iface = sample?.network.first(where: { $0.name == primary }) {
                HStack(spacing: 12) {
                    Text(InterfaceNames.name(primary)).foregroundStyle(Color.secondaryText)
                    Spacer()
                    Meta(symbol: "arrow.down", text: Fmt.rate(iface.rxRate, bits: app.preferences.networkInBits),
                         color: Palette.tint(palette.download))
                    Meta(symbol: "arrow.up", text: Fmt.rate(iface.txRate, bits: app.preferences.networkInBits),
                         color: Palette.tint(palette.upload))
                }
            }

            Divider()

            Text("Top Processes").foregroundStyle(Color.secondaryText)
            let top = (sample?.processes ?? []).sorted { $0.cpuPerCore > $1.cpuPerCore }.prefix(6)
            VStack(spacing: 6) {
                ForEach(Array(top)) { p in
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.shared.icon(pid: p.pid, path: p.path)).resizable().frame(width: 16, height: 16)
                        Text(RunningApps.shared.name(p.pid, path: p.path, fallback: p.name)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", app.displayCPU(p.cpuPerCore)))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open Boxtop") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(Color.primaryText)
        .environment(\.graphStyle, app.preferences.graphStyle)
        .padding(14)
        .frame(width: 320)
        .background(Color.paneBackground)
        .preferredColorScheme(app.preferences.appearance.colorScheme)
    }
}
