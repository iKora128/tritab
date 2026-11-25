import AppKit
import TriTabCore

// MARK: - 受け口（ドラッグ中のトレイ）

/// ファイルなどを持ってきているあいだだけ出す受け口。置いたらどうなるか（ファイルならスイッチで決めた置き方。
/// ⌥ / ⌘⌥ でその場だけ変わる。画像やリンクはトレイの中に保存、テキストはメモ）をアイコンと大きな文字で出し、
/// カーソルがトレイに乗ったらその色で強調する。アイコンは、置いたあとの項目の印と同じ形
final class ShelfDropZoneView: NSView {
    /// 受け口の見せ方
    struct Look: Equatable {
        var symbol: String
        var color: NSColor
        var title: String
        var subtitle: String
        /// ⌥ / ⌘⌥ の案内を出すか（置き方を選べるファイルのときだけ）
        var modifierHint: Bool

        /// 持ってきたものと、置き方のスイッチから決める。ファイル以外は、置き方によらずトレイの中に保存する
        init(content: ShelfDropContent?, mode: ShelfDropMode) {
            switch content {
            case .files?, nil:
                symbol = ShelfItem.symbol(for: mode)
                color = ShelfItem.color(for: mode)
                title = mode == .copy ? L("コピーして置く", "Add a Copy") : L("参照で置く", "Add a Reference")
                subtitle = mode == .copy ? L("複製を置く。元のファイルはそのまま", "The original stays untouched")
                                         : L("元の場所のまま", "The file stays where it is")
                modifierHint = true
            case .promisedFiles?, .image?:
                symbol = ShelfItem.symbol(for: .copy)
                color = ShelfItem.color(for: .copy)
                title = L("コピーして置く", "Add a Copy")
                subtitle = L("ファイルとして保存", "Saved on the shelf")
                modifierHint = false
            case .link?:
                symbol = "globe"
                color = ShelfItem.color(for: .copy)
                title = L("リンクを置く", "Add the Link")
                subtitle = L("あとで開けるリンクとして保存", "Saved as a link to open later")
                modifierHint = false
            case .text?:
                symbol = "note.text"
                color = ShelfItem.noteColor
                title = L("メモにする", "Add as a Note")
                subtitle = L("テキストをメモとして保存", "The text becomes a note")
                modifierHint = false
            }
        }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: L("⌥ を押しながら離すとコピー、⌘⌥ なら参照",
                                                      "Hold ⌥ to add a copy, or ⌘⌥ to add a reference"))
    private var look: Look?
    private(set) var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        alphaValue = 0
        icon.imageScaling = .scaleProportionallyDown
        ShelfDropIcons.prepare()
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = .white
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = NSColor(white: 1, alpha: 0.6)
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor(white: 1, alpha: 0.4)
        for label in [title, subtitle, hint] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }
        [icon, title, subtitle, hint].forEach(addSubview)
        show(Look(content: nil, mode: .reference), active: false, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // マウスは下の項目へ通す（ドラッグの受け取りはトレイの土台がする）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 置いたらどうなるかと、カーソルがトレイに乗っているか（乗っていればその色で強調）を出す。
    /// ドラッグ中はマウスが動くたびに呼ばれるので、変わったときだけ描き直す。
    /// ドラッグがトレイに入った瞬間にも呼ばれ、ここで時間をかけるとドラッグ元が TriTab の返事を待ってドラッグの絵が止まる。
    /// そのため、アイコンは描いておいた画像に差し替えるだけにし（ShelfDropIcons）、弾む動きも Core Animation に任せる
    func show(_ newLook: Look, active: Bool, animated: Bool = true) {
        guard newLook != look || active != isActive else { return }
        let bounce = active && (newLook.symbol != look?.symbol || !isActive)
        look = newLook
        isActive = active
        if title.stringValue != newLook.title { title.stringValue = newLook.title }
        if subtitle.stringValue != newLook.subtitle { subtitle.stringValue = newLook.subtitle }
        let color = newLook.color
        icon.image = ShelfDropIcons.image(newLook.symbol, color: active ? color : .white)
        resizeSubviews(withOldSize: bounds.size) // 案内を出すかが変わるため
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.16 : 0
            ctx.allowsImplicitAnimation = animated
            layer?.backgroundColor = (active ? color.withAlphaComponent(0.22) : NSColor(white: 1, alpha: 0.06)).cgColor
            layer?.borderColor = (active ? color : NSColor(white: 1, alpha: 0.22)).cgColor
            layer?.borderWidth = active ? 2.5 : 1.5
        }
        if animated, bounce { bounceIcon() } // 乗ったとき・置き方が変わったときに、アイコンが小さく弾む
    }

    /// アイコンを真ん中を中心に小さく弾ませる。
    /// SF Symbols の弾む効果（addSymbolEffect）は、1 回ごとにメインスレッドを 12〜35 ms 止めるので使わない
    private func bounceIcon() {
        guard let layer = icon.layer else { return }
        let b = layer.bounds
        // ビューの層は左下が基準点なので、真ん中へ動かしてから拡大し、元へ戻す
        func scaled(_ s: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            return NSValue(caTransform3D: t)
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [1, 1.2, 0.95, 1.03, 1].map(scaled)
        a.keyTimes = [0, 0.3, 0.6, 0.82, 1]
        a.duration = 0.36
        layer.add(a, forKey: "bounce")
    }

    // 上から アイコン・名前・説明・修飾キーの案内 を、真ん中にそろえて置く。低いときは案内を省く
    // （トレイが広がるアニメーションの中で呼ばれたら、一緒に動く）
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let showsHint = bounds.height >= 120 && look?.modifierHint != false
        let parts: [(NSView, CGFloat, CGFloat)] = [(icon, 36, 0), (title, 20, 8), (subtitle, 15, 2)] + (showsHint ? [(hint, 14, 8)] : [])
        var top = ((bounds.height + parts.reduce(0) { $0 + $1.1 + $1.2 }) / 2).rounded()
        for (view, height, gap) in parts {
            top -= gap + height
            view.frame = NSRect(x: 8, y: top, width: max(bounds.width - 16, 0), height: height)
        }
        hint.isHidden = !showsHint
    }
}

// MARK: - 受け口のアイコン

/// 受け口のアイコンを、記号と色の組ごとに一度だけ画像（ビットマップ）に描いておく。
///
/// SF Symbols の記号を NSImageView にそのまま出すと、記号を差し替えるたびに描き直しの準備で約 10 ms、
/// 弾む効果で 12〜35 ms、メインスレッドが止まる（実測）。受け口はドラッグがトレイに入った瞬間に切り替わるので、
/// 止まったぶんだけドラッグ元が返事を待ち、ドラッグの絵が止まって見える。描いておいた画像の差し替えなら 1 ms かからない
enum ShelfDropIcons {
    private static var cache: [String: NSImage] = [:]

    /// その記号を、その色で描いた画像
    static func image(_ symbol: String, color: NSColor) -> NSImage? {
        let key = "\(symbol)|\(color.usingColorSpace(.sRGB).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)" } ?? color.description)"
        if let image = cache[key] { return image }
        let image = render(symbol, color: color)
        cache[key] = image
        return image
    }

    /// 受け口で使う絵を、まとめて描いておく（初めて使うときだけ時間がかかる。ドラッグが来る前に済ませる）
    static func prepare() {
        for content in [ShelfDropContent.files, .promisedFiles, .link, .text] {
            for mode in [ShelfDropMode.copy, .reference] {
                let look = ShelfDropZoneView.Look(content: content, mode: mode)
                _ = image(look.symbol, color: .white)
                _ = image(look.symbol, color: look.color)
            }
        }
    }

    private static func render(_ symbol: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let size = glyph.size
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard let context = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        glyph.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

// MARK: - 置き方のスイッチ

/// トレイの上の帯（ノッチの横）に置く、置き方のスイッチ。[コピー | 参照] のうち、いまの置き方をその色で塗る。押した側に切り替わる
final class ShelfModeSwitch: NSView {
    static let height: CGFloat = 20
    private static let order: [ShelfDropMode] = [.copy, .reference]
    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private let onChange: (ShelfDropMode) -> Void
    private var mode: ShelfDropMode
    private var segments: [(mode: ShelfDropMode, rect: NSRect)] = []
    private var iconOnly = false

    init(mode: ShelfDropMode, onChange: @escaping (ShelfDropMode) -> Void) {
        self.mode = mode
        self.onChange = onChange
        super.init(frame: .zero)
        toolTip = L("ファイルの置き方。ドラッグ中に ⌥ を押しながら離すとコピー、⌘⌥ なら参照になります（設定でも変えられます）",
                    "How files are added to the shelf. While dragging, hold ⌥ to add a copy, or ⌘⌥ to add a reference. You can also change this in Settings.")
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ mode: ShelfDropMode) -> String {
        mode == .copy ? L("コピー", "Copy") : L("参照", "Reference")
    }

    func setMode(_ newMode: ShelfDropMode) {
        guard newMode != mode else { return }
        mode = newMode
        needsDisplay = true
    }

    /// 最後に合わせた幅（同じ幅なら測り直さない。トレイを開くたびに呼ばれるため）
    private var fittedWidth: CGFloat?

    /// 使える幅に合わせて大きさを決める（文字まで入らなければアイコンだけにする）
    func fit(width: CGFloat) {
        guard width != fittedWidth else { return }
        fittedWidth = width
        func segmentWidth(_ mode: ShelfDropMode, iconOnly: Bool) -> CGFloat {
            if iconOnly { return 26 }
            let text = ceil((Self.label(mode) as NSString).size(withAttributes: [.font: Self.font]).width)
            return 9 + 12 + 4 + text + 9
        }
        iconOnly = Self.order.map { segmentWidth($0, iconOnly: false) }.reduce(4, +) > width
        var x: CGFloat = 2
        segments = Self.order.map { mode in
            let w = segmentWidth(mode, iconOnly: iconOnly)
            defer { x += w }
            return (mode, NSRect(x: x, y: 2, width: w, height: Self.height - 4))
        }
        frame.size = NSSize(width: x + 2, height: Self.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        for segment in segments {
            let selected = segment.mode == mode
            let r = segment.rect
            if selected {
                ShelfItem.color(for: segment.mode).withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            let tint = selected ? NSColor.white : NSColor(white: 1, alpha: 0.55)
            let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold).applying(.init(paletteColors: [tint]))
            let image = NSImage(systemSymbolName: ShelfItem.symbol(for: segment.mode), accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            let text = Self.label(segment.mode) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: tint]
            let textSize = text.size(withAttributes: attributes)
            let iconSize = image?.size ?? .zero
            var x = r.midX - (iconOnly ? iconSize.width : iconSize.width + 4 + textSize.width) / 2
            image?.draw(in: NSRect(x: x, y: r.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height))
            x += iconSize.width + 4
            if !iconOnly { text.draw(at: NSPoint(x: x, y: r.midY - textSize.height / 2), withAttributes: attributes) }
        }
    }

    // TriTab は前面に出ないので、最初のクリックから受け取る
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let segment = segments.first(where: { $0.rect.insetBy(dx: 0, dy: -2).contains(p) }),
              segment.mode != mode else { return }
        setMode(segment.mode)
        onChange(segment.mode)
    }
}

// MARK: - まとめの数

/// まとめの右上に付ける、中のファイルの数
final class ShelfCountBadge: NSView {
    var count = 0 {
        didSet {
            isHidden = count < 2
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                                                         .foregroundColor: NSColor(white: 0.1, alpha: 1)]
        let size = text.size(withAttributes: attributes)
        let width = min(max(ceil(size.width) + 10, bounds.height), bounds.width)
        let r = NSRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height) // 右にそろえ、桁が増えたら左へ伸ばす
        NSColor.black.setFill() // トレイの黒で縁取りして、サムネイルから浮かせる
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        NSColor(white: 0.95, alpha: 1).setFill()
        let inner = r.insetBy(dx: 1.5, dy: 1.5)
        NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
        text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attributes)
    }
}

// MARK: - 項目の印

/// 項目の右下に付ける小さな丸い印（コピー / 参照 / 見つからない）。受け口のアイコンと同じ形
final class ShelfBadgeView: NSView {
    static let size: CGFloat = 17
    private var badge: (symbol: String, color: NSColor)?

    func set(_ badge: (symbol: String, color: NSColor)?) {
        self.badge = badge
        isHidden = badge == nil
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let badge else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        // トレイの黒で縁取りして、サムネイルから浮かせる
        NSColor.black.setFill()
        NSBezierPath(ovalIn: r).fill()
        badge.color.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                              width: s.width, height: s.height))
    }
}

// MARK: - 部品

/// 項目を左上から並べる入れ物（スクロールの中身。上下を反転して、1 段目を上にする）
final class ShelfGridView: NSView {
    override var isFlipped: Bool { true }
}

/// 最初のクリックから受け取るボタン（TriTab は前面に出ないので、ふつうの NSButton だと 1 回目のクリックが捨てられる）
final class ShelfFirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 自分自身ではマウスを受けず、下にある項目へ通す（上に載せた文字やボタンはふつうに受ける）
final class ShelfPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

extension NSDragOperation {
    init(_ op: ShelfDragOperation) {
        var r: NSDragOperation = []
        if op.contains(.copy) { r.insert(.copy) }
        if op.contains(.link) { r.insert(.link) }
        if op.contains(.generic) { r.insert(.generic) }
        if op.contains(.move) { r.insert(.move) }
        self = r
    }
}

extension ShelfDragOperation {
    init(_ op: NSDragOperation) {
        var r: ShelfDragOperation = []
        if op.contains(.copy) { r.insert(.copy) }
        if op.contains(.link) { r.insert(.link) }
        if op.contains(.generic) { r.insert(.generic) }
        if op.contains(.move) { r.insert(.move) }
        self = r
    }
}
