import AppKit

/// 棚のメモを編集する小さなエディタ（棚のすぐ下に出る）。
/// 文字を打つたびに少し待ってから自動保存する。外をクリックするか ⌘W / esc で閉じる。
final class MemoEditor: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = MemoEditor()

    /// 閉じたとき（棚を落ち着かせるため）
    var onClose: (() -> Void)?
    private(set) var isOpen = false

    private var panel: MemoPanel?
    private var textView: NSTextView?
    private var url: URL?
    private var saveWork: DispatchWorkItem?

    func open(_ url: URL, below anchor: NSRect) {
        close()
        self.url = url

        let size = NSSize(width: 420, height: 260)
        let frame = NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 10,
                           width: size.width, height: size.height)
        let p = MemoPanel(contentRect: frame,
                          styleMask: [.borderless, .nonactivatingPanel, .resizable],
                          backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.onClose = { [weak self] in self?.close() }

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.5)
        title.frame = NSRect(x: 16, y: size.height - 26, width: size.width - 32, height: 16)
        title.autoresizingMask = [.width, .minYMargin]
        background.addSubview(title)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 38))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .white
        tv.insertionPointColor = .systemYellow
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        tv.delegate = self
        scroll.documentView = tv
        background.addSubview(scroll)

        p.contentView = background
        panel = p
        textView = tv
        isOpen = true

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
    }

    func close() {
        guard isOpen else { return }
        saveNow()
        isOpen = false
        let p = panel
        panel = nil
        textView = nil
        url = nil
        p?.delegate = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p?.animator().alphaValue = 0
        }, completionHandler: {
            p?.orderOut(nil)
        })
        onClose?()
    }

    // MARK: 保存

    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        guard let url, let text = textView?.string else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        ShelfController.shared.memoDidChange(url)
    }

    // 外をクリックしたら閉じる
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// キー入力を受けられるパネル。メニューバー常駐アプリにはメインメニューがないので、
/// コピー・貼り付けなどのショートカットはここで処理する。
final class MemoPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
        case "w":
            onClose?()
            return true
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    // esc はテキストビューが補完に使ってしまうので、先に拾って閉じる
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onClose?()
            return
        }
        super.sendEvent(event)
    }
}
