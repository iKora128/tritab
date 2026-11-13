import AppKit

/// メニューバーのアイコン（案 M4: 画面の枠 + ノッチ + 左へ払う 3 本指）。
/// テンプレート画像なので、ライト / ダークや壁紙に合わせて macOS が色を変える。
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { b in
            let screen = b.insetBy(dx: 1, dy: 2.5)
            // 画面の枠
            let frame = NSBezierPath(roundedRect: screen, xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.4
            NSColor.black.setStroke()
            frame.stroke()
            // ノッチ（上の角は外へ広がる）
            NSColor.black.setFill()
            notch(in: screen, width: 6, height: 2.6, radius: 1).fill()
            // 3 本指と、払った跡
            let y = b.midY - 1.2
            trail(from: NSPoint(x: b.midX + 2.2, y: y), r: 1.35, length: 4)
            for dx in [-3.2, 0.0, 3.2] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: b.midX + dx - 1 - 1.35, y: y - 1.35, width: 2.7, height: 2.7)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TriTab"
        return image
    }

    private static func notch(in b: NSRect, width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> NSBezierPath {
        let x0 = b.midX - w / 2, x1 = b.midX + w / 2, top = b.maxY, bottom = top - h
        let f: CGFloat = 1.6
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0 - f, y: top))
        p.curve(to: NSPoint(x: x0, y: top - f), controlPoint1: NSPoint(x: x0 - f * 0.4, y: top), controlPoint2: NSPoint(x: x0, y: top - f * 0.4))
        p.line(to: NSPoint(x: x0, y: bottom + r))
        p.curve(to: NSPoint(x: x0 + r, y: bottom), controlPoint1: NSPoint(x: x0, y: bottom + r * 0.45), controlPoint2: NSPoint(x: x0 + r * 0.45, y: bottom))
        p.line(to: NSPoint(x: x1 - r, y: bottom))
        p.curve(to: NSPoint(x: x1, y: bottom + r), controlPoint1: NSPoint(x: x1 - r * 0.45, y: bottom), controlPoint2: NSPoint(x: x1, y: bottom + r * 0.45))
        p.line(to: NSPoint(x: x1, y: top - f))
        p.curve(to: NSPoint(x: x1 + f, y: top), controlPoint1: NSPoint(x: x1, y: top - f * 0.4), controlPoint2: NSPoint(x: x1 + f * 0.4, y: top))
        p.close()
        return p
    }

    private static func trail(from c: NSPoint, r: CGFloat, length: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y + r * 0.8))
        p.line(to: NSPoint(x: c.x + length, y: c.y + r * 0.15))
        p.line(to: NSPoint(x: c.x + length, y: c.y - r * 0.15))
        p.line(to: NSPoint(x: c.x, y: c.y - r * 0.8))
        p.close()
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.4), NSColor.black.withAlphaComponent(0)])!
            .draw(in: NSRect(x: c.x, y: c.y - r, width: length, height: r * 2), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
