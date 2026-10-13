import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var windowVisible = true

    var body: some View {
        let prefs = app.preferences
        HStack(spacing: 0) {
            // While the window is fully hidden (covered, minimized, other Space) nothing is drawn;
            // sampling and graph histories continue, so everything is current when it reappears.
            if windowVisible {
                if prefs.sidebarVisible {
                    Sidebar()
                        .transition(.move(edge: .leading))
                }
                VStack(spacing: 0) {
                    if !prefs.sidebarVisible {
                        WindowControls(showLayoutMenu: true)
                    }
                    HStack(spacing: 8) {
                        WorkspaceView()
                        if app.showDetail {
                            ProcessDetailPane()
                                .frame(width: 340)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, prefs.sidebarVisible ? 8 : 2)
                    .padding(.bottom, 8)
                }
            } else {
                Color.clear
            }
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .frame(minWidth: 900, minHeight: 580)
        .background(Color.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .font(.system(size: prefs.fontSize))
        .foregroundStyle(Color.primaryText)
        .environment(\.palette, app.palette)
        .environment(\.baseFontSize, prefs.fontSize)
        .environment(\.graphStyle, prefs.graphStyle)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .tint(.accentClay)
        .animation(.easeInOut(duration: 0.2), value: prefs.sidebarVisible)
        .animation(.easeInOut(duration: 0.2), value: app.showDetail)
        .alert(
            app.pendingQuit.map { "Are you sure you want to quit “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { app.pendingQuit != nil }, set: { if !$0 { app.pendingQuit = nil } }),
            presenting: app.pendingQuit
        ) { request in
            Button("Quit") { app.quit(request, force: false) }
            Button("Force Quit", role: .destructive) { app.quit(request, force: true) }
            Button("Cancel", role: .cancel) { app.pendingQuit = nil }
        } message: { request in
            Text("Quit asks \(request.name) (PID \(String(request.pid))) to exit. Force Quit stops it immediately; unsaved work may be lost.")
        }
        .confirmationDialog(
            app.pendingSignal.map { "Send \(Signals.name($0.signal)) to \($0.name)?" } ?? "",
            isPresented: Binding(get: { app.pendingSignal != nil }, set: { if !$0 { app.pendingSignal = nil } }),
            presenting: app.pendingSignal
        ) { pending in
            Button("Send \(Signals.name(pending.signal))", role: .destructive) { app.send(pending) }
            Button("Cancel", role: .cancel) { app.pendingSignal = nil }
        } message: { pending in
            Text("Process \(pending.name) (PID \(String(pending.pid))). Unsaved work in that process may be lost.")
        }
        .alert("Couldn’t Send Signal", isPresented: Binding(get: { app.signalError != nil }, set: { if !$0 { app.signalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.signalError ?? "")
        }
    }
}

/// Reports whether the hosting window is at least partly visible on screen.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    /// Debug: `defaults write dev.boxtop.Boxtop debugAlwaysRender -bool YES` keeps drawing while the
    /// window is covered (for capturing screenshots of a background window).
    private static let alwaysRender = UserDefaults.standard.bool(forKey: "debugAlwaysRender")

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.alwaysVisible = Self.alwaysRender
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        var alwaysVisible = false
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange?(alwaysVisible || (window?.occlusionState.contains(.visible) ?? true))
        }
    }
}
