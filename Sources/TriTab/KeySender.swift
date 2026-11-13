import ApplicationServices
import CoreGraphics
import TriTabCore

enum KeySender {
    /// 物理キーの押下状態と混ざらないように専用のイベントソースを使う
    private static let source = CGEventSource(stateID: .privateState)

    static func send(_ combo: KeyCombo) {
        var flags = combo.flags
        if combo.isArrow {
            // 実キーボードの矢印キーと同じフラグを付ける（付いていないと無視するアプリがある）
            flags.formUnion([.maskNumericPad, .maskSecondaryFn])
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// キー送信にはアクセシビリティの許可が必要
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
