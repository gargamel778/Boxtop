import Foundation
import Testing
@testable import Boxtop

@Suite struct LayoutTests {
    let btop = LayoutPreset.btop.layout(hasGPU: true)!

    private func fractionsSumToOne(_ node: LayoutNode) -> Bool {
        guard case let .split(_, children, fractions) = node else { return true }
        return abs(fractions.reduce(0, +) - 1) < 0.0001 && children.allSatisfy(fractionsSumToOne)
    }

    @Test func presetContainsEveryPaneOnce() {
        #expect(Set(btop.panes) == Set(PaneKind.allCases))
        #expect(btop.panes.count == PaneKind.allCases.count)
        #expect(LayoutPreset.btop.layout(hasGPU: false)?.contains(.gpu) == false)
    }

    @Test func removingCollapsesSingleChildSplits() throws {
        // Removing gpu leaves cpu alone in the top row, which must collapse to a leaf.
        let without = try #require(btop.removing(.gpu))
        guard case let .split(.vertical, children, _) = without else { Issue.record("root changed"); return }
        #expect(children[0] == .pane(.cpu))
        #expect(fractionsSumToOne(without))
        #expect(without.removing(.cpu)?.removing(.mem)?.removing(.disks)?.removing(.net)?.removing(.proc) == nil)
    }

    @Test func dockingOnSameAxisJoinsTheParentSplit() {
        let row = LayoutNode.split(.horizontal, [.pane(.cpu), .pane(.gpu)], [0.5, 0.5])
        let docked = row.inserting(.net, beside: .gpu, edge: .left)
        #expect(docked == .split(.horizontal, [.pane(.cpu), .pane(.net), .pane(.gpu)], [0.5, 0.25, 0.25]))
    }

    @Test func dockingOnCrossAxisWrapsTheTarget() {
        let row = LayoutNode.split(.horizontal, [.pane(.cpu), .pane(.gpu)], [0.5, 0.5])
        let docked = row.inserting(.net, beside: .gpu, edge: .bottom)
        #expect(docked == .split(.horizontal, [.pane(.cpu), .split(.vertical, [.pane(.gpu), .pane(.net)], [0.5, 0.5])], [0.5, 0.5]))
    }

    @Test func workspaceEdgeAddsAFullColumn() {
        let docked = btop.removing(.proc)!.inserting(.proc, atWorkspaceEdge: .right)
        guard case let .split(.horizontal, children, fractions) = docked else { Issue.record("expected column split"); return }
        #expect(children.last == .pane(.proc))
        #expect(abs(fractions.last! - 0.33) < 0.001)
        #expect(fractionsSumToOne(docked))
    }

    @Test func swappingKeepsStructure() {
        let swapped = btop.swapping(.cpu, .proc)
        #expect(swapped.panes == btop.panes.map { $0 == .cpu ? .proc : ($0 == .proc ? .cpu : $0) })
        #expect(swapped.swapping(.cpu, .proc) == btop)
    }

    @Test func hiddenPaneReturnsBesideItsNeighbor() throws {
        let hint = try #require(btop.restoreHint(for: .gpu))
        #expect(hint == RestoreHint(neighbor: .cpu, edge: .right))
        let restored = btop.removing(.gpu)!.inserting(.gpu, beside: hint.neighbor, edge: hint.edge)
        #expect(restored.panes == btop.panes)
    }

    @Test func normalizeFlattensSameAxisNesting() {
        let nested = LayoutNode.split(.horizontal, [.pane(.cpu), .split(.horizontal, [.pane(.mem), .pane(.net)], [0.5, 0.5])], [0.5, 0.5])
        #expect(nested.normalized() == .split(.horizontal, [.pane(.cpu), .pane(.mem), .pane(.net)], [0.5, 0.25, 0.25]))
    }

    @Test func validationDropsDuplicatesAndRepairsFractions() {
        var seen = Set<PaneKind>()
        let broken = LayoutNode.split(.vertical, [.pane(.cpu), .pane(.cpu), .pane(.mem)], [0.2])
        let fixed = broken.validated(seen: &seen)
        #expect(fixed?.panes == [.cpu, .mem])
        #expect(fixed.map(fractionsSumToOne) == true)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(btop)
        #expect(try JSONDecoder().decode(LayoutNode.self, from: data) == btop)
    }

    @Test func resizingAtPathTouchesOnlyThatSplit() {
        let resized = btop.settingFractions([0.6, 0.4], at: [0][...])
        guard case let .split(_, children, rootFractions) = resized,
              case let .split(_, _, topFractions) = children[0] else { Issue.record("structure changed"); return }
        #expect(topFractions == [0.6, 0.4])
        #expect(rootFractions == [0.34, 0.66])
    }
}

/// Regression tests for untrusted hardware values (an Intel UHD 630 driver reported an underflowed inUseSysMemoryBytes).
@Suite struct DriverValueTests {
    @Test func underflowedCounterIsRejected() {
        let stats: [String: Any] = ["inUseSysMemoryBytes": NSNumber(value: UInt64(18_446_744_073_668_120_576))]
        #expect(DriverValue.bytes(stats, "inUseSysMemoryBytes") == nil)
    }

    @Test func normalCountersPassThrough() {
        let stats: [String: Any] = ["inUseVidMemoryBytes": NSNumber(value: 498_257_920), "Temperature(C)": NSNumber(value: 57)]
        #expect(DriverValue.bytes(stats, "inUseVidMemoryBytes") == 498_257_920)
        #expect(DriverValue.number(stats, "Temperature(C)", in: 1...150) == 57)
        #expect(DriverValue.number(stats, "missing", in: 0...1) == nil)
    }

    @Test func nonFiniteAndOutOfRangeValuesAreRejected() {
        #expect(Double.nan.sane(0...100) == nil)
        #expect(Double.infinity.sane(0...100) == nil)
        #expect((-5.0).sane(0...100) == nil)
        #expect(42.0.sane(0...100) == 42)
    }

    @Test func formattersNeverTrap() {
        #expect(Fmt.memory(-6_987_776.0) == Fmt.memory(UInt64(0)))
        _ = Fmt.memory(Double.infinity)
        _ = Fmt.size(Double.nan)
        _ = Fmt.uptime(.infinity)
        _ = Fmt.duration(-.infinity)
        _ = Fmt.cpuTime(.nan)
        _ = Fmt.cpuTime(1e300)
    }
}

@Suite struct RedactorTests {
    @Test func homeFoldersAreScrubbed() {
        #expect(Redactor.scrub("/Users/alice/bin/tool --config /Users/alice/.cfg") == "/Users/user/bin/tool --config /Users/user/.cfg")
        #expect(Redactor.scrub("/usr/sbin/cfprefsd agent") == "/usr/sbin/cfprefsd agent")
    }

    @Test func onlyAppleProcessesSurvive() {
        #expect(Redactor.isApple("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        #expect(Redactor.isApple("/usr/libexec/logd"))
        #expect(!Redactor.isApple("/Applications/Example.app/Contents/MacOS/Example"))
        #expect(!Redactor.isApple("/Users/alice/.local/bin/tool"))
    }
}
