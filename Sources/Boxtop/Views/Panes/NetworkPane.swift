import SwiftUI
import SystemConfiguration

/// Friendly interface names ("Ethernet", "Wi-Fi") from SystemConfiguration.
@MainActor
enum InterfaceNames {
    private static var cache: [String: String]?

    static func name(_ bsd: String) -> String {
        if cache == nil {
            var map: [String: String] = [:]
            for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
                if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                   let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                    map[bsd] = display
                }
            }
            cache = map
        }
        if bsd == "lo0" { return "Loopback" }
        return cache?[bsd] ?? bsd
    }
}

struct NetworkPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize

    var body: some View {
        let sample = app.monitor.latest
        let interfaces = sample?.network ?? []
        let current = selectedInterface(interfaces, primary: sample?.primaryInterface)
        let history = current.flatMap { app.monitor.net[$0.name] } ?? NetHistory()
        let bits = app.preferences.networkInBits

        Pane(.net, subtitle: current?.ipv4 ?? current?.ipv6) {
            HeaderMenu(title: current.map { InterfaceNames.name($0.name) } ?? "No interface") {
                interfaceMenu(interfaces, current: current)
            }
        } content: {
            GeometryReader { geo in
                if geo.size.width >= 420 {
                    HStack(spacing: 10) {
                        VStack(spacing: 10) {
                            tile("Download", "arrow.down.circle.fill", current?.rxRate ?? 0, top: current?.rxTop ?? 0,
                                 total: current?.rxTotal ?? 0, color: Palette.tint(palette.download), bits: bits)
                            tile("Upload", "arrow.up.circle.fill", current?.txRate ?? 0, top: current?.txTop ?? 0,
                                 total: current?.txTotal ?? 0, color: Palette.tint(palette.upload), bits: bits)
                        }
                        .frame(width: min(220, geo.size.width * 0.42))
                        chart(history, bits: bits)
                    }
                } else {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            tile("Download", "arrow.down.circle.fill", current?.rxRate ?? 0, top: current?.rxTop ?? 0,
                                 total: current?.rxTotal ?? 0, color: Palette.tint(palette.download), bits: bits)
                            tile("Upload", "arrow.up.circle.fill", current?.txRate ?? 0, top: current?.txTop ?? 0,
                                 total: current?.txTotal ?? 0, color: Palette.tint(palette.upload), bits: bits)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if geo.size.height >= 200 { chart(history, bits: bits) }
                    }
                }
            }
        }
    }

    private func selectedInterface(_ interfaces: [NetInterfaceSample], primary: String?) -> NetInterfaceSample? {
        let wanted = app.preferences.networkInterface
        if !wanted.isEmpty, let match = interfaces.first(where: { $0.name == wanted }) { return match }
        if let primary, let match = interfaces.first(where: { $0.name == primary }) { return match }
        return interfaces.filter { !$0.isLoopback && $0.isUp }
            .max { ($0.rxTotal + $0.txTotal) < ($1.rxTotal + $1.txTotal) } ?? interfaces.first
    }

    private func tile(_ title: String, _ symbol: String, _ rate: Double, top: Double, total: UInt64,
                      color: Color, bits: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(title).foregroundStyle(Color.secondaryText)
                }
                .font(.system(size: fontSize - 1))
                BigValue(value: Fmt.rate(rate, bits: bits))
                Text("Peak \(Fmt.rate(top, bits: bits)) · Total \(Fmt.size(total))")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(Color.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func chart(_ history: NetHistory, bits: Bool) -> some View {
        let window = 240
        let rxPeak = max(10 * 1024, (history.rx.values.suffix(window).max() ?? 0) * 1.15)
        let txPeak = max(10 * 1024, (history.tx.values.suffix(window).max() ?? 0) * 1.15)
        let sync = app.preferences.networkSyncScale
        let rxScale = sync ? max(rxPeak, txPeak) : rxPeak
        let txScale = sync ? max(rxPeak, txPeak) : txPeak
        return Card {
            VStack(spacing: 0) {
                GraphView(values: history.rx.values, maxValue: rxScale, gradient: palette.download)
                Rectangle().fill(Color.gridLine).frame(height: 1)
                GraphView(values: history.tx.values, maxValue: txScale, gradient: palette.upload, inverted: true)
            }
            .overlay(alignment: .topLeading) { scaleLabel(rxScale, bits: bits) }
            .overlay(alignment: .bottomLeading) { scaleLabel(txScale, bits: bits) }
        }
    }

    private func scaleLabel(_ value: Double, bits: Bool) -> some View {
        Text(Fmt.rate(value, bits: bits))
            .font(.system(size: fontSize - 3))
            .foregroundStyle(Color.tertiaryText)
            .monospacedDigit()
    }

    @ViewBuilder
    private func interfaceMenu(_ interfaces: [NetInterfaceSample], current: NetInterfaceSample?) -> some View {
        Picker("Interface", selection: Binding(get: { app.preferences.networkInterface },
                                               set: { app.preferences.networkInterface = $0 })) {
            Text("Automatic").tag("")
            Divider()
            ForEach(interfaces.filter { ($0.isUp && !$0.isLoopback) || $0.name == current?.name }) { iface in
                Text("\(InterfaceNames.name(iface.name)) (\(iface.name))" + (iface.ipv4.map { " · \($0)" } ?? "")).tag(iface.name)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Show Speeds in Bits", isOn: Binding(get: { app.preferences.networkInBits },
                                                    set: { app.preferences.networkInBits = $0 }))
        Toggle("Same Scale for Upload and Download", isOn: Binding(get: { app.preferences.networkSyncScale },
                                                                    set: { app.preferences.networkSyncScale = $0 }))
        Button("Reset Totals") { app.monitor.resetNetworkTotals() }
    }
}
