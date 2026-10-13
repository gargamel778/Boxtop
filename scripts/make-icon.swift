// Renders Boxtop app icon designs.
//
//   swift scripts/make-icon.swift [variant]        writes Resources/AppIcon.icns (+ AppIcon.png) from a variant
//   swift scripts/make-icon.swift --all <dir>      renders every variant to <dir>/icon-<variant>.png
//
// Variants: dashboard (default, the app icon), box, led, gauge, equalizer, light
import AppKit

// MARK: - Palette (btop default theme)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Ramp {
    var stops: [NSColor]
    func at(_ t: CGFloat) -> NSColor {
        let t = min(1, max(0, t))
        guard stops.count > 1 else { return stops[0] }
        let scaled = t * CGFloat(stops.count - 1)
        let i = min(stops.count - 2, Int(scaled))
        return stops[i].blended(withFraction: scaled - CGFloat(i), of: stops[i + 1])!
    }
}

let cpuRamp = Ramp(stops: [rgb(0x77CA9B), rgb(0xCBC06C), rgb(0xDC4C4C)])
let usedRamp = Ramp(stops: [rgb(0x592B26), rgb(0xD9626D), rgb(0xFF4769)])
let freeRamp = Ramp(stops: [rgb(0x384F21), rgb(0xB5E685), rgb(0xDCFF85)])
let cachedRamp = Ramp(stops: [rgb(0x163350), rgb(0x74E6FC), rgb(0x26C5FF)])
let downRamp = Ramp(stops: [rgb(0x291F75), rgb(0x4F43A3), rgb(0xB0A9DE)])
let upRamp = Ramp(stops: [rgb(0x620665), rgb(0x7D4180), rgb(0xDCAFDE)])
let lightCPURamp = Ramp(stops: [rgb(0x3FAE6F), rgb(0xD0A520), rgb(0xD9443A)])

let cpuBox = rgb(0x556D59), memBox = rgb(0x6C6C4B), netBox = rgb(0x5C588D), procBox = rgb(0x805252)
let wave: [CGFloat] = [0.18, 0.25, 0.22, 0.34, 0.3, 0.46, 0.4, 0.55, 0.5, 0.68, 0.62, 0.82, 0.74, 0.9, 0.7, 0.58, 0.64, 0.8]

// MARK: - Drawing helpers

/// The 824pt rounded tile on the 1024pt macOS icon grid.
func tileRect(_ s: CGFloat) -> NSRect { NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s) }

func drawTile(_ s: CGFloat, top: NSColor, bottom: NSColor) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: tileRect(s), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    return path
}

/// Dot-matrix graph: `values` 0...1 per column, colored by height. `unlit` draws the empty dots too.
func dots(_ rect: NSRect, values: [CGFloat], rows: Int? = nil, ramp: Ramp, unlit: NSColor? = nil,
          size: CGFloat = 0.64, downward: Bool = false) {
    let pitch = rect.width / CGFloat(values.count)
    let rowCount = rows ?? Int(rect.height / pitch)
    let pitchY = rect.height / CGFloat(rowCount)
    let dot = min(pitch, pitchY) * size
    for (i, v) in values.enumerated() {
        let lit = Int((v * CGFloat(rowCount)).rounded())
        for r in 0..<rowCount {
            let on = r < lit
            guard on || unlit != nil else { continue }
            (on ? ramp.at(CGFloat(r) / CGFloat(max(1, rowCount - 1))) : unlit!).setFill()
            let x = rect.minX + CGFloat(i) * pitch + (pitch - dot) / 2
            let y = downward ? rect.maxY - CGFloat(r + 1) * pitchY + (pitchY - dot) / 2
                             : rect.minY + CGFloat(r) * pitchY + (pitchY - dot) / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
        }
    }
}

/// btop box: rounded border with the title cut into the top edge.
func box(_ rect: NSRect, color: NSColor, title: String?, titleColor: NSColor, background: NSColor,
         s: CGFloat, line: CGFloat = 14, radius: CGFloat = 34, fontSize: CGFloat = 92, hotkey: String? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s)
    path.lineWidth = line * s
    color.setStroke()
    path.stroke()
    guard let title else { return }
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: fontSize * s, weight: .bold),
                                                .foregroundColor: titleColor]
    let text = title as NSString
    let size = text.size(withAttributes: attrs)
    let origin = NSPoint(x: rect.minX + fontSize * 0.75 * s, y: rect.maxY - size.height / 2 - fontSize * 0.06 * s)
    background.setFill()
    NSRect(x: origin.x - fontSize * 0.24 * s, y: rect.maxY - line * 1.5 * s,
           width: size.width + fontSize * 0.48 * s, height: line * 3 * s).fill()
    text.draw(at: origin, withAttributes: attrs)
    if let hotkey {
        (hotkey as NSString).draw(at: NSPoint(x: origin.x - fontSize * 0.33 * s, y: origin.y + fontSize * 0.13 * s),
                                  withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.7 * s, weight: .bold),
                                                   .foregroundColor: rgb(0xB54040)])
    }
}

// MARK: - Variants

typealias Painter = (CGFloat) -> Void

let variants: [(name: String, paint: Painter)] = [
    // The current icon: one btop box with a braille-style CPU graph.
    ("box", { s in
        _ = drawTile(s, top: rgb(0x1B1D22), bottom: rgb(0x0B0C0E))
        let r = tileRect(s).insetBy(dx: 92 * s, dy: 120 * s).offsetBy(dx: 0, dy: -18 * s)
        box(r, color: cpuBox, title: "cpu", titleColor: rgb(0xEEEEEE), background: rgb(0x111316), s: s, hotkey: "¹")
        dots(r.insetBy(dx: 58 * s, dy: 58 * s), values: wave, ramp: cpuRamp, size: 0.62)
    }),

    // A full-bleed LED matrix: lit dots form the graph, unlit dots fill the panel.
    ("led", { s in
        let tile = drawTile(s, top: rgb(0x15171B), bottom: rgb(0x050506))
        NSGraphicsContext.current?.saveGraphicsState()
        tile.addClip()
        let panel = tileRect(s).insetBy(dx: 96 * s, dy: 96 * s)
        let values: [CGFloat] = [0.2, 0.28, 0.24, 0.38, 0.32, 0.5, 0.44, 0.62, 0.56, 0.76, 0.66, 0.9, 0.78, 0.6, 0.7, 0.84]
        dots(panel, values: values, rows: 16, ramp: cpuRamp, unlit: rgb(0x22252B), size: 0.72)
        NSGraphicsContext.current?.restoreGraphicsState()
    }),

    // A miniature of the whole Boxtop window: cpu on top, mem + net left, proc right.
    ("dashboard", { s in
        _ = drawTile(s, top: rgb(0x16181C), bottom: rgb(0x08090A))
        let t = tileRect(s).insetBy(dx: 78 * s, dy: 92 * s)
        let gap = 26 * s
        let cpu = NSRect(x: t.minX, y: t.maxY - 240 * s, width: t.width, height: 240 * s)
        let left = (t.width - gap) * 0.44
        let netHeight = 150 * s
        let mem = NSRect(x: t.minX, y: t.minY + netHeight + gap, width: left, height: cpu.minY - gap * 2 - t.minY - netHeight)
        let net = NSRect(x: t.minX, y: t.minY, width: left, height: netHeight)
        let proc = NSRect(x: t.minX + left + gap, y: t.minY, width: t.width - left - gap, height: cpu.minY - gap - t.minY)
        let bg = rgb(0x0F1013)
        box(cpu, color: cpuBox, title: "cpu", titleColor: rgb(0xEEEEEE), background: bg, s: s, line: 9, radius: 22, fontSize: 52)
        box(mem, color: memBox, title: "mem", titleColor: rgb(0xEEEEEE), background: bg, s: s, line: 9, radius: 22, fontSize: 52)
        box(net, color: netBox, title: "net", titleColor: rgb(0xEEEEEE), background: bg, s: s, line: 9, radius: 22, fontSize: 52)
        box(proc, color: procBox, title: "proc", titleColor: rgb(0xEEEEEE), background: bg, s: s, line: 9, radius: 22, fontSize: 52)

        dots(cpu.insetBy(dx: 40 * s, dy: 40 * s), values: wave + wave.prefix(10).reversed(), ramp: cpuRamp, size: 0.66)
        // Memory meters.
        for (i, (ramp, fill)) in [(usedRamp, 0.82), (cachedRamp, 0.45), (freeRamp, 0.25)].enumerated() {
            let y = mem.maxY - 66 * s - CGFloat(i) * 46 * s
            let segments = 9
            let w = (mem.width - 70 * s) / CGFloat(segments)
            for k in 0..<segments {
                (CGFloat(k) / CGFloat(segments) < CGFloat(fill) ? ramp.at(CGFloat(k) / CGFloat(segments - 1)) : rgb(0x2A2C30)).setFill()
                NSBezierPath(roundedRect: NSRect(x: mem.minX + 35 * s + CGFloat(k) * w, y: y, width: w - 8 * s, height: 26 * s),
                             xRadius: 4 * s, yRadius: 4 * s).fill()
            }
        }
        // Network: download up, upload down.
        // Leave room under the title notch.
        let inner = NSRect(x: net.minX + 28 * s, y: net.minY + 20 * s, width: net.width - 56 * s, height: net.height - 70 * s)
        let half = inner.height / 2
        dots(NSRect(x: inner.minX, y: inner.minY + half, width: inner.width, height: half),
             values: [0.5, 1, 0.5, 1, 1, 0.5, 1, 0.5, 1, 0.5], rows: 2, ramp: downRamp, size: 0.75)
        dots(NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: half),
             values: [0.5, 0.5, 1, 0.5, 0.5, 1, 0.5, 0.5, 1, 0.5], rows: 2, ramp: upRamp, size: 0.75, downward: true)
        // Process rows, one selected.
        for i in 0..<6 {
            let y = proc.maxY - 80 * s - CGFloat(i) * 46 * s
            let row = NSRect(x: proc.minX + 28 * s, y: y - 8 * s, width: proc.width - 56 * s, height: 36 * s)
            if i == 1 {
                rgb(0x6A2F2F).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6 * s, yRadius: 6 * s).fill()
            }
            let widths: [CGFloat] = [0.7, 0.55, 0.8, 0.45, 0.62, 0.5, 0.72]
            rgb(0xCCCCCC, i == 1 ? 0.95 : 0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: row.minX + 14 * s, y: row.minY + 11 * s,
                                             width: (row.width - 110 * s) * widths[i], height: 14 * s),
                         xRadius: 7 * s, yRadius: 7 * s).fill()
            cpuRamp.at(CGFloat(5 - i) / 5).setFill()
            NSBezierPath(roundedRect: NSRect(x: row.maxX - 74 * s, y: row.minY + 11 * s, width: 60 * s, height: 14 * s),
                         xRadius: 7 * s, yRadius: 7 * s).fill()
        }
    }),

    // A btop meter bent into a 270° gauge around a small graph.
    ("gauge", { s in
        _ = drawTile(s, top: rgb(0x1A1C21), bottom: rgb(0x0A0B0D))
        let center = NSPoint(x: 512 * s, y: 500 * s)
        let radius = 300 * s
        let segments = 30, lit = 21
        for i in 0..<segments {
            let t = CGFloat(i) / CGFloat(segments - 1)
            let angle = (225 - t * 270) * .pi / 180
            let path = NSBezierPath()
            path.lineWidth = 44 * s
            path.lineCapStyle = .round
            let inner = radius - 26 * s, outer = radius + 26 * s
            path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            (i < lit ? cpuRamp.at(t) : rgb(0x2A2D33)).setStroke()
            path.lineWidth = 22 * s
            path.stroke()
        }
        let graph = NSRect(x: center.x - 170 * s, y: center.y - 110 * s, width: 340 * s, height: 200 * s)
        dots(graph, values: [0.2, 0.35, 0.3, 0.5, 0.45, 0.7, 0.55, 0.8, 0.65, 0.5, 0.6, 0.75], ramp: cpuRamp, size: 0.66)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 84 * s, weight: .bold),
                                                    .foregroundColor: rgb(0xEEEEEE)]
        let label = "cpu" as NSString
        let w = label.size(withAttributes: attrs).width
        label.draw(at: NSPoint(x: center.x - w / 2, y: center.y - 250 * s), withAttributes: attrs)
    }),

    // Vertical btop meters, like an equalizer of per-core usage.
    ("equalizer", { s in
        _ = drawTile(s, top: rgb(0x1B1D22), bottom: rgb(0x0B0C0E))
        let r = tileRect(s).insetBy(dx: 110 * s, dy: 120 * s)
        let levels: [CGFloat] = [0.85, 0.62, 0.95, 0.48, 0.72, 0.36, 0.58, 0.28]
        let rows = 11
        let colW = r.width / CGFloat(levels.count)
        let rowH = r.height / CGFloat(rows)
        for (c, level) in levels.enumerated() {
            for row in 0..<rows {
                let on = CGFloat(row) < level * CGFloat(rows)
                (on ? cpuRamp.at(CGFloat(row) / CGFloat(rows - 1)) : rgb(0x24272C)).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(c) * colW + 9 * s, y: r.minY + CGFloat(row) * rowH + 7 * s,
                                                 width: colW - 18 * s, height: rowH - 14 * s),
                             xRadius: 9 * s, yRadius: 9 * s).fill()
            }
        }
    }),

    // The box design on a light tile, for light Docks and light themes.
    ("light", { s in
        _ = drawTile(s, top: rgb(0xFFFFFF), bottom: rgb(0xE9E6DD))
        let r = tileRect(s).insetBy(dx: 92 * s, dy: 120 * s).offsetBy(dx: 0, dy: -18 * s)
        box(r, color: rgb(0x8AA58F), title: "cpu", titleColor: rgb(0x2B2B2B), background: rgb(0xF6F4EE), s: s, hotkey: "¹")
        dots(r.insetBy(dx: 58 * s, dy: 58 * s), values: wave, ramp: lightCPURamp, size: 0.62)
    }),
]

// MARK: - Output

func render(_ paint: Painter, size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    paint(size / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--all" {
    let dir = args.count > 1 ? args[1] : "."
    for variant in variants {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("icon-\(variant.name).png")
        try png(render(variant.paint, size: 1024)).write(to: url)
        print(url.path)
    }
    exit(0)
}

let name = args.first ?? "dashboard"
guard let variant = variants.first(where: { $0.name == name }) else {
    print("Unknown variant \(name). Choose one of: \(variants.map(\.name).joined(separator: ", "))")
    exit(1)
}
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(render(variant.paint, size: CGFloat(points * scale))).write(to: iconset.appendingPathComponent(file))
    }
}
try png(render(variant.paint, size: 1024)).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns (\(name))" : "iconutil failed")
