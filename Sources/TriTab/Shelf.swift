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
/// - ドラッグ中の棚は左右 2 つの受け口に分かれる。左に落とすとコピー（棚に複製。元はそのまま）、右に落とすと参照（元の場所のまま）
/// - ノッチにマウスを乗せる / クリックしても開く。開いているあいだ ⌘V で貼り付け（ファイルはコピー、⌘⌥V なら参照）、⌘N で新しいメモ
/// - 項目にマウスを乗せてスペースで Quick Look。画像や PDF はサムネイルで見せる
/// - ⌘クリック・⇧クリック・⌘A で選び、まとめてドラッグできる。右クリックで「Finder で表示」など（ShelfActions.swift）
/// - 中身は再起動しても戻る（ShelfLibrary）。空で閉じたらウィンドウごと破棄してメモリを返す
final class ShelfController: NSObject {
    static let shared = ShelfController()

    enum State: Equatable { case hidden, peek, collapsed, open, large }

    private(set) var items: [ShelfItem] = []
    private(set) var selection = ShelfSelection<UUID>()
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
    /// ほかのアプリからファイルを持ってきている最中（棚を左右 2 つの受け口にする）
    private(set) var receivingDrag = false {
        didSet { if receivingDrag != oldValue { panel?.receivingDragChanged() } }
    }
    /// 右クリックメニューを開いているあいだ（棚を閉じない）
    var menuOpen = false
    /// マウスが乗っている項目（スペースで Quick Look する対象）
    var hoveredItem: UUID?
    private var previewCaption: String?
    fileprivate let quickLook = ShelfQuickLook()
    let library = ShelfLibrary(directory: ShelfController.shelfDirectory, memoDirectory: ShelfController.memoDirectory)
    /// 参照からコピーへ切り替えている途中の項目の、切り替える前（失敗したら戻す。終わるまでは参照のまま保存する）
    private var conversions: [UUID: ShelfItem] = [:]

    private override init() {
        super.init()
        // 0.1.0 が貼り付けた画像を置いていた一時フォルダを片付ける（いまは棚の中に置く）
        try? FileManager.default.removeItem(at: Self.legacyCacheDirectory)
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

        // 前回の棚の中身（メモ・コピー・参照）を戻す
        items = library.load()
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
        items = [] // 保存した一覧はそのまま（もう一度オンにしたら戻る）
        selection.clear()
        receivingDrag = false
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
                if dragHasFiles == true, !draggingOut { receivingDrag = true } // 1 回のドラッグにつき 1 度だけ
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
        receivingDrag = false
        guard dragHasFiles == true else { return }
        dragHasFiles = nil
        largeWork?.cancel()
        scheduleSettle(after: 0.3) // ドロップの処理が終わってから落ち着かせる
    }

    // MARK: 中身

    /// ファイルを棚に置く。コピーは棚の中に複製を作り（作り終わるまで印を出す）、参照は元のファイルを指すだけ
    func add(_ urls: [URL], as mode: ShelfDropMode) {
        var added: [ShelfItem] = []
        for url in urls {
            switch mode {
            case .reference:
                // 同じファイルの参照がもうあれば足さない
                let path = url.standardizedFileURL.path
                guard !(items + added).contains(where: { $0.kind == .reference && $0.url.standardizedFileURL.path == path })
                else { continue }
                added.append(library.reference(to: url))
            case .copy:
                let item = library.plannedCopy(of: url)
                added.append(item)
                startCopy(item, from: url)
            }
        }
        insert(added)
    }

    /// 棚に落とされた（ShelfStage から）
    func receive(_ urls: [URL], as mode: ShelfDropMode) {
        receivingDrag = false
        add(urls, as: mode)
    }

    /// ファイルを持ったまま棚に入ってきた（ドラッグの追跡で気づけなかったときのため）
    func beginReceivingDrag() {
        if !draggingOut { receivingDrag = true }
    }

    private func insert(_ new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        itemsChanged()
        panel?.bounce()
    }

    /// 棚の中身が変わったら、選択・表示・保存をそろえる
    private func itemsChanged() {
        selection.keep(items.map(\.id))
        panel?.itemsChanged(items)
        panel?.selectionChanged()
        library.save(items.map { conversions[$0.id] ?? $0 })
    }

    /// 棚から外す。コピーとメモはゴミ箱へ（戻せる）。参照の元のファイルには触らない
    func remove(_ ids: [UUID]) {
        let gone = items.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for item in gone {
            conversions[item.id] = nil // コピーを作っている途中なら、作り終わったところで片付ける（copyFinished）
            ShelfThumbnails.shared.forget(item.url)
            library.discard(item)
        }
        itemsChanged()
        if items.isEmpty { scheduleSettle(after: 0.4) }
    }

    func removeAll() {
        remove(items.map(\.id))
    }

    /// 外へのドラッグが終わった。移動として受け取られた項目は棚から外す（コピーやエイリアスなら残す。ShelfRules）
    func dragEnded(_ ids: [UUID], operation: ShelfDragOperation) {
        draggingOut = false
        let moved = items.filter { ids.contains($0.id) && !ShelfRules.staysOnShelf($0.kind, after: operation) }
        if !moved.isEmpty {
            items.removeAll { item in moved.contains { $0.id == item.id } }
            for item in moved {
                ShelfThumbnails.shared.forget(item.url)
                library.cleanUpAfterMove(item)
            }
            itemsChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restoreUnmoved(moved) }
        }
        scheduleSettle(after: 0.3)
    }

    /// 移動として受け取られたのに、ファイルが元の場所に残っているものを棚に戻す
    /// （Finder の「同じ名前があります」で中止した、移動と返して読んだだけのアプリ、など）。
    /// 移動されたコピーの、空になったフォルダはここで片付ける
    private func restoreUnmoved(_ moved: [ShelfItem]) {
        let unmoved = moved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        moved.filter { m in !unmoved.contains { $0.id == m.id } }.forEach(library.cleanUpAfterMove)
        let back = unmoved.filter { u in !items.contains { $0.id == u.id } }
        guard enabled, !back.isEmpty else { return }
        insert(back)
    }

    /// 元のファイルが動いた・消えたかを確かめ直す（棚を開くとき・ドラッグやメニューの前）
    func refreshItems(_ ids: [UUID]? = nil) {
        var changed = false
        for i in items.indices where ids?.contains(items[i].id) ?? true {
            if library.refresh(&items[i]) { changed = true }
        }
        if changed { itemsChanged() }
    }

    /// ⌘V: クリップボードの中身を棚に入れる（ファイル → コピー（⌘⌥V なら参照）、画像 → PNG、テキスト → メモ）
    func paste(as mode: ShelfDropMode = .copy) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls, as: mode) // Finder の ⌘C → ⌘V と同じく、元のファイルはそのまま
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  let item = library.store(png, name: "\(L("画像", "Image")) \(Self.stamp()).png") {
            insert([item])
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            createMemo(text)
        } else {
            NSSound.beep()
        }
    }

    // MARK: コピー

    private func startCopy(_ item: ShelfItem, from source: URL) {
        let id = item.id, destination = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = (try? ShelfLibrary.copy(from: source, to: destination)) != nil
            DispatchQueue.main.async { self?.copyFinished(id, ok: ok) }
        }
    }

    private func copyFinished(_ id: UUID, ok: Bool) {
        let original = conversions.removeValue(forKey: id)
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            library.removeCopyFolder(id) // 作っている途中で棚から外された
            return
        }
        if ok {
            items[i].status = .ready
        } else {
            library.removeCopyFolder(id)
            NSSound.beep()
            if let original { items[i] = original } else { items.remove(at: i) }
        }
        itemsChanged()
    }

    /// 参照で置いたものを、棚の中のコピーに切り替える（元のファイルはそのまま）
    func makeCopies(_ ids: [UUID]) {
        refreshItems(ids)
        for i in items.indices where ids.contains(items[i].id) && items[i].kind == .reference && items[i].isAvailable {
            let reference = items[i]
            let copy = library.plannedCopy(of: reference.url, id: reference.id)
            conversions[reference.id] = reference
            items[i] = copy
            startCopy(copy, from: reference.url)
        }
        itemsChanged()
    }

    // MARK: 選択

    func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// ⌘クリック / ⇧クリック
    func click(_ id: UUID, command: Bool, shift: Bool) {
        selection.click(id, in: items.map(\.id), command: command, shift: shift)
        panel?.selectionChanged()
    }

    func select(_ id: UUID) {
        selection.select(id)
        panel?.selectionChanged()
    }

    func selectAll() {
        selection.selectAll(items.map(\.id))
        panel?.selectionChanged()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        panel?.selectionChanged()
    }

    /// 選んである項目（棚の並び順）
    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    /// その項目からドラッグを始めたときに持ち出すもの。選んであればまとめて。
    /// 場所を確かめ直し、使えないもの（見つからない・コピー中）は外す
    func itemsToDrag(from id: UUID) -> [ShelfItem] {
        let ids = selection.dragItems(from: id, in: items.map(\.id))
        refreshItems(ids)
        guard items.first(where: { $0.id == id })?.isAvailable == true else { return [] }
        return items.filter { ids.contains($0.id) && $0.isAvailable }
    }

    /// 開いている棚の上でのキー操作（イベントタップから呼ばれる。true を返すと前面のアプリに届かない）
    /// - ⌘V: 貼り付け（ファイルはコピー）/ ⌘⌥V: 参照で貼り付け / ⌘N: 新しいメモ / ⌘A: すべて選択 / esc: 選択を外す
    /// - スペース: Quick Look
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
        case (Int64(kVK_ANSI_V), [.maskCommand, .maskAlternate]):
            DispatchQueue.main.async { self.paste(as: .reference) }
            return true
        case (Int64(kVK_ANSI_N), [.maskCommand]):
            DispatchQueue.main.async { self.createMemo(edit: true) }
            return true
        case (Int64(kVK_ANSI_A), [.maskCommand]):
            guard !items.isEmpty else { return false }
            DispatchQueue.main.async { self.selectAll() }
            return true
        case (Int64(kVK_Escape), []):
            guard !selection.isEmpty else { return false }
            DispatchQueue.main.async { self.clearSelection() }
            return true
        case (Int64(kVK_Space), []):
            guard !items.isEmpty else { return false }
            DispatchQueue.main.async { self.showQuickLook() }
            return true
        default:
            return false
        }
    }

    /// 0.1.0 が貼り付けた画像を置いていた場所（いまは使わない。起動したときに片付ける）
    private static let legacyCacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TriTab").appendingPathComponent("Shelf")

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: メモ

    private static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TriTab")
    static let memoDirectory = supportDirectory.appendingPathComponent("Memos")
    /// 棚の一覧と、棚に作ったコピーの置き場所
    static let shelfDirectory = supportDirectory.appendingPathComponent("Shelf")

    @discardableResult
    func createMemo(_ text: String = "", edit: Bool = false) -> URL? {
        try? FileManager.default.createDirectory(at: Self.memoDirectory, withIntermediateDirectories: true)
        let url = Self.memoDirectory.appendingPathComponent("\(L("メモ", "Note")) \(Self.stamp()).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        insert([ShelfItem(kind: .memo, url: url)])
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

    /// 選んである項目があればそれを、なければ棚の全部を、マウスが乗っている項目から見せる
    func showQuickLook() {
        showQuickLook(selection.isEmpty ? items : selectedItems)
    }

    func showQuickLook(_ targets: [ShelfItem]) {
        let shown = targets.filter(\.isAvailable)
        guard let panel, !shown.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        quickLook.items = shown.map(\.url)
        quickLook.sourceFrame = { [weak panel] url in panel?.screenFrame(of: url) ?? .zero }
        quickLook.onClose = { [weak self] in self?.quickLookEnded() }
        // 中身は直接渡す（TriTab は前面に出ないので、レスポンダチェーン経由では渡らない）
        ql.dataSource = quickLook
        ql.delegate = quickLook
        ql.reloadData()
        ql.currentPreviewItemIndex = hoveredItem.flatMap { id in shown.firstIndex { $0.id == id } } ?? 0
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
        let wasOpen = state == .open || state == .large
        state = target
        if target == .open || target == .large {
            if !wasOpen { refreshItems() } // 開くたびに、元のファイルが動いた・消えたかを確かめる
        } else {
            clearSelection() // 選択は棚を閉じると外れる
        }

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
            if self.panel?.containsMouse == true || self.draggingOut || self.dragHasFiles == true || self.menuOpen
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

    func itemsChanged(_ items: [ShelfItem]) {
        let countChanged = items.count != itemCount
        itemCount = items.count
        stage.setItems(items, animated: true)
        // 数が変わったときだけ大きさを合わせる（コピーが終わった・場所が変わった、だけなら表示を直すだけ）
        guard countChanged, state == .open || state == .large else { return }
        animate(to: state, style: .smooth, caption: nil, completion: nil)
    }

    func selectionChanged() { stage.selectionChanged() }
    func receivingDragChanged() { stage.receivingDragChanged() }
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
    /// ドラッグで持ってきているあいだの、左右 2 つの受け口
    private let dropZones = ShelfDropZonesView()
    /// 文字やボタン。項目の上に重なるので、自分自身はマウスを受けずに下の項目へ通す
    private let message = ShelfPassthroughView()
    private var itemViews: [UUID: ShelfItemView] = [:]
    private var order: [UUID] = []
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
        addSubview(dropZones)
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
            fadeContent()
        } else {
            content.alphaValue = 0
            message.alphaValue = 0
            dropZones.alphaValue = 0
            layoutContent(animated: false)
            let delay = growing ? min(duration * 0.35, 0.12) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state == state else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = growing ? 0.18 : 0.1
                    self.content.animator().alphaValue = self.showsItems ? 1 : 0
                    self.message.animator().alphaValue = state == .hidden ? 0 : 1
                    self.dropZones.animator().alphaValue = self.showsDropZones ? 1 : 0
                }
            }
        }
        updateTrackingArea()
    }

    // MARK: 中身

    /// ファイルを持ってきているあいだは、項目の代わりに左右 2 つの受け口を出す（広がった状態はいつも）
    private var showsDropZones: Bool {
        state == .large || (state == .open && controller?.receivingDrag == true)
    }

    private var showsItems: Bool { (state == .open || state == .large) && !order.isEmpty && !showsDropZones }

    /// 項目と受け口を入れ替える（ファイルを持ってきた・置いた・広がった）
    private func fadeContent() {
        if !showsDropZones { dropZones.highlighted = nil }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            content.animator().alphaValue = showsItems ? 1 : 0
            dropZones.animator().alphaValue = showsDropZones ? 1 : 0
        }
    }

    func receivingDragChanged() {
        updateMessage(caption: nil)
        layoutContent(animated: false)
        fadeContent()
    }

    func setItems(_ items: [ShelfItem], animated: Bool) {
        // 増えたものだけ作り、消えたものだけ外す（作り直さない）
        for id in Set(itemViews.keys).subtracting(items.map(\.id)) {
            let v = itemViews.removeValue(forKey: id)
            if animated, let v {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    v.animator().alphaValue = 0
                }, completionHandler: { v.removeFromSuperview() })
            } else {
                v?.removeFromSuperview()
            }
        }
        for item in items {
            if let v = itemViews[item.id] {
                v.update(item) // 状態や場所が変わっただけ
                continue
            }
            let v = ShelfItemView(item: item, controller: controller)
            v.isSelected = controller?.isSelected(item.id) == true
            itemViews[item.id] = v
            content.addSubview(v)
            if animated {
                v.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    v.animator().alphaValue = 1
                }
            }
        }
        order = items.map(\.id)
        if showsItems { content.alphaValue = 1 }
        updateMessage(caption: nil)
        layoutContent(animated: animated)
    }

    func selectionChanged() {
        for (id, v) in itemViews { v.isSelected = controller?.isSelected(id) == true }
    }

    func refreshItem(_ url: URL) { itemViews.values.first { $0.item.url == url }?.refresh() }

    func screenFrame(of url: URL) -> NSRect {
        guard let v = itemViews.values.first(where: { $0.item.url == url }), let window else { return .zero }
        return window.convertToScreen(v.convert(v.thumbFrame, to: nil))
    }

    private func layoutContent(animated: Bool) {
        let r = rect(for: targetSize)
        let area = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height - notchHeight, 0))
        content.frame = area
        message.frame = area
        // insetBy は小さすぎる矩形で null（原点が無限大）を返すので、自分で縮める
        let zones = NSRect(x: area.minX + 14, y: area.minY + 10,
                           width: max(area.width - 28, 0), height: max(area.height - 20, 0))
        if animated, dropZones.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.allowsImplicitAnimation = true
                dropZones.animator().frame = zones // 受け口は棚の広がりについていく
            }
        } else {
            dropZones.frame = zones
        }
        guard showsItems else { return }
        let total = CGFloat(order.count) * ShelfItemView.width
        let side = state == .open ? ShelfSideButton.width + 16 : 40
        var x = max((area.width - total) / 2, side)
        let y = (area.height - ShelfItemView.height) / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.allowsImplicitAnimation = animated
            for id in order {
                guard let v = itemViews[id] else { continue }
                let f = NSRect(x: x, y: y, width: ShelfItemView.width, height: ShelfItemView.height)
                if animated { v.animator().frame = f } else { v.frame = f }
                v.loadThumbnailIfNeeded() // サムネイルは、項目が見えるときに初めて作る
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
            break // 左右の受け口（dropZones）だけを出す
        case .open:
            if showsDropZones { break } // ファイルを持ってきているあいだは、受け口だけ
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

    // 項目のないところをクリック: 選択を外す / 右クリック: すべて選択・棚を空にする
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        controller?.clearSelection()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller, let menu = controller.backgroundMenu() else { return }
        controller.popUp(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as? ShelfItemView) == nil else { return [] }
        shape.fillColor = NSColor(white: 0.12, alpha: 1).cgColor
        controller?.beginReceivingDrag()
        controller?.dragHover(true)
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard (sender.draggingSource as? ShelfItemView) == nil else { return [] }
        return dropOperation(for: sender)
    }

    /// カーソルのある側（左: コピー / 右: 参照）を強調し、カーソルの印（「+」かエイリアスの矢印）を返す
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let mode = dropMode(at: sender.draggingLocation)
        dropZones.highlighted = mode
        return NSDragOperation(ShelfRules.dropOperation(for: mode, sourceAllows: ShelfDragOperation(sender.draggingSourceOperationMask)))
    }

    private func dropMode(at windowPoint: NSPoint) -> ShelfDropMode {
        let p = convert(windowPoint, from: nil)
        let r = rect(for: targetSize)
        return ShelfRules.dropMode(atX: p.x, shelfMinX: r.minX, shelfMaxX: r.maxX)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shape.fillColor = NSColor.black.cgColor
        dropZones.highlighted = nil
        // 広がった直後はウィンドウが変わるので、外に出たかはマウスの位置で確かめる
        if window.map({ !NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? true {
            controller?.dragHover(false)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shape.fillColor = NSColor.black.cgColor
        let mode = dropMode(at: sender.draggingLocation)
        controller?.dragHover(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        controller?.receive(urls, as: mode)
        if controller?.state == .large { controller?.show(.open) }
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropZones.highlighted = nil
    }
}

// MARK: - 項目

/// 棚の 1 項目。サムネイル（画像・PDF・動画など）か付箋（メモ）を表示し、右下にコピー / 参照の印を付ける。
/// ドラッグで持ち出し（選んであればまとめて）、⌘クリック・⇧クリックで選び、右クリックでメニュー、
/// マウスを乗せてスペースで Quick Look、ダブルクリックで開く、メモはクリックで編集。
final class ShelfItemView: NSView, NSDraggingSource {
    static let width: CGFloat = 82
    static let height: CGFloat = 80
    static let thumb: CGFloat = 50

    private(set) var item: ShelfItem
    private weak var controller: ShelfController?
    private let imageView = NSImageView()
    private let memoCard = MemoCardView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let hoverLayer = CALayer()
    private let selectionLayer = CALayer()
    private let nameHighlight = CALayer()
    private let badge = ShelfBadgeView()
    private var spinner: NSProgressIndicator?
    private var mouseDownEvent: NSEvent?
    /// 選んである項目を修飾キーなしで押した（離したときにドラッグしていなければ、その項目だけを選び直す）
    private var reselectOnMouseUp = false
    private var modifiedClick = false
    /// いまドラッグで持ち出している項目
    private var dragged: [ShelfItem] = []
    private var thumbnailRequested = false
    private var isMemo: Bool { item.kind == .memo }
    /// サムネイルとアイコンに使う場所（コピーを作っている途中は、まだ元のファイルのほうを見せる）
    private var displayURL: URL { item.status == .copying ? (item.sourceURL ?? item.url) : item.url }

    var isSelected = false {
        didSet { if isSelected != oldValue { updateSelection() } }
    }

    var thumbFrame: NSRect {
        NSRect(x: (Self.width - Self.thumb) / 2, y: 24, width: Self.thumb, height: Self.thumb)
    }

    init(item: ShelfItem, controller: ShelfController?) {
        self.item = item
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true

        hoverLayer.frame = bounds.insetBy(dx: 3, dy: 1)
        hoverLayer.cornerRadius = 10
        hoverLayer.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
        // 選んであるときは Finder と同じく、アイコンの後ろを明るくし、名前をアクセントカラーで囲む
        selectionLayer.frame = thumbFrame.insetBy(dx: -6, dy: -5)
        selectionLayer.cornerRadius = 9
        selectionLayer.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        selectionLayer.opacity = 0
        layer?.addSublayer(selectionLayer)
        nameHighlight.cornerRadius = 4
        nameHighlight.opacity = 0
        layer?.addSublayer(nameHighlight)

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
        badge.frame = NSRect(x: thumbFrame.maxX - ShelfBadgeView.size + 5, y: thumbFrame.minY - 4,
                             width: ShelfBadgeView.size, height: ShelfBadgeView.size)
        addSubview(badge)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 状態や場所が変わったとき
    func update(_ newItem: ShelfItem) {
        guard newItem != item else { return }
        item = newItem
        refresh()
    }

    func refresh() {
        if isMemo {
            memoCard.text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            nameLabel.stringValue = L("メモ", "Note")
        } else {
            nameLabel.stringValue = item.url.lastPathComponent
            if thumbnailRequested { loadThumbnail() }
        }
        // 見つからないものは薄く、コピー中のものはくるくるを重ねる
        let alpha: CGFloat = item.isAvailable ? 1 : item.status == .copying ? 0.45 : 0.35
        imageView.alphaValue = alpha
        memoCard.alphaValue = alpha
        badge.set(item.badge)
        toolTip = item.tooltip
        updateSpinner()
        updateSelection()
    }

    /// サムネイルを作る。閉じた棚では作らず、項目が見えるときに初めて作る（常駐時のメモリを増やさないため）
    func loadThumbnailIfNeeded() {
        guard !thumbnailRequested, !isMemo else { return }
        thumbnailRequested = true
        loadThumbnail()
    }

    private func loadThumbnail() {
        let url = displayURL
        imageView.image = ShelfThumbnails.shared.image(for: url, size: Self.thumb) { [weak self] image in
            guard let self, self.displayURL == url else { return }
            self.imageView.image = image
        }
    }

    private func updateSpinner() {
        if item.status == .copying {
            guard spinner == nil else { return }
            let s = NSProgressIndicator(frame: NSRect(x: thumbFrame.midX - 8, y: thumbFrame.midY - 8, width: 16, height: 16))
            s.style = .spinning
            s.controlSize = .small
            s.appearance = NSAppearance(named: .darkAqua)
            addSubview(s)
            s.startAnimation(nil)
            spinner = s
        } else if let spinner {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
            self.spinner = nil
        }
    }

    private func updateSelection() {
        let textWidth = min(ceil(nameLabel.attributedStringValue.size().width) + 10, Self.width - 4)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        nameHighlight.frame = NSRect(x: (Self.width - textWidth) / 2, y: nameLabel.frame.minY - 0.5,
                                     width: textWidth, height: nameLabel.frame.height + 1)
        nameHighlight.backgroundColor = NSColor.controlAccentColor.cgColor
        selectionLayer.opacity = isSelected ? 1 : 0
        nameHighlight.opacity = isSelected ? 1 : 0
        CATransaction.commit()
        nameLabel.textColor = isSelected ? .white : NSColor(white: 1, alpha: item.isAvailable || isMemo ? 0.88 : 0.5)
    }

    // MARK: マウス

    // TriTab は前面に出ないので、最初のクリックから受け取る
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        controller?.hoveredItem = item.id
        hoverLayer.opacity = 1
    }

    override func mouseExited(with event: NSEvent) {
        if controller?.hoveredItem == item.id { controller?.hoveredItem = nil }
        hoverLayer.opacity = 0
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.control) { return rightMouseDown(with: event) }
        guard let controller else { return }
        modifiedClick = flags.contains(.command) || flags.contains(.shift)
        reselectOnMouseUp = false
        if modifiedClick {
            controller.click(item.id, command: flags.contains(.command), shift: flags.contains(.shift))
        } else if controller.isSelected(item.id) {
            reselectOnMouseUp = true // 選んだものをまとめてドラッグできるよう、押した時点では選び直さない
        } else {
            controller.select(item.id)
        }
        mouseDownEvent = event
        if event.clickCount == 2, !modifiedClick, !isMemo { controller.open([item]) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        if reselectOnMouseUp { controller?.select(item.id) }
        if isMemo, !modifiedClick { controller?.openEditor(item.url) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller else { return }
        controller.popUp(controller.contextMenu(for: item.id), with: event, for: self)
    }

    // MARK: 外へドラッグ

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let controller else { return }
        mouseDownEvent = nil
        reselectOnMouseUp = false
        let items = controller.itemsToDrag(from: item.id)
        guard !items.isEmpty else { return NSSound.beep() } // 見つからない・コピー中
        // 選んだものはそれぞれの位置から持ち上げる
        let views = superview?.subviews.compactMap { $0 as? ShelfItemView } ?? []
        let draggingItems = items.map { item -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let view = views.first { $0.item.id == item.id } ?? self
            d.setDraggingFrame(view.convert(view.thumbFrame, to: self), contents: view.dragImage)
            return d
        }
        dragged = items
        controller.draggingOut = true
        beginDraggingSession(with: draggingItems, event: down, source: self)
    }

    private var dragImage: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        return isMemo ? icon : (imageView.image ?? icon)
    }

    /// 行き先に許す操作は、項目の種類で決める（参照は元のファイルを移動、コピーは棚の複製を移動、メモは書き出すだけ）。
    /// ⌥を押しながらなら、macOS がコピーだけに絞る
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? NSDragOperation(ShelfRules.dragOutOperations(for: dragged.map(\.kind))) : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = dragged.map(\.id)
        dragged = []
        controller?.dragEnded(ids, operation: ShelfDragOperation(operation))
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
