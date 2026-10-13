import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var baseFontSize: Double = 13
    @Entry var graphStyle: GraphStyle = .line
}

// MARK: - Pane chrome

/// A workspace pane in the style of the Claude desktop app: a flat rounded panel with a hairline
/// border, a plain title row (drag handle) and icon buttons on the right.
struct Pane<Accessory: View, Content: View>: View {
    @Environment(AppState.self) private var app: AppState?
    @Environment(\.baseFontSize) private var fontSize

    let kind: PaneKind
    var subtitle: String?
    let accessory: Accessory
    let content: Content

    init(_ kind: PaneKind, subtitle: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    @State private var middleWidth: CGFloat = 0
    @State private var accessoryWidth: CGFloat = 0
    @State private var subtitleWidth: CGFloat = 0

    private var showAccessory: Bool { accessoryWidth > 0 && accessoryWidth + 6 <= middleWidth }
    private var showSubtitle: Bool {
        subtitle != nil && subtitleWidth + (showAccessory ? accessoryWidth + 14 : 0) <= middleWidth
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            content
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.paneBackground, in: shape)
        .overlay(shape.strokeBorder(Color.paneBorder, lineWidth: 1))
        .clipShape(shape)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
        }
    }

    private var accessoryView: some View {
        accessory
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .fixedSize()
    }

    private var header: some View {
        let layout = app?.layout
        let movable = !(layout?.locked ?? true) && layout?.maximized == nil
        let maximized = layout?.maximized == kind
        return HStack(spacing: 8) {
            Text(kind.menuTitle)
                .font(.system(size: fontSize + 1))
                .foregroundStyle(Color.primaryText)
                .fixedSize()
            // Narrow panes drop the subtitle first, then the accessory, instead of squeezing them.
            // Both are measured invisibly and shown only when they fit the space that is left.
            HStack(spacing: 8) {
                if showSubtitle { subtitleText }
                Spacer(minLength: 0)
                if showAccessory { accessoryView }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { middleWidth = $0 }
            .background(alignment: .leading) {
                ZStack {
                    accessoryView
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { accessoryWidth = $0 }
                    subtitleText
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { subtitleWidth = $0 }
                }
                .hidden()
            }
            HStack(spacing: 0) {
                IconButton(symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: maximized ? "Restore layout" : "Maximize \(kind.menuTitle)") {
                    layout?.toggleMaximized(kind)
                }
                if !(layout?.locked ?? false), !maximized {
                    IconButton(symbol: "xmark", help: "Hide \(kind.menuTitle) (⌘\(kind.hotkey) shows it again)") {
                        layout?.setVisible(kind, false)
                    }
                }
            }
            .fixedSize()
        }
        .font(.system(size: fontSize))
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .contentShape(Rectangle())
        .pointerStyle(movable ? .grabIdle : nil)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Workspace.space))
                .onChanged { layout?.dragChanged(kind, at: $0.location) }
                .onEnded { _ in layout?.dragEnded() },
            including: movable ? .all : .subviews
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { layout?.toggleMaximized(kind) })
        .help(movable ? "Drag to move · double-click to maximize" : "")
    }
}

/// Small borderless icon button with a hover background (Claude's pane header buttons).
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .frame(width: size, height: size)
                .background(hovering ? Color.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(hovering ? Color.primaryText : Color.secondaryText)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Title-style dropdown ("Name ⌄") for pane headers.
struct HeaderMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.secondaryText)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Inner rounded card (the task rows inside Claude's panes).
struct Card<Content: View>: View {
    var padding: CGFloat = 10
    var fill = true
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SectionLabel<Trailing: View>: View {
    @Environment(\.baseFontSize) private var fontSize
    let text: String
    @ViewBuilder var trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Spacer(minLength: 4)
            trailing
        }
        .font(.system(size: fontSize - 1))
        .foregroundStyle(Color.secondaryText)
        .lineLimit(1)
    }
}

/// Header metadata: a symbol and a short value in secondary text.
struct Meta: View {
    var symbol: String?
    let text: String
    var color: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color ?? Color.secondaryText) }
            Text(text).monospacedDigit()
        }
        .foregroundStyle(Color.secondaryText)
        .lineLimit(1)
        .fixedSize()
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        // The value always stays whole; the label truncates first when space runs out.
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(Color.secondaryText).layoutPriority(-1)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(Color.primaryText).monospacedDigit().fixedSize()
        }
        .lineLimit(1)
    }
}

/// A large value with a caption, used in metric cards.
struct BigValue: View {
    @Environment(\.baseFontSize) private var fontSize
    let value: String
    var caption: String?
    var color: Color = .primaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: fontSize * 1.65, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Gauges

struct RingGauge<Label: View>: View {
    var value: Double              // 0...100
    var color: Color
    var lineWidth: CGFloat = 9
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(Color.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.001, value / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Stacked capacity bar (macOS storage-bar style). Segment values are fractions of the whole.
struct CapacityBar: View {
    var segments: [(value: Double, color: Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geo.size.width * min(1, segment.value)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.track)
        .clipShape(Capsule())
    }
}

// MARK: - Graph

/// Scrolling history chart; the newest value is at the right edge.
/// Styles: smooth area (default), bars, or btop's braille-like dots.
struct GraphView: View {
    @Environment(\.graphStyle) private var environmentStyle

    var values: [Double]
    var maxValue: Double = 100
    var gradient: Gradient
    var style: GraphStyle?
    var inverted = false
    var pitch: CGFloat = 3
    var gridLines = false
    var lineWidth: CGFloat = 1.5

    init(values: [Double], maxValue: Double = 100, color: Color, style: GraphStyle? = nil,
         inverted: Bool = false, pitch: CGFloat = 3, gridLines: Bool = false, lineWidth: CGFloat = 1.5) {
        self.init(values: values, maxValue: maxValue, gradient: Gradient(colors: [color, color]), style: style,
                  inverted: inverted, pitch: pitch, gridLines: gridLines, lineWidth: lineWidth)
    }

    init(values: [Double], maxValue: Double = 100, gradient: Gradient, style: GraphStyle? = nil,
         inverted: Bool = false, pitch: CGFloat = 3, gridLines: Bool = false, lineWidth: CGFloat = 1.5) {
        self.values = values
        self.maxValue = maxValue
        self.gradient = gradient
        self.style = style
        self.inverted = inverted
        self.pitch = pitch
        self.gridLines = gridLines
        self.lineWidth = lineWidth
    }

    var body: some View {
        let style = style ?? environmentStyle
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 2, size.height > 2, maxValue > 0 else { return }
            if gridLines {
                var grid = Path()
                for fraction in [0.25, 0.5, 0.75] {
                    let y = size.height * fraction
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.gridLine), lineWidth: 1)
            }
            let start = CGPoint(x: 0, y: inverted ? 0 : size.height)
            let end = CGPoint(x: 0, y: inverted ? size.height : 0)
            let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: start, endPoint: end)
            switch style {
            case .line:
                let points = points(size)
                guard points.count > 1 else { return }
                let fade = Gradient(stops: gradient.stops.map {
                    .init(color: $0.color.opacity(0.04 + 0.34 * $0.location), location: $0.location)
                })
                context.fill(area(points, size: size), with: .linearGradient(fade, startPoint: start, endPoint: end))
                context.stroke(curve(points), with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            case .block:
                context.fill(bars(size), with: shading)
            case .braille:
                context.fill(dots(size), with: shading)
            }
        }
    }

    private func level(_ value: Double) -> Double { min(1, max(0, value / maxValue)) }

    private func points(_ size: CGSize) -> [CGPoint] {
        let columns = Int(size.width / pitch)
        let slice = values.suffix(columns + 1)
        let startX = size.width - CGFloat(max(0, slice.count - 1)) * pitch
        let usable = size.height - lineWidth
        return slice.enumerated().map { i, value in
            let h = CGFloat(level(value)) * usable
            return CGPoint(x: startX + CGFloat(i) * pitch, y: inverted ? h + lineWidth / 2 : size.height - h - lineWidth / 2)
        }
    }

    /// Smoothed polyline through the midpoints (cheap and steady for live data).
    private func curve(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            let previous = points[i - 1], current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private func area(_ points: [CGPoint], size: CGSize) -> Path {
        var path = curve(points)
        let baseline = inverted ? 0 : size.height
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
        path.addLine(to: CGPoint(x: points[0].x, y: baseline))
        path.closeSubpath()
        return path
    }

    private func bars(_ size: CGSize) -> Path {
        let columns = Int(size.width / pitch)
        let slice = values.suffix(columns)
        let first = columns - slice.count
        let offset = size.width - CGFloat(columns) * pitch
        var path = Path()
        for (i, value) in slice.enumerated() {
            let h = CGFloat(level(value)) * size.height
            guard h > 0.3 else { continue }
            let rect = CGRect(x: offset + CGFloat(first + i) * pitch, y: inverted ? 0 : size.height - h,
                              width: max(1, pitch - 1), height: h)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.8, height: 0.8))
        }
        return path
    }

    /// Dot matrix that mimics btop's braille graphs.
    private func dots(_ size: CGSize) -> Path {
        let columns = Int(size.width / pitch)
        let rows = max(1, Int(size.height / pitch))
        let dot = pitch * 0.68
        let inset = (pitch - dot) / 2
        let slice = values.suffix(columns)
        let first = columns - slice.count
        let xOffset = size.width - CGFloat(columns) * pitch
        let yOffset = size.height - CGFloat(rows) * pitch
        var path = Path()
        for (i, value) in slice.enumerated() {
            let l = level(value)
            var count = Int((l * Double(rows)).rounded())
            if l > 0.004, count == 0 { count = 1 }
            let x = xOffset + CGFloat(first + i) * pitch + inset
            for r in 0..<count {
                let y = inverted ? CGFloat(r) * pitch + inset : yOffset + CGFloat(rows - r - 1) * pitch + inset
                path.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
        }
        return path
    }
}
