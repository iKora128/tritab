import Foundation

// MARK: - トレイの項目

/// ノッチのトレイに置いた 1 項目。
///
/// - 参照（reference）: 元のファイルはその場に置いたまま、ブックマークで指す。外へドラッグすると元のファイルが移動する
/// - コピー（copy）: トレイの中に複製を持つ。外へドラッグすると複製が移動し、元のファイルはそのまま。貼り付けた画像もこれ
/// - メモ（memo）: トレイで書いたメモ（.txt）。外へドラッグしても書き出すだけで、トレイに残る
///
/// 一度に置いた 2 つ以上のファイルは、1 つの「まとめ」にする（Yoink のスタックと同じ）。
/// まとめは `members` に 1 ファイルずつの項目を持ち、自分の `url` などは先頭のファイルのもの
public struct ShelfItem: Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case reference, copy, memo
    }

    public enum Status: Equatable, Sendable {
        /// 使える
        case ready
        /// トレイにコピーを作っている途中
        case copying
        /// ファイルが見つからない
        case missing
        /// 元のファイルがゴミ箱に入っている
        case trashed
    }

    public let id: UUID
    public var kind: Kind
    /// いまのファイルの場所。参照は最後に見つかった元の場所、コピーとメモはトレイの中
    public var url: URL
    /// 参照: 元のファイルのブックマーク（元が移動・名前変更されても追える）
    public var bookmark: Data?
    /// コピー: 複製した元の場所（表示用。貼り付けた画像は nil）
    public var sourceURL: URL?
    public var status: Status
    /// まとめの中身（1 ファイルずつの項目）。ふつうの項目なら空
    public var members: [ShelfItem]
    /// トレイに置いた日時（古い項目を自動で削除するときに使う）。まとめは、中でいちばん新しいファイルの日時
    public var addedAt: Date

    public init(id: UUID = UUID(), kind: Kind, url: URL, bookmark: Data? = nil, sourceURL: URL? = nil,
                status: Status = .ready, members: [ShelfItem] = [], addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.url = url
        self.bookmark = bookmark
        self.sourceURL = sourceURL
        self.status = status
        self.members = members
        self.addedAt = addedAt
        updateGroupState()
    }

    /// 一度に置いたファイルをまとめる。1 つだけならそのまま返す
    public static func group(_ files: [ShelfItem], id: UUID = UUID()) -> ShelfItem {
        precondition(!files.isEmpty)
        guard files.count > 1 else { return files[0] }
        return ShelfItem(id: id, kind: files[0].kind, url: files[0].url, members: files)
    }

    /// ドラッグ・Quick Look・開く・Finder で表示に使えるか（まとめは、使えるファイルが 1 つでもあれば）
    public var isAvailable: Bool { status == .ready }
    public var isGroup: Bool { !members.isEmpty }
    /// 中のファイル（まとめなら中身、ふつうの項目ならそれ自身）
    public var files: [ShelfItem] { members.isEmpty ? [self] : members }
    /// 見つからない・ゴミ箱の中のファイルの数
    public var missingCount: Int { files.filter { $0.status == .missing || $0.status == .trashed }.count }

    /// まとめの種類・場所・状態を、中身から決め直す。
    /// 作っている途中のコピーがあればコピー中、使えるファイルが 1 つでもあれば使える
    public mutating func updateGroupState() {
        guard let first = members.first else { return }
        url = first.url
        kind = first.kind
        addedAt = members.map(\.addedAt).max() ?? addedAt
        if members.contains(where: { $0.status == .copying }) {
            status = .copying
        } else if members.contains(where: \.isAvailable) {
            status = .ready
        } else {
            status = members.allSatisfy { $0.status == .trashed } ? .trashed : .missing
        }
    }

    /// 中のファイルの状態を変える
    public mutating func setStatus(_ newStatus: Status, ofFile fileID: UUID) {
        updateFile(fileID) { $0.status = newStatus }
    }

    /// 中のファイルを書き換える（まとめなら、そのあと種類・場所・状態を決め直す）
    public mutating func updateFile(_ fileID: UUID, _ change: (inout ShelfItem) -> Void) {
        if members.isEmpty {
            if id == fileID { change(&self) }
            return
        }
        guard let i = members.firstIndex(where: { $0.id == fileID }) else { return }
        change(&members[i])
        updateGroupState()
    }

    /// そのファイルを除いた項目。何も残らなければ nil、まとめに 1 つだけ残ったらふつうの項目に戻す
    public func removingFiles(_ ids: Set<UUID>) -> ShelfItem? {
        let rest = files.filter { !ids.contains($0.id) }
        if rest.isEmpty { return nil }
        if rest.count == files.count { return self }
        if rest.count == 1 { return rest[0] }
        var item = self
        item.members = rest
        item.updateGroupState()
        return item
    }

    /// 使えるファイルだけにした項目（外へドラッグするとき。見つからないものやコピー中のものは持ち出さない）
    public func keepingAvailableFiles() -> ShelfItem {
        guard isGroup else { return self }
        var item = self
        item.members = members.filter(\.isAvailable)
        return item
    }
}

// MARK: - 選択

/// トレイの項目の選択。⌘クリックで足し引き、⇧クリックで範囲、⌘A で全部、矢印キーで隣へ。
public struct ShelfSelection<ID: Hashable>: Equatable {
    public private(set) var ids: Set<ID> = []
    /// ⇧クリックの起点（最後にふつうのクリックか ⌘クリックをした項目）
    public private(set) var anchor: ID?
    /// 矢印キーで動かすときの今の位置（最後にクリックした項目か、矢印で移った項目）
    public private(set) var focus: ID?

    /// 矢印キーの向き
    public enum Direction: Sendable { case left, right, up, down }

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// 項目を押したとき。
    /// - 修飾キーなし: その項目だけを選ぶ。すでに選んである項目なら、まとめてドラッグできるようにそのまま
    ///   （離したときにドラッグしていなければ、呼ぶ側が `select(_:)` で選び直す。Finder と同じ）
    /// - ⌘: 足す / 外す
    /// - ⇧: 起点からその項目までを足す
    public mutating func click(_ id: ID, in order: [ID], command: Bool = false, shift: Bool = false) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            ids.formUnion(order[min(a, b)...max(a, b)])
            focus = id
        } else if command || shift {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            focus = id
        } else if !ids.contains(id) {
            select(id)
        }
    }

    /// その項目だけを選ぶ
    public mutating func select(_ id: ID) {
        ids = [id]
        anchor = id
        focus = id
    }

    public mutating func selectAll(_ order: [ID]) {
        ids = Set(order)
        if anchor.map({ !order.contains($0) }) ?? true { anchor = order.first }
        if focus.map({ !order.contains($0) }) ?? true { focus = anchor }
    }

    public mutating func clear() {
        ids = []
        anchor = nil
        focus = nil
    }

    /// トレイから消えた項目を選択からも外す
    public mutating func keep(_ order: [ID]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
        if let focus, !order.contains(focus) { self.focus = nil }
    }

    /// 矢印キーを押したとき。選択を隣の項目へ動かす（←→ は 1 つ、↑↓ は 1 段。columns は 1 段に並ぶ数）。
    /// ⇧ を押していれば、起点からそこまでを選ぶ。
    /// 何も選んでいなければ、start（マウスが乗っている項目）か、押した向きの端の項目を選ぶ。選択が変わったら true
    @discardableResult
    public mutating func move(_ direction: Direction, in order: [ID], columns: Int, extend: Bool = false, start: ID? = nil) -> Bool {
        guard !order.isEmpty else { return false }
        let columns = max(columns, 1)
        guard let current = (focus ?? order.first(where: ids.contains)).flatMap({ order.firstIndex(of: $0) }) else {
            let backward = direction == .left || direction == .up
            select(start.flatMap { order.contains($0) ? $0 : nil } ?? (backward ? order[order.count - 1] : order[0]))
            return true
        }
        var next: Int
        switch direction {
        case .left: next = current - 1
        case .right: next = current + 1
        case .up: next = current - columns
        case .down:
            next = current + columns
            // 下に段はあるのに真下に項目がないときは、最後の項目へ（Finder と同じ）
            if next >= order.count, current / columns < (order.count - 1) / columns { next = order.count - 1 }
        }
        guard order.indices.contains(next) else { return false }
        if extend {
            let a = anchor.flatMap { order.firstIndex(of: $0) } ?? current
            ids = Set(order[min(a, next)...max(a, next)])
            anchor = order[a]
            focus = order[next]
        } else {
            select(order[next])
        }
        return true
    }

    /// その項目からドラッグを始めたときに持ち出すもの（トレイの並び順）。
    /// 選んである項目からなら選んだもの全部、選んでいない項目からならその項目だけ
    public func dragItems(from id: ID, in order: [ID]) -> [ID] {
        ids.contains(id) ? order.filter(ids.contains) : [id]
    }
}

// MARK: - ドラッグの決まり

/// ドラッグの操作。AppKit の NSDragOperation と同じ意味（TriTabCore を AppKit に依存させないため別に持つ）
public struct ShelfDragOperation: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let copy = ShelfDragOperation(rawValue: 1 << 0)
    public static let link = ShelfDragOperation(rawValue: 1 << 1)
    public static let generic = ShelfDragOperation(rawValue: 1 << 2)
    public static let move = ShelfDragOperation(rawValue: 1 << 4)
}

/// トレイへ置くときの置き方。ふだんはトレイの上のスイッチ（設定と同じ値）で決め、ドラッグ中の修飾キーでその場だけ変えられる
public enum ShelfDropMode: String, CaseIterable, Sendable {
    case reference, copy
}

/// ドラッグや貼り付けで持ってきたもの。トレイはこの順に見て、最初に当てはまるものとして受け取る
public enum ShelfDropContent: Equatable, Sendable {
    /// ファイル（Finder など）。置き方のスイッチに従う
    case files
    /// 落としたあとにドラッグ元が書き出すファイル（ブラウザの画像、写真、メールの添付など）。トレイの中に保存する
    case promisedFiles
    /// 画像のデータ。トレイの中に画像ファイルとして保存する
    case image
    /// Web のリンク。トレイの中にリンクのファイル（.webloc）として保存する
    case link
    /// テキスト。メモにする
    case text

    /// ドラッグを上へ動かすだけでトレイを出すか（ファイルと画像）。
    /// リンクとテキストは、ノッチやトレイまで持ってきたときだけ開く。タブやテキストのドラッグは画面の上のほうでもよく行うため
    public var opensOnApproach: Bool {
        switch self {
        case .files, .promisedFiles, .image: return true
        case .link, .text: return false
        }
    }
}

/// ドラッグを上へ動かしたときのトレイの出方
public enum ShelfApproach: Equatable, Sendable {
    /// 何もしない
    case none
    /// ノッチから顔を出す（ここへ置ける、という合図）
    case peek
    /// トレイを広げて待つ
    case open
}

/// ファイルを持ってきたときに、トレイを広げる範囲（画面の上端の、左右の真ん中のまわり）
public struct ShelfReceiveArea: Equatable, Sendable {
    /// 画面の上端からこの距離までに来たら広げる
    public var depth: Double
    /// 左右の真ん中からこの距離までに来たら広げる（横長の画面の端のほうでは開かない）
    public var halfWidth: Double

    /// 広げたあと、範囲からこれだけ離れたら引っ込める。
    /// 広げる範囲より大きく取り、境目のあたりを行き来しても開いたり閉じたりしないようにする
    public static let retractMargin: Double = 150

    public init(depth: Double, halfWidth: Double) {
        self.depth = depth
        self.halfWidth = halfWidth
    }

    func contains(fromTop: Double, fromCenter: Double) -> Bool {
        fromTop < depth && fromCenter < halfWidth
    }

    func isFar(fromTop: Double, fromCenter: Double) -> Bool {
        fromTop > depth + Self.retractMargin || fromCenter > halfWidth + Self.retractMargin
    }
}

public enum ShelfRules {
    /// 何として受け取るか。ファイル → 書き出されるファイル → 画像 → リンク → テキストの順に見て、当てはまったところでやめる
    /// （ブラウザの画像はリンクや画像のデータも一緒に持っているので、元のファイルの形のまま受け取れるものを先にする）
    public static func dropContent(fileURLs: @autoclosure () -> Bool, promisedFiles: @autoclosure () -> Bool,
                                   image: @autoclosure () -> Bool, link: @autoclosure () -> Bool,
                                   text: @autoclosure () -> Bool) -> ShelfDropContent? {
        if fileURLs() { return .files }
        if promisedFiles() { return .promisedFiles }
        if image() { return .image }
        if link() { return .link }
        if text() { return .text }
        return nil
    }

    /// 上へ動かしたとみなす量（いちばん下まで来た位置から）
    public static let riseToPeek: Double = 20
    /// 画面の上端からこの距離までなら、上へ動かしていなくてもトレイを広げる（ノッチのすぐ近くまで来ている）
    public static let nearTop: Double = 80

    /// ドラッグの位置から、トレイの出方を決める。
    /// - fromTop: 画面の上端からの距離
    /// - fromCenter: 画面の左右の真ん中からの、横の距離
    /// - risen: このドラッグでいちばん下まで来た位置から、どれだけ上へ戻ったか
    /// - area: トレイを広げる範囲
    ///
    /// 上へ動かすと顔を出し、範囲に入るとトレイを広げる。
    /// 画面の上のほうでドラッグを始めただけでは開かない
    /// （Finder のウィンドウの中でファイルを動かすたびに、トレイが開いて邪魔をしないように）。
    /// 動かす速さは使わない。トラックパッドでは指を置き直すたびに止まるので、速さで決めると開いたり閉じたりをくり返す
    public static func approach(fromTop: Double, fromCenter: Double, risen: Double, area: ShelfReceiveArea) -> ShelfApproach {
        let rising = risen > riseToPeek
        if area.contains(fromTop: fromTop, fromCenter: fromCenter) && (rising || fromTop < nearTop) { return .open }
        return rising ? .peek : .none
    }

    /// 広げたトレイを引っ込めるか（トレイの上にいるときは、呼ぶ側で引っ込めない）。
    /// 広げる範囲から十分に離れたときだけ引っ込める。途中で止まっても引っ込めない
    public static func shouldRetract(fromTop: Double, fromCenter: Double, area: ShelfReceiveArea) -> Bool {
        area.isFar(fromTop: fromTop, fromCenter: fromCenter)
    }

    /// 自動で削除する項目（古い順）。置いてから `limit` 秒以上たったもの。コピーを作っている途中のものは削除しない
    public static func expired(_ items: [ShelfItem], olderThan limit: TimeInterval, now: Date) -> [UUID] {
        items.filter { $0.status != .copying && now.timeIntervalSince($0.addedAt) >= limit }
            .sorted { $0.addedAt < $1.addedAt }
            .map(\.id)
    }

    /// あとで消される場所のファイルか（一時フォルダやキャッシュ）。スクリーンショットのサムネイルや、
    /// アプリがドラッグのために書き出したファイルなど。参照で置くとすぐ見つからなくなるので、コピーで置く
    public static func isTemporary(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let caches = home.appendingPathComponent("Library/Caches").standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = ["/private/var/folders/", "/private/tmp/", "/var/folders/", "/tmp/", caches + "/"]
        return temporary.contains { path.hasPrefix($0) }
    }

    /// 落とすときの置き方。ふだんはスイッチで決めた置き方。
    /// ⌥ を押していればコピー、⌘⌥ なら参照（Finder の ⌥ でコピー、⌘⌥ でエイリアス、と同じ）
    public static func dropMode(default mode: ShelfDropMode, option: Bool, command: Bool) -> ShelfDropMode {
        guard option else { return mode }
        return command ? .reference : .copy
    }

    /// トレイへ落とすときにドラッグ元へ返す操作。カーソルの印になる（コピーは「+」、参照はエイリアスの矢印）。
    /// .move は返さない（ドラッグ元のアプリによっては、元のデータを消してしまうため）
    public static func dropOperation(for mode: ShelfDropMode, sourceAllows mask: ShelfDragOperation) -> ShelfDragOperation {
        let preferred: [ShelfDragOperation] = mode == .copy ? [.copy, .generic, .link] : [.link, .generic, .copy]
        return preferred.first(where: mask.contains) ?? []
    }

    /// トレイから外へドラッグするとき、行き先に許す操作。
    /// - 参照: 移動（Finder の既定で、同じディスクの中なら元のファイルが移動する）、⌥でコピー、⌘⌥でエイリアス
    /// - コピー: 移動（トレイの複製が行き先へ移る）と、⌥でコピー。エイリアスは作らせない（トレイから外すと複製は消えるため）
    /// - メモ: コピーだけ（トレイのメモ自体は動かさない）
    public static func dragOutOperations(for kind: ShelfItem.Kind) -> ShelfDragOperation {
        switch kind {
        case .reference: return [.copy, .link, .generic, .move]
        case .copy: return [.copy, .generic, .move]
        case .memo: return [.copy]
        }
    }

    /// まとめてドラッグするときは、全部に共通する操作だけを許す
    public static func dragOutOperations(for kinds: [ShelfItem.Kind]) -> ShelfDragOperation {
        kinds.reduce([.copy, .link, .generic, .move]) { $0.intersection(dragOutOperations(for: $1)) }
    }

    /// 外へ置いたあと、トレイに残すか。移動として受け取られたらトレイから消え、
    /// コピー（⌥を押しながら・別のディスク・メールへの添付など）やエイリアスならトレイに残る。メモはいつも残る
    public static func staysOnShelf(_ kind: ShelfItem.Kind, after operation: ShelfDragOperation) -> Bool {
        kind == .memo || operation.isDisjoint(with: [.move, .generic])
    }
}
