import AppKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--diagnose") {
            Diagnostics.run()
            return
        }
        if let i = args.firstIndex(of: "--render-dock-previews"), i + 1 < args.count {
            MainActor.assumeIsolated { Diagnostics.renderDockPreviews(to: args[i + 1]) }
            return
        }
        BoxtopApp.main()
    }
}

struct BoxtopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared

    var body: some Scene {
        Window("Boxtop", id: "main") {
            ContentView()
                .environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands { BoxtopCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra(isInserted: Binding(get: { app.preferences.showMenuBarExtra },
                                         set: { app.preferences.showMenuBarExtra = $0 })) {
            MenuBarPanel()
                .environment(app)
        } label: {
            MenuBarLabel()
                .environment(app)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    static let shared = AppState()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than an .app bundle.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        AppState.shared.startDockTile()
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.shared.menu()
    }

    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppState.shared.preferences.showMenuBarExtra
    }
}

struct BoxtopCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(before: .sidebar) {
            Button(app.preferences.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                app.preferences.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Divider()
        }

        CommandGroup(before: .toolbar) {
            ForEach(PaneKind.allCases) { pane in
                Toggle(pane.menuTitle, isOn: Binding(get: { app.layout.isVisible(pane) },
                                                     set: { app.layout.setVisible(pane, $0) }))
                    .keyboardShortcut(KeyEquivalent(Character(pane.hotkey)))
            }
            Menu("Maximize Pane") {
                ForEach(PaneKind.allCases) { pane in
                    Button(pane.menuTitle) { app.layout.toggleMaximized(pane) }
                        .keyboardShortcut(KeyEquivalent(Character(pane.hotkey)), modifiers: [.command, .option])
                        .disabled(!app.layout.isVisible(pane))
                }
                Divider()
                Button("Restore Layout") { app.layout.maximized = nil }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(app.layout.maximized == nil)
            }
            Menu("Layout") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.label) { app.layout.apply(preset) }
                }
                Divider()
                Toggle("Lock Layout", isOn: Binding(get: { app.layout.locked }, set: { app.layout.locked = $0 }))
            }
            Divider()
            Button("Faster Updates") { app.stepInterval(faster: true) }.keyboardShortcut("+")
            Button("Slower Updates") { app.stepInterval(faster: false) }.keyboardShortcut("-")
            Toggle("Pause Updates", isOn: Binding(get: { app.isPaused }, set: { app.isPaused = $0 }))
                .keyboardShortcut("p")
            Divider()
            Picker("Appearance", selection: binding(\.appearance)) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Chart Style", selection: binding(\.graphStyle)) {
                ForEach(GraphStyle.allCases) { Text($0.label).tag($0) }
            }
            Picker("Chart Colors", selection: binding(\.chartColors)) {
                Text("Default").tag(Palette.standard.name)
                ForEach(app.themes) { Text($0.name).tag($0.name) }
            }
            Button("Bigger Text") { app.preferences.fontSize = min(16, app.preferences.fontSize + 0.5) }
                .keyboardShortcut("=", modifiers: [.command, .option])
            Button("Smaller Text") { app.preferences.fontSize = max(11, app.preferences.fontSize - 0.5) }
                .keyboardShortcut("-", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Process") {
            Button("Search Processes") {
                app.preferences.sidebarVisible = true
                app.focusSearch = true
            }
            .keyboardShortcut("f")
            Button(app.showDetail ? "Hide Details" : "Show Details") { app.showDetail.toggle() }
                .keyboardShortcut("i")
                .disabled(app.selectedPID == nil)
            Divider()
            Button("Quit Process…") { app.requestQuit() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.selectedProcess == nil)
            Button("Force Quit Process") { app.requestSignal(SIGKILL) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(app.selectedProcess == nil)
            Button(app.selectedProcess?.state == .stopped ? "Resume" : "Suspend") { app.toggleSuspend() }
                .disabled(app.selectedProcess == nil)
            Menu("Send Signal") {
                ForEach(Signals.common, id: \.0) { signal in
                    Button("\(signal.1) (\(signal.0))") { app.requestSignal(signal.0) }
                }
            }
            .disabled(app.selectedProcess == nil)
            Divider()
            Picker("Show", selection: binding(\.processScope)) {
                ForEach(ProcessScope.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Tree View", isOn: binding(\.processTree)).keyboardShortcut("t")
            Toggle("% CPU per Core", isOn: binding(\.processPerCore))
            Divider()
            Button("Reset Network Totals") { app.monitor.resetNetworkTotals() }
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { app.preferences[keyPath: keyPath] }, set: { app.preferences[keyPath: keyPath] = $0 })
    }
}
