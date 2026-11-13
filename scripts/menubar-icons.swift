// メニューバーのアイコン案を描いて、明るい / 暗いメニューバーに並べたプレビューを作る。
//   swift scripts/menubar-icons.swift <出力PNG>
import AppKit

/// 18x18pt の枠に描く（左下原点）。テンプレート画像なので黒＋透明度だけで描く
typealias Glyph = (NSRect) -> Void

func notch(_ b: NSRect, width w: CGFloat, height h: CGFloat, radius r: CGFloat) -> NSBezierPath {
    let x0 = b.midX - w / 2, x1 = b.midX + w / 2, top = b.maxY, bottom = top - h
    let f: CGFloat = 1.6 // 上の角のフレア
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

func dot(_ c: NSPoint, _ r: CGFloat, alpha: CGFloat = 1) {
    NSColor.black.withAlphaComponent(alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
}

/// 点から右へ細くなる跡
func trail(from c: NSPoint, r: CGFloat, length: CGFloat, alpha: CGFloat = 0.45) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r * 0.8))
    p.line(to: NSPoint(x: c.x + length, y: c.y + r * 0.15))
    p.line(to: NSPoint(x: c.x + length, y: c.y - r * 0.15))
    p.line(to: NSPoint(x: c.x, y: c.y - r * 0.8))
    p.close()
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    NSGradient(colors: [NSColor.black.withAlphaComponent(alpha), NSColor.black.withAlphaComponent(0)])!
        .draw(in: NSRect(x: c.x, y: c.y - r, width: length, height: r * 2), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
}

let glyphs: [(String, String, Glyph)] = [
    ("M1", "ノッチ + 横並びの指（アプリアイコンそのまま）", { b in
        NSColor.black.setFill()
        notch(b, width: 11, height: 5.2, radius: 2).fill()
        for (i, dx) in [-4.2, 0.0, 4.2].enumerated() {
            let c = NSPoint(x: b.midX - 1.5 + dx, y: b.minY + 6 + (i == 1 ? 0.8 : 0))
            trail(from: c, r: 1.9, length: 5, alpha: 0.35)
        }
        for (i, dx) in [-4.2, 0.0, 4.2].enumerated() {
            dot(NSPoint(x: b.midX - 1.5 + dx, y: b.minY + 6 + (i == 1 ? 0.8 : 0)), 1.9)
        }
    }),
    ("M2", "ノッチ + 棚の中身（くり抜き）", { b in
        let n = notch(b, width: 15, height: 8.5, radius: 3)
        NSColor.black.setFill()
        n.fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        for dx in [-4.2, 0.0, 4.2] as [CGFloat] {
            NSBezierPath(roundedRect: NSRect(x: b.midX + dx - 1.6, y: b.maxY - 6.6, width: 3.2, height: 2.6), xRadius: 0.8, yRadius: 0.8).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // 下に 3 本指
        for dx in [-4.0, 0.0, 4.0] as [CGFloat] { dot(NSPoint(x: b.midX + dx, y: b.minY + 4), 1.7) }
    }),
    ("M3", "ノッチ + 縦の 3 本線（払った跡）", { b in
        NSColor.black.setFill()
        notch(b, width: 11, height: 4.6, radius: 1.8).fill()
        for i in 0..<3 {
            let c = NSPoint(x: b.minX + 4.5, y: b.minY + 2.6 + CGFloat(i) * 3.6)
            trail(from: c, r: 1.45, length: 9, alpha: 0.5)
            dot(c, 1.45)
        }
    }),
    ("M4", "画面の枠 + ノッチ + 指", { b in
        let frame = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 2.5), xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.4
        NSColor.black.setStroke()
        frame.stroke()
        NSColor.black.setFill()
        notch(b.insetBy(dx: 1, dy: 2.5), width: 6, height: 2.6, radius: 1).fill()
        for dx in [-3.2, 0.0, 3.2] as [CGFloat] { dot(NSPoint(x: b.midX + dx - 1, y: b.midY - 1.2), 1.35) }
        trail(from: NSPoint(x: b.midX + 2.2, y: b.midY - 1.2), r: 1.35, length: 4, alpha: 0.4)
    }),
    ("M5", "ノッチだけ（いちばんシンプル）", { b in
        NSColor.black.setFill()
        notch(b, width: 14, height: 7, radius: 3).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        for dx in [-3.6, 0.0, 3.6] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: b.midX + dx - 1.2, y: b.maxY - 5, width: 2.4, height: 2.4)).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }),
]

func render(_ glyph: @escaping Glyph, scale: CGFloat, tint: NSColor) -> NSImage {
    let pt: CGFloat = 18
    let mask = NSImage(size: NSSize(width: pt * scale, height: pt * scale), flipped: false) { r in
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        glyph(NSRect(x: 0, y: 0, width: pt, height: pt))
        return true
    }
    // テンプレート画像としての見え方: マスクを tint で塗る
    return NSImage(size: mask.size, flipped: false) { r in
        mask.draw(in: r)
        tint.set()
        r.fill(using: .sourceIn)
        return true
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "menubar.png"
let rowH: CGFloat = 120
let canvas = NSImage(size: NSSize(width: 1100, height: rowH * CGFloat(glyphs.count) + 20))
canvas.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(origin: .zero, size: canvas.size).fill()
for (i, (id, name, g)) in glyphs.enumerated() {
    let y = canvas.size.height - 20 - CGFloat(i + 1) * rowH
    // 拡大表示
    render(g, scale: 5, tint: .black).draw(in: NSRect(x: 20, y: y + 10, width: 90, height: 90))
    // 明るいメニューバー（実寸 2x）
    NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: 140, y: y + 40, width: 300, height: 48).fill()
    render(g, scale: 2, tint: NSColor(white: 0.1, alpha: 1)).draw(in: NSRect(x: 170, y: y + 46, width: 36, height: 36))
    ("あ  􀙇  􀊫" as NSString).draw(at: NSPoint(x: 230, y: y + 52), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
    // 暗いメニューバー
    NSColor(white: 0.13, alpha: 1).setFill(); NSRect(x: 470, y: y + 40, width: 300, height: 48).fill()
    render(g, scale: 2, tint: NSColor(white: 0.95, alpha: 1)).draw(in: NSRect(x: 500, y: y + 46, width: 36, height: 36))
    ("あ  􀙇  􀊫" as NSString).draw(at: NSPoint(x: 560, y: y + 52), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.95, alpha: 1)])
    ("\(id)  \(name)" as NSString).draw(at: NSPoint(x: 800, y: y + 55), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black])
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
