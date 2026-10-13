import AppKit
import SwiftUI

/// Window chrome colors, modelled on the Claude desktop app (warm neutral greys, flat
/// rounded panes with a hairline border). Every color adapts to light and dark mode.
extension Color {
    private static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }

    static let windowBackground = adaptive(light: 0xF5F4EF, dark: 0x181818)
    static let sidebarBackground = adaptive(light: 0xEEEDE7, dark: 0x151515)
    static let paneBackground = adaptive(light: 0xFFFFFF, dark: 0x222221)
    static let paneBorder = adaptive(light: 0xE3E1D8, dark: 0x373737)
    static let cardBackground = adaptive(light: 0xF4F3EE, dark: 0x2C2C2B)
    static let controlBackground = adaptive(light: 0xE8E6DF, dark: 0x3A3A39)
    static let rowSelected = adaptive(light: 0xE6E4DC, dark: 0x2B2B2A)
    static let rowHover = adaptive(light: 0xEDEBE4, dark: 0x262625)
    static let track = adaptive(light: 0xE6E4DD, dark: 0x3A3A39)
    static let gridLine = adaptive(light: 0xECEAE3, dark: 0x2E2E2D)
    static let primaryText = adaptive(light: 0x1F1E1D, dark: 0xE9E7E1)
    static let secondaryText = adaptive(light: 0x6F6E69, dark: 0x9C9A94)
    static let tertiaryText = adaptive(light: 0xA3A19A, dark: 0x6A6965)
    /// Claude's clay accent, used for drop targets, focus and toggles.
    static let accentClay = Color(.sRGB, red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Colors for charts and metrics. The default palette is muted to sit on the neutral panes;
/// any btop theme can be used instead ("Chart colors" in Settings).
struct Palette: Equatable {
    var name: String
    var cpu: Gradient
    var cpuSystem: Color
    var memApp: Color
    var memWired: Color
    var memCompressed: Color
    var memCached: Color
    var download: Gradient
    var upload: Gradient
    var read: Color
    var write: Color
    var gpu: Gradient
    var temperature: ThemeGradient
    var usage: ThemeGradient

    static let blue = RGB(0x5E / 255, 0x9D / 255, 0xF0 / 255)
    static let coral = RGB(0xE0 / 255, 0x7A / 255, 0x5F / 255)
    static let amber = RGB(0xE3 / 255, 0xA8 / 255, 0x57 / 255)
    static let violet = RGB(0xA9 / 255, 0x8B / 255, 0xE8 / 255)
    static let teal = RGB(0x5B / 255, 0xBF / 255, 0xAE / 255)
    static let green = RGB(0x6C / 255, 0xC0 / 255, 0x8B / 255)
    static let red = RGB(0xE0 / 255, 0x62 / 255, 0x5A / 255)

    static let standard = Palette(
        name: "Default",
        cpu: Gradient(colors: [blue.color, blue.color]),
        cpuSystem: coral.color,
        memApp: blue.color, memWired: amber.color, memCompressed: violet.color, memCached: teal.color,
        download: Gradient(colors: [blue.color, blue.color]),
        upload: Gradient(colors: [amber.color, amber.color]),
        read: teal.color, write: coral.color,
        gpu: Gradient(colors: [violet.color, violet.color]),
        temperature: ThemeGradient(start: green, mid: amber, end: red),
        usage: ThemeGradient(start: green, mid: amber, end: red)
    )

    /// btop theme colors applied to charts (the chrome stays neutral).
    static func from(_ theme: Theme) -> Palette {
        Palette(
            name: theme.name,
            cpu: theme.cpu.gradient,
            cpuSystem: theme.cpu.rgb(at: 1).color,
            memApp: theme.used.rgb(at: 0.7).color,
            memWired: theme.available.rgb(at: 0.8).color,
            memCompressed: theme.cached.rgb(at: 0.8).color,
            memCached: theme.free.rgb(at: 0.7).color,
            download: theme.download.gradient,
            upload: theme.upload.gradient,
            read: theme.download.rgb(at: 0.9).color,
            write: theme.upload.rgb(at: 0.9).color,
            gpu: theme.cpu.gradient,
            temperature: theme.temp,
            usage: theme.cpu
        )
    }

    /// Representative single color of a gradient (its top stop).
    static func tint(_ gradient: Gradient) -> Color { gradient.stops.last?.color ?? .accentColor }
}

extension EnvironmentValues {
    @Entry var palette: Palette = .standard
}

extension PaneKind {
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .mem: "memorychip"
        case .net: "network"
        case .proc: "list.bullet.rectangle"
        case .gpu: "cube.transparent"
        case .disks: "internaldrive"
        }
    }
}
