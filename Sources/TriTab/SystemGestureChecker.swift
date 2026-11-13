import AppKit

/// macOS 標準のトラックパッドジェスチャーとの衝突を調べる。
///
/// アプリ側からシステムのジェスチャーを止める方法はない（両方が同時に動いてしまう）ので、
/// 設定を読んで衝突を見つけ、システム設定を開いてもらう。設定の書き換えはしない。
struct GestureConflict {
    let title: String
    let fix: String
    /// 3 本指ドラッグなど、システム側を変えるより 4 本指モードを勧めるべきもの
    let suggestsFourFingerMode: Bool
}

enum SystemGestureChecker {
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",                  // 内蔵トラックパッド
        "com.apple.driver.AppleBluetoothMultitouch.trackpad", // Magic Trackpad
    ]

    /// どちらかのドメインで有効になっていれば、その値を返す
    private static func value(_ key: String) -> Int {
        var result = 0
        for domain in domains {
            let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
            if let n = v as? Int { result = max(result, n) }
            else if let b = v as? Bool, b { result = max(result, 1) }
        }
        return result
    }

    static func conflicts(fingers: Int) -> [GestureConflict] {
        var list: [GestureConflict] = []
        if fingers == 3 {
            switch value("TrackpadThreeFingerHorizSwipeGesture") {
            case 2:
                list.append(.init(title: "フルスクリーンアプリケーション間をスワイプ（3本指）",
                                  fix: "「その他のジェスチャ」で「4本指で左右にスワイプ」に変更", suggestsFourFingerMode: false))
            case 1:
                list.append(.init(title: "ページ間をスワイプ（3本指）",
                                  fix: "「その他のジェスチャ」で「2本指で左右にスクロール」に変更", suggestsFourFingerMode: false))
            default: break
            }
            if value("TrackpadThreeFingerVertSwipeGesture") != 0 {
                list.append(.init(title: "Mission Control / アプリExposé（3本指）",
                                  fix: "「その他のジェスチャ」で「4本指で上 / 下にスワイプ」に変更", suggestsFourFingerMode: false))
            }
            if value("TrackpadThreeFingerDrag") != 0 {
                list.append(.init(title: "3本指のドラッグ（アクセシビリティ）",
                                  fix: "このアプリを「4本指モード」に切り替えるのがおすすめです", suggestsFourFingerMode: true))
            }
            if value("TrackpadThreeFingerTapGesture") == 2 {
                list.append(.init(title: "調べる＆データ検出（3本指でタップ）",
                                  fix: "「ポイントとクリック」で「1本指で強めのクリック」またはオフに変更", suggestsFourFingerMode: false))
            }
        } else {
            if value("TrackpadFourFingerHorizSwipeGesture") == 2 {
                list.append(.init(title: "フルスクリーンアプリケーション間をスワイプ（4本指）",
                                  fix: "「その他のジェスチャ」でオフに変更", suggestsFourFingerMode: false))
            }
            if value("TrackpadFourFingerVertSwipeGesture") == 2 {
                list.append(.init(title: "Mission Control / アプリExposé（4本指）",
                                  fix: "「その他のジェスチャ」でオフに変更（キーボードの F3 などで代用）", suggestsFourFingerMode: false))
            }
        }
        return list
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
