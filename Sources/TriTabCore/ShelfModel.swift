import Foundation

// MARK: - 棚の項目

/// ノッチの棚に置いた 1 項目。
///
/// - 参照（reference）: 元のファイルはその場に置いたまま、ブックマークで指す。外へドラッグすると元のファイルが移動する
/// - コピー（copy）: 棚の中に複製を持つ。外へドラッグすると複製が移動し、元のファイルはそのまま。貼り付けた画像もこれ
/// - メモ（memo）: 棚で書いたメモ（.txt）。外へドラッグしても書き出すだけで、棚に残る
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
        /// 棚にコピーを作っている途中
        case copying
        /// ファイルが見つからない
        case missing
        /// 元のファイルがゴミ箱に入っている
        case trashed
    }

    public let id: UUID
    public var kind: Kind
    /// いまのファイルの場所。参照は最後に見つかった元の場所、コピーとメモは棚の中
    public var url: URL
    /// 参照: 元のファイルのブックマーク（元が移動・名前変更されても追える）
    public var bookmark: Data?
    /// コピー: 複製した元の場所（表示用。貼り付けた画像は nil）
    public var sourceURL: URL?
    public var status: Status
    /// まとめの中身（1 ファイルずつの項目）。ふつうの項目なら空
    public var members: [ShelfItem]

    public init(id: UUID = UUID(), kind: Kind, url: URL, bookmark: Data? = nil, sourceURL: URL? = nil,
                status: Status = .ready, members: [ShelfItem] = []) {
        self.id = id
        self.kind = kind
        self.url = url
        self.bookmark = bookmark
        self.sourceURL = sourceURL
        self.status = status
        self.members = members
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
        if members.isEmpty {
            if id == fileID { status = newStatus }
            return
        }
        guard let i = members.firstIndex(where: { $0.id == fileID }) else { return }
        members[i].status = newStatus
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

/// 棚の項目の選択。⌘クリックで足し引き、⇧クリックで範囲、⌘A で全部。
public struct ShelfSelection<ID: Hashable>: Equatable {
    public private(set) var ids: Set<ID> = []
    /// ⇧クリックの起点（最後にふつうのクリックか ⌘クリックをした項目）
    public private(set) var anchor: ID?

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
        } else if command || shift {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else if !ids.contains(id) {
            select(id)
        }
    }

    /// その項目だけを選ぶ
    public mutating func select(_ id: ID) {
        ids = [id]
        anchor = id
    }

    public mutating func selectAll(_ order: [ID]) {
        ids = Set(order)
        if anchor.map({ !order.contains($0) }) ?? true { anchor = order.first }
    }

    public mutating func clear() {
        ids = []
        anchor = nil
    }

    /// 棚から消えた項目を選択からも外す
    public mutating func keep(_ order: [ID]) {
        ids.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }

    /// その項目からドラッグを始めたときに持ち出すもの（棚の並び順）。
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

/// 棚へ置くときの置き方。ふだんは棚の上のスイッチ（設定と同じ値）で決め、ドラッグ中の修飾キーでその場だけ変えられる
public enum ShelfDropMode: String, CaseIterable, Sendable {
    case reference, copy
}

public enum ShelfRules {
    /// 落とすときの置き方。ふだんはスイッチで決めた置き方。
    /// ⌥ を押していればコピー、⌘⌥ なら参照（Finder の ⌥ でコピー、⌘⌥ でエイリアス、と同じ）
    public static func dropMode(default mode: ShelfDropMode, option: Bool, command: Bool) -> ShelfDropMode {
        guard option else { return mode }
        return command ? .reference : .copy
    }

    /// 棚へ落とすときにドラッグ元へ返す操作。カーソルの印になる（コピーは「+」、参照はエイリアスの矢印）。
    /// .move は返さない（ドラッグ元のアプリによっては、元のデータを消してしまうため）
    public static func dropOperation(for mode: ShelfDropMode, sourceAllows mask: ShelfDragOperation) -> ShelfDragOperation {
        let preferred: [ShelfDragOperation] = mode == .copy ? [.copy, .generic, .link] : [.link, .generic, .copy]
        return preferred.first(where: mask.contains) ?? []
    }

    /// 棚から外へドラッグするとき、行き先に許す操作。
    /// - 参照: 移動（Finder の既定で、同じディスクの中なら元のファイルが移動する）、⌥でコピー、⌘⌥でエイリアス
    /// - コピー: 移動（棚の複製が行き先へ移る）と、⌥でコピー。エイリアスは作らせない（棚から外すと複製は消えるため）
    /// - メモ: コピーだけ（棚のメモ自体は動かさない）
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

    /// 外へ置いたあと、棚に残すか。移動として受け取られたら棚から消え、
    /// コピー（⌥を押しながら・別のディスク・メールへの添付など）やエイリアスなら棚に残る。メモはいつも残る
    public static func staysOnShelf(_ kind: ShelfItem.Kind, after operation: ShelfDragOperation) -> Bool {
        kind == .memo || operation.isDisjoint(with: [.move, .generic])
    }
}
