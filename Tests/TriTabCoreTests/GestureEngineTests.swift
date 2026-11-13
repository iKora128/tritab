import Testing
@testable import TriTabCore

/// 重心が (cx, cy) になる n 本の指（ID は 1...n）
private func fingers(_ n: Int, _ cx: Float, _ cy: Float) -> [TouchPoint] {
    (0..<n).map { i in TouchPoint(id: Int32(i + 1), x: cx + Float(i - n / 2) * 0.05, y: cy) }
}

/// 起点から (dx, dy) まで steps フレームで動かして離す。発火したイベントを全部返す。
private func swipe(_ e: GestureEngine, n: Int = 3, dx: Float, dy: Float, steps: Int = 10,
                   duration: Double = 0.2, start: Double = 0) -> [GestureEvent] {
    var out: [GestureEvent] = []
    for i in 0...steps {
        let t = Float(i) / Float(steps)
        if let ev = e.process(fingers(n, 0.5 + dx * t, 0.5 + dy * t), time: start + duration * Double(t)) {
            out.append(ev)
        }
    }
    if let ev = e.process([], time: start + duration + 0.01) { out.append(ev) }
    return out
}

@Suite struct SwipeTests {
    @Test func fourDirections() {
        let e = GestureEngine()
        #expect(swipe(e, dx: -0.2, dy: 0) == [.swipe(.left, fingers: 3)])
        #expect(swipe(e, dx: 0.2, dy: 0) == [.swipe(.right, fingers: 3)])
        #expect(swipe(e, dx: 0, dy: 0.3) == [.swipe(.up, fingers: 3)])
        #expect(swipe(e, dx: 0, dy: -0.3) == [.swipe(.down, fingers: 3)])
    }

    @Test func firesOncePerSwipe() {
        #expect(swipe(GestureEngine(), dx: 0.6, dy: 0, steps: 30) == [.swipe(.right, fingers: 3)])
    }

    @Test func smallSlowMovementDoesNothing() {
        let e = GestureEngine()
        // 0.4 秒かけて 0.04 → スワイプにも（時間・移動量的に）タップにもならない
        #expect(swipe(e, dx: 0.04, dy: 0, duration: 0.4) == [])
        #expect(swipe(e, dx: 0, dy: 0.08, duration: 0.4) == []) // 縦は 0.65 倍で評価 → 0.052
    }

    @Test func diagonalIsIgnored() {
        #expect(swipe(GestureEngine(), dx: 0.15, dy: 0.2) == [])
    }

    @Test func reportsFingerCount() {
        let e = GestureEngine()
        #expect(swipe(e, n: 2, dx: 0.3, dy: 0) == []) // 2 本指はスクロールなので扱わない
        #expect(swipe(e, n: 4, dx: 0.3, dy: 0) == [.swipe(.right, fingers: 4)])
        #expect(swipe(e, n: 5, dx: 0, dy: 0.4) == [.swipe(.up, fingers: 5)])
    }

    @Test func liftingBeforeThresholdCancels() {
        let e = GestureEngine()
        _ = e.process(fingers(3, 0.5, 0.5), time: 0)
        _ = e.process(fingers(2, 0.5, 0.5), time: 0.02)
        _ = e.process(fingers(2, 0.5, 0.5), time: 0.08) // 0.06 秒以上 2 本のまま → 離した
        #expect(e.process(fingers(3, 0.8, 0.5), time: 0.1) == nil)
    }

    @Test func briefDropoutDoesNotCancel() {
        // スワイプの途中で 1 本を 1 フレームだけ見失っても、スワイプは成立する
        let e = GestureEngine()
        var out: [GestureEvent] = []
        for i in 0...10 {
            let t = Double(i) * 0.016
            let pts = i == 4 ? Array(fingers(3, 0.5 + Float(i) * 0.02, 0.5).prefix(2)) : fingers(3, 0.5 + Float(i) * 0.02, 0.5)
            if let ev = e.process(pts, time: t) { out.append(ev) }
        }
        #expect(out == [.swipe(.right, fingers: 3)])
    }

    @Test func slowDragDoesNotFire() {
        // 5 秒で 0.3 → しきい値に届くのは 1 秒を過ぎてから
        #expect(swipe(GestureEngine(), dx: 0.3, dy: 0, steps: 50, duration: 5.0) == [])
    }

    @Test func quickFlickFiresEarly() {
        // 0.075 を 0.05 秒で払う（1.5 幅/秒）→ 通常しきい値 0.10 未満でもフリックで発火
        #expect(swipe(GestureEngine(), dx: 0.075, dy: 0, steps: 5, duration: 0.05) == [.swipe(.right, fingers: 3)])
    }

    @Test func tinyFlickDoesNotFire() {
        // 速くても 0.04 しか動かしていなければ発火しない（固め）
        #expect(swipe(GestureEngine(), dx: 0.04, dy: 0, steps: 4, duration: 0.03) == [])
    }

    @Test func mediumSpeedSwipeFires() {
        // 実測で取りこぼしていたスワイプ: 0.09 を約 0.13 秒（0.7 幅/秒）。感度「低い」でも発火する
        var c = GestureEngine.Config()
        c.threshold = 0.11
        #expect(swipe(GestureEngine(config: c), dx: 0.09, dy: 0, steps: 8, duration: 0.13) == [.swipe(.right, fingers: 3)])
    }

    /// 指を離さずに x の位置を順にたどる
    private func path(_ e: GestureEngine, _ xs: [Float], dt: Double = 0.016) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for (i, x) in xs.enumerated() {
            if let ev = e.process(fingers(3, x, 0.5), time: Double(i) * dt) { out.append(ev) }
        }
        if let ev = e.process([], time: Double(xs.count) * dt) { out.append(ev) }
        return out
    }

    @Test func zigzagWithoutLifting() {
        // 右へ払って、離さずに左へ戻し、また右へ
        let right = stride(from: Float(0.5), through: 0.62, by: 0.02).map { $0 }
        let left = stride(from: Float(0.6), through: 0.48, by: -0.02).map { $0 }
        let right2 = stride(from: Float(0.5), through: 0.6, by: 0.02).map { $0 }
        #expect(path(GestureEngine(), right + left + right2) ==
                [.swipe(.right, fingers: 3), .swipe(.left, fingers: 3), .swipe(.right, fingers: 3)])
    }

    @Test func smallReboundDoesNotReverse() {
        // 払ったあとの小さな跳ね返り（0.02）では逆向きに発火しない
        let right = stride(from: Float(0.5), through: 0.62, by: 0.02).map { $0 }
        #expect(path(GestureEngine(), right + [0.61, 0.60, 0.60]) == [.swipe(.right, fingers: 3)])
    }

    @Test func reverseCanBeDisabled() {
        var c = GestureEngine.Config()
        c.allowReverse = false
        let right = stride(from: Float(0.5), through: 0.62, by: 0.02).map { $0 }
        let left = stride(from: Float(0.6), through: 0.46, by: -0.02).map { $0 }
        #expect(path(GestureEngine(config: c), right + left) == [.swipe(.right, fingers: 3)])
    }

    @Test func slowMoveIsNotSwipe() {
        // 0.8 秒かけて 0.15（0.19 幅/秒）→ 距離は足りても遅いので発火しない
        #expect(swipe(GestureEngine(), dx: 0.15, dy: 0, steps: 40, duration: 0.8) == [])
    }

    @Test func restThenSwipeFires() {
        // 指を置いて 0.3 秒止まってから払う → その瞬間の速さで判定するので発火する
        let e = GestureEngine()
        for i in 0...6 { _ = e.process(fingers(3, 0.5, 0.5), time: Double(i) * 0.05) }
        var out: [GestureEvent] = []
        for i in 1...10 {
            if let ev = e.process(fingers(3, 0.5 + Float(i) * 0.02, 0.5), time: 0.3 + Double(i) * 0.02) { out.append(ev) }
        }
        #expect(out == [.swipe(.right, fingers: 3)])
    }

    @Test func fingersLandingOneByOne() {
        let e = GestureEngine()
        _ = e.process(fingers(1, 0.5, 0.5), time: 0)
        _ = e.process(fingers(2, 0.5, 0.5), time: 0.01)
        #expect(swipe(e, dx: -0.2, dy: 0, start: 0.02) == [.swipe(.left, fingers: 3)])
    }
}

@Suite struct TapAndPinchTests {
    private func tap(_ e: GestureEngine, n: Int, duration: Double = 0.12, click: Bool = false) -> GestureEvent? {
        _ = e.process(fingers(n, 0.5, 0.5), time: 0)
        if click { e.noteClick() }
        _ = e.process(fingers(n, 0.505, 0.5), time: duration / 2)
        _ = e.process(fingers(n, 0.505, 0.5), time: duration)
        return e.process([], time: duration + 0.01)
    }

    @Test func threeAndFourFingerTap() {
        #expect(tap(GestureEngine(), n: 3) == .tap(fingers: 3))
        #expect(tap(GestureEngine(), n: 4) == .tap(fingers: 4))
    }

    @Test func clickIsNotTap() {
        #expect(tap(GestureEngine(), n: 3, click: true) == nil)
    }

    @Test func longRestIsNotTap() {
        #expect(tap(GestureEngine(), n: 3, duration: 0.6) == nil)
    }

    @Test func twoFingerTapIsIgnored() {
        #expect(tap(GestureEngine(), n: 2) == nil) // 2 本指タップは副ボタンクリック
    }

    @Test func quickSwipeIsNotAlsoTap() {
        #expect(swipe(GestureEngine(), dx: 0.075, dy: 0, steps: 5, duration: 0.05) == [.swipe(.right, fingers: 3)])
    }

    @Test func pinchIn() {
        let e = GestureEngine()
        // 2 本指（上）と親指（下）が寄ってくる。重心はほぼ動かない
        func frame(_ k: Float) -> [TouchPoint] {
            [TouchPoint(id: 1, x: 0.45, y: 0.7 - k), TouchPoint(id: 2, x: 0.55, y: 0.7 - k),
             TouchPoint(id: 3, x: 0.5, y: 0.2 + 2 * k)]
        }
        var events: [GestureEvent] = []
        for i in 0...10 {
            if let ev = e.process(frame(Float(i) * 0.015), time: Double(i) * 0.02) { events.append(ev) }
        }
        _ = e.process([], time: 0.3)
        #expect(events == [.pinchIn(fingers: 3)])
    }

    @Test func pinchIsNotSwipeUp() {
        let e = GestureEngine()
        // 親指が大きく上がり、2 本指は少し下がる → 重心は上に動くが、指の向きがバラバラなのでスワイプにしない
        var events: [GestureEvent] = []
        for i in 0...10 {
            let k = Float(i)
            let pts = [TouchPoint(id: 1, x: 0.45, y: 0.7 - k * 0.004), TouchPoint(id: 2, x: 0.55, y: 0.7 - k * 0.004),
                       TouchPoint(id: 3, x: 0.5, y: 0.2 + k * 0.04)]
            if let ev = e.process(pts, time: Double(i) * 0.02) { events.append(ev) }
        }
        #expect(!events.contains(.swipe(.up, fingers: 3)))
    }
}

@Suite struct MappingTests {
    @Test func defaultMapping() {
        let m = GestureMapping()
        #expect(m.action(for: .left) == .nextTab)
        #expect(m.action(for: .right) == .prevTab)
        #expect(m.action(for: .up) == .reopenTab)
        #expect(m.action(for: .down) == .closeTab)
    }

    @Test func reversed() {
        let m = GestureMapping(leftIsNext: false)
        #expect(m.action(for: .left) == .prevTab)
        #expect(m.action(for: .right) == .nextTab)
    }

    @Test func terminalNeverClosesOrReopens() {
        let p = AppProfiles.profile(for: "com.apple.Terminal")!
        #expect(p.combo(for: .closeTab) == nil)
        #expect(p.combo(for: .reopenTab) == nil)
        #expect(p.combo(for: .nextTab) != nil)
    }

    @Test func unknownAppHasNoProfile() {
        #expect(AppProfiles.profile(for: "dev.necoder.editor") == nil)
        #expect(AppProfiles.profile(for: nil) == nil)
    }

    @Test func slackAndMailAreDisabled() {
        for id in ["com.tinyspeck.slackmacgap", "com.apple.mail"] {
            let p = AppProfiles.profile(for: id)!
            for a in TabAction.allCases { #expect(p.combo(for: a) == nil) }
        }
    }

    @Test func browsersReload() {
        #expect(AppProfiles.profile(for: "com.google.Chrome")?.combo(for: .reload) == .cmdR)
        #expect(AppProfiles.profile(for: "com.apple.Terminal")?.combo(for: .reload) == nil)
    }

    @Test func arcUsesVerticalArrows() {
        #expect(AppProfiles.profile(for: "company.thebrowser.Browser")?.next == .cmdOptDown)
    }
}
