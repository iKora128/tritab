import AppKit
import SwiftUI
import TriTabCore

// 設定画面とオンボーディングで共有する見た目の部品（システム設定風）

/// 色付きの角丸アイコン（システム設定のサイドバーと同じ形）
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    /// 塗り（指定がなければ color のグラデーション）
    var fill: LinearGradient? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(color.gradient))
                    .shadow(color: color.opacity(size > 30 ? 0.35 : 0), radius: size * 0.18, y: size * 0.06)
            )
    }
}

/// 各ページの先頭に置く見出しカード
struct PaneHeader: View {
    let symbol: String
    let color: Color
    var fill: LinearGradient? = nil
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 48, fill: fill)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// すりガラスの背景
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// 状態表示（許可済み・競合なし など）
struct StatusPill: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

// MARK: - ジェスチャーのアニメーション

/// トラックパッドの上で指（点）が動く小さなアニメーション
struct GestureIllustration: View {
    enum Kind: Equatable {
        case swipe(SwipeDirection, fingers: Int)
        case tap(fingers: Int)
        case click(fingers: Int)
        case pinch
    }

    let kind: Kind
    var width: CGFloat = 64
    var tint: Color = Sunset.accent
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            let period = 1.8
            let t = animated
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                : 0.45
            Canvas { gc, size in
                draw(in: &gc, size: size, t: t)
            }
        }
        .frame(width: width, height: width * 0.68)
        .accessibilityHidden(true)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, t: Double) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let pad = Path(roundedRect: rect, cornerRadius: size.height * 0.16, style: .continuous)
        gc.fill(pad, with: .color(.primary.opacity(0.05)))
        gc.stroke(pad, with: .color(.primary.opacity(0.14)), lineWidth: 1)

        let r = size.height * 0.085
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        func dot(_ p: CGPoint, alpha: Double, scale: Double = 1) {
            let rr = r * scale
            gc.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)),
                    with: .color(tint.opacity(alpha)))
        }

        switch kind {
        case let .swipe(dir, n):
            // 0〜0.15 着地、0.15〜0.65 移動、0.65〜0.85 離す
            let move = ease(clamp((t - 0.15) / 0.5))
            let alpha = t < 0.15 ? t / 0.15 : (t > 0.65 ? max(0, 1 - (t - 0.65) / 0.2) : 1)
            let travel = (dir == .left || dir == .right ? size.width : size.height) * 0.42
            let (ux, uy): (CGFloat, CGFloat) = {
                switch dir {
                case .left: return (-1, 0)
                case .right: return (1, 0)
                case .up: return (0, -1)
                case .down: return (0, 1)
                }
            }()
            let start = CGPoint(x: center.x - ux * travel / 2, y: center.y - uy * travel / 2)
            let spacing = r * 2.6
            for i in 0..<n {
                let off = (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
                // 指は手の形どおり、どの向きでも横に並べる
                let base = CGPoint(x: start.x + off, y: start.y)
                // 軌跡
                for k in 1...4 {
                    let m = max(0, move - Double(k) * 0.07)
                    dot(CGPoint(x: base.x + ux * travel * m, y: base.y + uy * travel * m),
                        alpha: alpha * 0.12 * Double(5 - k) / 4, scale: 0.8)
                }
                dot(CGPoint(x: base.x + ux * travel * move, y: base.y + uy * travel * move), alpha: alpha)
            }

        case let .tap(n), let .click(n):
            let isClick = { if case .click = kind { return true } else { return false } }()
            // 0.2〜0.45 で触れて離す
            let on = t > 0.2 && t < 0.45
            let pulse = on ? sin((t - 0.2) / 0.25 * .pi) : 0
            let spacing = r * 2.6
            for i in 0..<n {
                let off = (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
                let p = CGPoint(x: center.x + off, y: center.y)
                dot(p, alpha: on ? 1 : 0.18, scale: 1 + (isClick ? 0.1 : 0.25) * pulse)
            }
            if isClick, t > 0.25 {
                // 押し込みの波紋
                let w = clamp((t - 0.25) / 0.45)
                let rr = size.height * (0.2 + 0.35 * w)
                gc.stroke(Path(ellipseIn: CGRect(x: center.x - rr, y: center.y - rr, width: rr * 2, height: rr * 2)),
                          with: .color(tint.opacity(0.5 * (1 - w))), lineWidth: 2)
            }

        case .pinch:
            let k = ease(clamp((t - 0.15) / 0.5))
            let alpha = t < 0.15 ? t / 0.15 : (t > 0.7 ? max(0, 1 - (t - 0.7) / 0.2) : 1)
            let top = size.height * (0.24 + 0.16 * k)
            let bottom = size.height * (0.8 - 0.26 * k)
            dot(CGPoint(x: center.x - r * 1.5, y: top), alpha: alpha)
            dot(CGPoint(x: center.x + r * 1.5, y: top), alpha: alpha)
            dot(CGPoint(x: center.x, y: bottom), alpha: alpha, scale: 1.25) // 親指
        }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
}

/// ジェスチャーの説明行（アニメーション + 名前 + 右側に設定）
struct GestureRow<Accessory: View>: View {
    let kind: GestureIllustration.Kind
    let title: String
    var detail: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            GestureIllustration(kind: kind, width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 2)
    }
}
