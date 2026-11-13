import Foundation

/// 旧名（Swiper, バンドル ID dev.swiper.Swiper）からの引き継ぎ。初回起動時に 1 回だけ行う。
/// - 設定（UserDefaults）を新しいドメインへコピー
/// - メモのフォルダを新しい場所へ移動
enum Migration {
    private static let oldBundleID = "dev.swiper.Swiper"
    private static let doneKey = "migratedFromSwiper"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = defaults.persistentDomain(forName: oldBundleID) {
            for (key, value) in old where defaults.object(forKey: key) == nil || isRegisteredOnly(key) {
                defaults.set(value, forKey: key)
            }
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldMemos = support.appendingPathComponent(oldBundleID).appendingPathComponent("Memos")
        let newMemos = ShelfController.memoDirectory
        if FileManager.default.fileExists(atPath: oldMemos.path), !FileManager.default.fileExists(atPath: newMemos.path) {
            try? FileManager.default.createDirectory(at: newMemos.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: oldMemos, to: newMemos)
        }
    }

    /// 既定値（register）だけで、まだ保存されていない設定か
    private static func isRegisteredOnly(_ key: String) -> Bool {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil
    }
}
