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

/// 5本指で上へスワイプしたときにスリープさせるもの
enum FiveFingerSwipeUp: String, CaseIterable {
    case off, display, mac

    var label: String {
        switch self {
        case .off: return L("しない", "Off")
        case .display: return L("ディスプレイをスリープ", "Sleep Display")
        case .mac: return L("Mac をスリープ", "Sleep Mac")
        }
    }
}

/// UserDefaults に保存する設定
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        // 0.1.1 までは、5本指の上スワイプはディスプレイのスリープだけで、オン / オフの設定だった。
        // オンにしていた人は「ディスプレイをスリープ」にする（既定の値を登録する前に、保存された値だけを見る）
        if d.object(forKey: "fiveFingerUp") == nil, d.object(forKey: "fiveFingerSleep") != nil {
            d.set(d.bool(forKey: "fiveFingerSleep") ? FiveFingerSwipeUp.display.rawValue : FiveFingerSwipeUp.off.rawValue,
                  forKey: "fiveFingerUp")
            d.removeObject(forKey: "fiveFingerSleep")
        }
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
            "fiveFingerUp": FiveFingerSwipeUp.off.rawValue,
            "dragSpaces": false,
            // 日本語入力を使っている人だけ、英数／かな切り替えを最初からオンにする
            "imeCmd": Self.usesJapaneseInput,
            "imeTap": Self.usesJapaneseInput,
            "shelf": false,
            "shelfAnimation": "jelly",
            "shelfDropMode": ShelfDropMode.reference.rawValue,
            "shelfAutoRemove": 0, // 削除しない（トレイの中身は再起動しても残る、という動きを、選ばない限り変えない）
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
    /// 5 本指で上スワイプ → ディスプレイだけ、または Mac をスリープ（既定: しない）
    var fiveFingerSwipeUp: FiveFingerSwipeUp {
        get { FiveFingerSwipeUp(rawValue: d.string(forKey: "fiveFingerUp") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "fiveFingerUp") }
    }
    /// ドラッグ中に N 本指で左右へスワイプ → 隣のデスクトップへ（つかんでいるものも一緒に）
    var dragSpaces: Bool { get { d.bool(forKey: "dragSpaces") } set { d.set(newValue, forKey: "dragSpaces") } }
    /// ⌘ 単体で英数 / かな（左⌘=英数、右⌘=かな）
    var imeCmd: Bool { get { d.bool(forKey: "imeCmd") } set { d.set(newValue, forKey: "imeCmd") } }
    /// N+1 本指タップで英数 / かなを切り替え
    var imeTap: Bool { get { d.bool(forKey: "imeTap") } set { d.set(newValue, forKey: "imeTap") } }
    /// ノッチのトレイ
    var shelf: Bool { get { d.bool(forKey: "shelf") } set { d.set(newValue, forKey: "shelf") } }

    var shelfAnimation: ShelfAnimationStyle {
        ShelfAnimationStyle(rawValue: d.string(forKey: "shelfAnimation") ?? "") ?? .jelly
    }

    /// トレイに置くときの置き方（参照 / コピー）。トレイの上の帯のスイッチでも切り替わる
    var shelfDropMode: ShelfDropMode {
        get { ShelfDropMode(rawValue: d.string(forKey: "shelfDropMode") ?? "") ?? .reference }
        set { d.set(newValue.rawValue, forKey: "shelfDropMode") }
    }

    /// トレイに置いてからこの日数がたった項目を、自動で削除する（0 なら削除しない）
    var shelfAutoRemoveDays: Int {
        get { max(d.integer(forKey: "shelfAutoRemove"), 0) }
        set { d.set(newValue, forKey: "shelfAutoRemove") }
    }

    /// 自動で削除するまでの時間（削除しないなら nil）
    var shelfAutoRemoveAfter: TimeInterval? {
        shelfAutoRemoveDays > 0 ? TimeInterval(shelfAutoRemoveDays) * 24 * 60 * 60 : nil
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
        c.holdSwipe = dragSpaces // クリックを押さえている指を数えずに判定する
        return c
    }
}
