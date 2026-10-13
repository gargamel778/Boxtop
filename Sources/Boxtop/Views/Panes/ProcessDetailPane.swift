import AppKit
import SwiftUI

/// Right-hand details pane for the selected process (like Claude's side panes).
struct ProcessDetailPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.baseFontSize) private var fontSize

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Process").font(.system(size: fontSize + 1)).foregroundStyle(Color.primaryText)
                Spacer()
                if let process = app.selectedProcess {
                    Menu {
                        ProcessMenuItems(process: process)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize()
                }
                IconButton(symbol: "xmark", help: "Close details") { app.showDetail = false }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)

            Group {
                if let process = app.selectedProcess {
                    ScrollView(.vertical) {
                        content(process)
                    }
                    .scrollIndicators(.never)
                } else {
                    ContentUnavailableView("No Process Selected", systemImage: "list.bullet.rectangle",
                                           description: Text("Select a process to see its details."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .font(.system(size: fontSize))
        .background(Color.paneBackground, in: shape)
        .overlay(shape.strokeBorder(Color.paneBorder, lineWidth: 1))
        .clipShape(shape)
    }

    private func content(_ process: ProcessSample) -> some View {
        let monitor = app.monitor
        let cpu = monitor.processCPU[process.pid] ?? History()
        let memory = monitor.processMemory[process.pid] ?? History()
        let detail = monitor.latest?.processDetail?.pid == process.pid ? monitor.latest?.processDetail : nil
        let parent = monitor.latest?.processes.first { $0.pid == process.ppid }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.shared.icon(pid: process.pid, path: process.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RunningApps.shared.name(process.pid, path: process.path, fallback: process.name))
                        .font(.system(size: fontSize + 3, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(2)
                    Text("PID \(String(process.pid)) · \(process.user)")
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
                StateBadge(state: process.state)
            }
            .padding(.vertical, 4)

            Card(fill: false) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("CPU") {
                        Text(String(format: "%.1f%%", app.displayCPU(process.cpuPerCore))).monospacedDigit()
                            .foregroundStyle(Color.primaryText)
                    }
                    GraphView(values: cpu.values, maxValue: max(100, cpu.values.max() ?? 0), gradient: palette.cpu,
                              style: .line, gridLines: true)
                        .frame(height: 70)
                }
            }
            Card(fill: false) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Memory") {
                        Text(Fmt.memory(process.residentBytes)).monospacedDigit().foregroundStyle(Color.primaryText)
                    }
                    GraphView(values: memory.values, maxValue: max(1, (memory.values.max() ?? 1) * 1.25),
                              color: palette.memApp, style: .line, gridLines: true)
                        .frame(height: 56)
                }
            }

            Card(fill: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Parent", parent.map { "\($0.name) (\(String($0.pid)))" } ?? String(process.ppid))
                    row("Started", process.startTime.formatted(date: .abbreviated, time: .shortened))
                    row("Running for", Fmt.duration(Date().timeIntervalSince(process.startTime)))
                    row("CPU time", Fmt.cpuTime(process.cpuTimeSeconds))
                    row("Threads", String(process.threads))
                    row("Priority (nice)", String(process.nice))
                    if let detail {
                        row("Disk read", Fmt.size(detail.diskRead))
                        row("Disk written", Fmt.size(detail.diskWritten))
                        if let files = detail.openFiles { row("Open files", String(files)) }
                    }
                }
                .font(.system(size: fontSize - 1))
            }

            Card(fill: false) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Command")
                    Text(process.command)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !process.path.isEmpty, process.path != process.command {
                        Text(process.path)
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(Color.tertiaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Quit…") { app.requestQuit(pid: process.pid) }
                Button(process.state == .stopped ? "Resume" : "Suspend") {
                    app.requestSignal(process.state == .stopped ? SIGCONT : SIGSTOP, pid: process.pid)
                }
                Spacer()
                Button("Force Quit", role: .destructive) { app.requestSignal(SIGKILL, pid: process.pid) }
            }
            .controlSize(.regular)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Color.secondaryText)
            Text(value).foregroundStyle(Color.primaryText).lineLimit(1).truncationMode(.middle)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct StateBadge: View {
    @Environment(\.baseFontSize) private var fontSize
    let state: ProcessState

    var body: some View {
        Text(state.label)
            .font(.system(size: fontSize - 2, weight: .medium))
            .foregroundStyle(state == .stopped || state == .zombie ? Color.accentClay : Color.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.cardBackground, in: Capsule())
    }
}
