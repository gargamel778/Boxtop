import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Appearance", systemImage: "paintpalette") { AppearanceSettings() }
            Tab("Panes", systemImage: "rectangle.3.group") { PaneSettings() }
            Tab("Processes", systemImage: "list.bullet.rectangle") { ProcessSettings() }
        }
        .frame(width: 560, height: 580)
        .preferredColorScheme(app.preferences.appearance.colorScheme)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Updates") {
                LabeledContent("Update interval") {
                    HStack {
                        Slider(value: Binding(get: { prefs.updateInterval }, set: { app.setInterval($0) }),
                               in: 0.25...10, step: 0.25)
                        Text("\(Int(prefs.updateInterval * 1000)) ms")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                Toggle("Pause updates", isOn: Binding(get: { app.isPaused }, set: { app.isPaused = $0 }))
            }
            Section("Units") {
                Picker("Temperature", selection: $prefs.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Network speeds in bits per second", isOn: $prefs.networkInBits)
            }
            Section("Privacy") {
                Toggle("Screenshot mode", isOn: Binding(get: { prefs.screenshotMode }, set: { app.setScreenshotMode($0) }))
                Text("Hides your Mac’s name, your user name, network addresses, other volumes and third-party processes, so the window can be captured and shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Menu Bar") {
                Toggle("Show CPU graph in the menu bar", isOn: $prefs.showMenuBarExtra)
                Text("With the menu bar item on, closing the window keeps Boxtop running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Window") {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $prefs.fontSize, in: 11...16, step: 0.5)
                        Text(String(format: "%.1f pt", prefs.fontSize)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
            Section("Charts") {
                Picker("Chart style", selection: $prefs.graphStyle) {
                    ForEach(GraphStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Chart colors", selection: $prefs.chartColors) {
                    HStack {
                        PaletteSwatch(colors: [Palette.blue, Palette.coral, Palette.amber, Palette.violet, Palette.teal].map(\.color))
                        Text("Default")
                    }
                    .tag(Palette.standard.name)
                    Divider()
                    ForEach(app.themes) { theme in
                        HStack {
                            PaletteSwatch(colors: [theme.cpu.start, theme.cpu.mid ?? theme.cpu.start, theme.cpu.end ?? theme.cpu.start,
                                                   theme.download.rgb(at: 1), theme.used.rgb(at: 1)].map(\.color))
                            Text(theme.name)
                            if theme.source == .user { Text("user").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(theme.name)
                    }
                }
                HStack {
                    Text("Use any btop theme for chart colors. Themes in ~/.config/btop/themes are picked up automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reload") { app.reloadThemes() }
                    Button("Open Folder") { openThemeFolder() }
                }
            }
            Section("Dock Icon") {
                Picker("Dock icon shows", selection: $prefs.dockIconMode) {
                    ForEach(DockIconMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show current value", isOn: $prefs.dockIconShowValue)
                    .disabled(prefs.dockIconMode == .appIcon)
                Toggle("Use chart colors", isOn: $prefs.dockIconThemeColors)
                    .disabled(prefs.dockIconMode == .appIcon)
                Text("You can also right-click Boxtop’s Dock icon to switch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func openThemeFolder() {
        guard let dir = ThemeStore.userThemeDirectories.first(where: { FileManager.default.fileExists(atPath: $0.path) })
                ?? ThemeStore.userThemeDirectories.last else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

private struct PaletteSwatch: View {
    let colors: [Color]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(color).frame(width: 9, height: 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.separator))
    }
}

private struct PaneSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Panes") {
                ForEach(PaneKind.allCases) { pane in
                    Toggle(isOn: Binding(get: { app.layout.isVisible(pane) }, set: { app.layout.setVisible(pane, $0) })) {
                        Label("\(pane.menuTitle)  ⌘\(pane.hotkey)", systemImage: pane.symbol)
                    }
                }
            }
            Section("Layout") {
                Toggle("Lock layout", isOn: Binding(get: { app.layout.locked }, set: { app.layout.locked = $0 }))
                LabeledContent("Preset") {
                    Menu("Apply…") {
                        ForEach(LayoutPreset.allCases) { preset in
                            Button(preset.label) { app.layout.apply(preset) }
                        }
                    }
                    .fixedSize()
                }
                Text("Drag a pane by its title to move it, drag the gaps between panes to resize, double-click a title to maximize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("CPU") {
                Toggle("Show temperatures", isOn: $prefs.showTemperatures)
                    .disabled(!app.monitor.hasTemperatures)
                Toggle("Show battery", isOn: $prefs.showBattery)
            }
            Section("Memory & Disks") {
                Toggle("Show swap", isOn: $prefs.showSwap)
                Toggle("Include hidden system volumes", isOn: Binding(get: { prefs.showHiddenDisks },
                                                                       set: { app.setShowHiddenDisks($0) }))
            }
            Section("Network") {
                Toggle("Same scale for upload and download", isOn: $prefs.networkSyncScale)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProcessSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Process list") {
                Picker("Show", selection: $prefs.processScope) {
                    ForEach(ProcessScope.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Tree view (group by parent process)", isOn: $prefs.processTree)
                Toggle("% CPU per core (100% = one core)", isOn: $prefs.processPerCore)
                Text("Right-click the table header to show, hide or reorder columns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Signals") {
                Toggle("Confirm before sending terminating signals", isOn: $prefs.confirmSignals)
            }
            Section("Keyboard") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    shortcut("⌘F", "Search processes")
                    shortcut("⌘I", "Show or hide process details")
                    shortcut("⌫ · ⌘⌫", "Quit the selected process")
                    shortcut("⌥⌘⌫", "Force quit")
                    shortcut("⌘T", "Tree view")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            Text(action)
        }
    }
}
