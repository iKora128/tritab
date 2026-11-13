// アプリアイコンを描く。
//   swift scripts/make-icon.swift <出力ディレクトリ> [variant...]
// variant を省略すると全パターンを 1024px の PNG で書き出す。
import AppKit

let size: CGFloat = 1024
// macOS のアイコンの基本形（1024 の中に 824 の角丸四角）
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawTile(_ colors: [NSColor], angle: CGFloat = -45) {
    let path = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    colors[0].setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
    // 上側にうっすら光
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: path, angle: -90)
}

/// 指の点と、動いた跡（左へ払う）
func drawSwipeDots(center: NSPoint, spacing: CGFloat, radius: CGFloat, trail: CGFloat,
                   dot: NSColor, glow: Bool = true) {
    for i in -1...1 {
        let c = NSPoint(x: center.x, y: center.y + CGFloat(i) * spacing)
        // 跡: 右へ向かって細く薄くなる
        let streak = NSBezierPath()
        streak.move(to: NSPoint(x: c.x, y: c.y + radius * 0.9))
        streak.line(to: NSPoint(x: c.x + trail, y: c.y + radius * 0.15))
        streak.line(to: NSPoint(x: c.x + trail, y: c.y - radius * 0.15))
        streak.line(to: NSPoint(x: c.x, y: c.y - radius * 0.9))
        streak.close()
        NSGraphicsContext.saveGraphicsState()
        streak.addClip()
        NSGradient(colors: [dot.withAlphaComponent(0.55), dot.withAlphaComponent(0)])!
            .draw(in: NSRect(x: c.x, y: c.y - radius, width: trail, height: radius * 2), angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        if glow {
            let s = NSShadow()
            s.shadowColor = dot.withAlphaComponent(0.8)
            s.shadowBlurRadius = radius * 0.9
            s.set()
        }
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// ブラウザのタブ（上だけ丸い）
func tabPath(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX - radius, y: r.minY))
    p.curve(to: NSPoint(x: r.minX, y: r.minY + radius), controlPoint1: NSPoint(x: r.minX, y: r.minY),
            controlPoint2: NSPoint(x: r.minX, y: r.minY))
    p.line(to: NSPoint(x: r.minX, y: r.maxY - radius))
    p.curve(to: NSPoint(x: r.minX + radius, y: r.maxY), controlPoint1: NSPoint(x: r.minX, y: r.maxY),
            controlPoint2: NSPoint(x: r.minX, y: r.maxY))
    p.line(to: NSPoint(x: r.maxX - radius, y: r.maxY))
    p.curve(to: NSPoint(x: r.maxX, y: r.maxY - radius), controlPoint1: NSPoint(x: r.maxX, y: r.maxY),
            controlPoint2: NSPoint(x: r.maxX, y: r.maxY))
    p.line(to: NSPoint(x: r.maxX, y: r.minY + radius))
    p.curve(to: NSPoint(x: r.maxX + radius, y: r.minY), controlPoint1: NSPoint(x: r.maxX, y: r.minY),
            controlPoint2: NSPoint(x: r.maxX, y: r.minY))
    p.close()
    return p
}

var variants: [String: () -> Void] = [
    // A: 青→紫。上にタブ、下に左へ払う 3 本指
    "a-tabs": {
        drawTile([color(0x4A8BFF), color(0x8B5CF6)])
        let tabs: [(CGFloat, CGFloat)] = [(230, 0.35), (418, 1.0), (606, 0.35)]
        for (x, a) in tabs {
            NSColor.white.withAlphaComponent(a).setFill()
            tabPath(NSRect(x: x, y: 600, width: 170, height: 110), radius: 26).fill()
        }
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 204, y: 560, width: 616, height: 48), xRadius: 14, yRadius: 14).fill()
        drawSwipeDots(center: NSPoint(x: 360, y: 380), spacing: 0, radius: 0, trail: 0, dot: .white, glow: false)
        // 3 本指を横に並べ、左へ払う跡
        for (i, x) in [330.0, 430.0, 530.0].enumerated() {
            let c = NSPoint(x: x, y: 360)
            NSGraphicsContext.saveGraphicsState()
            let s = NSShadow(); s.shadowColor = NSColor.white.withAlphaComponent(0.7); s.shadowBlurRadius = 30; s.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80)).fill()
            NSGraphicsContext.restoreGraphicsState()
            if i == 2 {
                let arrow = NSBezierPath()
                arrow.lineWidth = 26
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.move(to: NSPoint(x: 700, y: 360))
                arrow.line(to: NSPoint(x: 610, y: 360))
                NSColor.white.withAlphaComponent(0.55).setStroke()
                arrow.stroke()
            }
        }
    },
    // B: 夜の藍色に、光る 3 つの指が左へ流れる（ミニマル）
    "b-glow": {
        drawTile([color(0x1E2A78), color(0x5B3FD9)])
        drawSwipeDots(center: NSPoint(x: 400, y: 512), spacing: 150, radius: 62, trail: 330, dot: .white)
    },
    // C: 明るい白地に、青紫の 3 つの指（Apple の標準アプリ風）
    "c-light": {
        drawTile([color(0xFFFFFF), color(0xE9ECF5)], angle: -90)
        let g = NSGradient(colors: [color(0x3B82F6), color(0x8B5CF6)])!
        for i in -1...1 {
            let c = NSPoint(x: 420, y: 512 + CGFloat(i) * 150)
            let streak = NSBezierPath(roundedRect: NSRect(x: c.x, y: c.y - 22, width: 300, height: 44), xRadius: 22, yRadius: 22)
            NSGraphicsContext.saveGraphicsState()
            streak.addClip()
            NSGradient(colors: [color(0x6366F1, 0.45), color(0x6366F1, 0)])!.draw(in: streak.bounds, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 64, y: c.y - 64, width: 128, height: 128))
            g.draw(in: dot, angle: -45)
        }
    },
    // D: ノッチと棚 + 3 本指（全機能のまとめ）
    "d-notch": {
        drawTile([color(0x0EA5E9), color(0x6366F1)])
        // 上のノッチから垂れる黒い棚
        let notch = NSBezierPath()
        let x0: CGFloat = 330, x1: CGFloat = 694, top: CGFloat = 924, bottom: CGFloat = 760, r: CGFloat = 46, f: CGFloat = 26
        notch.move(to: NSPoint(x: x0 - f, y: top))
        notch.curve(to: NSPoint(x: x0, y: top - f), controlPoint1: NSPoint(x: x0, y: top), controlPoint2: NSPoint(x: x0, y: top))
        notch.line(to: NSPoint(x: x0, y: bottom + r))
        notch.curve(to: NSPoint(x: x0 + r, y: bottom), controlPoint1: NSPoint(x: x0, y: bottom), controlPoint2: NSPoint(x: x0, y: bottom))
        notch.line(to: NSPoint(x: x1 - r, y: bottom))
        notch.curve(to: NSPoint(x: x1, y: bottom + r), controlPoint1: NSPoint(x: x1, y: bottom), controlPoint2: NSPoint(x: x1, y: bottom))
        notch.line(to: NSPoint(x: x1, y: top - f))
        notch.curve(to: NSPoint(x: x1 + f, y: top), controlPoint1: NSPoint(x: x1, y: top), controlPoint2: NSPoint(x: x1, y: top))
        notch.close()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius).addClip()
        color(0x0B0B12).setFill()
        notch.fill()
        NSGraphicsContext.restoreGraphicsState()
        drawSwipeDots(center: NSPoint(x: 420, y: 430), spacing: 130, radius: 54, trail: 290, dot: .white)
    },
]


// MARK: - 案 4 を作り込んだもの（ノッチ + 3 本指）

/// 棚と同じ形のノッチ: 上の角は外へ広がり（フレア）、下は丸い
func notchPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, flare f: CGFloat) -> NSBezierPath {
    let top = tile.maxY, bottom = top - h
    let x0 = tile.midX - w / 2, x1 = tile.midX + w / 2
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x0 - f, y: top))
    p.curve(to: NSPoint(x: x0, y: top - f), controlPoint1: NSPoint(x: x0 - f * 0.45, y: top), controlPoint2: NSPoint(x: x0, y: top - f * 0.45))
    p.line(to: NSPoint(x: x0, y: bottom + r))
    p.curve(to: NSPoint(x: x0 + r, y: bottom), controlPoint1: NSPoint(x: x0, y: bottom + r * 0.45), controlPoint2: NSPoint(x: x0 + r * 0.45, y: bottom))
    p.line(to: NSPoint(x: x1 - r, y: bottom))
    p.curve(to: NSPoint(x: x1, y: bottom + r), controlPoint1: NSPoint(x: x1 - r * 0.45, y: bottom), controlPoint2: NSPoint(x: x1, y: bottom + r * 0.45))
    p.line(to: NSPoint(x: x1, y: top - f))
    p.curve(to: NSPoint(x: x1 + f, y: top), controlPoint1: NSPoint(x: x1, y: top - f * 0.45), controlPoint2: NSPoint(x: x1 + f * 0.45, y: top))
    p.close()
    return p
}

/// 角丸タイルの中だけに描く
func clipped(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius).addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// ガラスの縁の光（macOS 26 風）
func glassRim() {
    let path = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: tileRadius - 3, yRadius: tileRadius - 3)
    path.lineWidth = 6
    NSGraphicsContext.saveGraphicsState()
    path.setClip()
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.0),
                                  NSColor.white.withAlphaComponent(0.0), NSColor.white.withAlphaComponent(0.18)],
                         atLocations: [0, 0.35, 0.7, 1], colorSpace: .deviceRGB)!
    NSGraphicsContext.saveGraphicsState()
    let outer = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)
    let inner = NSBezierPath(roundedRect: tile.insetBy(dx: 5, dy: 5), xRadius: tileRadius - 5, yRadius: tileRadius - 5)
    outer.append(inner.reversed)
    outer.windingRule = .evenOdd
    outer.addClip()
    rim.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// 横に並んだ 3 本の指先（ゆるい弧）と、左へ払った跡
func fingertips(centerY cy: CGFloat, spacing: CGFloat = 132, radius r: CGFloat = 50, trail: CGFloat = 250,
                color: NSColor = .white, glow: NSColor = .white, centerX: CGFloat = 470) {
    let offsets: [(CGFloat, CGFloat)] = [(-spacing, -14), (0, 10), (spacing, -14)]
    // 跡（奥から）
    for (dx, dy) in offsets {
        let c = NSPoint(x: centerX + dx, y: cy + dy)
        let streak = NSBezierPath()
        streak.move(to: NSPoint(x: c.x, y: c.y + r * 0.92))
        streak.curve(to: NSPoint(x: c.x + trail, y: c.y), controlPoint1: NSPoint(x: c.x + trail * 0.5, y: c.y + r * 0.7),
                     controlPoint2: NSPoint(x: c.x + trail * 0.85, y: c.y + r * 0.12))
        streak.curve(to: NSPoint(x: c.x, y: c.y - r * 0.92), controlPoint1: NSPoint(x: c.x + trail * 0.85, y: c.y - r * 0.12),
                     controlPoint2: NSPoint(x: c.x + trail * 0.5, y: c.y - r * 0.7))
        streak.close()
        NSGraphicsContext.saveGraphicsState()
        streak.addClip()
        NSGradient(colors: [color.withAlphaComponent(0.5), color.withAlphaComponent(0)])!
            .draw(in: NSRect(x: c.x, y: c.y - r, width: trail, height: r * 2), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
    for (dx, dy) in offsets {
        let c = NSPoint(x: centerX + dx, y: cy + dy)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = glow.withAlphaComponent(0.85)
        s.shadowBlurRadius = r * 0.85
        s.set()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        // 指先のつや
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.0), NSColor.black.withAlphaComponent(0.08)])!
            .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), angle: -90)
    }
}

/// 黒いノッチ（影と、下の縁にかすかな光）
func drawNotch(width: CGFloat = 400, height: CGFloat = 176, items: Bool = false) {
    let notch = notchPath(width: width, height: height, radius: 60, flare: 34)
    clipped {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 30
        s.shadowOffset = NSSize(width: 0, height: -10)
        s.set()
        color(0x050508).setFill()
        notch.fill()
        NSGraphicsContext.restoreGraphicsState()
        // 下の縁の光
        NSGraphicsContext.saveGraphicsState()
        notch.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.10)])!
            .draw(in: NSRect(x: tile.midX - width / 2, y: tile.maxY - height, width: width, height: 40), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        if items {
            // 棚の中身（3 つの小さなタイル）
            let w: CGFloat = 62, gap: CGFloat = 22
            let y = tile.maxY - height + 34
            for i in -1...1 {
                let r = NSRect(x: tile.midX + CGFloat(i) * (w + gap) - w / 2, y: y, width: w, height: w * 0.78)
                let colors: [NSColor] = [color(0x60A5FA), color(0xF59E0B), color(0xA78BFA)]
                colors[i + 1].withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            }
        }
    }
}

func radialHighlight() {
    clipped {
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: 300, y: 760), radius: 0, toCenter: NSPoint(x: 300, y: 760), radius: 560, options: [])
    }
}

var refined: [String: () -> Void] = [
    // E1: 案 4 の色のまま作り込み（空色 → 藍）
    "e1-sky": {
        drawTile([color(0x38BDF8), color(0x4F46E5)], angle: -60)
        radialHighlight()
        drawNotch()
        fingertips(centerY: 400)
        glassRim()
    },
    // E2: 夜（濃紺 → すみれ）に、水色に光る指
    "e2-night": {
        drawTile([color(0x1E1B4B), color(0x6D28D9)], angle: -60)
        radialHighlight()
        drawNotch()
        fingertips(centerY: 400, color: color(0xE0F2FE), glow: color(0x67E8F9))
        glassRim()
    },
    // E3: ノッチの棚に中身が入っている（タブ + 棚の両方を表す）
    "e3-shelf": {
        drawTile([color(0x38BDF8), color(0x4F46E5)], angle: -60)
        radialHighlight()
        drawNotch(width: 430, height: 200, items: true)
        fingertips(centerY: 360)
        glassRim()
    },
    // E4: 明るい珊瑚 → すみれ（目立つ・個性）
    "e4-sunset": {
        drawTile([color(0xFB7185), color(0x7C3AED)], angle: -60)
        radialHighlight()
        drawNotch()
        fingertips(centerY: 400)
        glassRim()
    },
]
refinedVertical()
for (k, v) in refined { variants[k] = v }

/// 案 4 と同じ縦並び（3 本の指が左へ払った跡）を、新しいノッチとガラスの縁で
func refinedVertical() {
    refined["e5-vertical"] = {
        drawTile([color(0x38BDF8), color(0x4F46E5)], angle: -60)
        radialHighlight()
        drawNotch()
        drawSwipeDots(center: NSPoint(x: 420, y: 400), spacing: 118, radius: 50, trail: 300, dot: .white)
        glassRim()
    }
    // 採用: e4 の夕焼け色 + e3 の中身の入ったノッチの棚
    refined["final"] = {
        drawTile([color(0xFB7185), color(0x7C3AED)], angle: -60)
        radialHighlight()
        drawNotch(width: 430, height: 200, items: true)
        fingertips(centerY: 360)
        glassRim()
    }
    refined["e6-vertical-shelf"] = {
        drawTile([color(0x38BDF8), color(0x4F46E5)], angle: -60)
        radialHighlight()
        drawNotch(width: 430, height: 200, items: true)
        drawSwipeDots(center: NSPoint(x: 420, y: 380), spacing: 112, radius: 46, trail: 290, dot: .white)
        glassRim()
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let wanted = CommandLine.arguments.count > 2 ? Array(CommandLine.arguments.dropFirst(2)) : variants.keys.sorted()

for name in wanted {
    guard let draw = variants[name] else { print("unknown variant: \(name)"); continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent("icon-\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}
