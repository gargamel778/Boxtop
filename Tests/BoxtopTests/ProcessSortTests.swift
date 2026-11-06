import Testing
@testable import Boxtop

@Suite struct ProcessSortTests {
    private func item(_ pid: Int32, _ name: String = "p", cpu: Double = 0, memory: UInt64 = 0) -> ProcessItem {
        ProcessItem(pid: pid, name: name, command: name, path: "", user: "user", cpu: cpu, cpuTime: 0, threads: 1,
                    memory: memory, state: .sleeping)
    }

    @Test func numbersDescendingWithTiesByPID() {
        let items = [item(3, cpu: 5), item(1, cpu: 1), item(2, cpu: 5), item(4, cpu: 9)]
        let sorted = AppState.sortProcesses(items, by: .cpu, descending: true)
        #expect(sorted.map(\.pid) == [4, 2, 3, 1])
    }

    @Test func numbersAscending() {
        let items = [item(1, memory: 300), item(2, memory: 100), item(3, memory: 200)]
        #expect(AppState.sortProcesses(items, by: .memory, descending: false).map(\.pid) == [2, 3, 1])
    }

    @Test func namesInFinderOrder() {
        let items = [item(1, "Item 10"), item(2, "item 2"), item(3, "Alpha")]
        #expect(AppState.sortProcesses(items, by: .name, descending: false).map(\.pid) == [3, 2, 1])
        #expect(AppState.sortProcesses(items, by: .name, descending: true).map(\.pid) == [1, 2, 3])
    }
}
