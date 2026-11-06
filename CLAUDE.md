# Boxtop

Native macOS system monitor in SwiftUI, derived from btop (Apache-2.0, see NOTICE). It's a
SwiftPM package with a C target, not an Xcode project. It targets macOS 15+ as a universal
binary (arm64 + x86_64).

## Commands

- Build the app: `scripts/build-app.sh` (universal, ad-hoc signed) → `build/Boxtop.app`. `ARCHS=arm64 scripts/build-app.sh` is faster while iterating.
- Test: `swift test` (Swift Testing; layout tree + driver-value regression tests).
- Install locally: quit Boxtop, then `rm -rf /Applications/Boxtop.app && ditto build/Boxtop.app /Applications/Boxtop.app`.
- Deploy to another Mac (e.g. an Intel test machine): `scripts/deploy-remote.sh user@host`. It needs SSH key auth. It copies the app, installs it, prints `--diagnose` and launches it.
- Headless hardware report: `Boxtop.app/Contents/MacOS/Boxtop --diagnose`. Dock icon previews: `--render-dock-previews <dir>`.
- App icon: `swift scripts/make-icon.swift [variant]` (default and current: `dashboard`).
- Crash reports on a test machine: `~/Library/Logs/DiagnosticReports/Boxtop-*.ips`. Symbolicate with `atos -arch x86_64 -o build/Boxtop.app.dSYM -l <load address> <address>`; the dSYM's UUIDs match the app in `build/`.

## Layout

- `Sources/CSysInfo/`: C ports of btop's `src/osx` (SMC, HID thermal sensors, IOReport GPU, NET_RT_IFLIST2 counters, KERN_PROCARGS2).
- `Sources/Boxtop/Collectors/`: one collector per subsystem. All of them run on `Sampler`'s serial queue and produce `SystemSample` values (`Model/Samples.swift`).
- `Model/SystemMonitor.swift`: main-actor histories. `AppState`: selection, signals, process items. `Layout.swift`: the pane split tree (pure, unit tested). `Preferences.swift`: UserDefaults.
- `Views/`: Claude-desktop-style shell (`Sidebar`, `ContentView`, `WorkspaceView`, `Components.Pane`). The panes are in `Views/Panes/`. The process table is AppKit: `ProcessOutline.swift` (NSOutlineView).
- `Theme/Style.swift`: adaptive chrome colors and the chart `Palette`. btop `.theme` files only color the charts.

## Gotchas learned the hard way

- **Untrusted hardware values:** never convert driver, SMC or IOKit numbers straight to integer types. Use `DriverValue.bytes/number` and `Double.sane(_:)` (in `Collectors/Sysctl.swift`). Intel's `inUseSysMemoryBytes` underflows to ~2^64 and crashed the app on an Intel test machine.
- **Animations:** don't animate values that update every second. Implicit animations at 120 Hz took the app to ~50% CPU.
- **Process table:** don't use SwiftUI `Table` for it. Diffing and re-measuring 1000+ reordering rows was the other big CPU cost. The NSOutlineView uses positional rows in the flat list, and each update writes the new values into the cells already on screen. Never call `reloadData(forRowIndexes:)` per tick: it makes AppKit replace every visible cell view. Processes that come and go only insert or remove rows at the end. Cells (`ProcessCell`) draw their own text and icon, with no NSTextField or NSImageView, and only redraw when a value changed. Rows draw their cells into one layer. Icons are pre-rendered 16 pt bitmaps (`IconCache`), because workspace icons go through IconServices on every draw. Sorting uses plain keys (`AppState.sortProcesses`).
- **ViewThatFits in live views:** it lays out every candidate (all of its text) on each update. Pick layouts from a measured width instead (see `DiskCard`).
- **Header measuring:** `ViewThatFits` inside the pane header `HStack` mis-measures. Headers measure subtitle and accessory widths with `onGeometryChange` instead. The accessory is dropped when it doesn't fit, so pickers go in `Pane`'s `controls:` slot, which always shows and truncates the menu title. A picker in the accessory vanished after picking a longer GPU name.
- **Release binaries and personal paths:** the linker's symbol table lists every source file by absolute path, i.e. the build machine's home folder. `build-app.sh` saves a dSYM and then strips the binary, and `package-release.sh` fails if a home path is left. Check with a raw byte search (`grep -a`), because `strings` skips the symbol table.
- **Screenshots for docs:** turn on Settings → General → Screenshot mode (`Model/Redactor.swift`), which strips the Mac's name, user name, IPs, other volumes and third-party processes.
- **Hidden window:** the window stops drawing when occluded (sampling continues). `defaults write dev.boxtop.Boxtop debugAlwaysRender -bool YES` disables that for background screenshots; delete the key afterwards.
- **Measuring CPU cost:** with the window in front at a 1 s interval, expect about 4–5% of one core on an M5 Max and 16–20% on a 5 W Intel Core m3 (a slow Mac shows problems that a fast one hides). `scripts/pane-cost.sh` prints the cost with every pane and with each pane maximized alone; run it after changes to views or the table. Profile with `sample <pid> 5` and symbolicate the app's frames against `build/Boxtop.app.dSYM`.
