import AppKit
import Darwin
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One row of the process table (flat or, in tree view, with children).
struct ProcessItem: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let command: String
    let path: String
    let user: String
    let cpu: Double
    let cpuTime: Double
    let threads: Int
    let memory: UInt64
    let state: ProcessState
    var children: [ProcessItem]?
}

/// A signal waiting for confirmation, pinned to one exact process (pid + start time).
struct PendingSignal: Identifiable {
    let id = UUID()
    let signal: Int32
    let pid: Int32
    let name: String
    let startTime: Date
}

/// Activity Monitor's "Quit / Force Quit / Cancel" prompt.
struct QuitRequest: Identifiable {
    let id = UUID()
    let pid: Int32
    let name: String
    let startTime: Date
}

/// Signals offered in the UI (btop's signal menu, minus the obscure ones).
enum Signals {
    static let common: [(Int32, String)] = [
        (SIGTERM, "SIGTERM"), (SIGKILL, "SIGKILL"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP"),
        (SIGQUIT, "SIGQUIT"), (SIGSTOP, "SIGSTOP"), (SIGCONT, "SIGCONT"), (SIGUSR1, "SIGUSR1"),
        (SIGUSR2, "SIGUSR2"), (SIGTSTP, "SIGTSTP"), (SIGINFO, "SIGINFO"), (SIGWINCH, "SIGWINCH"),
    ]

    static func name(_ signal: Int32) -> String {
        common.first { $0.0 == signal }?.1 ?? "signal \(signal)"
    }
}

/// Friendly names and icons for processes LaunchServices knows about ("Safari Web Content"
/// instead of com.apple.WebKit.WebContent), refreshed every few seconds.
@MainActor
final class RunningApps {
    static let shared = RunningApps()
    // NSRunningApplication properties are fetched lazily over XPC, so values are copied out
    // once per refresh instead of being read on every redraw.
    private var names: [Int32: String] = [:]
    private var icons: [Int32: NSImage] = [:]
    private var refreshed = Date.distantPast
    /// Screenshot mode: helper processes (e.g. "<App> Web Content") inherit their host app's
    /// name and icon, which would reveal third-party apps; only app bundles keep theirs.
    var restrictToApplications = false

    private func refreshIfNeeded() {
        guard Date().timeIntervalSince(refreshed) > 5 else { return }
        refreshed = Date()
        var newNames: [Int32: String] = [:], newIcons: [Int32: NSImage] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if let name = app.localizedName, !name.isEmpty { newNames[pid] = name }
            newIcons[pid] = icons[pid] ?? app.icon
        }
        names = newNames
        icons = newIcons
    }

    func name(_ pid: Int32, path: String, fallback: String) -> String {
        if restrictToApplications, !IconCache.isApplication(path) { return fallback }
        refreshIfNeeded()
        return names[pid] ?? fallback
    }

    func icon(_ pid: Int32, path: String) -> NSImage? {
        if restrictToApplications, !IconCache.isApplication(path) { return nil }
        refreshIfNeeded()
        return icons[pid]
    }
}

/// App icons for process rows: the enclosing .app bundle's icon, or the generic executable icon.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private lazy var executable = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(pid: Int32, path: String) -> NSImage {
        if let icon = RunningApps.shared.icon(pid, path: path) { return icon }
        return icon(forExecutable: path)
    }

    func icon(forExecutable path: String) -> NSImage {
        guard let range = path.range(of: ".app/") else { return executable }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        if let cached = cache[bundle] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = icon
        return icon
    }

    /// True for the main executable of an application bundle (not helpers nested inside it).
    static func isApplication(_ path: String) -> Bool {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return false }
        return !path[..<range.lowerBound].contains(".app/")
    }
}

@MainActor
@Observable
final class AppState {
    let preferences = Preferences()
    let monitor = SystemMonitor()
    let layout: LayoutStore
    private(set) var themes: [Theme] = ThemeStore.loadAll()

    var selectedPID: Int32? {
        didSet { if selectedPID != oldValue { syncDetailPID() } }
    }
    var showDetail = false {
        didSet { syncDetailPID() }
    }
    var filterText = ""
    var pendingSignal: PendingSignal?
    var pendingQuit: QuitRequest?
    var signalError: String?
    var focusSearch = false
    var isPaused = false {
        didSet {
            let paused = isPaused
            monitor.configure { $0.paused = paused }
        }
    }

    /// Chart colors: the default palette or a btop theme.
    var palette: Palette {
        guard preferences.chartColors != Palette.standard.name,
              let theme = themes.first(where: { $0.name == preferences.chartColors }) else { return .standard }
        return .from(theme)
    }

    init() {
        layout = LayoutStore(hasGPU: monitor.hasGPU)
        monitor.redactsPersonalDetails = preferences.screenshotMode
        RunningApps.shared.restrictToApplications = preferences.screenshotMode
        monitor.start(interval: preferences.updateInterval, showHiddenDisks: preferences.showHiddenDisks)
        observeSelection()
    }

    /// Drops the selection (and detail pane) once the selected process exits.
    private func observeSelection() {
        withObservationTracking {
            _ = monitor.sampleCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let pid = self.selectedPID,
                   let processes = self.monitor.latest?.processes,
                   !processes.contains(where: { $0.pid == pid }) {
                    self.selectedPID = nil
                    self.showDetail = false
                }
                self.observeSelection()
            }
        }
    }

    @ObservationIgnored private var dockTile: DockTileController?

    /// Called once AppKit has finished launching (the Dock tile needs a running NSApp).
    func startDockTile() {
        if dockTile == nil { dockTile = DockTileController(state: self) }
    }

    func reloadThemes() { themes = ThemeStore.loadAll() }

    func setScreenshotMode(_ on: Bool) {
        preferences.screenshotMode = on
        monitor.redactsPersonalDetails = on
        RunningApps.shared.restrictToApplications = on
    }

    func setInterval(_ seconds: Double) {
        let value = min(10, max(0.25, (seconds * 4).rounded() / 4))
        preferences.updateInterval = value
        monitor.configure { $0.interval = value }
    }

    func stepInterval(faster: Bool) {
        let steps: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 5, 10]
        let current = preferences.updateInterval
        if faster {
            setInterval(steps.last { $0 < current - 0.01 } ?? steps[0])
        } else {
            setInterval(steps.first { $0 > current + 0.01 } ?? steps[steps.count - 1])
        }
    }

    func setShowHiddenDisks(_ show: Bool) {
        preferences.showHiddenDisks = show
        monitor.configure { $0.showHiddenDisks = show }
    }

    private func syncDetailPID() {
        let pid = showDetail ? selectedPID : nil
        monitor.configure { $0.detailPID = pid }
    }

    func showDetails(for pid: Int32) {
        selectedPID = pid
        showDetail = true
    }

    // MARK: Process table

    var selectedProcess: ProcessSample? {
        guard let pid = selectedPID else { return nil }
        return monitor.latest?.processes.first { $0.pid == pid }
    }

    /// CPU% as displayed: share of one core (Activity Monitor) or of the whole machine (btop).
    func displayCPU(_ perCore: Double) -> Double {
        preferences.processPerCore ? perCore : perCore / Double(max(1, monitor.cpuInfo.logicalCores))
    }

    /// Table sort order bridged to the persisted sort key and direction.
    var sortOrder: [KeyPathComparator<ProcessItem>] {
        get {
            let order: SortOrder = preferences.processDescending ? .reverse : .forward
            switch preferences.processSort {
            case .name: return [KeyPathComparator(\.name, order: order)]
            case .cpu: return [KeyPathComparator(\.cpu, order: order)]
            case .cpuTime: return [KeyPathComparator(\.cpuTime, order: order)]
            case .threads: return [KeyPathComparator(\.threads, order: order)]
            case .memory: return [KeyPathComparator(\.memory, order: order)]
            case .pid: return [KeyPathComparator(\.pid, order: order)]
            case .user: return [KeyPathComparator(\.user, order: order)]
            case .command: return [KeyPathComparator(\.command, order: order)]
            }
        }
        set {
            guard let first = newValue.first else { return }
            let keys: [(PartialKeyPath<ProcessItem>, ProcessSortKey)] = [
                (\.name, .name), (\.cpu, .cpu), (\.cpuTime, .cpuTime), (\.threads, .threads),
                (\.memory, .memory), (\.pid, .pid), (\.user, .user), (\.command, .command),
            ]
            if let key = keys.first(where: { $0.0 == first.keyPath })?.1 {
                preferences.processSort = key
                preferences.processDescending = first.order == .reverse
            }
        }
    }

    func setSort(_ key: ProcessSortKey) {
        if preferences.processSort == key {
            preferences.processDescending.toggle()
        } else {
            preferences.processSort = key
            preferences.processDescending = key.defaultDescending
        }
    }

    /// Filtered (search + scope), sorted processes; nested by parent in tree view.
    func processItems() -> [ProcessItem] {
        guard let processes = monitor.latest?.processes else { return [] }
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let uid = getuid()
        let scope = preferences.processScope
        func matches(_ p: ProcessSample) -> Bool {
            switch scope {
            case .all: break
            case .mine: if p.uid != uid { return false }
            case .apps: if !IconCache.isApplication(p.path) { return false }
            case .system: if p.uid >= 500 { return false }
            }
            return query.isEmpty || p.name.lowercased().contains(query) || p.command.lowercased().contains(query)
                || p.user.lowercased().contains(query) || String(p.pid).hasPrefix(query)
        }
        let names = RunningApps.shared
        func item(_ p: ProcessSample) -> ProcessItem {
            ProcessItem(pid: p.pid, name: names.name(p.pid, path: p.path, fallback: p.name), command: p.command, path: p.path, user: p.user,
                        cpu: displayCPU(p.cpuPerCore), cpuTime: p.cpuTimeSeconds, threads: p.threads,
                        memory: p.residentBytes, state: p.state)
        }
        let order = sortOrder
        func sorted(_ items: [ProcessItem]) -> [ProcessItem] {
            items.sorted { a, b in
                switch order[0].compare(a, b) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: a.pid < b.pid
                }
            }
        }

        guard preferences.processTree else {
            return sorted(processes.filter(matches).map(item))
        }

        // Tree: keep matches and their ancestors; children sorted like the top level.
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var visible = Set<Int32>()
        for p in processes where matches(p) {
            var current: ProcessSample? = p
            while let c = current, visible.insert(c.pid).inserted {
                current = c.ppid != c.pid ? byPID[c.ppid] : nil
            }
        }
        var children: [Int32: [ProcessSample]] = [:]
        var roots: [ProcessSample] = []
        for p in processes where visible.contains(p.pid) {
            if p.ppid != p.pid, visible.contains(p.ppid) {
                children[p.ppid, default: []].append(p)
            } else {
                roots.append(p)
            }
        }
        func build(_ p: ProcessSample) -> ProcessItem {
            var node = item(p)
            if let kids = children[p.pid], !kids.isEmpty { node.children = sorted(kids.map(build)) }
            return node
        }
        return sorted(roots.map(build))
    }

    // MARK: Signals

    func requestQuit(pid: Int32? = nil) {
        guard let process = resolve(pid ?? selectedPID) else { return }
        pendingQuit = QuitRequest(pid: process.pid, name: process.name, startTime: process.startTime)
    }

    func quit(_ request: QuitRequest, force: Bool) {
        pendingQuit = nil
        deliver(force ? SIGKILL : SIGTERM, pid: request.pid, name: request.name, startTime: request.startTime)
    }

    func requestSignal(_ signal: Int32, pid: Int32? = nil) {
        guard let process = resolve(pid ?? selectedPID) else { return }
        let pending = PendingSignal(signal: signal, pid: process.pid, name: process.name, startTime: process.startTime)
        // Only destructive signals need confirmation.
        if preferences.confirmSignals, [SIGTERM, SIGKILL, SIGINT, SIGHUP, SIGQUIT].contains(signal) {
            pendingSignal = pending
        } else {
            send(pending)
        }
    }

    func send(_ pending: PendingSignal) {
        pendingSignal = nil
        deliver(pending.signal, pid: pending.pid, name: pending.name, startTime: pending.startTime)
    }

    func toggleSuspend() {
        guard let process = selectedProcess else { return }
        requestSignal(process.state == .stopped ? SIGCONT : SIGSTOP, pid: process.pid)
    }

    private func resolve(_ pid: Int32?) -> ProcessSample? {
        guard let pid else { return nil }
        guard let process = monitor.latest?.processes.first(where: { $0.pid == pid }) else {
            signalError = "Process \(pid) is no longer running."
            if selectedPID == pid { selectedPID = nil }
            return nil
        }
        return process
    }

    /// Re-checks pid and start time right before sending, so a recycled pid is never signalled.
    private func deliver(_ signal: Int32, pid: Int32, name: String, startTime: Date) {
        guard let current = monitor.latest?.processes.first(where: { $0.pid == pid }), current.startTime == startTime else {
            signalError = "\(name) (\(pid)) has already exited. No signal was sent."
            return
        }
        if kill(pid, signal) != 0 {
            let reason = errno == EPERM
                ? "You don't have permission to signal this process. It is probably owned by another user or by the system."
                : String(cString: strerror(errno))
            signalError = "Could not send \(Signals.name(signal)) to \(name) (\(pid)).\n\n\(reason)"
        }
    }
}
