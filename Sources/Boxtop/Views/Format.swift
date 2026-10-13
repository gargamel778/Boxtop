import Foundation

/// Number formatting. Memory uses binary units (like Activity Monitor), storage and network
/// use decimal units (like Finder), both labelled "GB"/"MB" the way macOS does.
enum Fmt {
    nonisolated(unsafe) private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    nonisolated(unsafe) private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let lock = NSLock()

    static func memory(_ value: UInt64) -> String {
        lock.withLock { memoryFormatter.string(fromByteCount: Int64(clamping: value)) }
    }

    static func memory(_ value: Double) -> String { memory(clampedBytes(value)) }

    static func size(_ value: UInt64) -> String {
        lock.withLock { fileFormatter.string(fromByteCount: Int64(clamping: value)) }
    }

    static func size(_ value: Double) -> String { size(clampedBytes(value)) }

    /// Doubles to byte counts without trapping on NaN, infinity or negatives.
    static func clampedBytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt64(min(value, 9.0e18))
    }

    private static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1.0e12))
    }

    /// Kept for collectors and diagnostics.
    static func bytes(_ value: Double, compact: Bool = false) -> String { memory(value) }
    static func bytes(_ value: UInt64, compact: Bool = false) -> String { memory(value) }

    static func rate(_ bytesPerSecond: Double, bits: Bool) -> String {
        guard bits else { return size(bytesPerSecond) + "/s" }
        var v = max(0, bytesPerSecond * 8)
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var unit = 0
        while v >= 1000, unit < units.count - 1 {
            v /= 1000
            unit += 1
        }
        let format = unit == 0 || v >= 100 ? "%.0f" : (v >= 10 ? "%.1f" : "%.2f")
        return String(format: format, v) + " " + units[unit]
    }

    static func percent(_ value: Double) -> String {
        if value >= 99.95 || value == 0 { return String(format: "%.0f%%", value) }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    /// "27d 9h", "4h 12m", "12m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if days > 0 { return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, secs) }
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    static func cpuTime(_ seconds: Double) -> String {
        if !(seconds >= 60) { return String(format: "%.2f", seconds.isFinite ? max(0, seconds) : 0) }
        let total = wholeSeconds(seconds)
        if total < 3600 { return String(format: "%d:%02d.%02d", total / 60, total % 60, Int((seconds - Double(total)) * 100)) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func minutes(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func frequency(mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }
}
