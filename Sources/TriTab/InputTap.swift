import AppKit
import Carbon.HIToolbox

/// クリックとキー入力を横取りするイベントタップ（アクセシビリティの許可が必要）。
///
/// - N 本指で押し込みクリック → クリックに ⌘ を足す（リンクを新しいタブで開く）
/// - N+1 本指で押し込みクリック → クリックを捨てて「閉じたタブを復元」
/// - ⌘ を単体で押して離す → 左⌘ は英数、右⌘ はかな（Karabiner の定番ルールと同じ）
/// - ドラッグ中かどうかを覚える（ドラッグ中のスワイプは、タブではなく隣のデスクトップへの移動にする）
///
/// タップは 2 つに分ける。押す・離す・キーなどはメインスレッドで受け、ドラッグ中の動き（leftMouseDragged）だけは
/// 専用のスレッドで受ける。タップを通る入力は、TriTab が返すまで先へ進まない。動きは途切れずに来るので、
/// メインスレッドで受けると、トレイを開くなどで TriTab が少し忙しいあいだ、どのアプリのドラッグも引っかかってしまう
final class InputTap {
    static let shared = InputTap()

    enum ClickDecision {
        case passThrough
        case addCommand
        /// クリックを捨てて、代わりにこの処理を実行する
        case replace(() -> Void)
    }

    /// 左ボタンが押された瞬間に、どう扱うかを決める（メインスレッド）
    var decideClick: (() -> ClickDecision)?
    /// true を返している間はスクロールを捨てる（3 本指ジェスチャー中のページ送り誤爆を防ぐ）
    var shouldSuppressScroll: (() -> Bool)?
    /// キーが押されたとき。true を返すとそのキーを捨てる（トレイの ⌘V など）
    var onKeyDown: ((CGEvent) -> Bool)?
    /// ⌘ 単体での英数 / かなを有効にするか
    var imeCommandEnabled = false

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// ドラッグ中の動きだけを受けるタップ（専用のスレッドで動かす）
    private var dragTap: CFMachPort?

    private enum ClickMode { case none, addingCommand, swallowing }

    private var pendingCommand: (keyCode: Int64, time: TimeInterval)?

    /// 押したときに決めたクリックの扱い（clickMode）と、左ボタンを押したまま動かしたか（dragged。離すまで true）。
    /// 押す・離すはメインスレッドのタップが、動かすはドラッグ用のスレッドのタップが触るので、ロックで守る
    private let stateLock = NSLock()
    private var clickMode: ClickMode = .none
    private var dragged = false

    /// ウィンドウやファイルをドラッグしている最中か（左ボタンを押したまま、マウスを動かした）。
    /// 離したイベントを取りこぼしても残り続けないよう、いまボタンが押されているかも確かめる
    var isDragging: Bool {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        stateLock.lock()
        defer { stateLock.unlock() }
        if dragged, !pressed { dragged = false }
        return dragged
    }

    private init() {}

    /// タップを作る。アクセシビリティ未許可だと失敗するので、許可後にもう一度呼ぶ。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = Self.makeTap([.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
                                      .keyDown, .flagsChanged, .scrollWheel], callback: tapCallback)
        else { return false }
        guard let dragTap = Self.makeTap([.leftMouseDragged], callback: dragTapCallback) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.dragTap = dragTap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // ドラッグ中の動きは、専用のスレッドで受けてすぐ返す（TriTab のメインスレッドが忙しくても待たせない）
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, dragTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: dragTap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "TriTab drag tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
        return true
    }

    private static func makeTap(_ types: [CGEventType], callback: CGEventTapCallBack) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: callback, userInfo: nil)
    }

    /// メインスレッドのタップ（押す・離す・キー・スクロールなど）
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            pendingCommand = nil
            let decision = decideClick?() ?? .passThrough
            let mode: ClickMode
            switch decision {
            case .passThrough: mode = .none
            case .addCommand: mode = .addingCommand
            case .replace: mode = .swallowing
            }
            stateLock.lock()
            clickMode = mode
            dragged = false
            stateLock.unlock()
            switch decision {
            case .passThrough:
                break
            case .addCommand:
                event.flags.insert(.maskCommand)
            case let .replace(action):
                DispatchQueue.main.async(execute: action)
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            // 離したら、クリックの扱いもドラッグ中の印も終わり
            stateLock.lock()
            let mode = clickMode
            clickMode = .none
            dragged = false
            stateLock.unlock()
            switch mode {
            case .none:
                break
            case .addingCommand:
                event.flags.insert(.maskCommand)
            case .swallowing:
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // ⌘ を押したまま何か操作したら「単体押し」ではない
            pendingCommand = nil
            if onKeyDown?(event) == true { return nil }
            return Unmanaged.passUnretained(event)

        case .rightMouseDown, .otherMouseDown:
            pendingCommand = nil
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            // ⌘ + スクロール（拡大など）も「単体押し」ではない
            pendingCommand = nil
            if shouldSuppressScroll?() == true {
                // 終了・キャンセルのイベントだけは通す（アプリ側のスクロール状態を正しく終わらせるため）
                let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                let ending = phase == 4 || phase == 8 || momentum == 3
                if !ending { return nil }
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// ドラッグ用のスレッドのタップ（左ボタンを押したまま動かした）。押したときに決めた扱いに合わせて、
    /// ⌘ を足す・捨てる・そのまま通す。メインスレッドの状態には触らない
    fileprivate func handleDragged(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let dragTap { CGEvent.tapEnable(tap: dragTap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            stateLock.lock()
            let mode = clickMode
            if mode != .swallowing { dragged = true }
            stateLock.unlock()
            switch mode {
            case .none:
                break
            case .addingCommand:
                event.flags.insert(.maskCommand)
            case .swallowing:
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        guard imeCommandEnabled else { pendingCommand = nil; return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isCommandKey = keyCode == Int64(kVK_Command) || keyCode == Int64(kVK_RightCommand)
        guard isCommandKey else { pendingCommand = nil; return }

        let flags = event.flags
        let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        if flags.contains(.maskCommand) {
            // 押した: ほかの修飾キーと一緒でなければ候補にする
            pendingCommand = flags.isDisjoint(with: others) ? (keyCode, ProcessInfo.processInfo.systemUptime) : nil
        } else {
            // 離した: 同じ ⌘ を 1 秒以内に単体で押して離したなら切り替える
            if let p = pendingCommand, p.keyCode == keyCode,
               ProcessInfo.processInfo.systemUptime - p.time < 1.0 {
                IMESwitcher.select(japanese: keyCode == Int64(kVK_RightCommand))
            }
            pendingCommand = nil
        }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    InputTap.shared.handle(type: type, event: event)
}

private func dragTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    InputTap.shared.handleDragged(type: type, event: event)
}

/// 英数 / かなキーを送って入力ソースを切り替える
enum IMESwitcher {
    private static let source = CGEventSource(stateID: .privateState)

    static func select(japanese: Bool) {
        let key = CGKeyCode(japanese ? kVK_JIS_Kana : kVK_JIS_Eisu)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// いまが英字入力なら日本語に、日本語なら英字に切り替える
    static func toggle() {
        select(japanese: currentIsASCII)
    }

    static var currentIsASCII: Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable)
        else { return true }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }
}
