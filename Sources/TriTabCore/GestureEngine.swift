import Foundation

public enum SwipeDirection: String, CaseIterable, Sendable {
    case left, right, up, down
}

public enum GestureEvent: Equatable, Sendable {
    /// N 本指スワイプ（1 スワイプにつき 1 回）
    case swipe(SwipeDirection, fingers: Int)
    /// N 本指で軽く触れてすぐ離した（押し込みクリックは含まない）
    case tap(fingers: Int)
    /// 指をつまむように寄せた（親指＋2本指のピンチイン）
    case pinchIn(fingers: Int)
}

public struct TouchPoint: Equatable, Sendable {
    /// 接触ごとの ID（指を離すまで同じ）。不明なら 0。
    public var id: Int32
    /// 0...1 正規化座標。原点は左下（y は上方向が正）。
    public var x: Float
    public var y: Float
    public init(id: Int32 = 0, x: Float, y: Float) { self.id = id; self.x = x; self.y = y }
}

/// 1 台のトラックパッド分のジェスチャー判定器（UI に依存しない純粋なロジック）。
///
/// 「セッション」= 最初の指が触れてから全部の指が離れるまで。
/// - スワイプ: 本数が確定した時点の重心を起点に、全部の指が同じ向きへしきい値以上動いたら 1 回だけ発火
/// - タップ: 短時間でほとんど動かずに全部離れ、押し込みクリックもなかったら、離した瞬間に発火
/// - ピンチイン: 重心はあまり動かず、指どうしの距離が縮んだら発火
/// 発火後は、指が全部離れるまで何もしない。
public final class GestureEngine {
    public struct Config: Equatable, Sendable {
        /// 発火に必要な移動量（トラックパッドの横幅に対する割合）
        public var threshold: Float = 0.10
        /// 縦方向の正規化移動量を横幅単位に直す係数（トラックパッドは横長なので縦の 1.0 は横より短い）
        public var verticalScale: Float = 0.65
        /// 主軸の移動量が副軸の何倍以上なら方向を確定するか
        public var dominance: Float = 1.5
        /// 本数が決まってからこの秒数を過ぎたらスワイプとしては発火しない（ゆっくりしたドラッグとの誤認防止）
        public var maxDuration: Double = 1.0
        /// 発火の瞬間に必要な指の速さ（横幅 / 秒）。ゆっくりずれただけ・置き直しただけでは発火しない
        public var minSpeed: Float = 0.3
        /// 速く払ったとき（フリック）は、この短い距離で発火する
        public var flickDistance: Float = 0.055
        /// この速さ以上なら flickDistance で発火する（横幅 / 秒）。
        /// minSpeed〜flickSpeed のあいだは、必要な距離が threshold → flickDistance へなめらかに短くなる
        public var flickSpeed: Float = 0.9
        /// 速さを測る時間幅（秒）
        public var speedWindow: Double = 0.06
        /// 各指がスワイプ方向にしきい値の何割以上動いていれば「全部の指が同じ向き」とみなすか
        public var consistency: Float = 0.4
        /// タップとみなす最大時間（秒）と最大移動量
        public var tapMaxDuration: Double = 0.2
        public var tapMaxMove: Float = 0.015
        /// 指どうしの広がりが開始時のこの割合以下になったらピンチイン
        public var pinchRatio: Float = 0.6
        /// これより少ない本数のジェスチャーは扱わない（1〜2 本指はスクロールやクリック）
        public var minFingers: Int = 3
        /// 指が一瞬見えなくなっても「離した」とみなさない時間（秒）。トラックパッドは指を 1 フレームだけ見失うことがある
        public var dropoutTolerance: Double = 0.05
        /// 左右スワイプのあと、指を離さずに逆向きへ戻したら、もう一度（逆向きで）発火する
        public var allowReverse: Bool = true
        /// 折り返しに必要な戻りの距離（払ったあとの自然な跳ね返りより十分大きく）
        public var reverseDistance: Float = 0.06

        public init() {}
    }

    struct Tracking {
        var count: Int
        var t0: Double
        var centroid: TouchPoint
        var startById: [Int32: TouchPoint]
        var spread: Float
    }

    public var config: Config
    /// デバッグ用: 直近の発火時の移動量（横幅単位）
    public private(set) var lastDelta: (dx: Float, dy: Float) = (0, 0)
    /// 今触れている指の本数（クリック時の判定に使う）
    public private(set) var currentCount = 0
    /// デバッグ用: 直前のタッチ（指を全部離すまで）の記録。取り出したら消える
    private var lastSummary: String?

    public func takeSummary() -> String? {
        defer { lastSummary = nil }
        return lastSummary
    }

    private var sessionStart: Double?
    private var maxCount = 0
    private var maxMove: Float = 0
    private var clicked = false
    private var fired = false
    private var lifting = false
    private var tracking: Tracking?
    /// 直近の重心（速さの計算用）
    private var recent: [(t: Double, x: Float, y: Float)] = []
    /// 本数が減り始めた時刻（一瞬の見失いと、本当に離したのとを区別する）
    private var lowCountSince: Double?
    // デバッグ用の記録
    private var statMaxDist: Float = 0
    private var statMaxSpeed: Float = 0
    private var statSlowBlocked = false
    private var statInconsistent = false
    private var statTimedOut = false
    private var statDropouts = 0
    private var statRestarts = 0
    private var statFired: GestureEvent?
    /// 折り返し待ち: 最後に発火した左右の向きと、そこからいちばん進んだ位置
    private var reverse: (direction: SwipeDirection, anchor: Float)?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 押し込みクリックがあった（このセッションはタップにしない）
    public func noteClick() {
        clicked = true
    }

    public func reset() {
        reverse = nil
        lowCountSince = nil
        statMaxDist = 0
        statMaxSpeed = 0
        statSlowBlocked = false
        statInconsistent = false
        statTimedOut = false
        statDropouts = 0
        statRestarts = 0
        statFired = nil
        sessionStart = nil
        maxCount = 0
        maxMove = 0
        clicked = false
        fired = false
        lifting = false
        tracking = nil
        recent = []
        currentCount = 0
    }

    /// 1 フレーム分の「触れている指」を渡す。発火したらそのイベントを返す。
    public func process(_ points: [TouchPoint], time: Double) -> GestureEvent? {
        let n = points.count
        currentCount = n

        if n == 0 {
            defer { reset() }
            guard let start = sessionStart else { return nil }
            var result: GestureEvent?
            if !fired, !clicked, maxCount >= config.minFingers,
               time - start <= config.tapMaxDuration, maxMove <= config.tapMaxMove {
                result = .tap(fingers: maxCount)
            }
            lastSummary = summary(duration: time - start, result: result ?? statFired)
            return result
        }

        if sessionStart == nil { sessionStart = time }
        maxCount = max(maxCount, n)

        if let tr = tracking, n < tr.count, !fired, !lifting {
            // 一瞬の見失いなら待つ。しばらく少ないままなら「離し始めた」
            if lowCountSince == nil {
                lowCountSince = time
                statDropouts += 1
            }
            if time - lowCountSince! > config.dropoutTolerance { lifting = true }
            return nil
        }
        if lifting { return nil }
        if fired {
            if reverse != nil, let tr = tracking, n == tr.count { return checkReverse(points, time: time) }
            return nil
        }
        lowCountSince = nil

        // 指が着地していく途中（1→2→3 本）は、本数が増えるたびに起点を取り直す
        guard let tr = tracking, n == tr.count else {
            if tracking != nil { statRestarts += 1 }
            tracking = Self.makeTracking(points, time: time, verticalScale: config.verticalScale)
            recent = []
            return nil
        }

        let c = Self.centroid(points)
        recent.append((time, c.x, c.y))
        recent.removeAll { time - $0.t > config.speedWindow * 2 }
        let dx = c.x - tr.centroid.x
        let dy = (c.y - tr.centroid.y) * config.verticalScale
        let ax = abs(dx), ay = abs(dy)
        maxMove = max(maxMove, max(ax, ay))

        guard n >= config.minFingers else { return nil }
        statMaxDist = max(statMaxDist, max(ax, ay))
        guard time - tr.t0 <= config.maxDuration else {
            statTimedOut = true
            return nil
        }

        // ピンチイン: 重心はあまり動かず、広がりだけが縮む
        if tr.spread > 0.02, max(ax, ay) < config.threshold {
            let ratio = Self.spread(points, around: c, verticalScale: config.verticalScale) / tr.spread
            if ratio <= config.pinchRatio {
                fired = true
                statFired = .pinchIn(fingers: n)
                return .pinchIn(fingers: n)
            }
        }

        // スワイプ: その瞬間の指の速さを見る。遅ければ発火しない。
        // 速いほど短い距離で決める（段差にすると、少し遅いだけで急に長く動かす必要が出て「効かない」と感じる）
        let speed = recentSpeed(now: time)
        statMaxSpeed = max(statMaxSpeed, speed)
        guard speed >= config.minSpeed else {
            if max(ax, ay) >= config.threshold { statSlowBlocked = true }
            return nil
        }
        let fast = min(max((speed - config.minSpeed) / max(config.flickSpeed - config.minSpeed, 0.01), 0), 1)
        let shortest = min(config.flickDistance, config.threshold)
        let threshold = config.threshold + (shortest - config.threshold) * fast

        let direction: SwipeDirection?
        if ax >= threshold, ax >= ay * config.dominance {
            direction = dx > 0 ? .right : .left
        } else if ay >= threshold, ay >= ax * config.dominance {
            direction = dy > 0 ? .up : .down
        } else {
            direction = nil
        }
        guard let direction else { return nil }
        guard allFingersMoved(points, from: tr, toward: direction, atLeast: threshold * config.consistency) else {
            statInconsistent = true
            return nil
        }

        fired = true
        lastDelta = (dx, dy)
        statFired = .swipe(direction, fingers: n)
        if config.allowReverse, direction == .left || direction == .right {
            reverse = (direction, c.x)
            recent = recent.suffix(1).map { $0 }
        }
        return .swipe(direction, fingers: n)
    }

    private func summary(duration: Double, result: GestureEvent?) -> String {
        var why: [String] = []
        if result == nil && maxCount >= config.minFingers {
            if lifting { why.append("途中で指が離れた") }
            if statTimedOut { why.append("時間切れ") }
            if statSlowBlocked { why.append("遅い") }
            if statInconsistent { why.append("指の向きがそろわない") }
            if statMaxDist < config.threshold && !statSlowBlocked { why.append("距離不足") }
            if clicked { why.append("クリックあり") }
        }
        return String(format: "最大%d本 %.2f秒 最大距離%.3f 最大速度%.2f 見失い%d 起点取り直し%d → %@%@",
                      maxCount, duration, statMaxDist, statMaxSpeed, statDropouts, statRestarts,
                      result.map { String(describing: $0) } ?? "発火なし",
                      why.isEmpty ? "" : "（\(why.joined(separator: "・"))）")
    }

    /// 左右に払ったあと、指を離さずに逆向きへ戻したか
    private func checkReverse(_ points: [TouchPoint], time: Double) -> GestureEvent? {
        guard let rev = reverse else { return nil }
        let c = Self.centroid(points)
        recent.append((time, c.x, c.y))
        recent.removeAll { time - $0.t > config.speedWindow * 2 }
        // 同じ向きにさらに進んだら、折り返しの起点を更新する
        let further = rev.direction == .right ? c.x > rev.anchor : c.x < rev.anchor
        if further {
            reverse = (rev.direction, c.x)
            return nil
        }
        let back = abs(c.x - rev.anchor)
        guard back >= config.reverseDistance, recentSpeed(now: time) >= config.minSpeed else { return nil }
        let next: SwipeDirection = rev.direction == .right ? .left : .right
        reverse = (next, c.x)
        recent = recent.suffix(1).map { $0 }
        let n = points.count
        statFired = .swipe(next, fingers: n)
        return .swipe(next, fingers: n)
    }

    /// 直近 speedWindow 秒の重心の速さ（横幅 / 秒）
    private func recentSpeed(now: Double) -> Float {
        guard let last = recent.last,
              let first = recent.first(where: { now - $0.t <= config.speedWindow }) ?? recent.first,
              last.t > first.t
        else { return 0 }
        let dx = last.x - first.x
        let dy = (last.y - first.y) * config.verticalScale
        return max(abs(dx), abs(dy)) / Float(last.t - first.t)
    }

    /// 全部の指が同じ向きに動いているか（ピンチの途中で重心だけずれたものをスワイプと誤認しない）
    private func allFingersMoved(_ points: [TouchPoint], from tr: Tracking, toward d: SwipeDirection, atLeast minAlong: Float) -> Bool {
        // ID が取れない（全部 0 / 重複）ときは判定できないので通す
        guard tr.startById.count == tr.count else { return true }
        for p in points {
            guard let s = tr.startById[p.id] else { return true }
            let along: Float
            switch d {
            case .right: along = p.x - s.x
            case .left: along = s.x - p.x
            case .up: along = (p.y - s.y) * config.verticalScale
            case .down: along = (s.y - p.y) * config.verticalScale
            }
            if along < minAlong { return false }
        }
        return true
    }

    static func makeTracking(_ points: [TouchPoint], time: Double, verticalScale: Float) -> Tracking {
        let c = centroid(points)
        var byId: [Int32: TouchPoint] = [:]
        for p in points where p.id != 0 { byId[p.id] = p }
        return Tracking(count: points.count, t0: time, centroid: c, startById: byId,
                        spread: spread(points, around: c, verticalScale: verticalScale))
    }

    static func centroid(_ points: [TouchPoint]) -> TouchPoint {
        var x: Float = 0, y: Float = 0
        for p in points { x += p.x; y += p.y }
        let n = Float(points.count)
        return TouchPoint(x: x / n, y: y / n)
    }

    /// 重心からの平均距離（横幅単位）
    static func spread(_ points: [TouchPoint], around c: TouchPoint, verticalScale: Float) -> Float {
        var sum: Float = 0
        for p in points {
            let dx = p.x - c.x, dy = (p.y - c.y) * verticalScale
            sum += (dx * dx + dy * dy).squareRoot()
        }
        return sum / Float(points.count)
    }
}
