import AppKit
import Carbon.HIToolbox
import os
import QuartzCore
import QuickLookThumbnailing
import QuickLookUI
import TriTabCore
import UniformTypeIdentifiers

// MARK: - 動きの記録

private let traceLog = OSLog(subsystem: "io.github.ikora128.TriTab", category: "trace")

/// トレイの判定と動きを、時刻つきで書き出す（置く・持ち出すがうまくいかないときに、何がいつ起きたかを確かめるため）。
/// 見ているときだけ書く。ふだんは何もしない。ファイル名などの中身は書かない。見るとき:
///   log stream --level debug --predicate 'subsystem == "io.github.ikora128.TriTab" AND category == "trace"'
func shelfTrace(_ message: @autoclosure () -> String) {
    guard traceLog.isEnabled(type: .debug) else { return }
    os_log(.debug, log: traceLog, "%{public}@", message())
}

/// 記録用: いまマウスの下にあるウィンドウ（持ち主のアプリと重なりの高さ）
func shelfWindowUnderPointer() -> String {
    let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
    guard number > 0,
          let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
    else { return "none" }
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    return "\(owner)@\(layer)"
}

// MARK: - アニメーション

/// トレイの出入りの動き。rawValue は保存済みの設定と互換にしてある
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

    /// 横・縦それぞれの進み方（0 → 1）。quick なら同じ動きを半分ほどの時間で（ファイルを持ってきているあいだ。待たせないため）
    fileprivate func curves(growing: Bool, quick: Bool = false) -> (width: Curve, height: Curve) {
        let c = baseCurves(growing: growing)
        return quick ? (c.width.faster(0.55), c.height.faster(0.55)) : c
    }

    private func baseCurves(growing: Bool) -> (width: Curve, height: Curve) {
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

    /// 同じ形のまま、時間だけ縮めた曲線
    func faster(_ scale: Double) -> Curve {
        switch self {
        case let .spring(response, damping): return .spring(response: response * scale, damping: damping)
        case let .easeOut(duration): return .easeOut(duration: duration * scale)
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

// MARK: - トレイ

/// ノッチのトレイ。
///
/// - ファイルをドラッグして少し上へ動かすと、ノッチから顔を出す。上端の真ん中のまわりまで来ると、広げて待つ
///   （どこで広げ・引っ込めるかは位置だけで決める。ShelfRules.approach）
/// - ブラウザの画像（ドラッグ元が書き出すファイル）や画像のデータも同じように受け取り、トレイの中に保存する。
///   リンク（.webloc にする）とテキスト（メモにする）は、ノッチやトレイまで持ってきたときだけ開く
/// - 置き方（参照 / コピー）はトレイの上の帯のスイッチ（設定と同じ値）で決める。ドラッグ中に ⌥ でコピー、⌘⌥ で参照にもできる。
///   一時フォルダのファイルは、参照にするとすぐ見つからなくなるのでコピーで置く。
///   一度に複数を置いたら、1 つのまとめにする（Yoink のスタックと同じ。右クリックで 1 つずつに分けられる）
/// - ノッチにマウスを乗せる / クリックしても開く。開いているあいだ ⌘V で貼り付け（ファイルはスイッチの置き方）、⌘N で新しいメモ
/// - 項目にマウスを乗せてスペースで Quick Look。画像や PDF はサムネイルで見せる
/// - ⌘クリック・⇧クリック・⌘A で選び、まとめてドラッグできる。右クリックで「Finder で表示」など（ShelfActions.swift）
/// - 中身は再起動しても戻る（ShelfLibrary）。設定で決めた期間がたった項目は、古いものから自動で削除する。
///   空で閉じたらウィンドウごと破棄してメモリを返す
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
    /// このドラッグの中身を見た（1 回のドラッグにつき 1 度だけ見る）
    private var dragChecked = false
    /// このドラッグが持っているもの（トレイが受け取れないものなら nil）
    private var dragContent: ShelfDropContent?
    private var lowestY: CGFloat = 0
    /// 直前に位置を見た時刻（メインスレッドが詰まって、見る間があいたことを記録するため）
    private var lastPoll: CFTimeInterval = 0
    /// 直前の判定（変わったときだけ記録する）
    private var lastApproach: ShelfApproach?
    /// ドラッグの終わりの知らせ（draggingEnded）が、離したことに気づくより先に届いた
    private var sessionEndedBeforeRelease = false

    private var settleWork: DispatchWorkItem?
    /// トレイから外へドラッグしている最中
    var draggingOut = false
    /// ほかのアプリから持ってきている最中のもの（トレイで受け取る）
    private(set) var receiving: ShelfDropContent? {
        didSet {
            guard receiving != oldValue else { return }
            panel?.receivingDragChanged()
            updateCatcher()
        }
    }
    /// 持ってきているあいだ、広げたトレイに重ねる受け取り用のウィンドウ
    private var catcher: ShelfDropCatcher?
    var receivingDrag: Bool { receiving != nil }
    /// 置いてからこの秒数がたった項目を、自動で削除する（nil なら削除しない）
    var autoRemoveAfter: TimeInterval? {
        didSet {
            guard autoRemoveAfter != oldValue else { return }
            removeExpiredItems()
            panel?.refreshItemViews() // ツールチップの「削除されるころ」を書き直す
        }
    }
    private var expiryTimer: Timer?
    /// 置くときの置き方（トレイの上の帯のスイッチと、設定で切り替える）
    var dropMode: ShelfDropMode = .reference {
        didSet { if dropMode != oldValue { panel?.dropModeChanged() } }
    }
    /// トレイのスイッチで置き方を変えたとき（設定に書き戻す）
    var onDropModeChange: ((ShelfDropMode) -> Void)?
    /// 右クリックメニューを開いているあいだ（トレイを閉じない）
    var menuOpen = false
    /// マウスが乗っている項目（スペースで Quick Look する対象）
    var hoveredItem: UUID?
    private var previewCaption: String?
    fileprivate let quickLook = ShelfQuickLook()
    let library = ShelfLibrary(directory: ShelfController.shelfDirectory, memoDirectory: ShelfController.memoDirectory)
    /// ファイルの場所を確かめる・参照のブックマークを作る（iCloud Drive の中などは時間がかかるので、メインスレッドの外で順に）
    private let fileQueue = DispatchQueue(label: "io.github.ikora128.TriTab.shelf-files", qos: .userInitiated)
    /// 参照からコピーへ切り替えている途中の項目の、切り替える前（失敗したら戻す。終わるまでは参照のまま保存する）
    private var conversions: [UUID: ShelfItem] = [:]
    /// コピーを作っている途中の項目: 項目の id → まだ終わっていないファイルと、失敗したファイル
    private var copyJobs: [UUID: (pending: Set<UUID>, failed: Set<UUID>)] = [:]

    private override init() {
        super.init()
        // 0.1.0 が貼り付けた画像を置いていた一時フォルダを片付ける（いまはトレイの中に置く）
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

        // 前回のトレイの中身（メモ・コピー・参照）を戻し、期間がたったものは削除する
        items = library.load()
        removeExpiredItems()
        if !items.isEmpty { DispatchQueue.main.async { self.show(.collapsed) } }
        // 受け口のアイコンを描いておく（最初にファイルを持ってきたときに待たせない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ShelfDropIcons.prepare() }
        // 期間がたったかは 10 分おきに見る（日単位の設定なので、これで足りる）
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.removeExpiredItems() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func stop() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dragPoll?.invalidate()
        dragPoll = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        detectors.forEach { $0.orderOut(nil) }
        detectors = []
        items = [] // 保存した一覧はそのまま（もう一度オンにしたら戻る）
        selection.clear()
        receiving = nil
        dragChecked = false
        dragContent = nil
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
            w.onDragArrive = { [weak self] content in self?.dragArrived(content, on: screen) }
            w.onDrop = { [weak self] pasteboard, mode in self?.receive(from: pasteboard, as: mode) ?? false }
            w.dropMode = { [weak self] in self?.dropMode ?? .reference }
            w.orderFrontRegardless()
            return w
        }
    }

    // MARK: ドラッグの追跡

    private func mouseDown() {
        // ほかのアプリで押せたなら、トレイから外へのドラッグはもう終わっている（始まらずに終わったものの印が残っていても消す）
        draggingOut = false
        dragChangeCountAtDown = NSPasteboard(name: .drag).changeCount
        dragChecked = false
        dragContent = nil
        sessionEndedBeforeRelease = false
        lowestY = NSEvent.mouseLocation.y
        lastPoll = CACurrentMediaTime()
        lastApproach = nil
        shelfTrace("in.press state=\(state)")
        dragPoll?.invalidate()
        // ドラッグ＆ドロップ中のマウス移動はほかのアプリに届かないので、押しているあいだだけ位置を見る
        dragPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastPoll > 0.05 { shelfTrace("stall poll \(Int((now - self.lastPoll) * 1000))ms") }
            self.lastPoll = now
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
        if !dragChecked {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragChangeCountAtDown else { return } // まだドラッグになっていない
            dragChecked = true
            dragContent = ShelfDrop.content(of: pb)
            shelfTrace("in.drag content=\(dragContent.map { "\($0)" } ?? "none") out=\(draggingOut)")
            if let dragContent, !draggingOut { receiving = dragContent }
        }
        guard let content = dragContent, !draggingOut,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else { return }

        let fromTop = Double(screen.frame.maxY - loc.y)
        let fromCenter = Double(abs(loc.x - screen.frame.midX))
        let risen = Double(loc.y - lowestY)
        let area = ShelfGeometry.receiveArea(itemCount: items.count, on: screen)
        let overTray = panel?.containsMouse == true || pointerInDropArea
        // 広げたあとで範囲から離れていったら引っ込める（ほかの場所へ落とすのを邪魔しない）
        if state == .large, !overTray, ShelfRules.shouldRetract(fromTop: fromTop, fromCenter: fromCenter, area: area) {
            shelfTrace("in.retract top=\(Int(fromTop)) dx=\(Int(fromCenter))")
            show(content.opensOnApproach ? .peek : items.isEmpty ? .hidden : .collapsed, on: screen)
            return
        }
        guard content.opensOnApproach else { return } // リンクとテキストは、ノッチかトレイまで来たときだけ（dragArrived）
        let approach = ShelfRules.approach(fromTop: fromTop, fromCenter: fromCenter, risen: risen, area: area)
        if approach != lastApproach {
            shelfTrace("in.judge \(approach) top=\(Int(fromTop)) dx=\(Int(fromCenter)) risen=\(Int(risen)) state=\(state) overTray=\(overTray)")
            lastApproach = approach
        }
        switch approach {
        case .open:
            if state != .large { show(.large, on: screen) }
        case .peek:
            if state == .hidden || state == .collapsed { show(.peek, on: screen) }
        case .none:
            break
        }
    }

    private func mouseUp() {
        let carried = dragContent != nil
        let ended = sessionEndedBeforeRelease
        dragChecked = false
        dragContent = nil
        sessionEndedBeforeRelease = false
        guard carried else {
            receiving = nil
            return
        }
        let overTray = panel?.containsMouse == true || pointerInDropArea
        shelfTrace("in.release state=\(state) overTray=\(overTray) ended=\(ended)")
        if ended {
            // ドラッグの終わりの知らせは先に届いている（もう何も届かない）
            finishReceiving()
            return
        }
        if overTray, receiving != nil {
            // トレイの上で離した: このあと、落としたものの受け取り（performDragOperation）か、ドラッグの終わりの知らせ
            // （draggingEnded → receiveSessionEnded）が届く。片付けて中身を見せるのはそちらに任せる。
            // 位置を見ているほうが先に気づいてここで片付けると、受け取りの前に表示の作り直しが走ってドラッグ元を待たせ、
            // 受け取り用のウィンドウを先に下げてしまうこともある。どちらも届かなかったときのために、少しあとで確かめる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.dragContent == nil else { return } // もう次のドラッグが始まっている
                if self.receiving != nil || self.state == .large { self.finishReceiving() } else { self.scheduleSettle(after: 0.3) }
            }
            return
        }
        // ほかの場所で離した。ドロップの処理が終わってから落ち着かせる
        receiving = nil
        scheduleSettle(after: 0.3)
    }

    /// 持ってきたものの受け取りが終わった（落とした・やめた）。トレイの上なら中身を見せ、それから落ち着かせる。
    /// 中身を見せるのは、ドラッグ元への返事のあと（ドラッグの終わりの知らせの中でトレイを開き直すと、
    /// 項目を並べ直して描くあいだドラッグ元を待たせる。起動して最初に開くときは 100 ms ほどかかる）
    private func finishReceiving() {
        let overTray = panel?.containsMouse == true || pointerInDropArea
        receiving = nil
        guard overTray else {
            scheduleSettle(after: 0.3)
            return
        }
        afterDragReply { [weak self] in
            guard let self else { return }
            if self.state == .large { self.show(.open) }
            self.scheduleSettle(after: 0.3)
        }
    }

    // MARK: ドラッグ元への返事のあとで

    /// ドラッグ元への返事のあとで動かす処理
    private var afterReplyWork: [() -> Void] = []
    private var afterReplyMonitor: Any?
    private static let afterReplySubtype: Int16 = 0x5454

    /// ドラッグ元への返事が済んでから動かす。
    /// ドラッグの知らせ（落とした・終わった）を受けているあいだと、そのあと AppKit が返事の前に回すあいだ
    /// （画面の描画や、DispatchQueue.main.async の中身もここで動く）は、ドラッグ元が返事を待っている。
    /// アプリのイベントとして積んでおくと、知らせの処理が終わって次のイベントを取り出すときに動く
    func afterDragReply(_ work: @escaping () -> Void) {
        afterReplyWork.append(work)
        guard afterReplyWork.count == 1 else { return } // もう積んである
        if afterReplyMonitor == nil {
            afterReplyMonitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
                guard event.subtype.rawValue == Self.afterReplySubtype else { return event }
                self?.runAfterReplyWork()
                return nil
            }
        }
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, subtype: Self.afterReplySubtype, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        } else {
            DispatchQueue.main.async { self.runAfterReplyWork() }
        }
    }

    private func runAfterReplyWork() {
        let work = afterReplyWork
        afterReplyWork = []
        work.forEach { $0() }
    }

    /// 受け取れるものを持ったまま、トレイかノッチに入ってきた。すぐにトレイを広げる
    /// （リンクとテキストはここで初めて開く。ドラッグの追跡で気づけなかったときも、ここで広げる）
    func dragArrived(_ content: ShelfDropContent, on screen: NSScreen? = nil) {
        shelfTrace("in.arrive content=\(content) state=\(state) out=\(draggingOut)")
        guard !draggingOut else { return }
        receiving = content
        if state != .large { show(.large, on: screen) }
    }

    /// トレイの上を通ったドラッグが終わった。ドラッグの追跡がまだ離したことに気づいていなければ、気づいたとき（mouseUp）に任せる
    func receiveSessionEnded() {
        guard !dragChecked else {
            sessionEndedBeforeRelease = true
            return
        }
        finishReceiving()
    }

    // MARK: 中身

    /// ファイルをトレイに置く。一度に 2 つ以上を置いたら、1 つのまとめにする（Yoink のスタックと同じ）。
    /// コピーはトレイの中に複製を作り（作り終わるまで印を出す）、参照は元のファイルを指すだけ。
    /// 参照で置くときも、一時フォルダのファイル（スクリーンショットのサムネイルなど）は、すぐ消えるのでコピーにする
    func add(_ urls: [URL], as mode: ShelfDropMode) {
        var files: [ShelfItem] = []
        var sources: [UUID: URL] = [:]
        for url in urls {
            if mode == .reference, !ShelfRules.isTemporary(url) {
                // 1 つだけ置くときは、同じファイルの参照がもうあれば足さない
                let path = url.standardizedFileURL.path
                if urls.count == 1, items.contains(where: { !$0.isGroup && $0.kind == .reference && $0.url.standardizedFileURL.path == path }) {
                    continue
                }
                files.append(ShelfItem(kind: .reference, url: url)) // ブックマークはあとで作る（fillBookmarks）
            } else {
                let file = library.plannedCopy(of: url)
                files.append(file)
                sources[file.id] = url
            }
        }
        guard !files.isEmpty else { return }
        let item = ShelfItem.group(files)
        if !sources.isEmpty { startCopies(item, sources: sources) }
        insert([item])
        fillBookmarks(of: item)
    }

    /// 参照のブックマーク（元が移動・名前変更されても追えるようにするもの）を作って保存する。
    /// iCloud Drive の中のファイルなどは時間がかかるので、置いた瞬間を待たせないようメインスレッドの外で作る
    private func fillBookmarks(of item: ShelfItem) {
        let targets = item.files.filter { $0.kind == .reference && $0.bookmark == nil }.map { (id: $0.id, url: $0.url) }
        guard !targets.isEmpty else { return }
        fileQueue.async { [weak self] in
            let made = targets.compactMap { t in (try? t.url.bookmarkData()).map { (id: t.id, data: $0) } }
            guard !made.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for m in made {
                    // まとめを分けたあとでも見つかるよう、ファイルの id で探す
                    guard let i = self.items.firstIndex(where: { $0.files.contains { $0.id == m.id } }) else { continue }
                    self.items[i].updateFile(m.id) { if $0.kind == .reference, $0.bookmark == nil { $0.bookmark = m.data } }
                }
                self.save()
            }
        }
    }

    /// トレイのスイッチで置き方を変えた
    func switchDropMode(to mode: ShelfDropMode) {
        dropMode = mode
        onDropModeChange?(mode)
    }

    /// 落とされたもの・貼り付けたものをトレイに入れる（何として受け取るかは ShelfDrop.content の順）。
    /// ファイルはスイッチの置き方、ドラッグ元が書き出すファイルと画像はトレイの中に保存、リンクは .webloc、テキストはメモにする
    @discardableResult
    func receive(from pb: NSPasteboard, as mode: ShelfDropMode, promises: Bool = true) -> Bool {
        let started = CACurrentMediaTime()
        defer { shelfTrace("in.receive \(Int((CACurrentMediaTime() - started) * 1000))ms") }
        receiving = nil
        switch ShelfDrop.content(of: pb, promises: promises) {
        case .files?:
            add(ShelfDrop.fileURLs(in: pb), as: mode)
        case .promisedFiles?:
            let receivers = ShelfDrop.promises(in: pb)
            // 約束を読み取れなければ、一緒に持っている画像やリンクとして受け取る
            guard !receivers.isEmpty else { return receive(from: pb, as: mode, promises: false) }
            receivePromises(receivers)
        case .image?:
            guard let image = ShelfDrop.imageData(in: pb),
                  let item = library.store(image.data, name: "\(L("画像", "Image")) \(Self.stamp()).\(image.ext)") else { return false }
            insert([item])
        case .link?:
            guard let url = ShelfDrop.webURL(in: pb),
                  let item = library.storeLink(url, title: ShelfDrop.linkTitle(in: pb)) else { return false }
            insert([item])
        case .text?:
            guard let text = ShelfDrop.text(in: pb), createMemo(text) != nil else { return false }
        case nil:
            return false
        }
        return true
    }

    private func insert(_ new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        itemsChanged()
        panel?.bounce()
    }

    /// トレイの中身が変わったら、選択・表示・保存をそろえる
    private func itemsChanged() {
        selection.keep(items.map(\.id))
        panel?.itemsChanged(items)
        panel?.selectionChanged()
        save()
    }

    /// 一覧を保存する（コピーへ切り替えている途中の項目は、終わるまで参照のまま）
    private func save() {
        library.save(items.map { conversions[$0.id] ?? $0 })
    }

    /// トレイから外す。コピーとメモはゴミ箱へ（戻せる）。参照の元のファイルには触らない
    func remove(_ ids: [UUID]) {
        let gone = items.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for item in gone {
            conversions[item.id] = nil // コピーを作っている途中なら、作り終わったところで片付ける（copyFinished）
            item.files.forEach { ShelfThumbnails.shared.forget($0.url) }
            library.discard(item)
        }
        itemsChanged()
        if items.isEmpty { scheduleSettle(after: 0.4) }
    }

    func removeAll() {
        remove(items.map(\.id))
    }

    /// 外へのドラッグが終わった。移動として受け取られたファイルはトレイから外す（コピーやエイリアスなら残す。ShelfRules）。
    /// まとめは、持ち出したファイルが全部移動したら消え、残りがあればそのまま残る
    func dragEnded(_ dragged: [ShelfItem], operation: ShelfDragOperation) {
        shelfTrace("out.end operation=\(operation) state=\(state)")
        draggingOut = false
        var moved: [(itemID: UUID, file: ShelfItem)] = []
        for d in dragged where !ShelfRules.staysOnShelf(d.kind, after: operation) {
            guard let i = items.firstIndex(where: { $0.id == d.id }) else { continue }
            let ids = Set(d.files.map(\.id))
            moved += items[i].files.filter { ids.contains($0.id) }.map { (d.id, $0) }
            if let rest = items[i].removingFiles(ids) { items[i] = rest } else { items.remove(at: i) }
        }
        if !moved.isEmpty {
            for (_, file) in moved {
                ShelfThumbnails.shared.forget(file.url)
                library.cleanUpAfterMove(file)
            }
            itemsChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restoreUnmoved(moved) }
        }
        scheduleSettle(after: 0.3)
    }

    /// 移動として受け取られたのに、ファイルが元の場所に残っているものをトレイに戻す
    /// （Finder の「同じ名前があります」で中止した、移動と返して読んだだけのアプリ、など）。
    /// 移動されたコピーの、空になったフォルダはここで片付ける
    private func restoreUnmoved(_ moved: [(itemID: UUID, file: ShelfItem)]) {
        let exists = { (file: ShelfItem) in FileManager.default.fileExists(atPath: file.url.path) }
        moved.filter { !exists($0.file) }.forEach { library.cleanUpAfterMove($0.file) }
        guard enabled else { return }
        let onShelf = Set(items.flatMap(\.files).map(\.id))
        let unmoved = moved.filter { exists($0.file) && !onShelf.contains($0.file.id) }
        guard !unmoved.isEmpty else { return }
        // もとの項目ごとに戻す（まとめが残っていれば、その中へ）
        var back: [ShelfItem] = []
        for itemID in unmoved.map(\.itemID).reduce(into: [UUID](), { if !$0.contains($1) { $0.append($1) } }) {
            let files = unmoved.filter { $0.itemID == itemID }.map(\.file)
            if let i = items.firstIndex(where: { $0.id == itemID && $0.isGroup }) {
                items[i].members += files
                items[i].updateGroupState()
            } else {
                back.append(ShelfItem.group(files, id: itemID))
            }
        }
        if back.isEmpty { itemsChanged() } else { insert(back) }
    }

    /// 元のファイルが動いた・消えたかを確かめ直す（トレイを開くとき・ドラッグやメニューの前）
    func refreshItems(_ ids: [UUID]? = nil) {
        var changed = false
        for i in items.indices where ids?.contains(items[i].id) ?? true {
            if library.refresh(&items[i]) { changed = true }
        }
        if changed { itemsChanged() }
    }

    /// refreshItems をメインスレッドの外で行う（開いたとき）。
    /// 調べているあいだに変わらなかった項目にだけ結果を入れる（置いた・外した・コピーが終わった項目はそのまま）
    private func refreshItemsInBackground() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        let library = self.library
        fileQueue.async { [weak self] in
            var fresh: [ShelfItem] = []
            for var item in snapshot {
                if library.refresh(&item) { fresh.append(item) }
            }
            guard !fresh.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                var changed = false
                for item in fresh {
                    guard let i = self.items.firstIndex(where: { $0.id == item.id }),
                          let before = snapshot.first(where: { $0.id == item.id }), self.items[i] == before else { continue }
                    self.items[i] = item
                    changed = true
                }
                if changed { self.itemsChanged() }
            }
        }
    }

    /// ⌘V: クリップボードの中身をトレイに入れる（ファイル → スイッチの置き方、画像 → 画像ファイル、リンク → .webloc、テキスト → メモ）
    func paste() {
        if !receive(from: .general, as: dropMode, promises: false) { NSSound.beep() }
    }

    // MARK: ドラッグ元が書き出すファイル

    /// ファイルの約束を受け取る順番待ち（ファイルが書き終わるのを待つので、メインスレッドの外で）
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// ドラッグ元が書き出すファイル（ブラウザの画像、写真、メールの添付など）を、トレイの中のフォルダに書いてもらう。
    /// 届くまでは「コピー中」の項目として置き、届いたものから使えるようにする（届かなかったものは外す）
    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let placeholders = receivers.map { _ -> ShelfItem in
            let id = UUID()
            return ShelfItem(id: id, kind: .copy, url: library.copyLocation(id, name: L("受け取り中", "Receiving")), status: .copying)
        }
        let item = ShelfItem.group(placeholders)
        copyJobs[item.id] = (Set(placeholders.map(\.id)), [])
        insert([item])
        for (receiver, file) in zip(receivers, placeholders) {
            let folder = library.copyFolder(file.id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) { [weak self] url, error in
                let ok = error == nil && Self.waitUntilExists(url)
                DispatchQueue.main.async { self?.promiseDelivered(item.id, file: file.id, url: ok ? url : nil) }
            }
        }
    }

    /// 書き終わったと知らせが来ても、古い形式の受け渡しではファイルがまだ見えないことがある。少しだけ待つ
    private static func waitUntilExists(_ url: URL) -> Bool {
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: url.path) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 約束したファイルが届いた（url が nil なら失敗）
    private func promiseDelivered(_ itemID: UUID, file fileID: UUID, url: URL?) {
        let placeholder = items.first { $0.id == itemID }?.files.first { $0.id == fileID }
        if let url, let placeholder, placeholder.status != .copying {
            // 1 つの約束で 2 つ目のファイルが届いた（まれ）: 自分のフォルダへ移して、別の項目として置く
            let id = UUID()
            let destination = library.copyLocation(id, name: url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                insert([ShelfItem(id: id, kind: .copy, url: destination)])
            } catch {
                library.removeCopyFolder(id)
            }
            return
        }
        if let url, let i = items.firstIndex(where: { $0.id == itemID }) {
            items[i].updateFile(fileID) { $0.url = url } // 名前はドラッグ元が決める
        }
        copyFinished(itemID, file: fileID, ok: url != nil)
    }

    // MARK: コピー

    /// 項目の中のファイルを、それぞれトレイの中へ複製する（sources: ファイルの id → 複製のもと）
    private func startCopies(_ item: ShelfItem, sources: [UUID: URL]) {
        copyJobs[item.id] = (Set(sources.keys), [])
        for file in item.files {
            guard let source = sources[file.id] else { continue }
            let itemID = item.id, fileID = file.id, destination = file.url
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = (try? ShelfLibrary.copy(from: source, to: destination)) != nil
                DispatchQueue.main.async { self?.copyFinished(itemID, file: fileID, ok: ok) }
            }
        }
    }

    private func copyFinished(_ itemID: UUID, file fileID: UUID, ok: Bool) {
        guard var job = copyJobs[itemID] else { return library.removeCopyFolder(fileID) }
        job.pending.remove(fileID)
        if !ok { job.failed.insert(fileID) }
        copyJobs[itemID] = job.pending.isEmpty ? nil : job
        guard let i = items.firstIndex(where: { $0.id == itemID }) else {
            library.removeCopyFolder(fileID) // 作っている途中でトレイから外された
            if job.pending.isEmpty { conversions[itemID] = nil }
            return
        }
        if ok { items[i].setStatus(.ready, ofFile: fileID) }
        if job.pending.isEmpty {
            let original = conversions.removeValue(forKey: itemID)
            if !job.failed.isEmpty {
                NSSound.beep()
                if let original {
                    // 参照からの切り替え: 1 つでも失敗したら、作ったコピーを消して参照に戻す
                    items[i].files.forEach { library.removeCopyFolder($0.id) }
                    items[i] = original
                } else {
                    // 新しく置いたコピー: 失敗したファイルだけ外す
                    job.failed.forEach { library.removeCopyFolder($0) }
                    if let rest = items[i].removingFiles(job.failed) { items[i] = rest } else { items.remove(at: i) }
                }
            }
        }
        itemsChanged()
    }

    /// 参照で置いたものを、トレイの中のコピーに切り替える（元のファイルはそのまま）
    func makeCopies(_ ids: [UUID]) {
        refreshItems(ids)
        for i in items.indices where ids.contains(items[i].id) && items[i].kind == .reference && items[i].isAvailable
            && copyJobs[items[i].id] == nil {
            let original = items[i]
            var sources: [UUID: URL] = [:]
            let copies = original.files.filter(\.isAvailable).map { file -> ShelfItem in
                sources[file.id] = file.url
                var copy = library.plannedCopy(of: file.url, id: file.id)
                copy.addedAt = file.addedAt // 置いた日時は、参照で置いたときのまま
                return copy
            }
            let converted = ShelfItem.group(copies, id: original.id)
            conversions[converted.id] = original
            items[i] = converted
            startCopies(converted, sources: sources)
        }
        itemsChanged()
    }

    /// まとめを 1 つずつの項目に分ける（同じ場所に並べる）
    func ungroup(_ ids: [UUID]) {
        items = items.flatMap { item in
            ids.contains(item.id) && item.isGroup && copyJobs[item.id] == nil ? item.members : [item]
        }
        itemsChanged()
    }

    func isCopying(_ id: UUID) -> Bool { copyJobs[id] != nil }

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
        followInQuickLook(id)
    }

    /// 矢印キー: 選択を隣の項目へ動かし（⇧ なら広げる）、選んだ項目が見える段までスクロールする
    func moveSelection(_ direction: ShelfSelection<UUID>.Direction, extend: Bool) {
        guard selection.move(direction, in: items.map(\.id), columns: panel?.columns ?? 1, extend: extend, start: hoveredItem) else { return }
        panel?.selectionChanged()
        if let focus = selection.focus { panel?.scrollToItem(focus) }
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

    /// 選んである項目（トレイの並び順）
    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    /// その項目からドラッグを始めたときに持ち出すもの。選んであればまとめて。使えないもの（見つからない・コピー中）は外す。
    /// つかんだ瞬間に待たせないよう、ファイルがいまの場所にあるかだけを確かめる
    /// （場所はトレイを開いたときに確かめ直してある。見つからない参照だけ、ブックマークで追い直す）
    func itemsToDrag(from id: UUID) -> [ShelfItem] {
        let ids = selection.dragItems(from: id, in: items.map(\.id))
        var changed = false
        for i in items.indices where ids.contains(items[i].id) {
            if library.quickRefresh(&items[i]) { changed = true }
        }
        if changed { itemsChanged() }
        guard items.first(where: { $0.id == id })?.isAvailable == true else { return [] }
        return items.filter { ids.contains($0.id) && $0.isAvailable }.map { $0.keepingAvailableFiles() }
    }

    /// 開いているトレイの上でのキー操作（イベントタップから呼ばれる。true を返すと前面のアプリに届かない）
    /// - ⌘V: 貼り付け（ファイルはスイッチの置き方）/ ⌘N: 新しいメモ / ⌘A: すべて選択 / esc: 選択を外す
    /// - スペース: Quick Look / 矢印: 選択を隣の項目へ（⇧ を押しながらなら広げる）
    func handleKeyDown(_ event: CGEvent) -> Bool {
        guard !MemoEditor.shared.isOpen, let panel else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        let arrow = Self.arrowDirection(keyCode)

        // Quick Look が開いているあいだ: スペース / esc で閉じる、矢印で前後の項目へ。
        // 前面のアプリから入力先を奪わずに操作できるよう、TriTab がキーを受けて Quick Look を動かす
        if previewing, flags.isEmpty {
            if keyCode == Int64(kVK_Space) || keyCode == Int64(kVK_Escape) {
                DispatchQueue.main.async { self.closeQuickLook() }
                return true
            }
            if let arrow {
                DispatchQueue.main.async { self.stepQuickLook(by: arrow == .left || arrow == .up ? -1 : 1) }
                return true
            }
        }
        // トレイから持ち出しているあいだはキーを受けない（esc がドラッグをやめる操作として届くように）
        guard state == .open || state == .large, panel.containsMouse, !draggingOut else { return false }

        if let arrow, flags.subtracting(.maskShift).isEmpty {
            guard !items.isEmpty else { return false }
            let extend = flags.contains(.maskShift)
            DispatchQueue.main.async { self.moveSelection(arrow, extend: extend) }
            return true
        }
        switch (keyCode, flags) {
        case (Int64(kVK_ANSI_V), [.maskCommand]):
            DispatchQueue.main.async { self.paste() }
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

    private static func arrowDirection(_ keyCode: Int64) -> ShelfSelection<UUID>.Direction? {
        switch Int(keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        default: return nil
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
    /// トレイの一覧と、トレイに作ったコピーの置き場所
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

    /// Quick Look の 1 枚ごとの、持ち主の項目（まとめは中のファイルを全部見せるので、1 枚と 1 項目は対応しない）
    private var quickLookOwners: [UUID] = []
    /// Quick Look で全部の項目を見せている（矢印で動かすと、選択もついていく）
    private var quickLookFollowsSelection = false

    /// スペース。2 つ以上選んであればそれだけを、そうでなければ全部を見せる。
    /// 全部を見せるときは、選んである項目（なければマウスが乗っている項目）から始め、矢印で選択ごと動かせる（Finder と同じ）
    func showQuickLook() {
        if selection.count >= 2 {
            showQuickLook(selectedItems, start: selection.focus)
        } else {
            showQuickLook(items, start: selectedItems.first?.id ?? hoveredItem, followSelection: true)
        }
    }

    func showQuickLook(_ targets: [ShelfItem], start: UUID? = nil, followSelection: Bool = false) {
        var files: [ShelfItem] = []
        var owners: [UUID] = []
        for item in targets where item.isAvailable {
            for file in item.files where file.isAvailable { // まとめは中のファイルを全部
                files.append(file)
                owners.append(item.id)
            }
        }
        guard let panel, !files.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        quickLook.items = files.map(\.url)
        quickLookOwners = owners
        quickLookFollowsSelection = followSelection
        quickLook.sourceFrame = { [weak panel] url in panel?.screenFrame(of: url) ?? .zero }
        quickLook.onClose = { [weak self] in self?.quickLookEnded() }
        // 中身は直接渡す（TriTab は前面に出ないので、レスポンダチェーン経由では渡らない）
        ql.dataSource = quickLook
        ql.delegate = quickLook
        ql.reloadData()
        ql.currentPreviewItemIndex = (start ?? hoveredItem).flatMap { owners.firstIndex(of: $0) } ?? 0
        ql.orderFront(nil)
    }

    /// Quick Look の矢印: 前後のファイルへ。全部を見せているときは、選択もその項目へ動かす
    private func stepQuickLook(by step: Int) {
        guard previewing, let ql = QLPreviewPanel.shared() else { return }
        let n = quickLook.items.count
        guard n > 0 else { return }
        let index = (ql.currentPreviewItemIndex + step + n) % n
        ql.currentPreviewItemIndex = index
        guard quickLookFollowsSelection, quickLookOwners.indices.contains(index) else { return }
        let id = quickLookOwners[index]
        if !(selection.count == 1 && selection.contains(id)) {
            selection.select(id)
            panel?.selectionChanged()
        }
        panel?.scrollToItem(id)
    }

    /// Quick Look を開いたまま項目をクリックしたら、その項目を見せる
    private func followInQuickLook(_ id: UUID) {
        guard quickLookFollowsSelection, previewing, let i = quickLookOwners.firstIndex(of: id) else { return }
        QLPreviewPanel.shared()?.currentPreviewItemIndex = i
    }

    /// Quick Look の画面を前もって作っておく（最初にスペースを押したときに待たせない）。
    /// 開いて少したってから、起動しているあいだに 1 度だけ
    private func prepareQuickLook() {
        guard !QLPreviewPanel.sharedPreviewPanelExists(), items.contains(where: \.isAvailable) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.state == .open, !self.receivingDrag, !QLPreviewPanel.sharedPreviewPanelExists() else { return }
            _ = QLPreviewPanel.shared()
        }
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

    /// トレイをその状態にする
    func show(_ target: State, on screen: NSScreen? = nil) {
        settleWork?.cancel()
        settleWork = nil
        guard target != state else { return }
        shelfTrace("show \(state) → \(target) receiving=\(receivingDrag) out=\(draggingOut)")
        defer { updateCatcher() }
        let wasOpen = state == .open || state == .large
        state = target
        if target == .open || target == .large {
            // 開くたびに、元のファイルが動いた・消えたかを確かめる。メインスレッドの外で調べる
            // （iCloud Drive の中などは時間がかかり、開く動きやドラッグの受け取りを待たせてしまうため）。
            // 持ってきているあいだは項目を見せないので確かめない（受け取りの最中に表示を作り直して、待たせないように）
            if !wasOpen, !receivingDrag { refreshItemsInBackground() }
            if target == .open { prepareQuickLook() }
        } else {
            clearSelection() // 選択はトレイを閉じると外れる
        }

        if target == .hidden {
            panel?.animate(to: .hidden, style: style, quick: false, caption: previewCaption) { [weak self] in
                guard let self, self.state == .hidden else { return }
                self.panel?.orderOut(nil)
                self.panel = nil // ウィンドウごと破棄してメモリを返す
            }
            return
        }
        let p = panel ?? ShelfPanel(controller: self, screen: screen ?? ShelfGeometry.preferredScreen)
        panel = p
        p.orderFrontRegardless()
        // ファイルを持ってきているあいだは、同じ動きを速めにする（待たせずに置けるように）
        p.animate(to: target, style: style, quick: receivingDrag, caption: previewCaption, completion: nil)
    }

    /// 持ってきているあいだ、広げたトレイに受け取り用のウィンドウを重ねる（ShelfDropCatcher）。
    /// 出したら大きさを変えず、広げたトレイでなくなるか、持ってきたものがなくなったら片付ける
    private func updateCatcher() {
        guard state == .large, receiving != nil, let panel else {
            guard catcher?.isVisible == true else { return }
            // ドロップを受けている最中にも呼ばれるので、片付けは受け取りの処理が終わってから
            DispatchQueue.main.async { [weak self] in
                guard let self, !(self.state == .large && self.receiving != nil), self.catcher?.isVisible == true else { return }
                shelfTrace("catcher hide")
                self.catcher?.orderOut(nil)
            }
            return
        }
        let c = catcher ?? ShelfDropCatcher()
        catcher = c
        c.target = panel.dropTarget
        let area = panel.dropArea
        guard !c.isVisible || c.frame != area else { return }
        c.setFrame(area, display: false)
        c.orderFrontRegardless()
        shelfTrace("catcher show \(Int(area.width))x\(Int(area.height))")
    }

    /// 持ってきたものを受け取る範囲（広げたトレイと、そのまわり）にマウスがあるか
    private var pointerInDropArea: Bool {
        guard let catcher, catcher.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, catcher.frame, false)
    }

    func pointerMoved(inside: Bool) {
        shelfTrace("pointer \(inside ? "in" : "out") state=\(state)")
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
            if self.panel?.containsMouse == true || self.draggingOut || self.dragContent != nil || self.menuOpen
                || MemoEditor.shared.isOpen || self.previewing || self.previewCaption != nil {
                shelfTrace("settle skipped overTray=\(self.panel?.containsMouse == true) out=\(self.draggingOut) carrying=\(self.dragContent != nil)")
                return
            }
            self.show(self.items.isEmpty ? .hidden : .collapsed)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: 古い項目を削除する

    /// 置いてから決めた期間がたった項目を、古いものから削除する（トレイの中のコピーとメモはゴミ箱へ。参照はトレイから消すだけで、元のファイルは削除しない）。
    /// トレイを開いて使っている最中は削除せず、次に見るときに回す（項目が目の前で消えないように）
    func removeExpiredItems(now: Date = Date()) {
        guard enabled, let limit = autoRemoveAfter,
              state == .hidden || state == .collapsed, !draggingOut, dragContent == nil, !menuOpen,
              !MemoEditor.shared.isOpen, !previewing else { return }
        let expired = ShelfRules.expired(items, olderThan: limit, now: now)
        if !expired.isEmpty { remove(expired) }
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

    /// マウスを乗せる / クリックするとトレイが開く場所: ノッチ / ノッチのない画面は上端中央の細い帯
    static func detectorRect(on screen: NSScreen) -> NSRect {
        if let r = notchRect(on: screen) { return r }
        let f = screen.frame
        return NSRect(x: f.midX - 110, y: f.maxY - 3, width: 220, height: 3)
    }

    static var preferredScreen: NSScreen {
        NSScreen.screens.first { notchRect(on: $0) != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 状態ごとのトレイの大きさ
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
            // 項目が 1 段に並ぶまで横に広げ（左右に「新規メモ」「貼り付け」のボタンの列を取る）、
            // 画面で決まる上限を超えたら下へ段を足す。3 段を超えたぶんはスクロール
            let wanted = CGFloat(itemCount) * ShelfItemView.width + sideInset * 2
            // ノッチのある画面では、上の帯のノッチの横に置き方のスイッチが入るよう、少し広めにする
            let least = base + (notch.width > 0 ? 300 : 250)
            let width = min(max(least, wanted), maxWidth(screen))
            let grid = ShelfGrid(itemCount: itemCount, shelfWidth: width)
            return NSSize(width: width, height: notch.height + grid.visibleHeight + itemPadding * 2)
        case .large:
            // ファイルを受け取るときの大きさ。開いたトレイより横に広く、1 段のときは下へ 64 伸ばす
            // （受け取るあいだは項目を隠して受け口だけを出すので、段が多くても開いたトレイより高くはしない）
            let open = size(for: .open, itemCount: itemCount, screen: screen)
            let oneRow = notch.height + ShelfItemView.height + itemPadding * 2
            return NSSize(width: min(open.width + 150, maxWidth(screen) + 150),
                          height: max(open.height, oneRow + 64))
        }
    }

    /// ファイルを持って上へ動かしたとき、トレイを広げる範囲（上端の、左右の真ん中のまわり）。
    /// 広げたトレイより下へ 120、左右へ 200 広く取り、トレイに届く前から広げて待つ
    static func receiveArea(itemCount: Int, on screen: NSScreen) -> ShelfReceiveArea {
        let large = size(for: .large, itemCount: itemCount, screen: screen)
        return ShelfReceiveArea(depth: Double(large.height) + 120, halfWidth: Double(large.width) / 2 + 200)
    }

    /// 開いたトレイの、項目の上下の余白
    static let itemPadding: CGFloat = 17
    /// 開いたトレイの左右で、ボタンの列に取る幅（外側 10 + ボタン + 項目との間 12）。項目はこの内側だけに並べる
    static let sideInset: CGFloat = 10 + ShelfSideButton.width + 12

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
        let tallest = ShelfGrid.height(rows: ShelfGrid.maxVisibleRows)
        return NSSize(width: maxWidth(screen) + 150 + flare * 2 + shadowPad * 2,
                      height: notchSize(on: screen).height + tallest + itemPadding * 2 + 64 + shadowPad)
    }
}

/// 開いたトレイの項目の並べ方。左右のボタンの列のあいだに、左上から詰めて並べる。
/// 1 段に入りきらなければ段を足し、見せるのは 3 段まで（それより多いぶんはスクロール）
struct ShelfGrid {
    static let rowGap: CGFloat = 2
    static let maxVisibleRows = 3

    let itemCount: Int
    let columns: Int
    var rows: Int { max(Int((Double(itemCount) / Double(columns)).rounded(.up)), 1) }
    var visibleRows: Int { min(rows, Self.maxVisibleRows) }
    var scrolls: Bool { rows > Self.maxVisibleRows }
    /// 実際に使う列の数（1 段に収まるときは、項目の数だけ。真ん中に寄せるため）
    var usedColumns: Int { min(max(itemCount, 1), columns) }
    var width: CGFloat { CGFloat(usedColumns) * ShelfItemView.width }
    var visibleHeight: CGFloat { Self.height(rows: visibleRows) }
    var contentHeight: CGFloat { Self.height(rows: rows) }

    init(itemCount: Int, shelfWidth: CGFloat) {
        self.itemCount = itemCount
        columns = max(Int((shelfWidth - ShelfGeometry.sideInset * 2) / ShelfItemView.width), 1)
    }

    static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * ShelfItemView.height + CGFloat(max(rows - 1, 0)) * rowGap
    }

    /// i 番目の項目の位置（上から並べる入れ物の中で）
    func frame(of index: Int) -> NSRect {
        NSRect(x: CGFloat(index % columns) * ShelfItemView.width,
               y: CGFloat(index / columns) * (ShelfItemView.height + Self.rowGap),
               width: ShelfItemView.width, height: ShelfItemView.height)
    }
}

// MARK: - 受け口（透明）

/// 上端中央に置く透明なウィンドウ。マウスが乗る / クリック / ドラッグで持ってくるとトレイを開く。
/// トレイが出る前にここで離されたときも、そのまま受け取る。
/// ノッチ部分にはメニュー項目がないので、置いても操作の邪魔にならない。
final class ShelfDetectorWindow: NSPanel {
    var onActivate: (() -> Void)?
    /// 受け取れるものを持ってきた
    var onDragArrive: ((ShelfDropContent) -> Void)?
    /// ここで離された（受け取ったら true）
    var onDrop: ((NSPasteboard, ShelfDropMode) -> Bool)?
    /// いまのスイッチの置き方
    var dropMode: () -> ShelfDropMode = { .reference }

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
        /// いまこの上にあるドラッグが持っているもの
        private var incoming: ShelfDropContent?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(ShelfDrop.acceptedTypes)
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
            shelfTrace("notch.hover")
            // 通りすがりで開かないよう、少しだけ留まったら開く
            let work = DispatchWorkItem { [weak self] in self?.owner?.onActivate?() }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        override func mouseExited(with event: NSEvent) { dwell?.cancel() }

        override func mouseDown(with event: NSEvent) {
            shelfTrace("notch.click")
            dwell?.cancel()
            owner?.onActivate?()
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            shelfTrace("notch.enter own=\((sender.draggingSource as? ShelfItemView) != nil)")
            guard let owner, (sender.draggingSource as? ShelfItemView) == nil, // トレイから持ち出しているものは受け取らない
                  let content = ShelfDrop.content(of: sender.draggingPasteboard) else { return [] }
            incoming = content
            owner.onDragArrive?(content) // トレイが受け口を広げて、この上に出てくる
            return draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let incoming else { return [] }
            let mode = ShelfDrop.currentMode(default: owner?.dropMode() ?? .reference)
            return ShelfDrop.operation(for: incoming, mode: mode, sourceAllows: sender.draggingSourceOperationMask)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { incoming = nil }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            incoming = nil
            guard let owner else { return false }
            let accepted = owner.onDrop?(sender.draggingPasteboard, ShelfDrop.currentMode(default: owner.dropMode())) ?? false
            shelfTrace("notch.drop accepted=\(accepted)")
            return accepted
        }
    }
}

// MARK: - トレイのウィンドウ

/// トレイのウィンドウ。描画は大きさの変わらない「土台（stage）」の上で行い、ウィンドウは
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

    /// 持ってきたものの知らせを渡す先（受け取り用のウィンドウから）
    var dropTarget: ShelfStage { stage }

    /// 持ってきたものを受け取る範囲（画面の座標）。広げたトレイより左右に 40、下に 48 広く取る
    var dropArea: NSRect {
        let r = shelfFrame(for: .large, itemCount: itemCount)
        return NSRect(x: r.minX - 40, y: r.minY - 48, width: r.width + 80, height: r.height + 48)
    }

    /// トレイの描画範囲（影とフレアを含む）にウィンドウを合わせる。土台は上端中央に固定
    private func resizeWindow(to size: NSSize) {
        let f = targetScreen.frame
        let w = size.width + ShelfGeometry.flare * 2 + ShelfGeometry.shadowPad * 2
        let h = max(size.height, 1) + ShelfGeometry.shadowPad
        setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: false)
        root.pinStage()
    }

    func animate(to target: ShelfController.State, style: ShelfAnimationStyle, quick: Bool, caption: String?,
                 completion: (() -> Void)?) {
        state = target
        let size = ShelfGeometry.size(for: target, itemCount: itemCount, screen: targetScreen)
        let current = stage.displayedSize
        // 動いているあいだは大きいほうに合わせ、落ち着いたら目的の大きさに縮める
        resizeWindow(to: NSSize(width: max(size.width, current.width), height: max(size.height, current.height)))
        stage.animate(to: target, size: size, style: style, quick: quick, caption: caption) { [weak self] in
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
        animate(to: state, style: .smooth, quick: false, caption: nil, completion: nil)
    }

    func selectionChanged() { stage.selectionChanged() }
    func receivingDragChanged() { stage.receivingDragChanged() }
    func refreshItemViews() { stage.refreshItemViews() }
    func dropModeChanged() { stage.dropModeChanged() }
    func refreshItem(_ url: URL) { stage.refreshItem(url) }
    func bounce() { stage.bounce() }
    func screenFrame(of url: URL) -> NSRect { stage.screenFrame(of: url) }
    var columns: Int { stage.columns }
    func scrollToItem(_ id: UUID) { stage.scrollToItem(id) }

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
        stage.catchArea = convert(bounds, to: stage) // ウィンドウ全体（トレイのまわりの余白まで）
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        pinStage()
    }
}

/// 描画の土台。トレイの輪郭（CAShapeLayer）と中身を、上端中央を基準に置く
final class ShelfStage: NSView {
    private weak var controller: ShelfController?
    private let screen: NSScreen
    private let shape = CAShapeLayer()
    private let content = NSView()
    /// 項目を並べる場所（左右のボタンの列のあいだ）。3 段を超えたらスクロールする
    private let scroll = NSScrollView()
    private let grid = ShelfGridView()
    /// ドラッグで持ってきているあいだの受け口（いまの置き方を大きく出す）
    private let dropZones = ShelfDropZoneView()
    /// 文字やボタン。項目の上に重なるので、自分自身はマウスを受けずに下の項目へ通す
    private let message = ShelfPassthroughView()
    /// 持ってきているあいだ、トレイのまわりの余白（ウィンドウ全体）でも落とせるようにする面。
    /// 見えないほど薄く塗る（まったく塗らないと、そこではドラッグを受け取れない）
    private let catchLayer = CALayer()
    /// 余白まで含めたウィンドウ全体（土台の座標）
    var catchArea = NSRect.zero { didSet { updateCatchLayer() } }
    /// いまトレイの上にあるドラッグが持っているもの
    private var incoming: ShelfDropContent?
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
        catchLayer.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        catchLayer.isHidden = true
        catchLayer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(catchLayer)
        layer?.addSublayer(shape)
        content.wantsLayer = true
        message.wantsLayer = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.appearance = NSAppearance(named: .darkAqua) // 黒いトレイの上で見えるスクロールバー
        scroll.documentView = grid
        content.addSubview(scroll)
        dropZones.show(.init(content: controller.receiving, mode: controller.dropMode), active: false, animated: false)
        addSubview(content)
        addSubview(dropZones)
        addSubview(message)
        registerForDraggedTypes(ShelfDrop.acceptedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var notchHeight: CGFloat { ShelfGeometry.notchSize(on: screen).height }

    /// トレイの矩形（土台の座標）
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

    func animate(to state: ShelfController.State, size: NSSize, style: ShelfAnimationStyle, quick: Bool, caption: String?,
                 completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        let (fromSize, fromR) = sample(at: now)
        let toR = ShelfGeometry.radius(for: state, height: size.height)
        let growing = size.height >= fromSize.height
        let curves = style.curves(growing: growing, quick: quick)
        let duration = max(curves.width.duration, curves.height.duration)
        let previousState = self.state
        shelfTrace("anim \(previousState) → \(state) \(Int(duration * 1000))ms quick=\(quick) from=\(Int(fromSize.width))x\(Int(fromSize.height)) to=\(Int(size.width))x\(Int(size.height))")
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
            // 中身は広がりに合わせて出す。持ってきているあいだは、受け口をすぐ出す
            let delay = growing ? (quick ? 0.03 : min(duration * 0.35, 0.12)) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state == state else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = growing ? (quick ? 0.1 : 0.18) : 0.1
                    self.content.animator().alphaValue = self.showsItems ? 1 : 0
                    self.message.animator().alphaValue = state == .hidden ? 0 : 1
                    self.dropZones.animator().alphaValue = self.showsDropZones ? 1 : 0
                }
                // 3 段を超えて隠れている項目があることを、スクロールバーを一瞬出して知らせる
                if self.showsItems { self.scroll.flashScrollers() }
            }
        }
        updateTrackingArea()
        updateCatchLayer()
    }

    // MARK: 中身

    /// ファイルを持ってきているあいだは、項目の代わりに受け口を出す（広がった状態はいつも）
    private var showsDropZones: Bool {
        state == .large || (state == .open && controller?.receivingDrag == true)
    }

    private var showsItems: Bool { (state == .open || state == .large) && !order.isEmpty && !showsDropZones }

    /// 受け口の見せ方（持ってきているもの。トレイの上にあれば、そのドラッグのもの）
    private var dropLook: ShelfDropZoneView.Look {
        .init(content: incoming ?? controller?.receiving, mode: controller?.dropMode ?? .reference)
    }

    /// 項目と受け口を入れ替える（ファイルを持ってきた・置いた・広がった）
    private func fadeContent() {
        if !showsDropZones { dropZones.show(dropLook, active: false) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            content.animator().alphaValue = showsItems ? 1 : 0
            dropZones.animator().alphaValue = showsDropZones ? 1 : 0
        }
    }

    func receivingDragChanged() {
        if !dropZones.isActive { dropZones.show(dropLook, active: false, animated: false) }
        updateMessage(caption: nil)
        layoutContent(animated: false)
        fadeContent()
        updateCatchLayer()
    }

    /// 置き方が切り替わった（スイッチは作り直さずに表示だけ変える。押している最中に呼ばれるため）
    func dropModeChanged() {
        let mode = controller?.dropMode ?? .reference
        message.subviews.compactMap { $0 as? ShelfModeSwitch }.forEach { $0.setMode(mode) }
        if !dropZones.isActive { dropZones.show(dropLook, active: false) }
    }

    /// 持ってきているあいだだけ、トレイのまわりの余白でも落とせるようにする
    private func updateCatchLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        catchLayer.frame = catchArea
        catchLayer.isHidden = !(controller?.receivingDrag == true && state != .hidden)
        CATransaction.commit()
    }

    /// 項目の表示を全部書き直す（自動で削除する設定が変わり、ツールチップの「削除されるころ」が変わったとき）
    func refreshItemViews() {
        itemViews.values.forEach { $0.refresh() }
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
        var added = false
        for item in items {
            if let v = itemViews[item.id] {
                v.update(item) // 状態や場所が変わっただけ
                continue
            }
            let v = ShelfItemView(item: item, controller: controller)
            v.isSelected = controller?.isSelected(item.id) == true
            itemViews[item.id] = v
            grid.addSubview(v)
            added = true
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
        // 置いたものが見える段までスクロールする（段が多くてスクロールするとき）
        if added, animated, !order.isEmpty {
            grid.scrollToVisible(ShelfGrid(itemCount: order.count, shelfWidth: rect(for: targetSize).width).frame(of: order.count - 1))
            scroll.flashScrollers()
        }
    }

    func selectionChanged() {
        for (id, v) in itemViews { v.isSelected = controller?.isSelected(id) == true }
    }

    func refreshItem(_ url: URL) { itemViews.values.first { $0.item.url == url }?.refresh() }

    func screenFrame(of url: URL) -> NSRect {
        guard let v = itemViews.values.first(where: { $0.item.files.contains { $0.url == url } }), let window else { return .zero }
        return window.convertToScreen(v.convert(v.thumbFrame, to: nil))
    }

    /// 1 段に並ぶ項目の数（矢印キーの ↑↓ で 1 段ぶん動かすため）
    var columns: Int { ShelfGrid(itemCount: order.count, shelfWidth: rect(for: targetSize).width).columns }

    /// その項目が見える段までスクロールする（矢印キーで選んだとき）
    func scrollToItem(_ id: UUID) {
        guard let index = order.firstIndex(of: id) else { return }
        grid.scrollToVisible(ShelfGrid(itemCount: order.count, shelfWidth: rect(for: targetSize).width).frame(of: index))
    }

    private func layoutContent(animated: Bool) {
        let r = rect(for: targetSize)
        let area = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height - notchHeight, 0))
        content.frame = area
        message.frame = r // 上の帯（ノッチの横）にもボタンを置くので、トレイ全体
        // insetBy は小さすぎる矩形で null（原点が無限大）を返すので、自分で縮める
        let zones = NSRect(x: area.minX + 14, y: area.minY + 10,
                           width: max(area.width - 28, 0), height: max(area.height - 20, 0))
        if animated, dropZones.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.allowsImplicitAnimation = true
                dropZones.animator().frame = zones // 受け口はトレイの広がりについていく
            }
        } else {
            dropZones.frame = zones
        }
        guard showsItems else { return }
        // 左右のボタンの列のあいだの真ん中に置く。1 段目は左右のボタンと高さをそろえ、段は下へ足す
        let layout = ShelfGrid(itemCount: order.count, shelfWidth: area.width)
        scroll.frame = NSRect(x: ((area.width - layout.width) / 2).rounded(),
                              y: area.height - ShelfGeometry.itemPadding - layout.visibleHeight,
                              width: layout.width, height: layout.visibleHeight)
        scroll.verticalScrollElasticity = layout.scrolls ? .allowed : .none
        grid.frame = NSRect(x: 0, y: 0, width: layout.width, height: layout.contentHeight)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.allowsImplicitAnimation = animated
            for (i, id) in order.enumerated() {
                guard let v = itemViews[id] else { continue }
                let f = layout.frame(of: i)
                if animated { v.animator().frame = f } else { v.frame = f }
                v.loadThumbnailIfNeeded() // サムネイルは、項目が見えるときに初めて作る
            }
        }
    }

    // 文字やボタン（項目以外の表示）は一度だけ作り、状態に合わせて出し分ける。
    // 状態が変わるたびに作り直すと、作るのと描き直すのに時間がかかる。トレイに落とした瞬間は 1 回で 3〜4 回呼ばれ、
    // そのあいだドラッグ元を待たせていた（返事の前に描画まで済ませるため）
    private lazy var peekLabel = Self.messageLabel(12, 0.75)
    private lazy var captionLabel = Self.messageLabel(15, 0.9, weight: .semibold)
    private lazy var emptyTitle = Self.messageLabel(14, 0.85, text: L("ここへドロップ", "Drop here"))
    private lazy var emptySubtitle = Self.messageLabel(11, 0.45, text: L("ファイル・画像・リンク・テキスト", "Files, images, links, text"))
    private lazy var countLabel = Self.messageLabel(12, 0.95, weight: .semibold)
    private lazy var countBadge: NSStackView = {
        let icon = NSImageView(image: NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, countLabel])
        stack.spacing = 4
        return stack
    }()
    /// トレイを空にする: 項目にかぶらないよう、上の帯（ノッチの横）の右端に置く
    private lazy var clearButton: ShelfFirstClickButton = {
        let tip = L("トレイを空にする", "Clear Shelf")
        let b = ShelfFirstClickButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: tip)!,
                                      target: self, action: #selector(clearAll))
        b.isBordered = false
        b.contentTintColor = NSColor(white: 1, alpha: 0.5)
        b.toolTip = tip
        b.frame.size = NSSize(width: 22, height: 20)
        return b
    }()
    private lazy var memoButton = ShelfSideButton(symbol: "square.and.pencil", title: L("新規メモ", "New Note"), shortcut: "⌘N") { [weak self] in
        self?.controller?.createMemo(edit: true)
    }
    private lazy var pasteButton = ShelfSideButton(symbol: "doc.on.clipboard", title: L("貼り付け", "Paste"), shortcut: "") { [weak self] in
        self?.controller?.paste()
    }
    private lazy var modeSwitch = ShelfModeSwitch(mode: controller?.dropMode ?? .reference) { [weak self] mode in
        self?.controller?.switchDropMode(to: mode)
    }

    private static func messageLabel(_ size: CGFloat, _ alpha: CGFloat, weight: NSFont.Weight = .medium, text: String = "") -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor(white: 1, alpha: alpha)
        l.sizeToFit()
        return l
    }

    /// 文字やボタンなど、項目以外の表示
    private func updateMessage(caption: String?) {
        message.frame = rect(for: targetSize) // 上の帯（ノッチの横）まで含めたトレイ全体
        // 文字やボタンを置くところ（上の帯を除いた部分）
        let area = NSRect(x: 0, y: 0, width: message.bounds.width, height: max(message.bounds.height - notchHeight, 0))
        var shown: [NSView] = []

        func text(_ label: NSTextField, _ string: String) -> NSTextField {
            if label.stringValue != string {
                label.stringValue = string
                label.sizeToFit()
            }
            return label
        }
        func center(_ v: NSView, dy: CGFloat = 0) {
            v.setFrameOrigin(NSPoint(x: (area.width - v.frame.width) / 2, y: (area.height - v.frame.height) / 2 + dy))
            shown.append(v)
        }

        switch state {
        case .hidden:
            break
        case .peek:
            center(text(peekLabel, caption ?? L("ここへ", "Drop here")))
        case .collapsed:
            _ = text(countLabel, "\(order.count)")
            countBadge.frame.size = countBadge.fittingSize
            center(countBadge)
        case .large:
            break // 受け口（dropZones）だけを出す
        case .open:
            if showsDropZones { break } // ファイルを持ってきているあいだは、受け口だけ
            if !order.isEmpty {
                clearButton.setFrameOrigin(NSPoint(x: area.width - 16 - 22, y: area.height + (notchHeight - 20) / 2))
                shown.append(clearButton)
            }
            if let caption {
                if order.isEmpty { center(text(captionLabel, caption)) }
            } else if order.isEmpty {
                center(emptyTitle, dy: 9)
                center(emptySubtitle, dy: -11)
            }
            // 左: 新規メモ / 右: クリップボード（⌘C した内容）を貼り付け。1 段目の項目と高さをそろえる
            let h = min(area.height - ShelfGeometry.itemPadding * 2, ShelfItemView.height)
            let y = area.height - ShelfGeometry.itemPadding - h
            memoButton.frame = NSRect(x: 10, y: y, width: ShelfSideButton.width, height: h)
            pasteButton.setShortcut(Self.clipboardKind())
            pasteButton.frame = NSRect(x: area.width - 10 - ShelfSideButton.width, y: y, width: ShelfSideButton.width, height: h)
            shown += [memoButton, pasteButton]
        }

        // 置き方のスイッチ（コピー / 参照）: 開いているあいだ、上の帯（ノッチの横）の左端にいつも出す
        if state == .open || state == .large, let controller {
            modeSwitch.setMode(controller.dropMode)
            // ノッチのある画面では、ノッチにかからない幅だけ使う（足りなければ文字を省いてアイコンだけにする）
            let notchWidth = ShelfGeometry.notchRect(on: screen)?.width ?? 0
            let room = notchWidth > 0 ? (area.width - notchWidth) / 2 - 16 - 8 : area.width / 2 - 16 - 44
            modeSwitch.fit(width: room)
            modeSwitch.setFrameOrigin(NSPoint(x: 16, y: area.height + ((notchHeight - modeSwitch.frame.height) / 2).rounded()))
            shown.append(modeSwitch)
        }

        // 出すものだけを見せる（隠したものも、描いた中身を持ったまま残しておく）
        for v in shown where v.superview !== message { message.addSubview(v) }
        for v in message.subviews { v.isHidden = !shown.contains { $0 === v } }
    }

    /// クリップボードの種類を調べた結果（クリップボードが変わるまで使い回す）
    private static var clipboardKindCache: (changeCount: Int, kind: String)?

    /// いまクリップボードに入っているものの種類（貼り付けボタンの下に出す。貼り付けたときに受け取る順と同じ）。
    /// 中身まで読むので、クリップボードが変わったときだけ調べる（トレイを開くたびに、大きな画像やテキストを読まないように）
    private static func clipboardKind() -> String {
        let pb = NSPasteboard.general
        if let cached = clipboardKindCache, cached.changeCount == pb.changeCount { return cached.kind }
        let kind: String
        switch ShelfDrop.content(of: pb, promises: false) {
        case .files?, .promisedFiles?: kind = L("ファイル", "File")
        case .image?: kind = L("画像", "Image")
        case .link?: kind = L("リンク", "Link")
        case .text?: kind = L("テキスト", "Text")
        case nil: kind = L("空", "Empty")
        }
        clipboardKindCache = (pb.changeCount, kind)
        return kind
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

    // TriTab は前面に出ないので、最初のクリックから受け取る
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 項目のないところをクリック: 選択を外す / 右クリック: すべて選択・トレイを空にする
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        controller?.clearSelection()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller, let menu = controller.backgroundMenu() else { return }
        controller.popUp(menu, with: event, for: self)
    }

    /// 記録用: マウスがトレイの見えている形の中か、外ならどちらへどれだけ外れているか
    private var pointerNote: String {
        let r = shelfScreenRect, p = NSEvent.mouseLocation
        if NSMouseInRect(p, r, false) { return "inside" }
        var parts: [String] = []
        if p.y < r.minY { parts.append("below \(Int(r.minY - p.y))") }
        if p.x < r.minX { parts.append("left \(Int(r.minX - p.x))") }
        if p.x > r.maxX { parts.append("right \(Int(p.x - r.maxX))") }
        return parts.isEmpty ? "edge" : parts.joined(separator: " ")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        shelfTrace("tray.enter state=\(state) own=\((sender.draggingSource as? ShelfItemView) != nil) at=\(pointerNote) window=\(shelfWindowUnderPointer())")
        // 持ってきたものは、ドラッグの追跡でもう調べてあればそれを使う。
        // ドラッグ元はこの返事を待っているので、そのあいだにドラッグの中身を読み直して待たせない
        guard (sender.draggingSource as? ShelfItemView) == nil,
              let content = controller?.receiving ?? ShelfDrop.content(of: sender.draggingPasteboard) else { return [] }
        incoming = content
        shape.fillColor = NSColor(white: 0.12, alpha: 1).cgColor
        controller?.dragArrived(content) // すぐに受け口を広げる
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    /// 置いたらどうなるかを受け口に出し、カーソルの印（「+」かエイリアスの矢印）を返す
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let incoming else { return [] }
        let mode = currentDropMode
        dropZones.show(.init(content: incoming, mode: mode), active: true)
        return ShelfDrop.operation(for: incoming, mode: mode, sourceAllows: sender.draggingSourceOperationMask)
    }

    /// 落としたときの置き方: スイッチの置き方。⌥ を押していればコピー、⌘⌥ なら参照
    private var currentDropMode: ShelfDropMode {
        ShelfDrop.currentMode(default: controller?.dropMode ?? .reference)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shelfTrace("tray.exit state=\(state) at=\(pointerNote) window=\(shelfWindowUnderPointer())")
        incoming = nil
        shape.fillColor = NSColor.black.cgColor
        dropZones.show(dropLook, active: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shape.fillColor = NSColor.black.cgColor
        incoming = nil
        let accepted = controller?.receive(from: sender.draggingPasteboard, as: currentDropMode) ?? false
        shelfTrace("tray.drop accepted=\(accepted) state=\(state) at=\(pointerNote)")
        // 置いたものを見せるのは、ドラッグ元への返事のあと（draggingEnded → ShelfController.finishReceiving）
        return accepted
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        shelfTrace("tray.dragEnded state=\(state)")
        incoming = nil
        shape.fillColor = NSColor.black.cgColor
        dropZones.show(dropLook, active: false)
        controller?.receiveSessionEnded()
    }
}

// MARK: - 項目

/// トレイの 1 項目。サムネイル（画像・PDF・動画など）か付箋（メモ）を表示し、右下にコピー / 参照の印を付ける。
/// 一度に置いたまとめは、先頭のファイルのサムネイルのうしろにカードを重ね、右上に数を付ける。
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
    /// まとめの、うしろに重ねるカードと、中の数
    private let backCards = [NSImageView(), NSImageView()]
    private let countBadge = ShelfCountBadge()
    private var spinner: NSProgressIndicator?
    private var mouseDownEvent: NSEvent?
    /// 選んである項目を修飾キーなしで押した（離したときにドラッグしていなければ、その項目だけを選び直す）
    private var reselectOnMouseUp = false
    private var modifiedClick = false
    /// いまドラッグで持ち出している項目
    private var dragged: [ShelfItem] = []
    /// 外へのドラッグを始めようとしたが、まだ始まっていない（前のドラッグが終わりきる前だと macOS に断られる）
    private var dragRequested = false
    /// 最後にドラッグを始めようとした時刻（断られたときに、間をあけて試し直す）
    private var lastDragAttempt: CFTimeInterval = 0
    /// 押した時刻と、ドラッグ中に最後に動いた時刻（記録用）
    private var pressedAt: CFTimeInterval = 0
    private var lastMove: CFTimeInterval = 0
    private var thumbnailRequested = false
    private var isMemo: Bool { item.kind == .memo }
    /// サムネイルとアイコンに使う場所（コピーを作っている途中は、まだ元のファイルのほうを見せる）
    private static func displayURL(_ file: ShelfItem) -> URL {
        file.status == .copying ? (file.sourceURL ?? file.url) : file.url
    }

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

        for view in backCards.reversed() + [imageView] {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 6
            view.layer?.masksToBounds = true
        }
        backCards.reversed().forEach(addSubview) // うしろのカードから重ねる
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
        countBadge.frame = NSRect(x: thumbFrame.maxX - 20, y: thumbFrame.maxY - 12, width: 26, height: 15)
        addSubview(countBadge)

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
            nameLabel.stringValue = item.isGroup ? L("\(item.files.count) 項目", "\(item.files.count) items") : item.url.lastPathComponent
            if thumbnailRequested { loadThumbnail() }
        }
        layoutCards()
        // 見つからないものは薄く、コピー中のものはくるくるを重ねる
        let alpha: CGFloat = item.isAvailable ? 1 : item.status == .copying ? 0.45 : 0.35
        (backCards + [imageView]).forEach { $0.alphaValue = alpha }
        memoCard.alphaValue = alpha
        badge.set(item.badge)
        countBadge.count = item.isGroup ? item.files.count : 0
        toolTip = item.tooltip(removingAfter: controller?.autoRemoveAfter)
        updateSpinner()
        updateSelection()
    }

    /// サムネイルを作る。閉じたトレイでは作らず、項目が見えるときに初めて作る（常駐時のメモリを増やさないため）
    func loadThumbnailIfNeeded() {
        guard !thumbnailRequested, !isMemo else { return }
        thumbnailRequested = true
        loadThumbnail()
    }

    /// ふつうの項目はサムネイル 1 枚。まとめは先頭のファイルのサムネイルの右上へ、無地のカードを（3 つ以上なら 2 枚）ずらして重ねる
    private func layoutCards() {
        let cards = [imageView] + backCards
        let count = item.isGroup ? min(item.files.count, cards.count) : 1
        let side: CGFloat = item.isGroup ? 42 : Self.thumb
        for (i, card) in cards.enumerated() {
            card.isHidden = i >= count
            card.frame = NSRect(x: thumbFrame.minX + CGFloat(i) * 4, y: thumbFrame.minY + CGFloat(i) * 4, width: side, height: side)
            // まとめのカードは、重なりがわかるよう地と縁を付ける（うしろのカードは無地。小さすぎて中身は見分けられないため）
            card.layer?.backgroundColor = item.isGroup ? NSColor(white: i == 0 ? 0.17 : 0.24, alpha: 1).cgColor : nil
            card.layer?.borderWidth = item.isGroup ? 1 : 0
            card.layer?.borderColor = NSColor(white: 1, alpha: i == 0 ? 0.22 : 0.3).cgColor
        }
    }

    private func loadThumbnail() {
        let url = Self.displayURL(item.files[0])
        imageView.image = ShelfThumbnails.shared.image(for: url, size: Self.thumb) { [weak self] image in
            guard let self, Self.displayURL(self.item.files[0]) == url else { return }
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

    // 中のサムネイルや名前の文字ではなく、項目そのものでクリックを受ける。
    // 前面にないアプリのウィンドウでは、押したところにあるビューが acceptsFirstMouse で true を返さないと、
    // 最初の押す・動かす・離すが丸ごと捨てられる。サムネイル（NSImageView）や文字は false なので、
    // トレイを開いて最初につかんだときに持ち出しが始まらず、2 回目からしか動かなかった
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

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
        dragRequested = false
        lastDragAttempt = 0
        pressedAt = CACurrentMediaTime()
        shelfTrace("out.press clicks=\(event.clickCount) modified=\(modifiedClick) state=\(controller.state)")
        if event.clickCount == 2, !modifiedClick, !isMemo { controller.open([item]) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        shelfTrace("out.release requested=\(dragRequested) after=\(Int((CACurrentMediaTime() - pressedAt) * 1000))ms")
        if dragRequested {
            // 動かしたのに、ドラッグが始まらないまま離した（断られ続けた）。持ち出し中の印を残さない
            dragRequested = false
            dragged = []
            controller?.draggingOut = false
            return
        }
        if reselectOnMouseUp { controller?.select(item.id) }
        if isMemo, !modifiedClick { controller?.openEditor(item.url) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller else { return }
        controller.popUp(controller.contextMenu(for: item.id), with: event, for: self)
    }

    // MARK: 外へドラッグ

    /// これだけ動かしたらドラッグにする（押したときの指のわずかなずれで、クリックがドラッグにならないように）
    private static let dragThreshold: CGFloat = 3
    /// ドラッグを断られたとき、次に試すまでの間
    private static let dragRetryInterval: CFTimeInterval = 0.05

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let controller else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }
        // 前のドラッグが終わりきっていないと（やめた項目がトレイへ戻っていく途中など）、macOS は新しいドラッグを断る。
        // 押したまま動かしているあいだは間をあけて試し直し、前のものが終わったところで始める（始まると willBeginAt が来る）
        let now = CACurrentMediaTime()
        guard now - lastDragAttempt >= Self.dragRetryInterval else { return }
        lastDragAttempt = now
        reselectOnMouseUp = false
        let items = controller.itemsToDrag(from: item.id)
        guard !items.isEmpty else { // 見つからない・コピー中
            mouseDownEvent = nil
            return NSSound.beep()
        }
        // 選んだものはそれぞれの位置から持ち上げる。まとめは中のファイルを全部、少しずつずらして重ねる
        let views = superview?.subviews.compactMap { $0 as? ShelfItemView } ?? []
        let draggingItems = items.flatMap { item -> [NSDraggingItem] in
            let view = views.first { $0.item.id == item.id } ?? self
            let frame = view.convert(view.thumbFrame, to: self)
            return item.files.enumerated().map { i, file in
                let d = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                let shift = CGFloat(min(i, 3)) * 4
                d.setDraggingFrame(frame.offsetBy(dx: shift, dy: shift), contents: view.dragImage(for: file, at: i))
                return d
            }
        }
        dragged = items
        dragRequested = true
        controller.draggingOut = true
        shelfTrace("out.begin after=\(Int((now - pressedAt) * 1000))ms files=\(draggingItems.count)")
        _ = beginDraggingSession(with: draggingItems, event: down, source: self)
    }

    /// ドラッグの絵。先頭のファイルは、いまトレイに見えている絵をそのまま使う。ほかは作ってあるサムネイルか、種類のアイコン
    /// （ファイルごとにアイコンを読み込むと、iCloud Drive の中やファイルの多いまとめで、つかんだ瞬間に待たせてしまうため）
    private func dragImage(for file: ShelfItem, at index: Int) -> NSImage {
        if index == 0, !isMemo, let shown = imageView.image { return shown }
        return ShelfThumbnails.shared.cached(file.url) ?? ShelfThumbnails.typeIcon(for: file.url)
    }

    /// 行き先に許す操作は、項目の種類で決める（参照は元のファイルを移動、コピーはトレイの複製を移動、メモは書き出すだけ）。
    /// ⌥を押しながらなら、macOS がコピーだけに絞る
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication
            ? NSDragOperation(ShelfRules.dragOutOperations(for: dragged.flatMap(\.files).map(\.kind))) : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // 始まった。ここからのマウスの動きは macOS がドラッグとして扱う
        mouseDownEvent = nil
        dragRequested = false
        lastMove = CACurrentMediaTime()
        shelfTrace("out.began after=\(Int((lastMove - pressedAt) * 1000))ms")
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // ドラッグの絵が止まって見えるほど、知らせの間があいたら記録する（メインスレッドが詰まっている）
        let now = CACurrentMediaTime()
        if now - lastMove > 0.05 { shelfTrace("stall drag \(Int((now - lastMove) * 1000))ms") }
        lastMove = now
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // やめたとき・置けなかったときは、項目がトレイの元の場所へ戻っていく（macOS の標準の動き）。
        // ただ、戻っていくあいだは macOS が次のドラッグを始めさせない。トレイの上で終わったとき（戻した・やめた）は
        // 元の場所がすぐそこなので戻る動きを省き、すぐにつかみ直せるようにする
        let overTray = window?.frame.contains(screenPoint) == true
        if overTray { session.animatesToStartingPositionsOnCancelOrFail = false }
        shelfTrace("out.ended operation=\(operation.rawValue) overTray=\(overTray) after=\(Int((CACurrentMediaTime() - pressedAt) * 1000))ms")
        dragRequested = false
        let items = dragged
        dragged = []
        controller?.dragEnded(items, operation: ShelfDragOperation(operation))
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

/// Quick Look と同じ仕組みでサムネイルを作る。数を決めてキャッシュし、トレイから消えたら捨てる
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 48
        return c
    }()

    /// すぐ表示できるもの（キャッシュか、ファイルの種類のアイコン）を返し、サムネイルかそのファイルのアイコンが
    /// できたら completion で差し替える。
    /// ファイルごとのアイコン（NSWorkspace の icon(forFile:)）はファイルを読みに行くので、ここでは使わない
    /// （トレイを開くたびに項目の数だけ読み、iCloud Drive の中などでは、開く瞬間にメインスレッドを止めてしまうため）
    func image(for url: URL, size: CGFloat, completion: @escaping (NSImage) -> Void) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: url as NSURL)
                completion(image)
            }
        }
        return Self.typeIcon(for: url)
    }

    /// もう作ってあるサムネイル（ドラッグの絵に使う）
    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// ファイルの種類のアイコン（種類ごとにシステムが持っているので、すぐ返る）
    static func typeIcon(for url: URL) -> NSImage {
        var isFolder: ObjCBool = false
        if url.pathExtension.isEmpty, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
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

    // トレイのサムネイルから拡大して開く
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return sourceFrame?(url) ?? .zero
    }

    // 拡大し始めの絵。もう作ってあるサムネイルを渡す（渡さないと Quick Look が作るまで、開くのを待たされる）
    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        let image = ShelfThumbnails.shared.cached(url) ?? ShelfThumbnails.typeIcon(for: url)
        contentRect?.pointee = NSRect(origin: .zero, size: image.size)
        return image
    }
}

/// トレイの左右に置く大きめのボタン（アイコン + 名前 + 補足）
final class ShelfSideButton: NSView {
    static let width: CGFloat = 70

    private let action: () -> Void
    private let background = CALayer()
    private let icon = NSImageView()
    private let title: String
    private let name: NSTextField
    private let sub: NSTextField
    private var pressed = false

    init(symbol: String, title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        self.title = title
        name = NSTextField(labelWithString: title)
        sub = NSTextField(labelWithString: shortcut)
        super.init(frame: .zero)
        wantsLayer = true
        background.cornerRadius = 14
        background.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.addSublayer(background)

        // アイコンは決まった高さの枠に収める（記号によっては枠からはみ出して、下の文字に重なるため）
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = NSColor(white: 1, alpha: 0.9)
        for (label, size, weight, alpha) in [(name, 10.5, NSFont.Weight.semibold, 0.9), (sub, 9, .medium, 0.45)] {
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = NSColor(white: 1, alpha: alpha)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }
        [icon, name, sub].forEach(addSubview)
        toolTip = L("\(title)（\(shortcut)）", "\(title) (\(shortcut))")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 下の補足（ショートカットや、クリップボードの中身の種類）を変える
    func setShortcut(_ shortcut: String) {
        guard sub.stringValue != shortcut else { return }
        sub.stringValue = shortcut
        toolTip = L("\(title)（\(shortcut)）", "\(title) (\(shortcut))")
    }

    // 上から アイコン（22）・間（6）・名前（14）・間（2）・補足（12）を、真ん中にそろえて置く。
    // 高さが足りなければ補足を省く（文字とアイコンを重ねない）
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let showsSub = bounds.height >= 70
        let total: CGFloat = 22 + 6 + 14 + (showsSub ? 2 + 12 : 0)
        var top = ((bounds.height + total) / 2).rounded()
        func place(_ v: NSView, _ h: CGFloat, gap: CGFloat = 0) {
            top -= gap + h
            v.frame = NSRect(x: 3, y: top, width: bounds.width - 6, height: h)
        }
        place(icon, 22)
        place(name, 14, gap: 6)
        sub.isHidden = !showsSub
        if showsSub { place(sub, 12, gap: 2) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
    }

    // 最初のクリックから受け取る。中のアイコンや文字ではなく、ボタンそのもので受ける（ShelfItemView.hitTest と同じ理由）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
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
