import AppKit
import CoreGraphics

/// ダウンロード済みのアップデートを、Mac を使っていない隙に入れて再起動する。
///
/// Sparkle の「自動でダウンロードしてインストール」は、ふつうはアプリの終了時に入れ替える。
/// TriTab は常駐していて終了されることが少ないので、そのままだと再起動やログアウトまで更新が入らない。
/// そこで、更新がダウンロードされたら、次の条件がそろったときに Sparkle に入れてもらう（1 秒ほどで再起動する）。
///   - しばらく（idleSeconds）キーボード・マウス・トラックパッドの操作がない
///   - マウスのボタンが押されていない
///   - TriTab 側の事情で止める理由がない（isBusy。指が触れている、棚に中身がある、画面を開いている、など）
/// 条件がそろう前に TriTab が終了されたときは、Sparkle がその時点で入れる。
final class QuietUpdateInstaller {
    /// 何秒操作がなければ「使っていない」とみなすか。
    /// 確認用に `defaults write io.github.ikora128.TriTab quietUpdateIdleSeconds -float 10` で短くできる
    var idleSeconds: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "quietUpdateIdleSeconds")
        return custom > 0 ? custom : 60
    }
    /// 使っていないかを確かめる間隔
    var checkInterval: TimeInterval = 5
    /// TriTab 側の事情で、いま再起動してはいけないときに true を返す
    var isBusy: () -> Bool = { false }

    private var install: (() -> Void)?
    private var timer: Timer?

    /// Sparkle から、ダウンロード済みの更新をすぐ入れるための手段を受け取り、入れどきを待ち始める
    func schedule(_ immediateInstall: @escaping () -> Void) {
        install = immediateInstall
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.installIfQuiet()
        }
    }

    private func installIfQuiet() {
        guard let install, isQuiet else { return }
        timer?.invalidate()
        timer = nil
        self.install = nil
        install() // Sparkle が TriTab を終了し、入れ替えて起動し直す
    }

    private var isQuiet: Bool {
        guard NSEvent.pressedMouseButtons == 0, !isBusy() else { return false }
        // rawValue ~0 は kCGAnyInputEventType（キーボード・マウス・トラックパッドのどれか）
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= idleSeconds
    }
}
