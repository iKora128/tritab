import AppKit
import Carbon.HIToolbox

/// クリックとキー入力を横取りするイベントタップ（アクセシビリティの許可が必要）。
///
/// - N 本指で押し込みクリック → クリックに ⌘ を足す（リンクを新しいタブで開く）
/// - N+1 本指で押し込みクリック → クリックを捨てて「閉じたタブを復元」
/// - ⌘ を単体で押して離す → 左⌘ は英数、右⌘ はかな（Karabiner の定番ルールと同じ）
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
    /// キーが押されたとき。true を返すとそのキーを捨てる（棚の ⌘V など）
    var onKeyDown: ((CGEvent) -> Bool)?
    /// ⌘ 単体での英数 / かなを有効にするか
    var imeCommandEnabled = false

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var clickMode: ClickMode = .none
    private enum ClickMode { case none, addingCommand, swallowing }

    private var pendingCommand: (keyCode: Int64, time: TimeInterval)?


    private init() {}

    /// タップを作る。アクセシビリティ未許可だと失敗するので、許可後にもう一度呼ぶ。
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: nil)
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            pendingCommand = nil
            switch decideClick?() ?? .passThrough {
            case .passThrough:
                clickMode = .none
            case .addCommand:
                clickMode = .addingCommand
                event.flags.insert(.maskCommand)
            case let .replace(action):
                clickMode = .swallowing
                DispatchQueue.main.async(execute: action)
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged, .leftMouseUp:
            switch clickMode {
            case .none:
                break
            case .addingCommand:
                event.flags.insert(.maskCommand)
            case .swallowing:
                if type == .leftMouseUp { clickMode = .none }
                return nil
            }
            if type == .leftMouseUp { clickMode = .none }
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
