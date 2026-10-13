import Foundation
import Observation

/// The boxes that can be placed in the workspace.
enum PaneKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, mem, net, proc, gpu, disks

    var id: String { rawValue }
    var title: String { rawValue }

    var hotkey: String {
        switch self {
        case .cpu: "1"
        case .mem: "2"
        case .net: "3"
        case .proc: "4"
        case .gpu: "5"
        case .disks: "6"
        }
    }

    var menuTitle: String {
        switch self {
        case .cpu: "CPU"
        case .mem: "Memory"
        case .net: "Network"
        case .proc: "Processes"
        case .gpu: "GPU"
        case .disks: "Disks"
        }
    }
}

/// `horizontal` lays children side by side, `vertical` stacks them.
enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

enum DropEdge: String, Codable, Sendable {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var isLeading: Bool { self == .left || self == .top }
}

/// Where a dragged pane lands: an edge of another pane (dock beside it), its center (swap),
/// or an edge of the whole workspace (new full-height column / full-width row).
enum DropTarget: Equatable, Sendable {
    case pane(PaneKind, DropEdge?)
    case workspace(DropEdge)
}

/// A tiling layout: panes are leaves, splits divide space by fractions that sum to 1.
indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(PaneKind)
    case split(SplitAxis, [LayoutNode], [Double])

    var panes: [PaneKind] {
        switch self {
        case let .pane(kind): [kind]
        case let .split(_, children, _): children.flatMap(\.panes)
        }
    }

    /// Stable identity for SwiftUI: the panes it contains.
    var identity: String { panes.map(\.rawValue).joined(separator: "+") }

    func contains(_ pane: PaneKind) -> Bool { panes.contains(pane) }

    /// Removes `pane`; returns nil when nothing is left.
    func removing(_ pane: PaneKind) -> LayoutNode? {
        switch self {
        case let .pane(kind):
            return kind == pane ? nil : self
        case let .split(axis, children, fractions):
            var kept: [LayoutNode] = [], keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let remaining = child.removing(pane) {
                    kept.append(remaining)
                    keptFractions.append(fraction)
                }
            }
            return LayoutNode.split(axis, kept, keptFractions).normalized()
        }
    }

    /// Docks `pane` beside `target` on `edge`, splitting the target's space in half.
    func inserting(_ pane: PaneKind, beside target: PaneKind, edge: DropEdge) -> LayoutNode {
        switch self {
        case let .pane(kind):
            guard kind == target else { return self }
            let new = LayoutNode.pane(pane)
            return .split(edge.axis, edge.isLeading ? [new, self] : [self, new], [0.5, 0.5])
        case let .split(axis, children, fractions):
            if axis == edge.axis, let index = children.firstIndex(of: .pane(target)) {
                var c = children, f = fractions
                let half = f[index] / 2
                f[index] = half
                let at = edge.isLeading ? index : index + 1
                c.insert(.pane(pane), at: at)
                f.insert(half, at: at)
                return .split(axis, c, f)
            }
            return .split(axis, children.map { $0.inserting(pane, beside: target, edge: edge) }, fractions)
        }
    }

    /// Adds `pane` along one edge of the whole layout, taking about a third of the space.
    func inserting(_ pane: PaneKind, atWorkspaceEdge edge: DropEdge) -> LayoutNode {
        let new = LayoutNode.pane(pane)
        if case let .split(axis, children, fractions) = self, axis == edge.axis {
            let share = 1 / Double(children.count + 1)
            let scaled = fractions.map { $0 * (1 - share) }
            return edge.isLeading
                ? .split(axis, [new] + children, [share] + scaled)
                : .split(axis, children + [new], scaled + [share])
        }
        return .split(edge.axis, edge.isLeading ? [new, self] : [self, new], edge.isLeading ? [0.33, 0.67] : [0.67, 0.33])
    }

    func swapping(_ a: PaneKind, _ b: PaneKind) -> LayoutNode {
        switch self {
        case let .pane(kind):
            return kind == a ? .pane(b) : (kind == b ? .pane(a) : self)
        case let .split(axis, children, fractions):
            return .split(axis, children.map { $0.swapping(a, b) }, fractions)
        }
    }

    func settingFractions(_ newFractions: [Double], at path: ArraySlice<Int>) -> LayoutNode {
        guard case let .split(axis, children, fractions) = self else { return self }
        guard let first = path.first else {
            return newFractions.count == children.count ? .split(axis, children, newFractions) : self
        }
        var c = children
        guard first < c.count else { return self }
        c[first] = c[first].settingFractions(newFractions, at: path.dropFirst())
        return .split(axis, c, fractions)
    }

    /// Collapses single-child splits, flattens same-axis nesting and renormalizes fractions.
    func normalized() -> LayoutNode? {
        guard case let .split(axis, children, fractions) = self else { return self }
        var flat: [LayoutNode] = [], flatFractions: [Double] = []
        for (child, fraction) in zip(children, fractions) {
            guard let child = child.normalized() else { continue }
            if case let .split(childAxis, grandchildren, childFractions) = child, childAxis == axis {
                let sum = max(childFractions.reduce(0, +), 0.0001)
                flat += grandchildren
                flatFractions += childFractions.map { $0 / sum * fraction }
            } else {
                flat.append(child)
                flatFractions.append(fraction)
            }
        }
        if flat.isEmpty { return nil }
        if flat.count == 1 { return flat[0] }
        let total = flatFractions.reduce(0, +)
        let normalized = total > 0 ? flatFractions.map { max(0.02, $0 / total) } : Array(repeating: 1 / Double(flat.count), count: flat.count)
        let sum = normalized.reduce(0, +)
        return .split(axis, flat, normalized.map { $0 / sum })
    }

    /// Where to put `pane` back when it is shown again: beside its old neighbor.
    func restoreHint(for pane: PaneKind) -> RestoreHint? {
        guard case let .split(axis, children, _) = self else { return nil }
        if let index = children.firstIndex(of: .pane(pane)) {
            if index + 1 < children.count, let next = children[index + 1].panes.first {
                return RestoreHint(neighbor: next, edge: axis == .horizontal ? .left : .top)
            }
            if index > 0, let previous = children[index - 1].panes.last {
                return RestoreHint(neighbor: previous, edge: axis == .horizontal ? .right : .bottom)
            }
        }
        for child in children {
            if let hint = child.restoreHint(for: pane) { return hint }
        }
        return nil
    }

    /// Drops duplicate panes and repairs fraction arrays (for layouts read from disk).
    func validated(seen: inout Set<PaneKind>) -> LayoutNode? {
        switch self {
        case let .pane(kind):
            return seen.insert(kind).inserted ? self : nil
        case let .split(axis, children, fractions):
            var kept: [LayoutNode] = [], keptFractions: [Double] = []
            for (i, child) in children.enumerated() {
                if let valid = child.validated(seen: &seen) {
                    kept.append(valid)
                    keptFractions.append(i < fractions.count && fractions[i] > 0 ? fractions[i] : 1)
                }
            }
            return LayoutNode.split(axis, kept, keptFractions).normalized()
        }
    }
}

struct RestoreHint: Codable, Equatable, Sendable {
    var neighbor: PaneKind
    var edge: DropEdge
}

enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case btop, processes, graphs, stacked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .btop: "btop (default)"
        case .processes: "Process Focus"
        case .graphs: "Graphs Only"
        case .stacked: "Stacked"
        }
    }

    func layout(hasGPU: Bool) -> LayoutNode? {
        let node: LayoutNode
        switch self {
        case .btop:
            // btop's arrangement: cpu (+gpu) on top; mem, disks and net left of proc.
            node = .split(.vertical, [
                .split(.horizontal, [.pane(.cpu), .pane(.gpu)], [0.72, 0.28]),
                .split(.horizontal, [
                    .split(.vertical, [.split(.horizontal, [.pane(.mem), .pane(.disks)], [0.5, 0.5]), .pane(.net)], [0.62, 0.38]),
                    .pane(.proc),
                ], [0.44, 0.56]),
            ], [0.34, 0.66])
        case .processes:
            node = .split(.horizontal, [
                .split(.vertical, [.pane(.cpu), .pane(.mem), .pane(.net)], [0.4, 0.32, 0.28]),
                .pane(.proc),
            ], [0.36, 0.64])
        case .graphs:
            node = .split(.vertical, [
                .split(.horizontal, [.pane(.cpu), .pane(.gpu)], [0.62, 0.38]),
                .split(.horizontal, [.pane(.mem), .pane(.disks), .pane(.net)], [0.34, 0.3, 0.36]),
            ], [0.55, 0.45])
        case .stacked:
            node = .split(.vertical, [
                .pane(.cpu),
                .split(.horizontal, [.pane(.mem), .pane(.net)], [0.5, 0.5]),
                .pane(.proc),
            ], [0.3, 0.25, 0.45])
        }
        return hasGPU ? node : node.removing(.gpu)
    }
}

/// A pane being dragged by its title, with the drop target under the pointer.
struct PaneDrag: Equatable {
    var pane: PaneKind
    var location: CGPoint
    var target: DropTarget?
}

/// Owns the workspace layout: visibility, sizes, rearranging, presets and persistence.
@MainActor
@Observable
final class LayoutStore {
    private(set) var root: LayoutNode?
    var maximized: PaneKind?
    var locked: Bool { didSet { defaults.set(locked, forKey: Keys.locked) } }
    private(set) var drag: PaneDrag?

    /// Pane frames in the workspace coordinate space, reported by the views.
    @ObservationIgnored var paneFrames: [PaneKind: CGRect] = [:]
    @ObservationIgnored var workspaceSize: CGSize = .zero

    @ObservationIgnored private let hasGPU: Bool
    @ObservationIgnored private var hints: [PaneKind: RestoreHint] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let layout = "layout.v1"
        static let hints = "layout.hints.v1"
        static let locked = "layout.locked"
    }

    static let minPaneWidth: CGFloat = 170
    static let minPaneHeight: CGFloat = 90

    init(hasGPU: Bool) {
        self.hasGPU = hasGPU
        locked = defaults.bool(forKey: Keys.locked)
        if let data = defaults.data(forKey: Keys.hints),
           let saved = try? JSONDecoder().decode([PaneKind: RestoreHint].self, from: data) {
            hints = saved
        }
        if let data = defaults.data(forKey: Keys.layout), let saved = try? JSONDecoder().decode(LayoutNode?.self, from: data) {
            var seen = Set<PaneKind>()
            root = saved.validated(seen: &seen)
        } else {
            root = LayoutPreset.btop.layout(hasGPU: hasGPU)
        }
    }

    // MARK: Visibility

    func isVisible(_ pane: PaneKind) -> Bool { root?.contains(pane) ?? false }

    func toggle(_ pane: PaneKind) { setVisible(pane, !isVisible(pane)) }

    func setVisible(_ pane: PaneKind, _ visible: Bool) {
        guard visible != isVisible(pane) else { return }
        if visible {
            show(pane)
        } else {
            if let hint = root?.restoreHint(for: pane) { hints[pane] = hint }
            root = root?.removing(pane)
            if maximized == pane { maximized = nil }
        }
        save()
    }

    private func show(_ pane: PaneKind) {
        guard let current = root else {
            root = .pane(pane)
            return
        }
        if let hint = hints[pane], current.contains(hint.neighbor) {
            root = current.inserting(pane, beside: hint.neighbor, edge: hint.edge)
        } else if let largest = largestPane() {
            // Split the biggest pane along its longer side.
            let frame = paneFrames[largest] ?? .zero
            root = current.inserting(pane, beside: largest, edge: frame.width >= frame.height ? .right : .bottom)
        } else {
            root = current.inserting(pane, atWorkspaceEdge: .right)
        }
    }

    private func largestPane() -> PaneKind? {
        root?.panes.max { a, b in
            let fa = paneFrames[a] ?? .zero, fb = paneFrames[b] ?? .zero
            return fa.width * fa.height < fb.width * fb.height
        }
    }

    // MARK: Sizing

    func setFractions(_ fractions: [Double], at path: [Int]) {
        root = root?.settingFractions(fractions, at: path[...])
    }

    // MARK: Rearranging

    func dragChanged(_ pane: PaneKind, at point: CGPoint) {
        guard !locked else { return }
        drag = PaneDrag(pane: pane, location: point, target: target(for: pane, at: point))
    }

    func dragEnded() {
        defer { drag = nil }
        guard let drag, let target = drag.target else { return }
        move(drag.pane, to: target)
    }

    func move(_ pane: PaneKind, to target: DropTarget) {
        guard let current = root else { return }
        switch target {
        case let .pane(other, nil):
            guard other != pane else { return }
            root = current.swapping(pane, other)
        case let .pane(other, edge?):
            guard other != pane, let without = current.removing(pane) else { return }
            root = without.inserting(pane, beside: other, edge: edge).normalized()
        case let .workspace(edge):
            guard let without = current.removing(pane) else { return }
            root = without.inserting(pane, atWorkspaceEdge: edge).normalized()
        }
        save()
    }

    /// Edge bands of the workspace dock at the workspace level; within a pane, the outer 30%
    /// on each side docks beside it and the middle swaps.
    private func target(for pane: PaneKind, at p: CGPoint) -> DropTarget? {
        let size = workspaceSize
        let band: CGFloat = 16
        if size.width > 0, (root?.panes.count ?? 0) > 1 {
            if p.x < band { return .workspace(.left) }
            if p.x > size.width - band { return .workspace(.right) }
            if p.y < band { return .workspace(.top) }
            if p.y > size.height - band { return .workspace(.bottom) }
        }
        guard let (kind, frame) = paneFrames.first(where: { $0.value.contains(p) }), kind != pane else { return nil }
        let rx = (p.x - frame.minX) / max(frame.width, 1)
        let ry = (p.y - frame.minY) / max(frame.height, 1)
        let distances: [(DropEdge, CGFloat)] = [(.left, rx), (.right, 1 - rx), (.top, ry), (.bottom, 1 - ry)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.3 ? .pane(kind, nearest.0) : .pane(kind, nil)
    }

    // MARK: Presets

    func apply(_ preset: LayoutPreset) {
        root = preset.layout(hasGPU: hasGPU)
        maximized = nil
        save()
    }

    func toggleMaximized(_ pane: PaneKind) {
        maximized = maximized == pane ? nil : (isVisible(pane) ? pane : nil)
    }

    func save() {
        if let data = try? JSONEncoder().encode(root) { defaults.set(data, forKey: Keys.layout) }
        if let data = try? JSONEncoder().encode(hints) { defaults.set(data, forKey: Keys.hints) }
    }
}
