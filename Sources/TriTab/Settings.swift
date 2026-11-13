import Carbon
import Foundation
import TriTabCore

enum Sensitivity: String, CaseIterable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: return L("高い（短いスワイプで反応）", "High (reacts to short swipes)")
        case .medium: return L("ふつう", "Medium")
        case .low: return L("低い（しっかりスワイプ・おすすめ）", "Low (needs a deliberate swipe; recommended)")
        }
    }

    /// トラックパッド横幅に対する必要移動量
    var threshold: Float {
        switch self {
        case .high: return 0.07
        case .medium: return 0.09
        case .low: return 0.11
        }
    }
}

/// UserDefaults に保存する設定
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "enabled": true,
            "fingers": 3,
            "leftIsNext": true,
            "upAction": TabAction.reopenTab.rawValue,
            "downAction": TabAction.closeTab.rawValue,
            "sensitivity": Sensitivity.low.rawValue,
            "allApps": true,
            "showHUD": true,
            "haptic": false,
            // タブまわりの追加ジェスチャー（BTT でよく使われるもの）は既定で ON
            "tapNewTab": true,
            "clickCmd": true,
            "clickReopen": true,
            "pinchReload": true,
            "swipeReverse": true,
            // タブ以外の機能は既定で OFF（配布時に「タブ操作アプリ」としてわかりやすくするため）
            "fiveFingerSleep": false,
            // 日本語入力を使っている人だけ、英数／かな切り替えを最初からオンにする
            "imeCmd": Self.usesJapaneseInput,
            "imeTap": Self.usesJapaneseInput,
            "shelf": false,
            "shelfAnimation": "jelly",
            "didOnboard": false,
        ])
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }

    var fingers: Int {
        get { d.integer(forKey: "fingers") == 4 ? 4 : 3 }
        set { d.set(newValue, forKey: "fingers") }
    }

    var leftIsNext: Bool {
        get { d.bool(forKey: "leftIsNext") }
        set { d.set(newValue, forKey: "leftIsNext") }
    }

    var upAction: TabAction {
        get { TabAction(rawValue: d.string(forKey: "upAction") ?? "") ?? .reopenTab }
        set { d.set(newValue.rawValue, forKey: "upAction") }
    }

    var downAction: TabAction {
        get { TabAction(rawValue: d.string(forKey: "downAction") ?? "") ?? .closeTab }
        set { d.set(newValue.rawValue, forKey: "downAction") }
    }

    var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: d.string(forKey: "sensitivity") ?? "") ?? .low }
        set { d.set(newValue.rawValue, forKey: "sensitivity") }
    }

    /// 対応表にないアプリでも汎用キー（⌃Tab / ⌘W / ⇧⌘T）を送る（既定: ON）
    var allApps: Bool {
        get { d.bool(forKey: "allApps") }
        set { d.set(newValue, forKey: "allApps") }
    }

    var showHUD: Bool {
        get { d.bool(forKey: "showHUD") }
        set { d.set(newValue, forKey: "showHUD") }
    }

    /// 発火した瞬間にトラックパッドを振動させる（Force Touch トラックパッドのみ）
    var haptic: Bool {
        get { d.bool(forKey: "haptic") }
        set { d.set(newValue, forKey: "haptic") }
    }

    /// N 本指タップで新しいタブ
    var tapNewTab: Bool { get { d.bool(forKey: "tapNewTab") } set { d.set(newValue, forKey: "tapNewTab") } }
    /// N 本指で押し込みクリック → ⌘+クリック（リンクを新しいタブで開く）
    var clickCmd: Bool { get { d.bool(forKey: "clickCmd") } set { d.set(newValue, forKey: "clickCmd") } }
    /// N+1 本指で押し込みクリック → 閉じたタブを復元
    var clickReopen: Bool { get { d.bool(forKey: "clickReopen") } set { d.set(newValue, forKey: "clickReopen") } }
    /// 左右スワイプのあと、指を離さずに逆へ戻すと、もう一度タブを移動する
    var swipeReverse: Bool { get { d.bool(forKey: "swipeReverse") } set { d.set(newValue, forKey: "swipeReverse") } }
    /// 親指＋2本指のピンチイン → 再読み込み
    var pinchReload: Bool { get { d.bool(forKey: "pinchReload") } set { d.set(newValue, forKey: "pinchReload") } }
    /// 5 本指で上スワイプ → ディスプレイをスリープ
    var fiveFingerSleep: Bool { get { d.bool(forKey: "fiveFingerSleep") } set { d.set(newValue, forKey: "fiveFingerSleep") } }
    /// ⌘ 単体で英数 / かな（左⌘=英数、右⌘=かな）
    var imeCmd: Bool { get { d.bool(forKey: "imeCmd") } set { d.set(newValue, forKey: "imeCmd") } }
    /// N+1 本指タップで英数 / かなを切り替え
    var imeTap: Bool { get { d.bool(forKey: "imeTap") } set { d.set(newValue, forKey: "imeTap") } }
    /// ノッチの棚
    var shelf: Bool { get { d.bool(forKey: "shelf") } set { d.set(newValue, forKey: "shelf") } }

    var shelfAnimation: ShelfAnimationStyle {
        ShelfAnimationStyle(rawValue: d.string(forKey: "shelfAnimation") ?? "") ?? .jelly
    }

    /// 日本語を使っている人か（表示言語が日本語、または日本語の入力ソースが有効）
    static let usesJapaneseInput: Bool = {
        if Locale.preferredLanguages.first?.hasPrefix("ja") == true { return true }
        let filter = [kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        return list.contains { source in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return false }
            let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
            return langs.contains { $0.hasPrefix("ja") }
        }
    }()

    var didOnboard: Bool {
        get { d.bool(forKey: "didOnboard") }
        set { d.set(newValue, forKey: "didOnboard") }
    }

    var mapping: GestureMapping {
        GestureMapping(leftIsNext: leftIsNext, up: upAction, down: downAction)
    }

    var engineConfig: GestureEngine.Config {
        var c = GestureEngine.Config()
        c.threshold = sensitivity.threshold
        c.allowReverse = swipeReverse
        return c
    }
}
