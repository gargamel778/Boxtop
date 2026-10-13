import SwiftUI

struct RGB: Hashable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parses btop color values: "#rrggbb", "#gg" (greyscale) or "r g b" decimals.
    init?(btop value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") {
            let hex = v.dropFirst()
            guard let n = UInt32(hex, radix: 16) else { return nil }
            switch hex.count {
            case 2:
                let c = Double(n) / 255
                self.init(c, c, c)
            case 6:
                self.init(Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255)
            default:
                return nil
            }
        } else {
            let parts = v.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            self.init(parts[0] / 255, parts[1] / 255, parts[2] / 255)
        }
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }
}

/// btop's three-point gradients (start / optional mid / optional end), sampled 0...1.
struct ThemeGradient: Hashable, Sendable {
    var start: RGB
    var mid: RGB?
    var end: RGB?

    func rgb(at t: Double) -> RGB {
        let t = min(1, max(0, t))
        guard let end else { return start }
        if let mid {
            return t < 0.5 ? start.mix(mid, t * 2) : mid.mix(end, (t - 0.5) * 2)
        }
        return start.mix(end, t)
    }

    func color(at t: Double) -> Color { rgb(at: t).color }

    var gradient: Gradient {
        guard let end else { return Gradient(colors: [start.color, start.color]) }
        if let mid { return Gradient(colors: [start.color, mid.color, end.color]) }
        return Gradient(colors: [start.color, end.color])
    }
}

struct Theme: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable { case builtin, bundled, user }

    var id: String { name }
    var name: String
    var source: Source

    var mainBg: RGB, mainFg: RGB, title: RGB, hiFg: RGB
    var selectedBg: RGB, selectedFg: RGB, inactiveFg: RGB, graphText: RGB, meterBg: RGB
    var procMisc: RGB, cpuBox: RGB, memBox: RGB, netBox: RGB, procBox: RGB, divLine: RGB
    var temp: ThemeGradient, cpu: ThemeGradient, free: ThemeGradient, cached: ThemeGradient
    var available: ThemeGradient, used: ThemeGradient, download: ThemeGradient, upload: ThemeGradient
    var process: ThemeGradient

    var isLight: Bool { mainBg.luminance > 0.5 }

    // btop's Default_theme (src/btop_theme.cpp).
    static let defaultValues: [String: String] = [
        "main_bg": "#00", "main_fg": "#cc", "title": "#ee", "hi_fg": "#b54040",
        "selected_bg": "#6a2f2f", "selected_fg": "#ee", "inactive_fg": "#40", "graph_text": "#60",
        "meter_bg": "#40", "proc_misc": "#0de756", "cpu_box": "#556d59", "mem_box": "#6c6c4b",
        "net_box": "#5c588d", "proc_box": "#805252", "div_line": "#30",
        "temp_start": "#4897d4", "temp_mid": "#5474e8", "temp_end": "#ff40b6",
        "cpu_start": "#77ca9b", "cpu_mid": "#cbc06c", "cpu_end": "#dc4c4c",
        "free_start": "#384f21", "free_mid": "#b5e685", "free_end": "#dcff85",
        "cached_start": "#163350", "cached_mid": "#74e6fc", "cached_end": "#26c5ff",
        "available_start": "#4e3f0e", "available_mid": "#ffd77a", "available_end": "#ffb814",
        "used_start": "#592b26", "used_mid": "#d9626d", "used_end": "#ff4769",
        "download_start": "#291f75", "download_mid": "#4f43a3", "download_end": "#b0a9de",
        "upload_start": "#620665", "upload_mid": "#7d4180", "upload_end": "#dcafde",
        "process_start": "#80d0a3", "process_mid": "#dcd179", "process_end": "#d45454",
    ]

    static let `default` = Theme.make(name: "Default", source: .builtin, values: defaultValues)

    /// Parses `theme[key]="value"` lines from a btop .theme file.
    static func parse(name: String, source: Source, contents: String) -> Theme {
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("theme["), let close = trimmed.firstIndex(of: "]"),
                  let equals = trimmed[close...].firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<close])
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value.removeFirst()
                if let endQuote = value.firstIndex(of: "\"") { value = String(value[..<endQuote]) }
            } else if let space = value.firstIndex(of: " ") {
                value = String(value[..<space])
            }
            values[key] = value
        }
        return make(name: name, source: source, values: values)
    }

    /// Applies btop's `generateColors` fallback rules.
    private static func make(name: String, source: Source, values: [String: String]) -> Theme {
        func color(_ key: String, fallback: String? = nil) -> RGB {
            if let v = values[key], let rgb = RGB(btop: v) { return rgb }
            if let fallback, let v = values[fallback], let rgb = RGB(btop: v) { return rgb }
            if key == "main_bg", values[key] != nil {
                // Empty main_bg means "terminal background" in btop; use a neutral dark tone.
                return RGB(0.07, 0.07, 0.08)
            }
            return RGB(btop: defaultValues[fallback ?? key] ?? defaultValues[key] ?? "#cc") ?? RGB(0.8, 0.8, 0.8)
        }
        func gradient(_ base: String, fallback: String? = nil) -> ThemeGradient {
            // A theme that omits a gradient entirely inherits it (process_* -> cpu_*).
            if let fallback, values["\(base)_start"] == nil {
                return gradient(fallback)
            }
            let start = color("\(base)_start")
            // Empty values disable a stop; missing ones fall back to btop's default theme.
            func optional(_ key: String) -> RGB? {
                if let v = values[key] { return v.isEmpty ? nil : RGB(btop: v) }
                return RGB(btop: defaultValues[key] ?? "")
            }
            return ThemeGradient(start: start, mid: optional("\(base)_mid"), end: optional("\(base)_end"))
        }

        let inactive = color("inactive_fg")
        return Theme(
            name: name, source: source,
            mainBg: color("main_bg"), mainFg: color("main_fg"), title: color("title"), hiFg: color("hi_fg"),
            selectedBg: color("selected_bg"), selectedFg: color("selected_fg"), inactiveFg: inactive,
            graphText: values["graph_text"].flatMap { RGB(btop: $0) } ?? inactive,
            meterBg: values["meter_bg"].flatMap { RGB(btop: $0) } ?? inactive,
            procMisc: color("proc_misc"), cpuBox: color("cpu_box"), memBox: color("mem_box"),
            netBox: color("net_box"), procBox: color("proc_box"), divLine: color("div_line"),
            temp: gradient("temp"), cpu: gradient("cpu"), free: gradient("free"), cached: gradient("cached"),
            available: gradient("available"), used: gradient("used"), download: gradient("download"),
            upload: gradient("upload"), process: gradient("process", fallback: "cpu")
        )
    }
}
