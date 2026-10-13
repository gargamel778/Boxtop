import Foundation

/// Loads the built-in Default theme, btop's bundled themes, and user themes from
/// `~/.config/btop/themes` (so existing btop themes just work) and
/// `~/Library/Application Support/Boxtop/themes`.
enum ThemeStore {
    static var userThemeDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".config/btop/themes")]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            dirs.insert(URL(fileURLWithPath: xdg).appendingPathComponent("btop/themes"), at: 0)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(support.appendingPathComponent("Boxtop/themes"))
        }
        return dirs
    }

    static var bundledThemeDirectory: URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("themes"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // `swift run` during development: walk up from the executable (inside .build/) to the
        // package root. (No #filePath here: it would embed the build machine's path in the binary.)
        var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = directory else { break }
            let themes = current.appendingPathComponent("Resources/themes")
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: themes.path) {
                return themes
            }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }

    static func loadAll() -> [Theme] {
        var themes: [String: Theme] = [Theme.default.name: .default]
        if let bundled = bundledThemeDirectory {
            for theme in load(from: bundled, source: .bundled) { themes[theme.name] = theme }
        }
        // User themes override bundled ones with the same name.
        for dir in userThemeDirectories {
            for theme in load(from: dir, source: .user) { themes[theme.name] = theme }
        }
        return themes.values.sorted { a, b in
            if a.source == .builtin { return true }
            if b.source == .builtin { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func load(from directory: URL, source: Theme.Source) -> [Theme] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "theme" }.compactMap { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Theme.parse(name: url.deletingPathExtension().lastPathComponent, source: source, contents: contents)
        }
    }
}
