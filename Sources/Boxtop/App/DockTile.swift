import AppKit
import SwiftUI
import Observation

enum DockIconMode: String, CaseIterable, Identifiable, Sendable {
    case appIcon, cpuHistory, cpuCores, memory, network, gpu
    var id: String { rawValue }

    var label: String {
        switch self {
        case .appIcon: "Application Icon"
        case .cpuHistory: "CPU History"
        case .cpuCores: "CPU Usage per Core"
        case .memory: "Memory"
        case .network: "Network"
        case .gpu: "GPU"
        }
    }
}

/// What the Dock tile draws for one update.
struct DockTileModel {
    enum Graph {
        case history([Double], [NSColor])                       // 0...1, newest last; gradient bottom→top
        case columns([Double], NSColor)                         // 0...1 per column (cores)
        case mirrored([Double], [NSColor], [Double], [NSColor]) // download up, upload down
    }

    var title: String
    var value: String?
    var graph: Graph
}

/// Keeps `NSApp.dockTile` in sync with the chosen mode, redrawing after every sample
/// (Activity Monitor's "Dock Icon" menu).
@MainActor
final class DockTileController {
    private unowned let state: AppState
    private let view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var showingCustom = false

    init(state: AppState) {
        self.state = state
        observe()
    }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let tile = NSApp.dockTile
        guard state.preferences.dockIconMode != .appIcon, let model = makeModel() else {
            if showingCustom {
                tile.contentView = nil
                tile.display()
                showingCustom = false
            }
            return
        }
        view.frame = NSRect(origin: .zero, size: tile.size)
        view.model = model
        if !showingCustom {
            tile.contentView = view
            showingCustom = true
        }
        tile.display()
    }

    private func colors(_ gradient: Gradient) -> [NSColor] {
        gradient.stops.map { NSColor($0.color) }
    }

    private func makeModel() -> DockTileModel? {
        let prefs = state.preferences
        let monitor = state.monitor
        let palette = prefs.dockIconThemeColors ? state.palette : .standard
        let showValue = prefs.dockIconShowValue
        let columns = 30
        func normalized(_ history: History, max: Double = 100) -> [Double] {
            history.values.suffix(columns).map { min(1, $0 / max) }
        }

        switch prefs.dockIconMode {
        case .appIcon:
            return nil
        case .cpuHistory:
            return DockTileModel(title: "CPU", value: showValue ? Fmt.percent(monitor.cpuTotal.last) : nil,
                                 graph: .history(normalized(monitor.cpuTotal), colors(palette.cpu)))
        case .cpuCores:
            return DockTileModel(title: "CPU", value: showValue ? Fmt.percent(monitor.cpuTotal.last) : nil,
                                 graph: .columns(monitor.cpuCores.map { min(1, $0.last / 100) }, NSColor(Palette.tint(palette.cpu))))
        case .memory:
            return DockTileModel(title: "Memory", value: showValue ? Fmt.percent(monitor.memUsed.last) : nil,
                                 graph: .history(normalized(monitor.memUsed), [NSColor(palette.memApp), NSColor(palette.memApp)]))
        case .network:
            let sample = monitor.latest
            let name = prefs.networkInterface.isEmpty ? sample?.primaryInterface : prefs.networkInterface
            let history = name.flatMap { monitor.net[$0] } ?? NetHistory()
            let rx = history.rx.values.suffix(columns), tx = history.tx.values.suffix(columns)
            let scale = max(10 * 1024, rx.max() ?? 0, tx.max() ?? 0)
            let current = sample?.network.first { $0.name == name }
            return DockTileModel(title: "Network", value: showValue ? current.map { Fmt.size($0.rxRate) } : nil,
                                 graph: .mirrored(rx.map { $0 / scale }, colors(palette.download),
                                                  tx.map { $0 / scale }, colors(palette.upload)))
        case .gpu:
            guard let gpu = monitor.latest?.gpus.first, let history = monitor.gpuUtilization[gpu.id] else { return nil }
            return DockTileModel(title: "GPU", value: showValue ? Fmt.percent(history.last) : nil,
                                 graph: .history(normalized(history), colors(palette.gpu)))
        }
    }
}

/// Draws the tile on the macOS icon grid (824/1024 rounded square) in Boxtop's pane style.
final class DockTileView: NSView {
    var model: DockTileModel?

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        let unit = side / 1024
        let tile = NSRect(x: (bounds.width - 824 * unit) / 2, y: (bounds.height - 824 * unit) / 2,
                          width: 824 * unit, height: 824 * unit)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 16 * unit,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil))
        ctx.setFillColor(Self.srgb(0x222221).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 4 * unit, dy: 4 * unit), cornerWidth: 182 * unit,
                           cornerHeight: 182 * unit, transform: nil))
        ctx.setStrokeColor(Self.srgb(0x373737).cgColor)
        ctx.setLineWidth(8 * unit)
        ctx.strokePath()

        // Title (secondary) and value (primary), like a pane header.
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 92 * unit, weight: .medium),
            .foregroundColor: Self.srgb(0x9C9A94),
        ]
        (model.title as NSString).draw(at: NSPoint(x: tile.minX + 86 * unit, y: tile.maxY - 196 * unit),
                                       withAttributes: titleAttributes)
        if let value = model.value {
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 150 * unit, weight: .semibold),
                .foregroundColor: Self.srgb(0xE9E7E1),
            ]
            (value as NSString).draw(at: NSPoint(x: tile.minX + 82 * unit, y: tile.maxY - 382 * unit),
                                     withAttributes: valueAttributes)
        }

        let area = NSRect(x: tile.minX + 70 * unit, y: tile.minY + 76 * unit,
                          width: tile.width - 140 * unit, height: model.value == nil ? 520 * unit : 330 * unit)
        switch model.graph {
        case let .history(values, colors):
            areaChart(ctx, values: values, in: area, colors: colors, downward: false, unit: unit)
        case let .columns(values, color):
            columns(ctx, values: values, in: area, color: color, unit: unit)
        case let .mirrored(up, upColors, down, downColors):
            let half = area.height / 2
            areaChart(ctx, values: up, in: NSRect(x: area.minX, y: area.minY + half, width: area.width, height: half),
                      colors: upColors, downward: false, unit: unit)
            areaChart(ctx, values: down, in: NSRect(x: area.minX, y: area.minY, width: area.width, height: half),
                      colors: downColors, downward: true, unit: unit)
        }
    }

    private func areaChart(_ ctx: CGContext, values: [Double], in rect: NSRect, colors: [NSColor], downward: Bool, unit: CGFloat) {
        let count = 30
        let step = rect.width / CGFloat(count - 1)
        let slice = Array(values.suffix(count))
        guard slice.count > 1 else { return }
        let startX = rect.maxX - CGFloat(slice.count - 1) * step
        let points = slice.enumerated().map { i, v in
            CGPoint(x: startX + CGFloat(i) * step,
                    y: downward ? rect.maxY - CGFloat(v) * rect.height : rect.minY + CGFloat(v) * rect.height)
        }
        let line = CGMutablePath()
        line.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            line.addQuadCurve(to: mid, control: points[i - 1])
        }
        line.addLine(to: points[points.count - 1])

        let baseline = downward ? rect.maxY : rect.minY
        let fill = line.mutableCopy()!
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
        fill.addLine(to: CGPoint(x: points[0].x, y: baseline))
        fill.closeSubpath()

        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let stops = colors.isEmpty ? [NSColor.white] : colors
        let start = CGPoint(x: 0, y: baseline), end = CGPoint(x: 0, y: downward ? rect.minY : rect.maxY)
        let faded = stops.enumerated().map { i, c in
            c.withAlphaComponent(0.06 + 0.42 * CGFloat(i) / CGFloat(max(1, stops.count - 1))).cgColor
        } as CFArray
        ctx.saveGState()
        ctx.addPath(fill)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: faded, locations: nil) {
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(line)
        ctx.setLineWidth(14 * unit)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let solid = (stops.count == 1 ? [stops[0], stops[0]] : stops).map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: solid, locations: nil) {
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        ctx.restoreGState()
    }

    private func columns(_ ctx: CGContext, values: [Double], in rect: NSRect, color: NSColor, unit: CGFloat) {
        let count = max(1, values.count)
        let gap = 8 * unit
        let width = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for (i, value) in values.enumerated() {
            let x = rect.minX + CGFloat(i) * (width + gap)
            let track = CGRect(x: x, y: rect.minY, width: width, height: rect.height)
            ctx.addPath(CGPath(roundedRect: track, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            ctx.setFillColor(Self.srgb(0x3A3A39).cgColor)
            ctx.fillPath()
            let h = max(width, rect.height * CGFloat(value))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: rect.minY, width: width, height: h),
                               cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            ctx.setFillColor(color.withAlphaComponent(0.35 + 0.65 * CGFloat(value)).cgColor)
            ctx.fillPath()
        }
    }
}

/// Right-click menu on the Dock icon, like Activity Monitor's.
@MainActor
final class DockMenu: NSObject {
    static let shared = DockMenu()

    func menu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Dock Icon", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in DockIconMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = AppState.shared.preferences.dockIconMode == mode ? .on : .off
            if mode == .gpu, AppState.shared.monitor.latest?.gpus.isEmpty ?? true { item.isEnabled = false }
            submenu.addItem(item)
        }
        header.submenu = submenu
        menu.addItem(header)
        return menu
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DockIconMode(rawValue: raw) else { return }
        AppState.shared.preferences.dockIconMode = mode
    }
}
