import AppKit
import SwiftUI

struct ProcessesPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.baseFontSize) private var fontSize

    var body: some View {
        let items = app.processItems()
        let total = app.monitor.latest?.processes.count ?? 0
        let shown = app.preferences.processTree ? total : items.count
        Pane(.proc, subtitle: shown == total ? Fmt.count(total) : "\(Fmt.count(shown)) of \(Fmt.count(total))") {
            // Details and Quit are also on ⌘I / ⌘⌫ and the context menu, so they can drop out.
            HStack(spacing: 4) {
                IconButton(symbol: "info.circle", help: "Process details (⌘I)") {
                    if app.selectedPID != nil { app.showDetail.toggle() }
                }
                .disabled(app.selectedPID == nil)
                IconButton(symbol: "xmark.octagon", help: "Quit process (⌘⌫)") {
                    app.requestQuit()
                }
                .disabled(app.selectedPID == nil)
            }
        } controls: {
            HeaderMenu(title: app.preferences.processScope.label) {
                Picker("Show", selection: Binding(get: { app.preferences.processScope },
                                                  set: { app.preferences.processScope = $0 })) {
                    ForEach(ProcessScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Tree View", isOn: Binding(get: { app.preferences.processTree },
                                                  set: { app.preferences.processTree = $0 }))
                Toggle("% CPU per Core", isOn: Binding(get: { app.preferences.processPerCore },
                                                       set: { app.preferences.processPerCore = $0 }))
            }
        } content: {
            ProcessOutline(app: app, items: items, tree: app.preferences.processTree,
                           sortKey: app.preferences.processSort, descending: app.preferences.processDescending,
                           selection: app.selectedPID, fontSize: fontSize)
                .padding(.horizontal, -6)
                .padding(.bottom, -8)
        }
    }
}

/// Actions for one process, used by the details pane's menu.
struct ProcessMenuItems: View {
    @Environment(AppState.self) private var app
    let process: ProcessSample

    var body: some View {
        Button("Show Details") { app.showDetails(for: process.pid) }
        Divider()
        Button("Quit…") { app.requestQuit(pid: process.pid) }
        Button("Force Quit") { app.requestSignal(SIGKILL, pid: process.pid) }
        Button(process.state == .stopped ? "Resume" : "Suspend") {
            app.requestSignal(process.state == .stopped ? SIGCONT : SIGSTOP, pid: process.pid)
        }
        Menu("Send Signal") {
            ForEach(Signals.common, id: \.0) { signal in
                Button("\(signal.1) (\(signal.0))") { app.requestSignal(signal.0, pid: process.pid) }
            }
        }
        Divider()
        Button("Filter by “\(process.name)”") { app.filterText = process.name }
        Button("Copy PID") { copy(String(process.pid)) }
        Button("Copy Command") { copy(process.command) }
        if !process.path.isEmpty {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(process.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
