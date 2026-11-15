import AppKit
import TriTabCore

// MARK: - 受け口（ドラッグ中の棚の左右）

/// ファイルを持ってきているあいだだけ出す、棚の左右 2 つの受け口。
/// 左に落とすと「コピーして置く」（棚に複製。元はそのまま）、右に落とすと「参照で置く」（元の場所のまま）。
/// カーソルが乗っている側を強調し、もう片方は控えめにする。アイコンは、置いたあとの項目の印と同じ形
final class ShelfDropZonesView: NSView {
    private let copyZone = ZoneView(mode: .copy)
    private let referenceZone = ZoneView(mode: .reference)

    /// カーソルが乗っている側（nil ならどちらも同じ見た目）
    var highlighted: ShelfDropMode? {
        didSet {
            guard highlighted != oldValue else { return }
            for zone in [copyZone, referenceZone] {
                zone.apply(highlighted == nil ? .idle : highlighted == zone.mode ? .active : .dimmed, animated: true)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        addSubview(copyZone)
        addSubview(referenceZone)
    }
    required init?(coder: NSCoder) { fatalError() }

    // マウスは下の項目へ通す（ドラッグの受け取りは棚の土台がする）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let gap: CGFloat = 10
        let w = max((bounds.width - gap) / 2, 0)
        copyZone.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        referenceZone.frame = NSRect(x: w + gap, y: 0, width: w, height: bounds.height)
    }
}

private final class ZoneView: NSView {
    enum Look { case idle, active, dimmed }

    let mode: ShelfDropMode
    private let icon = NSImageView()
    private let stack: NSStackView

    init(mode: ShelfDropMode) {
        self.mode = mode
        let title = NSTextField(labelWithString: mode == .copy ? L("コピーして置く", "Add a Copy")
                                                               : L("参照で置く", "Add a Reference"))
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = .white
        let subtitle = NSTextField(labelWithString: mode == .copy ? L("棚に複製。元はそのまま", "The original stays untouched")
                                                                  : L("元の場所のまま", "The file stays where it is"))
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = NSColor(white: 1, alpha: 0.6)
        icon.image = NSImage(systemSymbolName: ShelfItem.symbol(for: mode), accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .semibold)
        stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.setCustomSpacing(10, after: icon)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        stack.frame.size = stack.fittingSize
        addSubview(stack)
        apply(.idle, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 中身はいつも真ん中に置く（棚が広がるアニメーションの中で呼ばれたら、一緒に動く）
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        stack.frame.origin = NSPoint(x: ((bounds.width - stack.frame.width) / 2).rounded(),
                                     y: ((bounds.height - stack.frame.height) / 2).rounded())
    }

    func apply(_ look: Look, animated: Bool) {
        let color = ShelfItem.color(for: mode)
        let fill: NSColor, border: NSColor, width: CGFloat, alpha: CGFloat
        switch look {
        case .idle: (fill, border, width, alpha) = (NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0.22), 1.5, 1)
        case .active: (fill, border, width, alpha) = (color.withAlphaComponent(0.24), color, 2.5, 1)
        case .dimmed: (fill, border, width, alpha) = (NSColor(white: 1, alpha: 0.03), NSColor(white: 1, alpha: 0.1), 1.5, 0.45)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.16 : 0
            ctx.allowsImplicitAnimation = animated
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border.cgColor
            layer?.borderWidth = width
            animator().alphaValue = alpha
        }
        icon.contentTintColor = look == .active ? color : .white
        if look == .active, animated, #available(macOS 14.0, *) {
            icon.addSymbolEffect(.bounce) // 乗った側のアイコンが小さく弾む
        }
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
        // 棚の黒で縁取りして、サムネイルから浮かせる
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
