import Foundation

/// 棚の中身の保存と、コピーの置き場所。
///
///     ~/Library/Application Support/<バンドル ID>/
///       Memos/                     メモ（.txt）
///       Shelf/shelf.json           棚に置いたものの一覧（並び順と、参照のブックマーク）
///       Shelf/Copies/<ID>/<名前>   棚に作ったコピーと、貼り付けた画像
///
/// 再起動やアップデートのあとも、棚の中身はそのまま戻る。
/// コピーとメモは棚から外すとゴミ箱へ移す（間違えて外しても戻せるように）。参照の元のファイルには触らない。
/// メインスレッドから使う（`copy(from:to:)` だけはどこからでもよい）。
public final class ShelfLibrary {
    public let directory: URL
    public let memoDirectory: URL
    private let trash: (URL) -> Void
    private let fm = FileManager.default

    /// - Parameter trash: ゴミ箱へ移す処理（テストで差し替える）
    public init(directory: URL, memoDirectory: URL,
                trash: @escaping (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory
        self.memoDirectory = memoDirectory
        self.trash = trash
    }

    public var copiesDirectory: URL { directory.appendingPathComponent("Copies", isDirectory: true) }
    var listURL: URL { directory.appendingPathComponent("shelf.json") }

    // MARK: 一覧の保存と読み込み

    private struct Record: Codable {
        var id: UUID
        var kind: ShelfItem.Kind
        var path: String
        var bookmark: Data?
        var source: String?
        /// コピーを作っている途中だった（起動したときに残っていたら、作りかけなので捨てる）
        var copying: Bool?
    }

    public func save(_ items: [ShelfItem]) {
        let records = items.map {
            Record(id: $0.id, kind: $0.kind, path: $0.url.path, bookmark: $0.bookmark,
                   source: $0.sourceURL?.path, copying: $0.status == .copying ? true : nil)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: listURL, options: .atomic)
    }

    /// 保存してある棚の中身を読み込む。参照は元の場所を確かめ直し、作りかけのコピーと、一覧にないコピーのフォルダは片付ける
    public func load() -> [ShelfItem] {
        var items: [ShelfItem] = []
        let records = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        var seen = Set<UUID>()
        for r in records where seen.insert(r.id).inserted {
            if r.copying == true {
                removeCopyFolder(r.id)
                continue
            }
            var item = ShelfItem(id: r.id, kind: r.kind, url: URL(fileURLWithPath: r.path), bookmark: r.bookmark,
                                 sourceURL: r.source.map { URL(fileURLWithPath: $0) })
            if r.kind == .memo, !fm.fileExists(atPath: item.url.path) { continue } // 消えたメモは外す
            refresh(&item)
            items.append(item)
        }
        // 一覧にないメモ（0.1.0 までに作ったもの）を後ろに足す
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        let memos = ((try? fm.contentsOfDirectory(at: memoDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" && !known.contains($0.standardizedFileURL.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        items += memos.map { ShelfItem(kind: .memo, url: $0) }
        sweep(keeping: items)
        return items
    }

    // MARK: 項目を作る

    /// 元のファイルを指す参照。ブックマークで持つので、元が移動・名前変更されても追える
    public func reference(to url: URL) -> ShelfItem {
        ShelfItem(kind: .reference, url: url, bookmark: try? url.bookmarkData())
    }

    /// 棚の中に作るコピー。場所だけを決める（中身は `ShelfLibrary.copy(from:to:)` で作る）。
    /// 参照をコピーに切り替えるときは、同じ id を渡す
    public func plannedCopy(of source: URL, id: UUID = UUID()) -> ShelfItem {
        ShelfItem(id: id, kind: .copy, url: copyLocation(id, name: source.lastPathComponent), sourceURL: source,
                  status: .copying)
    }

    /// 中身を棚の中に書き出す（貼り付けた画像など）
    public func store(_ data: Data, name: String) -> ShelfItem? {
        let id = UUID()
        let url = copyLocation(id, name: name)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return ShelfItem(id: id, kind: .copy, url: url)
        } catch {
            removeCopyFolder(id)
            return nil
        }
    }

    /// コピーを作る。大きなファイルは時間がかかるので、メインスレッド以外で呼ぶ。
    /// 同じ APFS のディスクの中ならクローンになるので、すぐに終わり、容量もほとんど使わない
    public static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }

    /// コピーは 1 つずつ専用のフォルダに入れる（同じ名前のファイルがぶつからないように。外へ出すときは元の名前のまま）
    func copyLocation(_ id: UUID, name: String) -> URL {
        let safe = name.isEmpty || name == "/" ? "Item" : name
        return copiesDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(safe)
    }

    // MARK: 状態

    /// ファイルの場所と状態を確かめ直す。参照は元が移動していれば新しい場所に、見つからなければ missing にする。
    /// 変わったら true
    @discardableResult
    public func refresh(_ item: inout ShelfItem) -> Bool {
        let before = item
        switch item.kind {
        case .reference:
            if let bookmark = item.bookmark, let (url, stale) = resolve(bookmark) {
                item.url = url
                if stale, let fresh = try? url.bookmarkData() { item.bookmark = fresh }
            }
            item.status = !fm.fileExists(atPath: item.url.path) ? .missing : Self.isInTrash(item.url) ? .trashed : .ready
        case .copy, .memo:
            if item.status != .copying {
                item.status = fm.fileExists(atPath: item.url.path) ? .ready : .missing
            }
        }
        return item != before
    }

    private func resolve(_ bookmark: Data) -> (URL, Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// ゴミ箱の中か（~/.Trash と、外付けディスクの .Trashes）
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    // MARK: 片付け

    /// 棚から外したときの後始末。コピーとメモはゴミ箱へ（戻せるように）。参照の元のファイルには触らない
    public func discard(_ item: ShelfItem) {
        switch item.kind {
        case .reference:
            break
        case .memo:
            if fm.fileExists(atPath: item.url.path) { trash(item.url) }
        case .copy:
            guard item.status != .copying else { return } // 作り終わったところで片付ける
            if fm.fileExists(atPath: item.url.path) { trash(item.url) }
            removeCopyFolder(item.id, onlyIfEmpty: true)
        }
    }

    /// 外へドラッグして移動されたコピーの、空になったフォルダを消す
    public func cleanUpAfterMove(_ item: ShelfItem) {
        guard item.kind == .copy else { return }
        removeCopyFolder(item.id, onlyIfEmpty: true)
    }

    /// コピーのフォルダを消す（作りかけのものや、作っている途中で棚から外したもの）
    public func removeCopyFolder(_ id: UUID, onlyIfEmpty: Bool = false) {
        let folder = copiesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if onlyIfEmpty, !visibleContents(of: folder).isEmpty { return }
        try? fm.removeItem(at: folder)
    }

    /// 一覧にないコピーのフォルダを片付ける。中身が残っていればゴミ箱へ（念のため戻せるように）、空なら消す
    func sweep(keeping items: [ShelfItem]) {
        let keep = Set(items.filter { $0.kind == .copy }.map(\.id.uuidString))
        let folders = (try? fm.contentsOfDirectory(at: copiesDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            visibleContents(of: folder).forEach(trash)
            try? fm.removeItem(at: folder)
        }
    }

    /// 隠しファイル（Finder が作る .DS_Store など）を除いた中身
    private func visibleContents(of folder: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }
}
