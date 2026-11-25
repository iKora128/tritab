import Foundation

/// トレイの中身の保存と、コピーの置き場所。
///
///     ~/Library/Application Support/<バンドル ID>/
///       Memos/                     メモ（.txt）
///       Shelf/shelf.json           トレイに置いたものの一覧（並び順と、参照のブックマーク）
///       Shelf/Copies/<ID>/<名前>   トレイに作ったコピーと、貼り付けた画像
///
/// 再起動やアップデートのあとも、トレイの中身はそのまま戻る。
/// コピーとメモはトレイから外すとゴミ箱へ移す（間違えて外しても戻せるように）。参照の元のファイルには触らない。
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
        /// まとめの中身
        var members: [Record]?
        /// トレイに置いた日時（0.1.1 までの一覧にはない）
        var added: Date?

        init(_ item: ShelfItem) {
            id = item.id
            kind = item.kind
            path = item.url.path
            bookmark = item.bookmark
            source = item.sourceURL?.path
            copying = !item.isGroup && item.status == .copying ? true : nil
            members = item.isGroup ? item.members.map(Record.init) : nil
            added = item.addedAt
        }

        /// 置いた日時を覚えていないファイルがある
        var lacksDate: Bool { members?.contains(where: \.lacksDate) ?? (added == nil) }
    }

    public func save(_ items: [ShelfItem]) {
        guard let data = try? JSONEncoder().encode(items.map(Record.init)) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: listURL, options: .atomic)
    }

    /// 保存してあるトレイの中身を読み込む。参照は元の場所を確かめ直し、作りかけのコピーと、一覧にないコピーのフォルダは片付ける。
    /// 置いた日時を覚えていない項目（0.1.1 までに置いたもの）は、読み込んだ時点を置いた日時にして保存し直す
    /// （古い項目を自動で削除する設定にしても、アップデートした直後にまとめて消えないように）
    public func load(now: Date = Date()) -> [ShelfItem] {
        var items: [ShelfItem] = []
        let records = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        var seen = Set<UUID>()
        for r in records where seen.insert(r.id).inserted {
            if let item = restore(r, now: now) { items.append(item) }
        }
        // 一覧にないメモ（0.1.0 までに作ったもの）を後ろに足す
        let known = Set(items.flatMap(\.files).map { $0.url.standardizedFileURL.path })
        let memos = ((try? fm.contentsOfDirectory(at: memoDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" && !known.contains($0.standardizedFileURL.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        items += memos.map { ShelfItem(kind: .memo, url: $0, addedAt: now) }
        sweep(keeping: items)
        if !memos.isEmpty || records.contains(where: \.lacksDate) { save(items) }
        return items
    }

    /// 保存してあった 1 項目を戻す。作りかけのコピーは捨て、消えたメモは外す。
    /// まとめの中身が 1 つになったら、ふつうの項目に戻す
    private func restore(_ r: Record, now: Date) -> ShelfItem? {
        if let members = r.members {
            let files = members.compactMap { restore($0, now: now) }
            return files.isEmpty ? nil : ShelfItem.group(files, id: r.id)
        }
        if r.copying == true {
            removeCopyFolder(r.id)
            return nil
        }
        var item = ShelfItem(id: r.id, kind: r.kind, url: URL(fileURLWithPath: r.path), bookmark: r.bookmark,
                             sourceURL: r.source.map { URL(fileURLWithPath: $0) }, addedAt: r.added ?? now)
        if r.kind == .memo, !fm.fileExists(atPath: item.url.path) { return nil }
        refresh(&item)
        return item
    }

    // MARK: 項目を作る

    /// 元のファイルを指す参照。ブックマークで持つので、元が移動・名前変更されても追える
    public func reference(to url: URL) -> ShelfItem {
        ShelfItem(kind: .reference, url: url, bookmark: try? url.bookmarkData())
    }

    /// トレイの中に作るコピー。場所だけを決める（中身は `ShelfLibrary.copy(from:to:)` で作る）。
    /// 参照をコピーに切り替えるときは、同じ id を渡す
    public func plannedCopy(of source: URL, id: UUID = UUID()) -> ShelfItem {
        ShelfItem(id: id, kind: .copy, url: copyLocation(id, name: source.lastPathComponent), sourceURL: source,
                  status: .copying)
    }

    /// 中身をトレイの中に書き出す（貼り付けた画像など）
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

    /// Web のリンクを、トレイの中にリンクのファイル（.webloc。Finder やブラウザで開ける）として書き出す。
    /// 名前はページやリンクの題名、なければサイトの名前
    public func storeLink(_ url: URL, title: String?) -> ShelfItem? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                                             format: .xml, options: 0) else { return nil }
        return store(data, name: Self.linkFileName(for: url, title: title))
    }

    /// リンクのファイルの名前（ファイル名に使えない文字を除き、長すぎるものは切る）
    static func linkFileName(for url: URL, title: String?) -> String {
        let cleaned = (title ?? "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? (url.host ?? "Link") : cleaned
        return String(name.prefix(80)).trimmingCharacters(in: .whitespaces) + ".webloc"
    }

    /// リンクのファイル（.webloc）が指している場所
    public static func linkTarget(of file: URL) -> URL? {
        guard file.pathExtension == "webloc", let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String else { return nil }
        return URL(string: string)
    }

    /// コピーを作る。大きなファイルは時間がかかるので、メインスレッド以外で呼ぶ。
    /// 同じ APFS のディスクの中ならクローンになるので、すぐに終わり、容量もほとんど使わない
    public static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }

    /// コピーは 1 つずつ専用のフォルダに入れる（同じ名前のファイルがぶつからないように。外へ出すときは元の名前のまま）
    public func copyLocation(_ id: UUID, name: String) -> URL {
        let safe = name.isEmpty || name == "/" ? "Item" : name
        return copyFolder(id).appendingPathComponent(safe)
    }

    /// 1 つのコピーを入れるフォルダ（ドラッグ元が書き出すファイルは、ここへ書いてもらう）
    public func copyFolder(_ id: UUID) -> URL {
        copiesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: 状態

    /// ファイルの場所と状態を確かめ直す。参照は元が移動していれば新しい場所に、見つからなければ missing にする。
    /// 変わったら true
    @discardableResult
    public func refresh(_ item: inout ShelfItem) -> Bool {
        let before = item
        if item.isGroup {
            for i in item.members.indices { refresh(&item.members[i]) }
            item.updateGroupState()
            return item != before
        }
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

    /// つかんで持ち出す瞬間に使う、軽い確かめ。ファイルがいまの場所にあれば、ブックマークは解決しない
    /// （iCloud Drive の中などは解決に時間がかかり、つかんだまま待たせてしまうため。場所はトレイを開いたときに確かめ直してある）。
    /// いまの場所に見つからないときだけ `refresh` と同じことをする（参照はブックマークで追い直す）
    @discardableResult
    public func quickRefresh(_ item: inout ShelfItem) -> Bool {
        let before = item
        if item.isGroup {
            for i in item.members.indices { quickRefresh(&item.members[i]) }
            item.updateGroupState()
            return item != before
        }
        if item.status == .copying { return false }
        guard fm.fileExists(atPath: item.url.path) else { return refresh(&item) }
        item.status = item.kind == .reference && Self.isInTrash(item.url) ? .trashed : .ready
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

    /// トレイから外したときの後始末。コピーとメモはゴミ箱へ（戻せるように）。参照の元のファイルには触らない
    public func discard(_ item: ShelfItem) {
        guard !item.isGroup else { return item.members.forEach(discard) }
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
        for file in item.files where file.kind == .copy {
            removeCopyFolder(file.id, onlyIfEmpty: true)
        }
    }

    /// コピーのフォルダを消す（作りかけのものや、作っている途中でトレイから外したもの）
    public func removeCopyFolder(_ id: UUID, onlyIfEmpty: Bool = false) {
        let folder = copyFolder(id)
        if onlyIfEmpty, !visibleContents(of: folder).isEmpty { return }
        try? fm.removeItem(at: folder)
    }

    /// 一覧にないコピーのフォルダを片付ける。中身が残っていればゴミ箱へ（念のため戻せるように）、空なら消す
    func sweep(keeping items: [ShelfItem]) {
        let keep = Set(items.flatMap(\.files).filter { $0.kind == .copy }.map(\.id.uuidString))
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
