import Foundation
import Observation

enum GraphStyle: String, CaseIterable, Identifiable, Sendable {
    case line, block, braille
    var id: String { rawValue }
    var label: String {
        switch self {
        case .line: "Area"
        case .block: "Bars"
        case .braille: "Dots (btop)"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit, kelvin, rankine
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func format(_ celsius: Double) -> String {
        switch self {
        case .celsius: String(format: "%.0f °C", celsius)
        case .fahrenheit: String(format: "%.0f °F", celsius * 9 / 5 + 32)
        case .kelvin: String(format: "%.0f K", celsius + 273.15)
        case .rankine: String(format: "%.0f °R", (celsius + 273.15) * 9 / 5)
        }
    }
}

/// Process table columns that can be sorted on.
enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
    case name, cpu, cpuTime, threads, memory, pid, user, command
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Process Name"
        case .cpu: "% CPU"
        case .cpuTime: "CPU Time"
        case .threads: "Threads"
        case .memory: "Memory"
        case .pid: "PID"
        case .user: "User"
        case .command: "Command"
        }
    }

    /// Numbers sort high-to-low first, text A–Z (like btop and Activity Monitor).
    var defaultDescending: Bool {
        switch self {
        case .name, .user, .command, .pid: false
        default: true
        }
    }
}

/// Activity Monitor's "View" filter.
enum ProcessScope: String, CaseIterable, Identifiable, Sendable {
    case all, mine, apps, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All Processes"
        case .mine: "My Processes"
        case .apps: "Applications"
        case .system: "System Processes"
        }
    }
}

/// User settings persisted in UserDefaults (btop's btop.conf equivalents).
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var updateInterval: Double { didSet { set(updateInterval, "updateInterval") } }
    var appearance: AppearanceMode { didSet { set(appearance.rawValue, "appearance") } }
    /// "Default" or the name of a btop theme whose colors are used for charts.
    var chartColors: String { didSet { set(chartColors, "chartColors") } }
    var graphStyle: GraphStyle { didSet { set(graphStyle.rawValue, "graphStyle.v2") } }
    var temperatureUnit: TemperatureUnit { didSet { set(temperatureUnit.rawValue, "temperatureUnit") } }
    var fontSize: Double { didSet { set(fontSize, "fontSize.v2") } }
    var sidebarVisible: Bool { didSet { set(sidebarVisible, "sidebarVisible") } }

    var showTemperatures: Bool { didSet { set(showTemperatures, "showTemperatures") } }
    var showBattery: Bool { didSet { set(showBattery, "showBattery") } }
    var showHiddenDisks: Bool { didSet { set(showHiddenDisks, "showHiddenDisks") } }
    var showSwap: Bool { didSet { set(showSwap, "showSwap") } }

    var networkInBits: Bool { didSet { set(networkInBits, "networkInBits") } }
    var networkSyncScale: Bool { didSet { set(networkSyncScale, "networkSyncScale") } }
    var networkInterface: String { didSet { set(networkInterface, "networkInterface") } }
    /// The GPU pane's GPU on Macs with several; "" shows the first.
    var gpu: String { didSet { set(gpu, "gpu") } }

    var processSort: ProcessSortKey { didSet { set(processSort.rawValue, "processSort.v2") } }
    var processDescending: Bool { didSet { set(processDescending, "processDescending") } }
    var processScope: ProcessScope { didSet { set(processScope.rawValue, "processScope") } }
    var processTree: Bool { didSet { set(processTree, "processTree") } }
    var processPerCore: Bool { didSet { set(processPerCore, "processPerCore") } }
    var confirmSignals: Bool { didSet { set(confirmSignals, "confirmSignals") } }

    var showMenuBarExtra: Bool { didSet { set(showMenuBarExtra, "showMenuBarExtra") } }
    var screenshotMode: Bool { didSet { set(screenshotMode, "screenshotMode") } }

    var dockIconMode: DockIconMode { didSet { set(dockIconMode.rawValue, "dockIconMode") } }
    var dockIconShowValue: Bool { didSet { set(dockIconShowValue, "dockIconShowValue") } }
    var dockIconThemeColors: Bool { didSet { set(dockIconThemeColors, "dockIconThemeColors") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }

        updateInterval = min(10, max(0.25, double("updateInterval", 1.0)))
        appearance = AppearanceMode(rawValue: string("appearance", "")) ?? .system
        chartColors = string("chartColors", Palette.standard.name)
        graphStyle = GraphStyle(rawValue: string("graphStyle.v2", "")) ?? .line
        temperatureUnit = TemperatureUnit(rawValue: string("temperatureUnit", "")) ?? .celsius
        fontSize = min(16, max(11, double("fontSize.v2", 13)))
        sidebarVisible = bool("sidebarVisible", true)

        showTemperatures = bool("showTemperatures", true)
        showBattery = bool("showBattery", true)
        showHiddenDisks = bool("showHiddenDisks", false)
        showSwap = bool("showSwap", true)

        networkInBits = bool("networkInBits", false)
        networkSyncScale = bool("networkSyncScale", false)
        networkInterface = string("networkInterface", "")
        gpu = string("gpu", "")

        processSort = ProcessSortKey(rawValue: string("processSort.v2", "")) ?? .cpu
        processDescending = bool("processDescending", true)
        processScope = ProcessScope(rawValue: string("processScope", "")) ?? .all
        processTree = bool("processTree", false)
        processPerCore = bool("processPerCore", false)
        confirmSignals = bool("confirmSignals", true)

        showMenuBarExtra = bool("showMenuBarExtra", false)
        screenshotMode = bool("screenshotMode", false)

        dockIconMode = DockIconMode(rawValue: string("dockIconMode", "")) ?? .appIcon
        dockIconShowValue = bool("dockIconShowValue", true)
        dockIconThemeColors = bool("dockIconThemeColors", true)
    }

    private func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
