import AppKit
import SwiftUI
import SystemConfiguration

/// Sidebar in the style of the Claude desktop app: search, pane list with live values,
/// layouts, top processes, and the machine with a settings button at the bottom.
struct Sidebar: View {
    @Environment(AppState.self) private var app
    @Environment(\.baseFontSize) private var fontSize
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowControls()
            search
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(PaneKind.allCases) { pane in paneRow(pane) }
                    SidebarSection("Layouts")
                    ForEach(LayoutPreset.allCases) { preset in
                        SidebarRow(symbol: preset.symbol, title: preset.label) { app.layout.apply(preset) }
                    }
                    SidebarRow(symbol: app.layout.locked ? "lock.fill" : "lock.open",
                               title: app.layout.locked ? "Layout Locked" : "Lock Layout") {
                        app.layout.locked.toggle()
                    }
                    SidebarSection("Top Processes")
                    ForEach(topProcesses) { process in
                        SidebarRow(image: IconCache.shared.icon(pid: process.pid, path: process.path),
                                   title: RunningApps.shared.name(process.pid, path: process.path, fallback: process.name),
                                   value: String(format: "%.1f%%", app.displayCPU(process.cpuPerCore)),
                                   selected: app.showDetail && app.selectedPID == process.pid) {
                            app.showDetails(for: process.pid)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            footer
        }
        .font(.system(size: fontSize))
        .frame(width: 240)
        .background(Color.sidebarBackground)
        .onChange(of: app.focusSearch) { _, focus in
            if focus {
                searchFocused = true
                app.focusSearch = false
            }
        }
    }

    private var search: some View {
        @Bindable var app = app
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryText)
            TextField("Search processes", text: $app.filterText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    app.filterText = ""
                    searchFocused = false
                    return .handled
                }
            if !app.filterText.isEmpty {
                Button { app.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searchFocused ? Color.accentClay.opacity(0.7) : Color.paneBorder, lineWidth: 1))
    }

    private func paneRow(_ pane: PaneKind) -> some View {
        let visible = app.layout.isVisible(pane)
        return SidebarRow(symbol: pane.symbol, title: pane.menuTitle, value: visible ? paneValue(pane) : "Hidden",
                          dimmed: !visible, selected: app.layout.maximized == pane) {
            app.layout.toggle(pane)
        }
        .help(visible ? "Hide \(pane.menuTitle) (⌘\(pane.hotkey))" : "Show \(pane.menuTitle) (⌘\(pane.hotkey))")
        .contextMenu {
            Button(visible ? "Hide" : "Show") { app.layout.toggle(pane) }
            Button(app.layout.maximized == pane ? "Restore Layout" : "Maximize") { app.layout.toggleMaximized(pane) }
                .disabled(!visible)
        }
    }

    private func paneValue(_ pane: PaneKind) -> String {
        let monitor = app.monitor
        let sample = monitor.latest
        switch pane {
        case .cpu:
            return Fmt.percent(monitor.cpuTotal.last)
        case .mem:
            return Fmt.percent(monitor.memUsed.last)
        case .net:
            guard let name = app.preferences.networkInterface.isEmpty ? sample?.primaryInterface : app.preferences.networkInterface,
                  let iface = sample?.network.first(where: { $0.name == name }) else { return "" }
            return "↓ " + Fmt.rate(iface.rxRate, bits: app.preferences.networkInBits)
        case .proc:
            return Fmt.count(sample?.processes.count ?? 0)
        case .gpu:
            return sample?.gpus.first?.utilization.map(Fmt.percent) ?? ""
        case .disks:
            return sample?.disks.first.map { Fmt.size($0.free) + " free" } ?? ""
        }
    }

    private var topProcesses: [ProcessSample] {
        Array((app.monitor.latest?.processes ?? []).sorted { $0.cpuPerCore > $1.cpuPerCore }.prefix(5))
    }

    private var footer: some View {
        let info = app.monitor.cpuInfo
        let memory = app.monitor.latest?.memory.total ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
                .frame(width: 30, height: 30)
                .background(Color.controlBackground, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(app.preferences.screenshotMode ? Redactor.genericComputerName : Self.computerName)
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text("\(info.model) · \(Fmt.memory(memory))")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondaryText)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static let computerName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Sysctl.string("kern.hostname") ?? "This Mac"
    }()
}

/// Traffic-light spacer, sidebar toggle, pause and update interval (top of the sidebar, or of
/// the window when the sidebar is hidden).
struct WindowControls: View {
    @Environment(AppState.self) private var app
    var showLayoutMenu = false

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 70, height: 1)
            IconButton(symbol: "sidebar.left", help: "Show or hide the sidebar (⌃⌘S)") {
                app.preferences.sidebarVisible.toggle()
            }
            Spacer(minLength: 8)
            if showLayoutMenu {
                Menu {
                    LayoutMenuItems()
                } label: {
                    Image(systemName: "rectangle.3.group").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(Color.secondaryText)
                .fixedSize()
                .help("Panes and layout")
            }
            IconButton(symbol: app.isPaused ? "play.fill" : "pause.fill",
                       help: app.isPaused ? "Resume updates (⌘P)" : "Pause updates (⌘P)") {
                app.isPaused.toggle()
            }
            HeaderMenu(title: intervalLabel) {
                Picker("Update Every", selection: Binding(get: { app.preferences.updateInterval },
                                                          set: { app.setInterval($0) })) {
                    ForEach([0.5, 1, 2, 3, 5, 10], id: \.self) { seconds in
                        Text(seconds < 1 ? "\(Int(seconds * 1000)) ms" : "\(Int(seconds)) s").tag(seconds)
                    }
                }
                .pickerStyle(.inline)
            }
            .help("Update interval")
            .padding(.trailing, 6)
        }
        .frame(height: 28)
    }

    private var intervalLabel: String {
        if app.isPaused { return "Paused" }
        let seconds = app.preferences.updateInterval
        return seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: seconds == seconds.rounded() ? "%.0f s" : "%.1f s", seconds)
    }
}

private struct SidebarSection: View {
    @Environment(\.baseFontSize) private var fontSize
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: fontSize - 1))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

/// A sidebar row: icon, title, optional trailing value, hover and selected backgrounds.
struct SidebarRow: View {
    var symbol: String?
    var image: NSImage?
    let title: String
    var value: String?
    var dimmed = false
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().frame(width: 16, height: 16)
                    } else if let symbol {
                        Image(systemName: symbol).frame(width: 16)
                    }
                }
                .foregroundStyle(dimmed ? Color.tertiaryText : Color.secondaryText)
                Text(title)
                    .foregroundStyle(dimmed ? Color.tertiaryText : Color.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let value {
                    Text(value)
                        .foregroundStyle(dimmed ? Color.tertiaryText : Color.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Color.rowSelected : (hovering ? Color.rowHover : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension LayoutPreset {
    var symbol: String {
        switch self {
        case .btop: "square.grid.2x2"
        case .processes: "sidebar.right"
        case .graphs: "chart.xyaxis.line"
        case .stacked: "rectangle.split.1x2"
        }
    }
}
