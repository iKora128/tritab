import AppKit
import Carbon.HIToolbox
import QuartzCore
import QuickLookThumbnailing
import QuickLookUI
import TriTabCore

// MARK: - アニメーション

/// 棚の出入りの動き。rawValue は保存済みの設定と互換にしてある
enum ShelfAnimationStyle: String, CaseIterable {
    case jelly, spring, smooth, snappy

    var label: String {
        switch self {
        case .jelly: return L("ぬるっと（縦が先に伸び、横があとから追いつく・おすすめ）", "Jelly (stretches down first, then widens; recommended)")
        case .spring: return L("ぷるん（少し弾む）", "Springy (bounces a little)")
        case .smooth: return L("スッ（弾まない）", "Smooth (no bounce)")
        case .snappy: return L("キビキビ（最短）", "Snappy (fastest)")
        }
    }

    var shortLabel: String {
        switch self {
        case .jelly: return L("ぬるっと", "Jelly")
        case .spring: return L("ぷるん", "Springy")
        case .smooth: return L("スッ", "Smooth")
        case .snappy: return L("キビキビ", "Snappy")
        }
    }

    /// 横・縦それぞれの進み方（0 → 1）
    fileprivate func curves(growing: Bool) -> (width: Curve, height: Curve) {
        switch self {
        case .jelly:
            // 縦が先、横があとから。どちらもほとんど弾まない柔らかいバネ
            return growing
                ? (.spring(response: 0.34, damping: 0.8), .spring(response: 0.24, damping: 0.86))
                : (.spring(response: 0.22, damping: 1.0), .spring(response: 0.26, damping: 1.0))
        case .spring:
            return growing
                ? (.spring(response: 0.36, damping: 0.62), .spring(response: 0.3, damping: 0.66))
                : (.spring(response: 0.24, damping: 0.9), .spring(response: 0.24, damping: 0.9))
        case .smooth:
            return (.easeOut(duration: growing ? 0.26 : 0.2), .easeOut(duration: growing ? 0.26 : 0.2))
        case .snappy:
            return (.easeOut(duration: 0.14), .easeOut(duration: 0.14))
        }
    }
}

/// 0 → 1 へ進む曲線
fileprivate enum Curve {
    case spring(response: Double, damping: Double)
    case easeOut(duration: Double)

    func value(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        switch self {
        case let .spring(response, damping):
            let w0 = 2 * Double.pi / response
            if damping >= 1 {
                return 1 - exp(-w0 * t) * (1 + w0 * t)
            }
            let wd = w0 * (1 - damping * damping).squareRoot()
            return 1 - exp(-damping * w0 * t) * (cos(wd * t) + (damping * w0 / wd) * sin(wd * t))
        case let .easeOut(duration):
            let x = min(t / duration, 1)
            return 1 - pow(1 - x, 4)
        }
    }

    /// 落ち着くまでの時間
    var duration: Double {
        switch self {
        case .easeOut(let d):
            return d
        case .spring:
            var last = 0.0
            var t = 0.0
            while t < 1.5 {
                if abs(1 - value(t)) > 0.002 { last = t }
                t += 1.0 / 240
            }
            return last + 1.0 / 60
        }
    }
}

// MARK: - 棚

/// ノッチの棚。
///
/// - ファイルをドラッグして少し上へ動かすと、ノッチから顔を出す。上端に近づくと開く。棚の上で待つとさらに広がる
/// - ノッチにマウスを乗せる / クリックしても開く。開いているあいだ ⌘V で貼り付け、⌘N で新しいメモ
/// - 項目にマウスを乗せてスペースで Quick Look。画像や PDF はサムネイルで見せる
/// - ファイルは参照（URL）だけを持つ。空で閉じたらウィンドウごと破棄してメモリを返す
final class ShelfController: NSObject {
    static let shared = ShelfController()

    enum State: Equatable { case hidden, peek, collapsed, open, large }

    private(set) var items: [URL] = []
    private(set) var state: State = .hidden
    var style: ShelfAnimationStyle = .jelly

    private var panel: ShelfPanel?
    private var detectors: [ShelfDetectorWindow] = []
    private var mouseDownMonitor: Any?
    private var screenObserver: Any?
    private var enabled = false

    // ドラッグの追跡（マウスボタンが押されているあいだだけ見る）
    private var dragPoll: Timer?
    private var dragChangeCountAtDown = -1
    private var dragHasFiles: Bool?
    private var lowestY: CGFloat = 0

    private var settleWork: DispatchWorkItem?
    private var largeWork: DispatchWorkItem?
    /// 棚から外へドラッグしている最中
    var draggingOut = false
    /// マウスが乗っている項目（スペースで Quick Look する対象）
    var hoveredItem: URL?
    private var previewCaption: String?
    fileprivate let quickLook = ShelfQuickLook()

    private override init() {
        super.init()
        // 前回の貼り付けで作った一時ファイルを片付ける
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    // MARK: 有効 / 無効

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        on ? start() : stop()
    }

    private func start() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDown()
        }
        rebuildDetectors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildDetectors() }
        MemoEditor.shared.onClose = { [weak self] in self?.scheduleSettle(after: 0.4) }

        // 保存してあるメモを棚に戻す
        let memos = (try? FileManager.default.contentsOfDirectory(at: Self.memoDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        items = memos
        if !items.isEmpty { DispatchQueue.main.async { self.show(.collapsed) } }
    }

    private func stop() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dragPoll?.invalidate()
        dragPoll = nil
        detectors.forEach { $0.orderOut(nil) }
        detectors = []
        items = []
        state = .hidden
        panel?.orderOut(nil)
        panel = nil
        ShelfThumbnails.shared.removeAll()
    }

    /// 各画面の上端中央（ノッチ）に、マウスとドラッグを受ける透明な受け口を置く
    private func rebuildDetectors() {
        detectors.forEach { $0.orderOut(nil) }
        detectors = NSScreen.screens.map { screen in
            let w = ShelfDetectorWindow(rect: ShelfGeometry.detectorRect(on: screen))
            w.onActivate = { [weak self] in
                guard let self, self.state != .large else { return }
                self.show(.open, on: screen)
            }
            w.orderFrontRegardless()
            return w
        }
    }

    // MARK: ドラッグの追跡

    private func mouseDown() {
        dragChangeCountAtDown = NSPasteboard(name: .drag).changeCount
        dragHasFiles = nil
        lowestY = NSEvent.mouseLocation.y
        dragPoll?.invalidate()
        // ドラッグ＆ドロップ中のマウス移動はほかのアプリに届かないので、押しているあいだだけ位置を見る
        dragPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.dragPoll?.invalidate()
                self.dragPoll = nil
                self.mouseUp()
            } else {
                self.mouseDragged()
            }
        }
    }

    private func mouseDragged() {
        let loc = NSEvent.mouseLocation
        lowestY = min(lowestY, loc.y)
        if dragHasFiles == nil {
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != dragChangeCountAtDown {
                dragHasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            }
        }
        guard dragHasFiles == true, !draggingOut,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else { return }

        if screen.frame.maxY - loc.y < 200 {
            if state != .large { show(.open, on: screen) }
        } else if loc.y - lowestY > 20, state == .hidden || state == .collapsed {
            show(.peek, on: screen) // 少しでも上へ動かしたら、ノッチから顔を出す
        }
    }

    private func mouseUp() {
        guard dragHasFiles == true else { return }
        dragHasFiles = nil
        largeWork?.cancel()
        scheduleSettle(after: 0.3) // ドロップの処理が終わってから落ち着かせる
    }

    // MARK: 中身

    func add(_ urls: [URL]) {
        let new = urls.filter { !items.contains($0) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        panel?.itemsChanged(items)
        panel?.bounce()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        if Self.isMemo(url) { NSWorkspace.shared.recycle([url]) } // メモはゴミ箱へ（戻せる）
        ShelfThumbnails.shared.forget(url)
        panel?.itemsChanged(items)
        if items.isEmpty { scheduleSettle(after: 0.4) }
    }

    func removeAll() {
        let memos = items.filter(Self.isMemo)
        if !memos.isEmpty { NSWorkspace.shared.recycle(memos) }
        items.forEach(ShelfThumbnails.shared.forget)
        items = []
        panel?.itemsChanged(items)
    }

    /// ⌘V: クリップボードの中身を棚に入れる（ファイル → そのまま、画像 → PNG、テキスト → メモ）
    func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls)
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  let url = writeCache(png, name: "\(L("画像", "Image")) \(Self.stamp()).png") {
            add([url])
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            createMemo(text)
        } else {
            NSSound.beep()
        }
    }

    /// 開いている棚の上でのキー操作（イベントタップから呼ばれる。true を返すと前面のアプリに届かない）
    /// - ⌘V: 貼り付け / ⌘N: 新しいメモ / スペース: Quick Look
    func handleKeyDown(_ event: CGEvent) -> Bool {
        guard !MemoEditor.shared.isOpen, let panel else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])

        // Quick Look が開いているあいだ: スペース / esc で閉じる、矢印で前後の項目へ。
        // 前面のアプリから入力先を奪わずに操作できるよう、TriTab がキーを受けて Quick Look を動かす
        if previewing, flags.isEmpty, let ql = QLPreviewPanel.shared() {
            switch Int(keyCode) {
            case kVK_Space, kVK_Escape:
                DispatchQueue.main.async { self.closeQuickLook() }
                return true
            case kVK_LeftArrow, kVK_UpArrow, kVK_RightArrow, kVK_DownArrow:
                let step = (Int(keyCode) == kVK_LeftArrow || Int(keyCode) == kVK_UpArrow) ? -1 : 1
                DispatchQueue.main.async {
                    let n = self.quickLook.items.count
                    guard n > 0 else { return }
                    ql.currentPreviewItemIndex = (ql.currentPreviewItemIndex + step + n) % n
                }
                return true
            default:
                break
            }
        }
        guard state == .open || state == .large, panel.containsMouse else { return false }

        switch (keyCode, flags) {
        case (Int64(kVK_ANSI_V), [.maskCommand]):
            DispatchQueue.main.async { self.paste() }
            return true
        case (Int64(kVK_ANSI_N), [.maskCommand]):
            DispatchQueue.main.async { self.createMemo(edit: true) }
            return true
        case (Int64(kVK_Space), []):
            guard !items.isEmpty else { return false }
            DispatchQueue.main.async { self.showQuickLook() }
            return true
        default:
            return false
        }
    }

    private static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TriTab").appendingPathComponent("Shelf")

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    private func writeCache(_ data: Data, name: String) -> URL? {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        let url = Self.cacheDirectory.appendingPathComponent(name)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: メモ

    static let memoDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TriTab").appendingPathComponent("Memos")

    static func isMemo(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == memoDirectory.standardizedFileURL
    }

    @discardableResult
    func createMemo(_ text: String = "", edit: Bool = false) -> URL? {
        try? FileManager.default.createDirectory(at: Self.memoDirectory, withIntermediateDirectories: true)
        let url = Self.memoDirectory.appendingPathComponent("\(L("メモ", "Note")) \(Self.stamp()).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        add([url])
        if edit { openEditor(url) }
        return url
    }

    func openEditor(_ url: URL) {
        if state != .open { show(.open) }
        guard let panel else { return }
        MemoEditor.shared.open(url, below: panel.shelfFrame(for: .open, itemCount: items.count))
    }

    func memoDidChange(_ url: URL) {
        panel?.refreshItem(url)
    }

    // MARK: Quick Look

    func showQuickLook() {
        guard let panel, !items.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        quickLook.items = items
        quickLook.sourceFrame = { [weak panel] url in panel?.screenFrame(of: url) ?? .zero }
        quickLook.onClose = { [weak self] in self?.quickLookEnded() }
        // 中身は直接渡す（TriTab は前面に出ないので、レスポンダチェーン経由では渡らない）
        ql.dataSource = quickLook
        ql.delegate = quickLook
        ql.reloadData()
        ql.currentPreviewItemIndex = hoveredItem.flatMap { items.firstIndex(of: $0) } ?? 0
        ql.orderFront(nil)
    }

    func closeQuickLook() {
        QLPreviewPanel.shared()?.orderOut(nil)
        quickLookEnded()
    }

    fileprivate func quickLookEnded() {
        scheduleSettle(after: 0.3)
    }

    private var previewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    // MARK: 表示状態

    /// 棚をその状態にする
    func show(_ target: State, on screen: NSScreen? = nil) {
        settleWork?.cancel()
        settleWork = nil
        guard target != state else { return }
        state = target

        if target == .hidden {
            panel?.animate(to: .hidden, style: style, caption: previewCaption) { [weak self] in
                guard let self, self.state == .hidden else { return }
                self.panel?.orderOut(nil)
                self.panel = nil // ウィンドウごと破棄してメモリを返す
            }
            return
        }
        let p = panel ?? ShelfPanel(controller: self, screen: screen ?? ShelfGeometry.preferredScreen)
        panel = p
        p.orderFrontRegardless()
        p.animate(to: target, style: style, caption: previewCaption, completion: nil)
    }

    func pointerMoved(inside: Bool) {
        if inside {
            settleWork?.cancel()
            settleWork = nil
            if state == .collapsed { show(.open) }
        } else {
            scheduleSettle(after: 0.25)
        }
    }

    /// 何もしていないときの落ち着き先（中身があれば小さなタブ、なければ隠す）
    func scheduleSettle(after delay: TimeInterval) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork = nil
            if self.panel?.containsMouse == true || self.draggingOut || self.dragHasFiles == true
                || MemoEditor.shared.isOpen || self.previewing || self.previewCaption != nil { return }
            self.show(self.items.isEmpty ? .hidden : .collapsed)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// ファイルを持ったまま棚に入った / 出た。入ったまま 0.45 秒待つと、もう一段広がる
    func dragHover(_ inside: Bool) {
        largeWork?.cancel()
        if inside {
            if state != .large { show(.open) }
            let work = DispatchWorkItem { [weak self] in self?.show(.large) }
            largeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else if state == .large {
            show(.open)
        }
    }

    // MARK: プレビュー（設定画面から）

    /// 指定したアニメーションで、顔を出す → 開く → 広がる → 閉じる を見せる。nil なら全パターンを順に
    func preview(_ only: ShelfAnimationStyle?) {
        let styles = only.map { [$0] } ?? ShelfAnimationStyle.allCases
        let original = style
        let screen = ShelfGeometry.preferredScreen
        var t: TimeInterval = 0
        for s in styles {
            after(t) { self.style = s; self.previewCaption = s.shortLabel; self.show(.peek, on: screen) }
            after(t + 0.6) { self.show(.open, on: screen) }
            after(t + 1.5) { self.show(.large, on: screen) }
            after(t + 2.2) { self.show(.open, on: screen) }
            after(t + 2.8) { self.show(self.items.isEmpty ? .hidden : .collapsed) }
            t += 3.5
        }
        after(t) { self.style = original; self.previewCaption = nil }
    }

    private func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

// MARK: - 位置・大きさ

enum ShelfGeometry {
    static let flare: CGFloat = 10
    static let shadowPad: CGFloat = 24

    static func notchRect(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let f = screen.frame
        let h = screen.safeAreaInsets.top
        return NSRect(x: f.minX + left.width, y: f.maxY - h, width: f.width - left.width - right.width, height: h)
    }

    static func notchSize(on screen: NSScreen) -> NSSize {
        notchRect(on: screen)?.size ?? NSSize(width: 0, height: NSStatusBar.system.thickness)
    }

    /// マウスを乗せる / クリックすると棚が開く場所: ノッチ / ノッチのない画面は上端中央の細い帯
    static func detectorRect(on screen: NSScreen) -> NSRect {
        if let r = notchRect(on: screen) { return r }
        let f = screen.frame
        return NSRect(x: f.midX - 110, y: f.maxY - 3, width: 220, height: 3)
    }

    static var preferredScreen: NSScreen {
        NSScreen.screens.first { notchRect(on: $0) != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 状態ごとの棚の大きさ
    static func size(for state: ShelfController.State, itemCount: Int, screen: NSScreen) -> NSSize {
        let notch = notchSize(on: screen)
        let base = max(notch.width, 160)
        switch state {
        case .hidden:
            return notch.width > 0 ? notch : NSSize(width: 160, height: 0)
        case .peek:
            return NSSize(width: base + 70, height: notch.height + 30)
        case .collapsed:
            return NSSize(width: base + 8, height: notch.height + 22)
        case .open:
            // 左右に「新規メモ」「貼り付け」のボタン（各 ShelfSideButton.width）を置くぶん広げる
            let content = CGFloat(itemCount) * ShelfItemView.width + ShelfSideButton.width * 2 + 48
            return NSSize(width: min(max(base + 250, content), maxWidth(screen)),
                          height: notch.height + ShelfItemView.height + 34)
        case .large:
            let open = size(for: .open, itemCount: itemCount, screen: screen)
            return NSSize(width: min(open.width + 150, maxWidth(screen) + 150), height: open.height + 64)
        }
    }

    static func radius(for state: ShelfController.State, height: CGFloat) -> CGFloat {
        switch state {
        case .hidden: return min(10, height / 2)
        case .peek, .collapsed: return 14
        case .open: return 22
        case .large: return 30
        }
    }

    static func maxWidth(_ screen: NSScreen) -> CGFloat { min(screen.frame.width * 0.6, 700) }

    /// 描画の土台の大きさ（どの状態もこの中に収まる）
    static func stageSize(_ screen: NSScreen) -> NSSize {
        NSSize(width: maxWidth(screen) + 150 + flare * 2 + shadowPad * 2,
               height: notchSize(on: screen).height + ShelfItemView.height + 34 + 64 + shadowPad)
    }
}

// MARK: - 受け口（透明）

/// 上端中央に置く透明なウィンドウ。マウスが乗る / クリック / ファイルのドラッグで棚を開く。
/// ノッチ部分にはメニュー項目がないので、置いても操作の邪魔にならない。
final class ShelfDetectorWindow: NSPanel {
    var onActivate: (() -> Void)?

    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = false
        isReleasedWhenClosed = false
        let view = DetectorView(frame: NSRect(origin: .zero, size: rect.size))
        view.owner = self
        contentView = view
    }

    final class DetectorView: NSView {
        weak var owner: ShelfDetectorWindow?
        private var dwell: DispatchWorkItem?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        required init?(coder: NSCoder) { fatalError() }

        // ほぼ透明で塗る（完全に透明だとマウスもドラッグも受け取れない）
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.01).setFill()
            dirtyRect.fill()
        }

        override func mouseEntered(with event: NSEvent) {
            // 通りすがりで開かないよう、少しだけ留まったら開く
            let work = DispatchWorkItem { [weak self] in self?.owner?.onActivate?() }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        override func mouseExited(with event: NSEvent) { dwell?.cancel() }

        override func mouseDown(with event: NSEvent) {
            dwell?.cancel()
            owner?.onActivate?()
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.onActivate?()
            return []
        }
    }
}

// MARK: - 棚のウィンドウ

/// 棚のウィンドウ。描画は大きさの変わらない「土台（stage）」の上で行い、ウィンドウは
/// いま必要な範囲だけに合わせる（土台は上端中央に固定されるので、ウィンドウの大きさを変えても絵は動かない）。
final class ShelfPanel: NSPanel {
    private weak var controller: ShelfController?
    let targetScreen: NSScreen
    private let root = ShelfRootView()
    private let stage: ShelfStage
    private var state: ShelfController.State = .hidden
    private var itemCount = 0

    init(controller: ShelfController, screen: NSScreen) {
        self.controller = controller
        targetScreen = screen
        stage = ShelfStage(controller: controller, screen: screen)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = root
        root.addSubview(stage)
        root.stage = stage
        itemCount = controller.items.count
        stage.setItems(controller.items, animated: false)
        let hidden = ShelfGeometry.size(for: .hidden, itemCount: 0, screen: screen)
        resizeWindow(to: hidden)
        stage.jump(to: .hidden, size: hidden)
    }

    override var canBecomeKey: Bool { true } // Quick Look のため

    var containsMouse: Bool {
        NSMouseInRect(NSEvent.mouseLocation, stage.shelfScreenRect.insetBy(dx: -10, dy: -10), false)
    }

    func shelfFrame(for state: ShelfController.State, itemCount: Int) -> NSRect {
        let size = ShelfGeometry.size(for: state, itemCount: itemCount, screen: targetScreen)
        let f = targetScreen.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    /// 棚の描画範囲（影とフレアを含む）にウィンドウを合わせる。土台は上端中央に固定
    private func resizeWindow(to size: NSSize) {
        let f = targetScreen.frame
        let w = size.width + ShelfGeometry.flare * 2 + ShelfGeometry.shadowPad * 2
        let h = max(size.height, 1) + ShelfGeometry.shadowPad
        setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: false)
        root.pinStage()
    }

    func animate(to target: ShelfController.State, style: ShelfAnimationStyle, caption: String?,
                 completion: (() -> Void)?) {
        state = target
        let size = ShelfGeometry.size(for: target, itemCount: itemCount, screen: targetScreen)
        let current = stage.displayedSize
        // 動いているあいだは大きいほうに合わせ、落ち着いたら目的の大きさに縮める
        resizeWindow(to: NSSize(width: max(size.width, current.width), height: max(size.height, current.height)))
        stage.animate(to: target, size: size, style: style, caption: caption) { [weak self] in
            guard let self, self.state == target else { return }
            self.resizeWindow(to: size)
            completion?()
        }
    }

    func itemsChanged(_ items: [URL]) {
        itemCount = items.count
        stage.setItems(items, animated: true)
        guard state == .open || state == .large else { return }
        animate(to: state, style: .smooth, caption: nil, completion: nil)
    }

    func refreshItem(_ url: URL) { stage.refreshItem(url) }
    func bounce() { stage.bounce() }
    func screenFrame(of url: URL) -> NSRect { stage.screenFrame(of: url) }

    // Quick Look のデータ元になる（キーウィンドウとしてレスポンダチェーンに入る）
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller?.quickLook
        panel.delegate = controller?.quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        controller?.quickLookEnded()
    }
}

/// ウィンドウの中身。土台を上端中央に固定する
final class ShelfRootView: NSView {
    weak var stage: ShelfStage?

    func pinStage() {
        guard let stage else { return }
        stage.setFrameOrigin(NSPoint(x: ((bounds.width - stage.frame.width) / 2).rounded(),
                                     y: bounds.height - stage.frame.height))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        pinStage()
    }
}

/// 描画の土台。棚の輪郭（CAShapeLayer）と中身を、上端中央を基準に置く
final class ShelfStage: NSView {
    private weak var controller: ShelfController?
    private let screen: NSScreen
    private let shape = CAShapeLayer()
    private let content = NSView()
    private let message = NSView()
    private var itemViews: [URL: ShelfItemView] = [:]
    private var order: [URL] = []
    private var state: ShelfController.State = .hidden
    private var trackingArea: NSTrackingArea?

    // いま動いているアニメーション（途中で次の動きが来たら、その時点の大きさからつなぐ）
    private var motion: (from: NSSize, to: NSSize, fromR: CGFloat, toR: CGFloat, start: CFTimeInterval,
                         width: Curve, height: Curve, duration: Double)?
    private(set) var targetSize = NSSize.zero
    private var targetRadius: CGFloat = 10

    init(controller: ShelfController, screen: NSScreen) {
        self.controller = controller
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: ShelfGeometry.stageSize(screen)))
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.4
        shape.shadowRadius = 12
        shape.shadowOffset = CGSize(width: 0, height: -4)
        shape.frame = bounds
        layer?.addSublayer(shape)
        content.wantsLayer = true
        message.wantsLayer = true
        addSubview(content)
        addSubview(message)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var notchHeight: CGFloat { ShelfGeometry.notchSize(on: screen).height }

    /// 棚の矩形（土台の座標）
    private func rect(for size: NSSize) -> NSRect {
        NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
    }

    var shelfScreenRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect(for: displayedSize), to: nil))
    }

    // MARK: 輪郭

    /// 上端に貼り付き、上の角は外へなめらかに広がり（フレア）、下の角は丸い形
    private func path(_ size: NSSize, radius: CGFloat) -> CGPath {
        let r0 = rect(for: size)
        let h = max(size.height, 0.5)
        let x0 = r0.minX, x1 = r0.maxX, top = bounds.height, bottom = top - h
        let r = min(radius, h / 2, size.width / 2)
        let fl = min(ShelfGeometry.flare, h / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0 - fl, y: top))
        p.addQuadCurve(to: CGPoint(x: x0, y: top - fl), control: CGPoint(x: x0, y: top))
        p.addLine(to: CGPoint(x: x0, y: bottom + r))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: bottom), control: CGPoint(x: x0, y: bottom))
        p.addLine(to: CGPoint(x: x1 - r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: x1, y: bottom + r), control: CGPoint(x: x1, y: bottom))
        p.addLine(to: CGPoint(x: x1, y: top - fl))
        p.addQuadCurve(to: CGPoint(x: x1 + fl, y: top), control: CGPoint(x: x1, y: top))
        p.closeSubpath()
        return p
    }

    /// 画面に見えている大きさ（アニメーションの途中ならその時点の値）
    var displayedSize: NSSize { sample(at: CACurrentMediaTime()).size }

    private func sample(at now: CFTimeInterval) -> (size: NSSize, radius: CGFloat) {
        guard let m = motion else { return (targetSize, targetRadius) }
        let t = now - m.start
        if t >= m.duration { return (m.to, m.toR) }
        let pw = CGFloat(m.width.value(t)), ph = CGFloat(m.height.value(t))
        return (NSSize(width: m.from.width + (m.to.width - m.from.width) * pw,
                       height: m.from.height + (m.to.height - m.from.height) * ph),
                m.fromR + (m.toR - m.fromR) * ph)
    }

    func jump(to state: ShelfController.State, size: NSSize) {
        self.state = state
        targetSize = size
        targetRadius = ShelfGeometry.radius(for: state, height: size.height)
        motion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path(size, radius: targetRadius)
        shape.opacity = (state == .hidden && ShelfGeometry.notchRect(on: screen) == nil) ? 0 : 1
        CATransaction.commit()
        layoutContent(animated: false)
    }

    func animate(to state: ShelfController.State, size: NSSize, style: ShelfAnimationStyle, caption: String?,
                 completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        let (fromSize, fromR) = sample(at: now)
        let toR = ShelfGeometry.radius(for: state, height: size.height)
        let growing = size.height >= fromSize.height
        let curves = style.curves(growing: growing)
        let duration = max(curves.width.duration, curves.height.duration)
        let previousState = self.state
        self.state = state
        targetSize = size
        targetRadius = toR
        motion = (fromSize, size, fromR, toR, now, curves.width, curves.height, duration)

        // 2 つのバネを 60fps で前もって計算し、輪郭の変化をキーフレームにする（描画は Core Animation 任せ）
        let frames = max(Int(duration * 60), 2)
        var values: [CGPath] = []
        values.reserveCapacity(frames + 1)
        for i in 0...frames {
            let s = sample(at: now + duration * Double(i) / Double(frames))
            values.append(path(s.size, radius: s.radius))
        }
        let anim = CAKeyframeAnimation(keyPath: "path")
        anim.values = values
        anim.duration = duration
        anim.calculationMode = .linear

        let hiddenOnFlat = state == .hidden && ShelfGeometry.notchRect(on: screen) == nil
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        shape.path = values.last
        shape.add(anim, forKey: "morph")
        if shape.opacity != (hiddenOnFlat ? 0 : 1) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.opacity
            fade.toValue = hiddenOnFlat ? 0 : 1
            fade.duration = min(duration, 0.2)
            shape.opacity = hiddenOnFlat ? 0 : 1
            shape.add(fade, forKey: "fade")
        }
        CATransaction.commit()

        updateMessage(caption: caption)
        // 中身: 「開いた」系どうしなら位置をすべらせるだけ。それ以外はさっと消して、広がりに合わせて出す
        let openish: Set<ShelfController.State> = [.open, .large]
        if openish.contains(previousState) && openish.contains(state) {
            layoutContent(animated: true)
        } else {
            content.alphaValue = 0
            message.alphaValue = 0
            layoutContent(animated: false)
            let delay = growing ? min(duration * 0.35, 0.12) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state == state else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = growing ? 0.18 : 0.1
                    self.content.animator().alphaValue = self.showsItems ? 1 : 0
                    self.message.animator().alphaValue = state == .hidden ? 0 : 1
                }
            }
        }
        updateTrackingArea()
    }

    // MARK: 中身

    private var showsItems: Bool { (state == .open || state == .large) && !order.isEmpty }

    func setItems(_ items: [URL], animated: Bool) {
        // 増えたものだけ作り、消えたものだけ外す（作り直さない）
        for url in Set(itemViews.keys).subtracting(items) {
            let v = itemViews.removeValue(forKey: url)
            if animated, let v {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    v.animator().alphaValue = 0
                }, completionHandler: { v.removeFromSuperview() })
            } else {
                v?.removeFromSuperview()
            }
        }
        for url in items where itemViews[url] == nil {
            let v = ShelfItemView(url: url, controller: controller)
            itemViews[url] = v
            content.addSubview(v)
            if animated {
                v.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    v.animator().alphaValue = 1
                }
            }
        }
        order = items
        if showsItems { content.alphaValue = 1 }
        updateMessage(caption: nil)
        layoutContent(animated: animated)
    }

    func refreshItem(_ url: URL) { itemViews[url]?.refresh() }

    func screenFrame(of url: URL) -> NSRect {
        guard let v = itemViews[url], let window else { return .zero }
        return window.convertToScreen(v.convert(v.thumbFrame, to: nil))
    }

    private func layoutContent(animated: Bool) {
        let r = rect(for: targetSize)
        let area = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height - notchHeight, 0))
        content.frame = area
        message.frame = area
        guard showsItems else { return }
        let total = CGFloat(order.count) * ShelfItemView.width
        let side = state == .open ? ShelfSideButton.width + 16 : 40
        var x = max((area.width - total) / 2, side)
        // 広がった状態では、上に案内の文字を出すので項目は少し下げる
        let y = (area.height - ShelfItemView.height) / 2 - (state == .large ? 14 : 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.allowsImplicitAnimation = animated
            for url in order {
                guard let v = itemViews[url] else { continue }
                let f = NSRect(x: x, y: y, width: ShelfItemView.width, height: ShelfItemView.height)
                if animated { v.animator().frame = f } else { v.frame = f }
                x += ShelfItemView.width
            }
        }
    }

    /// 文字やボタンなど、項目以外の表示
    private func updateMessage(caption: String?) {
        message.subviews.forEach { $0.removeFromSuperview() }
        let r = rect(for: targetSize)
        message.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height - notchHeight, 0))
        let area = message.bounds

        func label(_ text: String, _ size: CGFloat, _ alpha: CGFloat, weight: NSFont.Weight = .medium) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = NSColor(white: 1, alpha: alpha)
            l.sizeToFit()
            return l
        }
        func center(_ v: NSView, dy: CGFloat = 0) {
            v.frame.origin = NSPoint(x: (area.width - v.frame.width) / 2, y: (area.height - v.frame.height) / 2 + dy)
            message.addSubview(v)
        }
        func button(_ symbol: String, _ tip: String, _ action: Selector, x: CGFloat) {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.contentTintColor = NSColor(white: 1, alpha: 0.5)
            b.toolTip = tip
            b.frame = NSRect(x: x, y: area.height - 26, width: 22, height: 20)
            message.addSubview(b)
        }

        switch state {
        case .hidden:
            break
        case .peek:
            center(label(caption ?? L("ここへ", "Drop here"), 12, 0.75))
        case .collapsed:
            let icon = NSImageView(image: NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)!)
            icon.contentTintColor = .white
            let stack = NSStackView(views: [icon, label("\(order.count)", 12, 0.95, weight: .semibold)])
            stack.spacing = 4
            stack.frame.size = stack.fittingSize
            center(stack)
        case .large:
            let zone = DropZoneView(frame: area.insetBy(dx: 18, dy: 12))
            message.addSubview(zone)
            if order.isEmpty {
                center(label(L("離すと置けます", "Release to drop here"), 17, 0.95, weight: .semibold), dy: 10)
                center(label(L("ファイルを一時置きできます", "Stash files here for later"), 11, 0.5), dy: -13)
            } else {
                let title = label(L("離すと追加", "Release to add"), 13, 0.9, weight: .semibold)
                title.frame.origin = NSPoint(x: (area.width - title.frame.width) / 2, y: area.height - 36)
                message.addSubview(title)
            }
        case .open:
            if let caption {
                if order.isEmpty { center(label(caption, 15, 0.9, weight: .semibold)) }
            } else if order.isEmpty {
                center(label(L("ここへドロップ", "Drop here"), 14, 0.85), dy: 9)
                center(label(L("ファイル・画像・テキスト", "Files, images, text"), 11, 0.45), dy: -11)
            }
            // 左: 新規メモ / 右: クリップボード（⌘C した内容）を貼り付け
            let h = min(area.height - 16, ShelfItemView.height)
            let y = (area.height - h) / 2
            let memo = ShelfSideButton(symbol: "square.and.pencil", title: L("新規メモ", "New Note"), shortcut: "⌘N") { [weak self] in
                self?.controller?.createMemo(edit: true)
            }
            memo.frame = NSRect(x: 10, y: y, width: ShelfSideButton.width, height: h)
            message.addSubview(memo)
            let paste = ShelfSideButton(symbol: "doc.on.clipboard", title: L("貼り付け", "Paste"), shortcut: Self.clipboardKind()) { [weak self] in
                self?.controller?.paste()
            }
            paste.frame = NSRect(x: area.width - 10 - ShelfSideButton.width, y: y, width: ShelfSideButton.width, height: h)
            message.addSubview(paste)
            if !order.isEmpty {
                button("xmark.circle.fill", L("棚を空にする", "Clear Shelf"), #selector(clearAll), x: area.width - ShelfSideButton.width - 40)
            }
        }
    }

    /// いまクリップボードに入っているものの種類（貼り付けボタンの下に出す）
    private static func clipboardKind() -> String {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return L("ファイル", "File") }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return L("画像", "Image") }
        if pb.string(forType: .string)?.isEmpty == false { return L("テキスト", "Text") }
        return L("空", "Empty")
    }

    @objc private func clearAll() { controller?.removeAll() }

    func bounce() {
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.03, 0.995, 1]
        a.keyTimes = [0, 0.3, 0.65, 1]
        a.duration = 0.32
        shape.add(a, forKey: "bounce")
    }

    // MARK: マウスとドラッグ

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: rect(for: targetSize).insetBy(dx: -8, dy: -8),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerMoved(inside: true) }
    override func mouseExited(with event: NSEvent) { controller?.pointerMoved(inside: false) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as? ShelfItemView) == nil else { return [] }
        shape.fillColor = NSColor(white: 0.12, alpha: 1).cgColor
        controller?.dragHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shape.fillColor = NSColor.black.cgColor
        // 広がった直後はウィンドウが変わるので、外に出たかはマウスの位置で確かめる
        if window.map({ !NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? true {
            controller?.dragHover(false)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shape.fillColor = NSColor.black.cgColor
        controller?.dragHover(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        controller?.add(urls)
        if controller?.state == .large { controller?.show(.open) }
        return true
    }
}

/// 広がったときの点線の受け皿
final class DropZoneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 16, yRadius: 16)
        path.lineWidth = 2
        path.setLineDash([7, 6], count: 2, phase: 0)
        NSColor(white: 1, alpha: 0.28).setStroke()
        path.stroke()
        NSColor(white: 1, alpha: 0.04).setFill()
        path.fill()
    }
}

// MARK: - 項目

/// 棚の 1 項目。サムネイル（画像・PDF・動画など）か付箋（メモ）を表示する。
/// ドラッグで持ち出し、マウスを乗せてスペースで Quick Look、ダブルクリックで開く、メモはクリックで編集。
final class ShelfItemView: NSView, NSDraggingSource {
    static let width: CGFloat = 82
    static let height: CGFloat = 80
    static let thumb: CGFloat = 50

    let url: URL
    private weak var controller: ShelfController?
    private let imageView = NSImageView()
    private let memoCard = MemoCardView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let hoverLayer = CALayer()
    private var mouseDownEvent: NSEvent?
    private var isMemo: Bool { ShelfController.isMemo(url) }

    var thumbFrame: NSRect {
        NSRect(x: (Self.width - Self.thumb) / 2, y: 24, width: Self.thumb, height: Self.thumb)
    }

    init(url: URL, controller: ShelfController?) {
        self.url = url
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        toolTip = url.path

        hoverLayer.frame = bounds.insetBy(dx: 3, dy: 1)
        hoverLayer.cornerRadius = 10
        hoverLayer.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)

        imageView.frame = thumbFrame
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        memoCard.frame = thumbFrame.insetBy(dx: 2, dy: 3)

        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = NSColor(white: 1, alpha: 0.88)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: 3, y: 4, width: Self.width - 6, height: 15)
        addSubview(isMemo ? memoCard : imageView)
        addSubview(nameLabel)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if isMemo {
            memoCard.text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            nameLabel.stringValue = L("メモ", "Note")
        } else {
            nameLabel.stringValue = url.lastPathComponent
            imageView.image = ShelfThumbnails.shared.image(for: url, size: Self.thumb) { [weak self] image in
                self?.imageView.image = image
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.hoveredItem = url
        hoverLayer.opacity = 1
    }

    override func mouseExited(with event: NSEvent) {
        if controller?.hoveredItem == url { controller?.hoveredItem = nil }
        hoverLayer.opacity = 0
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2, !isMemo { NSWorkspace.shared.open(url) }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil, isMemo { controller?.openEditor(url) }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = isMemo ? NSWorkspace.shared.icon(forFile: url.path)
                           : (imageView.image ?? NSWorkspace.shared.icon(forFile: url.path))
        item.setDraggingFrame(thumbFrame, contents: image)
        controller?.draggingOut = true
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.draggingOut = false
        // どこかに置けたら棚から外す。メモは .txt として書き出すだけで、棚には残す
        if operation != [], !isMemo { controller?.remove(url) }
        controller?.scheduleSettle(after: 0.3)
    }
}

/// 付箋風のメモカード
final class MemoCardView: NSView {
    var text = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGradient(colors: [NSColor(srgbRed: 1, green: 0.89, blue: 0.42, alpha: 1),
                            NSColor(srgbRed: 1, green: 0.8, blue: 0.26, alpha: 1)])!.draw(in: path, angle: -90)
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        ((preview.isEmpty ? L("（空）", "(empty)") : String(preview.prefix(48))) as NSString).draw(
            in: r.insetBy(dx: 5, dy: 4),
            withAttributes: [.font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
                             .foregroundColor: NSColor(white: 0.15, alpha: 0.9),
                             .paragraphStyle: style])
    }
}

// MARK: - サムネイル

/// Quick Look と同じ仕組みでサムネイルを作る。数を決めてキャッシュし、棚から消えたら捨てる
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 48
        return c
    }()

    /// すぐ表示できるもの（キャッシュかファイルのアイコン）を返し、サムネイルができたら completion で差し替える
    func image(for url: URL, size: CGFloat, completion: @escaping (NSImage) -> Void) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: url as NSURL)
                completion(image)
            }
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
    func removeAll() { cache.removeAllObjects() }
}

// MARK: - Quick Look

final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []
    var sourceFrame: ((URL) -> NSRect)?
    var onClose: (() -> Void)?

    // Quick Look の閉じるボタンで閉じられたとき
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index] as NSURL
    }

    // 棚のサムネイルから拡大して開く
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return sourceFrame?(url) ?? .zero
    }
}

/// 棚の左右に置く大きめのボタン（アイコン + 名前 + 補足）
final class ShelfSideButton: NSView {
    static let width: CGFloat = 70

    private let action: () -> Void
    private let background = CALayer()
    private var pressed = false

    init(symbol: String, title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        background.cornerRadius = 14
        background.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.addSublayer(background)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = NSColor(white: 1, alpha: 0.9)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 10.5, weight: .semibold)
        name.textColor = NSColor(white: 1, alpha: 0.9)
        let sub = NSTextField(labelWithString: shortcut)
        sub.font = .systemFont(ofSize: 9, weight: .medium)
        sub.textColor = NSColor(white: 1, alpha: 0.45)
        let stack = NSStackView(views: [icon, name, sub])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = L("\(title)（\(shortcut)）", "\(title) (\(shortcut))")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) {
        background.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        background.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        background.backgroundColor = NSColor(white: 1, alpha: 0.24).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        background.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        pressed = false
    }
}
