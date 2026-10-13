import Foundation

/// Screenshot mode: strips personal details from samples before any view sees them, so the
/// window, Dock tile and menu bar can be captured and shared safely.
enum Redactor {
    static let genericComputerName = "MacBook Pro"
    private static let userName = NSUserName()
    private static let homePattern = try? NSRegularExpression(pattern: "/Users/[^/\\s]+")

    static func redact(_ sample: SystemSample) -> SystemSample {
        var sample = sample
        // Only Apple's own processes: third-party apps reveal what is installed.
        sample.processes = sample.processes.filter { isApple($0.path) }.map { process in
            var process = process
            if process.user == userName { process.user = "user" }
            process.command = scrub(process.command)
            process.path = scrub(process.path)
            return process
        }
        // Addresses from the documentation ranges (RFC 5737 / RFC 3849).
        sample.network = sample.network.enumerated().map { index, interface in
            var interface = interface
            interface.ipv4 = interface.ipv4.map { _ in "192.0.2.\(10 + index)" }
            interface.ipv6 = interface.ipv6.map { _ in "2001:db8::\(index + 1)" }
            return interface
        }
        // Volume names (shares, backup disks) are personal; keep the startup disk only.
        sample.disks = sample.disks.filter { $0.mountPoint == "/" }
        return sample
    }

    static func isApple(_ path: String) -> Bool {
        ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/Applications/Safari.app/", "/Applications/Boxtop.app/"]
            .contains { path.hasPrefix($0) }
    }

    /// Replaces "/Users/<name>" with "/Users/user".
    static func scrub(_ text: String) -> String {
        guard let homePattern else { return text }
        return homePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: "/Users/user")
    }
}
