import AppKit
import SwiftUI

enum Workspace {
    static let space = "workspace"
    static let gap: CGFloat = 6
}

extension EnvironmentValues {
    /// Set on a top-level pane so its BoxView shows drag / maximize / close controls.
    @Entry var paneKind: PaneKind?
}

private struct PaneFramesKey: PreferenceKey {
    static let defaultValue: [PaneKind: CGRect] = [:]
    static func reduce(value: inout [PaneKind: CGRect], nextValue: () -> [PaneKind: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Renders the layout tree, the drop preview while a pane is dragged, and maximized panes.
struct WorkspaceView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let layout = app.layout
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let pane = layout.maximized, layout.isVisible(pane) {
                    PaneView(kind: pane)
                } else if let root = layout.root {
                    LayoutNodeView(node: root, path: [])
                } else {
                    EmptyWorkspace()
                }
                if let drag = layout.drag {
                    DropPreview(drag: drag)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { layout.workspaceSize = geo.size }
            .onChange(of: geo.size) { _, size in layout.workspaceSize = size }
        }
        .coordinateSpace(.named(Workspace.space))
        .onPreferenceChange(PaneFramesKey.self) { frames in
            MainActor.assumeIsolated { app.layout.paneFrames = frames }
        }
    }
}

struct LayoutNodeView: View {
    let node: LayoutNode
    let path: [Int]

    var body: some View {
        switch node {
        case let .pane(kind):
            PaneView(kind: kind)
        case let .split(axis, children, fractions):
            SplitContainer(axis: axis, children: children, fractions: fractions, path: path)
        }
    }
}

private struct SplitContainer: View {
    let axis: SplitAxis
    let children: [LayoutNode]
    let fractions: [Double]
    let path: [Int]

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let available = max(1, length - Workspace.gap * CGFloat(children.count - 1))
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(children.enumerated()), id: \.element.identity) { index, child in
                    let size = available * CGFloat(index < fractions.count ? fractions[index] : 0)
                    LayoutNodeView(node: child, path: path + [index])
                        .frame(width: axis == .horizontal ? size : nil, height: axis == .vertical ? size : nil)
                    if index < children.count - 1 {
                        SplitHandle(axis: axis, index: index, fractions: fractions, available: available, path: path)
                    }
                }
            }
        }
    }
}

/// The gap between two panes: drag to resize, double-click to make them equal.
private struct SplitHandle: View {
    @Environment(AppState.self) private var app

    let axis: SplitAxis
    let index: Int
    let fractions: [Double]
    let available: CGFloat
    let path: [Int]

    @State private var start: [Double]?
    @State private var hovering = false

    var body: some View {
        let horizontal = axis == .horizontal
        let active = hovering || start != nil
        Rectangle()
            .fill(Color.clear)
            .frame(width: horizontal ? Workspace.gap : nil, height: horizontal ? nil : Workspace.gap)
            .overlay {
                Capsule()
                    .fill(Color.accentClay.opacity(active ? 0.9 : 0))
                    .frame(width: horizontal ? 2 : 36, height: horizontal ? 36 : 2)
            }
            .contentShape(Rectangle().inset(by: -2))
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Workspace.space))
                    .onChanged { value in
                        let initial = start ?? fractions
                        if start == nil { start = fractions }
                        resize(from: initial, by: horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        start = nil
                        app.layout.save()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                var f = fractions
                let pair = f[index] + f[index + 1]
                f[index] = pair / 2
                f[index + 1] = pair / 2
                app.layout.setFractions(f, at: path)
                app.layout.save()
            })
            .help("Drag to resize · double-click to split evenly")
    }

    private func resize(from initial: [Double], by delta: CGFloat) {
        guard index + 1 < initial.count else { return }
        var f = initial
        let minimum = (axis == .horizontal ? LayoutStore.minPaneWidth : LayoutStore.minPaneHeight) / available
        let pair = f[index] + f[index + 1]
        let first = min(max(f[index] + delta / available, min(minimum, pair / 2)), pair - min(minimum, pair / 2))
        f[index] = first
        f[index + 1] = pair - first
        app.layout.setFractions(f, at: path)
    }
}

/// One box in the workspace; reports its frame for drag-and-drop hit testing.
struct PaneView: View {
    @Environment(AppState.self) private var app
    let kind: PaneKind

    var body: some View {
        content
            .environment(\.paneKind, kind)
            .opacity(app.layout.drag?.pane == kind ? 0.45 : 1)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: PaneFramesKey.self, value: [kind: geo.frame(in: .named(Workspace.space))])
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .cpu: CPUPane()
        case .mem: MemoryPane()
        case .net: NetworkPane()
        case .proc: ProcessesPane()
        case .gpu: GPUPane()
        case .disks: DisksPane()
        }
    }
}

/// Highlights where a dragged pane will land and shows a label that follows the pointer.
private struct DropPreview: View {
    @Environment(AppState.self) private var app
    @Environment(\.baseFontSize) private var fontSize
    let drag: PaneDrag

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let (rect, label) = highlight {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentClay.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentClay, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    )
                    .overlay {
                        Text(label)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(Color.primaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.paneBackground, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.paneBorder))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeOut(duration: 0.12), value: rect)
            }
            Label(drag.pane.menuTitle, systemImage: drag.pane.symbol)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.paneBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.paneBorder))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .position(x: drag.location.x, y: drag.location.y - 14)
        }
        .allowsHitTesting(false)
    }

    private var highlight: (CGRect, String)? {
        guard let target = drag.target else { return nil }
        let layout = app.layout
        switch target {
        case let .pane(kind, edge):
            guard let frame = layout.paneFrames[kind] else { return nil }
            guard let edge else { return (frame, "Swap with \(kind.menuTitle)") }
            return (half(of: frame, edge: edge), "Dock \(edgeName(edge))")
        case let .workspace(edge):
            let bounds = CGRect(origin: .zero, size: layout.workspaceSize)
            return (strip(of: bounds, edge: edge), edge.axis == .horizontal ? "Full-height column" : "Full-width row")
        }
    }

    private func half(of rect: CGRect, edge: DropEdge) -> CGRect {
        switch edge {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    private func strip(of rect: CGRect, edge: DropEdge) -> CGRect {
        let w = rect.width * 0.3, h = rect.height * 0.3
        switch edge {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        case .right: return CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
        case .bottom: return CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
        }
    }

    private func edgeName(_ edge: DropEdge) -> String {
        switch edge {
        case .left: "left"
        case .right: "right"
        case .top: "above"
        case .bottom: "below"
        }
    }
}

private struct EmptyWorkspace: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("All panes are hidden", systemImage: "square.dashed")
        } description: {
            Text("Show panes from the View menu (⌘1–⌘6) or restore a layout.")
        } actions: {
            Button("Restore Default Layout") { app.layout.apply(.btop) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pane visibility, presets and locking (compact top bar when the sidebar is hidden).
struct LayoutMenuItems: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let layout = app.layout
        Section("Panes") {
            ForEach(PaneKind.allCases) { pane in
                Toggle(pane.menuTitle, isOn: Binding(get: { layout.isVisible(pane) }, set: { layout.setVisible(pane, $0) }))
            }
        }
        Section("Layout") {
            Menu("Apply Preset") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.label) { layout.apply(preset) }
                }
            }
            Toggle("Lock Layout", isOn: Binding(get: { layout.locked }, set: { layout.locked = $0 }))
            if let pane = layout.maximized {
                Button("Restore \(pane.menuTitle) Pane") { layout.maximized = nil }
            }
        }
    }
}
