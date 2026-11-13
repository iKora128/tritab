import Foundation

/// 画面の言語。日本語を優先している人には日本語、それ以外の人には英語を出す。
///
/// 判定には Foundation の標準の選び方（ユーザーの言語の優先順位と、TriTab が対応する en / ja の突き合わせ）を使う。
/// 例: 日本語 → ja、中国語・日本語・英語の順 → ja、英語・日本語の順 → en、フランス語だけ → en。
/// 「システム設定 › 一般 › 言語と地域 › アプリケーション」で TriTab だけ言語を変えた場合も、これに従う。
/// Info.plist の CFBundleLocalizations（en, ja）と同じ結果になるので、
/// macOS 標準の文言や Sparkle の画面とも言語がそろう。
///
/// forPreferences を省略すると、実行中のバンドル自体の対応言語でも絞り込まれてしまう
/// （Info.plist のない `swift run` などでは常に en になる）ので、ユーザーの言語設定を明示して渡す。
public enum Lang {
    public static let isJapanese: Bool =
        Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: Locale.preferredLanguages).first == "ja"
}

/// 画面に出す文言を日本語と英語で並べて書く。
///
///     L("設定…", "Settings…")
///     L("\(n)本指でタップ", "Tap with \(n) fingers")
///
/// ログ（TRITAB_DEBUG のときだけ出るもの）には使わない。
public func L(_ ja: String, _ en: String) -> String {
    Lang.isJapanese ? ja : en
}
