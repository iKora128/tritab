import Foundation

// MARK: - 棚の項目

/// ノッチの棚に置いた 1 項目。
///
/// - 参照（reference）: 元のファイルはその場に置いたまま、ブックマークで指す。外へドラッグすると元のファイルが移動する
/// - コピー（copy）: 棚の中に複製を持つ。外へドラッグすると複製が移動し、元のファイルはそのまま。貼り付けた画像もこれ
/// - メモ（memo）: 棚で書いたメモ（.txt）。外へドラッグしても書き出すだけで、棚に残る
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

    public init(id: UUID = UUID(), kind: Kind, url: URL, bookmark: Data? = nil, sourceURL: URL? = nil,
                status: Status = .ready) {
        self.id = id
        self.kind = kind
        self.url = url
        self.bookmark = bookmark
        self.sourceURL = sourceURL
        self.status = status
    }

    /// ドラッグ・Quick Look・開く・Finder で表示に使えるか
    public var isAvailable: Bool { status == .ready }
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

/// 棚へ落とすときの置き方。ドラッグ中は棚を左右に分け、左に落とすとコピー、右に落とすと参照で置く
public enum ShelfDropMode: Equatable, Sendable {
    case copy, reference
}

public enum ShelfRules {
    /// カーソルの位置での置き方（棚の左半分 = コピー、右半分 = 参照）
    public static func dropMode(atX x: Double, shelfMinX: Double, shelfMaxX: Double) -> ShelfDropMode {
        x < (shelfMinX + shelfMaxX) / 2 ? .copy : .reference
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
