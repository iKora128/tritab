import AppKit
import TriTabCore

/// ドラッグや貼り付けで持ってきたものを読む。何として受け取るかの順番は `ShelfRules.dropContent` で決める。
///
/// ブラウザの画像は、ドラッグ元（ブラウザ）が落とした先にファイルを書き出す「ファイルの約束」で受け取る。
/// TriTab 自身は Web からダウンロードしない（通信はアップデートの確認だけ、という約束を守るため）
enum ShelfDrop {
    /// ドラッグ元が書き出すファイルの種類（新しい形式と、Chrome や Safari が使う古い形式）
    private static let promiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// トレイとノッチの受け口が受け取る種類
    static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        let images: [NSPasteboard.PasteboardType] = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        return [.fileURL] + promiseTypes + images + [.URL, .string]
    }()

    /// 落としたときの置き方: スイッチの置き方。⌥ を押していればコピー、⌘⌥ なら参照
    static func currentMode(default mode: ShelfDropMode) -> ShelfDropMode {
        let flags = NSEvent.modifierFlags
        return ShelfRules.dropMode(default: mode, option: flags.contains(.option), command: flags.contains(.command))
    }

    /// ドラッグ元へ返す操作（カーソルの印になる）。ファイル以外は、置き方によらずトレイの中に保存するのでコピー
    static func operation(for content: ShelfDropContent, mode: ShelfDropMode, sourceAllows mask: NSDragOperation) -> NSDragOperation {
        NSDragOperation(ShelfRules.dropOperation(for: content == .files ? mode : .copy, sourceAllows: ShelfDragOperation(mask)))
    }

    /// 何を持ってきたか。受け取れるものがなければ nil。
    /// - Parameter promises: ドラッグのときだけ true（ファイルの約束は貼り付けでは受け取れない）
    static func content(of pb: NSPasteboard, promises: Bool = true) -> ShelfDropContent? {
        ShelfRules.dropContent(
            fileURLs: !fileURLs(in: pb).isEmpty,
            promisedFiles: promises && !Set(pb.types ?? []).isDisjoint(with: promiseTypes),
            image: pb.canReadObject(forClasses: [NSImage.self], options: nil),
            link: webURL(in: pb) != nil,
            text: text(in: pb) != nil)
    }

    static func fileURLs(in pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func promises(in pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// Web のリンク（http / https）
    static func webURL(in pb: NSPasteboard) -> URL? {
        (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// リンクの題名（ブラウザが、リンクの文字やページの題名を入れてくれる）
    static func linkTitle(in pb: NSPasteboard) -> String? {
        pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
    }

    /// 空白だけではないテキスト
    static func text(in pb: NSPasteboard) -> String? {
        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 画像のデータと拡張子。PNG・JPEG・GIF などはそのまま保存し（画質や GIF の動きを保つ）、それ以外は PNG にする
    static func imageData(in pb: NSPasteboard) -> (data: Data, ext: String)? {
        let direct: [(String, String)] = [("public.png", "png"), ("public.jpeg", "jpg"), ("com.compuserve.gif", "gif"),
                                          ("public.heic", "heic"), ("org.webmproject.webp", "webp")]
        for (type, ext) in direct {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty { return (data, ext) }
        }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }
}
