import AppKit
import IOKit
import MTBridge
import TriTabCore

/// MultitouchSupport からタッチを受け取り、デバイスごとの `GestureEngine` に流す。
///
/// - コールバックは MultitouchSupport 内部のスレッドから来るので、判定器へのアクセスはロックで守る
/// - 蓋の開閉・Magic Trackpad の抜き差し・スリープ復帰でデバイスのハンドルが無効になるため、
///   IOKit の通知とスリープ復帰通知を受けて全デバイスを登録し直す
final class MultitouchManager {
    static let shared = MultitouchManager()

    /// 発火したジェスチャー。メインスレッドで呼ばれる。
    var onGesture: ((GestureEvent) -> Void)?

    private(set) var isLoaded = false
    private(set) var deviceCount = 0

    private var deviceList: CFArray?
    private var devices: [MTBDeviceRef] = []

    private let lock = NSLock()
    private var engines: [UInt: GestureEngine] = [:]
    private var config = GestureEngine.Config()

    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var terminateIterator: io_iterator_t = 0
    private var restartWork: DispatchWorkItem?

    /// 何本以上の指が触れたら、そのタッチ中のスクロールを止めるか（0 なら止めない）
    var scrollSuppressFingers = 3
    private var multiActive = false
    // クリック判定用: 最初の指が触れた時刻と、各本数にそろった時刻
    private var touchStartAt: TimeInterval = 0
    private var reachedAt: [Int: TimeInterval] = [:]
    private var lastCountForClick = 0
    private var multiEndedAt: TimeInterval = 0

    private let debug = ProcessInfo.processInfo.environment["TRITAB_DEBUG"] != nil
    private var receivedFirstFrame = false
    private var lastFingerCount = -1

    private init() {}

    // MARK: - 開始 / 停止

    @discardableResult
    func start() -> Bool {
        guard MTBLoad() else {
            log("MultitouchSupport.framework を読み込めませんでした")
            return false
        }
        isLoaded = true
        guard let list = MTBCreateDeviceList() else {
            log("デバイス一覧を取得できませんでした")
            return false
        }
        deviceList = list
        devices = (0..<CFArrayGetCount(list)).compactMap { i in
            CFArrayGetValueAtIndex(list, i).map { UnsafeMutableRawPointer(mutating: $0) }
        }
        for device in devices {
            MTBRegister(device, frameCallback)
            MTBStart(device)
        }
        deviceCount = devices.count
        log("トラックパッド \(devices.count) 台を監視開始")
        observeDeviceChangesIfNeeded()
        return true
    }

    func stop() {
        for device in devices {
            MTBUnregister(device, frameCallback)
            MTBStop(device)
        }
        devices = []
        deviceList = nil
        deviceCount = 0
        lock.lock()
        engines.removeAll()
        lock.unlock()
    }

    /// デバイス構成が変わったときに少し待ってから登録し直す（通知が連続して来るのでまとめる）
    func scheduleRestart(after delay: TimeInterval = 0.8) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log("デバイスを登録し直します")
            self.stop()
            self.start()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func update(config newConfig: GestureEngine.Config) {
        lock.lock()
        config = newConfig
        for e in engines.values {
            e.config = newConfig
            e.reset()
        }
        lock.unlock()
    }

    /// いまトラックパッドに触れている指の本数（複数台あるときは最大）。クリック時の判定に使う。
    var currentFingerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return engines.values.map(\.currentCount).max() ?? 0
    }

    /// 3 本指ジェスチャーの最中（と、離した直後の慣性スクロールの間）か。
    /// 指は同時には着地・離陸しないので、一瞬 2 本指になったところを macOS が
    /// 「2 本指スクロール（ページ送り）」と解釈してしまう。その間のスクロールを止めるのに使う。
    var shouldSuppressScroll: Bool {
        lock.lock()
        defer { lock.unlock() }
        return multiActive || ProcessInfo.processInfo.systemUptime - multiEndedAt < 0.4
    }

    /// わざと N 本指でクリックしたときの N。そうでなければ 0。
    /// 「N 本がほぼ同時に（0.25 秒以内に）着地し、そろってから 1.2 秒以内に押し込んだ」ときだけ数える。
    /// 指を置いたまま別の指でクリックしただけのときに、⌘クリックなどにならないようにするため
    var intentionalClickFingers: Int {
        lock.lock()
        defer { lock.unlock() }
        let n = engines.values.map(\.currentCount).max() ?? 0
        guard n >= 3, let reached = reachedAt[n] else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        return (reached - touchStartAt <= 0.25 && now - reached <= 1.2) ? n : 0
    }

    /// 押し込みクリックがあったことを伝える（そのタッチはタップ扱いにしない）
    func noteClick() {
        lock.lock()
        for e in engines.values where e.currentCount > 0 { e.noteClick() }
        lock.unlock()
    }

    // MARK: - フレーム処理（MultitouchSupport のスレッド）

    fileprivate func handle(device: MTBDeviceRef?, touches: UnsafePointer<MTBTouch>?, count: Int, timestamp: Double) {
        var active: [MTBTouch] = []
        if let touches, count > 0 {
            active.reserveCapacity(count)
            for i in 0..<count {
                let t = touches[i]
                // 3: MakeTouch, 4: Touching だけを「触れている指」として数える
                if t.state == 3 || t.state == 4 {
                    active.append(t)
                }
            }
        }

        // fingerID / handID が 0 の接触はパーム（手のひら）として除外する。
        // ただしデバイスによっては ID が入らないことがあるので、全員 0 なら従来どおり使う。
        let identified = active.filter { $0.fingerID != 0 && $0.handID != 0 }
        let chosen = identified.isEmpty ? active : identified
        let points = chosen.map {
            TouchPoint(id: $0.pathIndex, x: $0.normalized.position.x, y: $0.normalized.position.y)
        }

        let key = UInt(bitPattern: device)
        if debug && points.count != lastFingerCount {
            lastFingerCount = points.count
            let ids = chosen.map { "\($0.fingerID)/\($0.handID)" }.joined(separator: ",")
            log("指 \(points.count) 本 (ids=\(ids))")
        }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if points.count != lastCountForClick {
            if points.isEmpty {
                reachedAt.removeAll()
            } else {
                if lastCountForClick == 0 { touchStartAt = now }
                if points.count > lastCountForClick { reachedAt[points.count] = now }
            }
            lastCountForClick = points.count
        }
        if scrollSuppressFingers > 0, points.count >= scrollSuppressFingers {
            multiActive = true
        } else if points.isEmpty, multiActive {
            multiActive = false
            multiEndedAt = ProcessInfo.processInfo.systemUptime
        }
        if debug && !receivedFirstFrame {
            receivedFirstFrame = true
            log("最初のタッチを受信しました（指 \(points.count) 本）")
        }
        let engine: GestureEngine
        if let e = engines[key] {
            engine = e
        } else {
            engine = GestureEngine(config: config)
            engines[key] = engine
        }
        let event = engine.process(points, time: timestamp)
        let delta = engine.lastDelta
        let summary = debug ? engine.takeSummary() : nil
        lock.unlock()

        if let summary, summary.contains("本") && !summary.hasPrefix("最大1本") && !summary.hasPrefix("最大2本") {
            log("タッチ終了: \(summary)")
        }

        guard let event else { return }
        if debug {
            log(String(format: "ジェスチャー %@ (dx=%.3f dy=%.3f)", String(describing: event), delta.dx, delta.dy))
        }
        DispatchQueue.main.async { [weak self] in
            self?.onGesture?(event)
        }
    }

    // MARK: - デバイスの抜き差し・スリープ復帰

    private func observeDeviceChangesIfNeeded() {
        guard notifyPort == nil else { return }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart(after: 1.5)
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { _, iterator in
            let count = drain(iterator)
            if count > 0 { MultitouchManager.shared.scheduleRestart() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                         IOServiceMatching("AppleMultitouchDevice"),
                                         callback, nil, &matchIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                         IOServiceMatching("AppleMultitouchDevice"),
                                         callback, nil, &terminateIterator)
        // 既存分を読み捨てて通知を有効化する
        let existing = drain(matchIterator)
        drain(terminateIterator)
        log("IOKit: AppleMultitouchDevice \(existing) 件")
    }

    func log(_ message: String) {
        if debug { NSLog("[TriTab] %@", message) }
    }
}

@discardableResult
private func drain(_ iterator: io_iterator_t) -> Int {
    var count = 0
    while case let object = IOIteratorNext(iterator), object != 0 {
        IOObjectRelease(object)
        count += 1
    }
    return count
}

/// C から呼ばれるコールバック（キャプチャなしのクロージャ = C 関数ポインタ）
private let frameCallback: MTBFrameCallback = { device, touches, count, timestamp, _ in
    MultitouchManager.shared.handle(device: device, touches: touches, count: Int(count), timestamp: timestamp)
}
