import AppKit
import TriTabCore

/// 隣のデスクトップ（操作スペース）へ移るためのキー。
///
/// Mission Control の「左（右）の操作スペースに移動」のキー（既定は ⌃← / ⌃→）を送って移る。
/// ドラッグ中にこのキーを押すと、つかんでいるウィンドウも一緒に移り、ファイルのドラッグも続く。
/// 公開 API でデスクトップを切り替える方法はないので、macOS 自身のショートカットに任せる。
enum SpaceSwitcher {
    /// com.apple.symbolichotkeys の番号（79: 左の操作スペースに移動、81: 右の操作スペースに移動）
    private static func hotKeyID(toRight: Bool) -> String { toRight ? "81" : "79" }

    /// 送るキー。ショートカットがオフなら nil。キーを変えている人には、その組み合わせを返す
    static func shortcut(toRight: Bool) -> KeyCombo? {
        let fallback = KeyCombo(toRight ? 124 : 123, .maskControl) // ⌃→ / ⌃←
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let entry = all[hotKeyID(toRight: toRight)] as? [String: Any]
        else { return fallback } // 一度も変えていなければ項目がない（既定のまま有効）
        if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3
        else { return fallback }
        // parameters は [文字コード, キーコード, 修飾キー]。修飾キーは CGEventFlags と同じビット
        let keyCode = parameters[1].intValue
        guard (0..<0xFFFF).contains(keyCode) else { return nil } // キーが割り当てられていない
        let flags = CGEventFlags(rawValue: parameters[2].uint64Value)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
        return KeyCombo(CGKeyCode(keyCode), flags)
    }

    /// 左右どちらのショートカットも使えるか
    static var isAvailable: Bool { shortcut(toRight: false) != nil && shortcut(toRight: true) != nil }

    /// システム設定の「キーボード」を開く（キーボードショートカット… › Mission Control にある）
    static func openShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
