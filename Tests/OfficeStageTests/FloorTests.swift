import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 엔진 → OfficeFloor(화면에 보일 사람만) → 무대를 함께 돌리는 하네스. 앱과 같은 방식입니다.
struct FloorHarness {
    var engine = OfficeEngine(seed: 3)
    var floor: OfficeFloor
    var now = 0.0
    var events: [StageEvent] = []
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    init(width: Double = OfficeLayout.defaultWidth, height: Double = OfficeLayout.defaultHeight) {
        floor = OfficeFloor(width: width, height: height)
    }

    var stage: Stage { floor.stage }

    mutating func hook(_ json: String, hint: SessionHint? = nil, at seconds: Double? = nil) {
        if let seconds { run(until: seconds) }
        let directives = (try? engine.handle(hookPayload: Data(json.utf8), hint: hint, at: epoch.addingTimeInterval(now))) ?? []
        floor.apply(directives, engine: engine)
    }

    mutating func run(until seconds: Double, frame: Double = 1.0 / 30) {
        var nextTick = (now / 0.25).rounded(.down) * 0.25 + 0.25
        while now < seconds {
            let step = min(frame, seconds - now)
            now += step
            floor.update(dt: step)
            if now >= nextTick {
                floor.apply(engine.tick(at: epoch.addingTimeInterval(now)), engine: engine)
                nextTick += 0.25
            }
            events += floor.drainEvents()
        }
    }

    mutating func select(_ selection: FloorSelection) { floor.setSelection(selection, engine: engine) }
    mutating func resize(_ width: Double, _ height: Double) { floor.setViewport(width: width, height: height, engine: engine) }

    func actor(_ raw: String) -> StageActor? { stage.actors[AgentID(raw)] }
    func team(_ session: String) -> TeamID { engine.state.lead(of: SessionID(session))!.teamID }

    /// 무대 위 그 행 사람들의 이름 (책상 순서)
    func names(_ team: TeamID) -> [String] {
        stage.actors.values.filter { $0.agent.teamID == team }.sorted { $0.agent.seat < $1.agent.seat }.map(\.agent.displayName)
    }

}

/// 서브에이전트 위임·완료 훅
func delegateHook(_ session: String, _ id: String) -> String {
    hook("PreToolUse", #""tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"일","subagent_type":"general-purpose"}"#, session: session)
}

func finishHook(_ session: String, _ id: String) -> String {
    hook("PostToolUse", #""tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{}"#, session: session)
}

/// M5(1): 메인 선택, 행 배치, 빈 책상 없음, 넘침 숨김과 +N, 화면 크기별 수용 수
@Suite("무대: 행 배치와 메인 선택")
struct FloorTests {
    let team = TeamID("/w/a-sdn-portal#1")

    @Test("메인마다 한 행: 가장 왼쪽이 메인, 오른쪽에 서브 책상이 사람 수만큼 (빈 책상 없음)")
    func rowsPerMain() throws {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m1"))
        h.hook(hook("SessionStart", session: "m2"), at: 0.5)
        h.hook(delegateHook("m1", "a1"), at: 1)
        h.hook(delegateHook("m1", "a2"), at: 1.2)
        h.hook(hook("SessionStart", session: "c1"), hint: SessionHint(ancestors: [SessionID("m2")]), at: 1.5)
        h.run(until: 30)
        let (row1, row2) = (h.team("m1"), h.team("m2"))
        #expect(h.stage.layout.rows.map(\.team) == [row1, row2])
        #expect(h.stage.layout.rows.map(\.desks) == [3, 2])
        #expect(h.names(row1) == ["메인1", "서브1", "서브2"])
        #expect(h.names(row2) == ["메인2", "서브"])
        let main = try #require(h.actor("lead-1"))
        #expect(main.position == h.stage.layout.seat(row1, .main).final)
        #expect(main.position.x == OfficeLayout.deskX(0))
        #expect(h.actor("lead-5")?.position == h.stage.layout.seat(row2, Seat(desk: 1)).final)
        #expect(h.stage.nameplates[row1]?[.main] == "★ 메인1")
        #expect(h.stage.nameplates[row2]?[Seat(desk: 1)] == "서브")
    }

    @Test("서브가 둘이 되면 걸어가는 중에도 명패가 바로 서브1·서브2 (앉은 뒤에야 바뀌지 않음)")
    func nameplatesNumberedWhileWalking() throws {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m"))
        h.hook(delegateHook("m", "a1"), at: 1)
        h.hook(delegateHook("m", "a2"), at: 1.1)
        h.run(until: 1.4)
        let row = h.team("m")
        #expect(h.actor("member-2")?.isWalking == true)
        #expect(h.stage.nameplates[row]?[Seat(desk: 1)] == "서브1")
        #expect(h.stage.nameplates[row]?[Seat(desk: 2)] == "서브2")
        #expect(h.actor("member-2")?.agent.displayName == "서브1")
    }

    @Test("서브가 오면 오른쪽 끝에 책상이 생기고, 가운데 서브가 퇴근하면 오른쪽 끝 사람만 옮겨 앉고 끝 책상을 치운다")
    func desksAttachAndDetach() throws {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m"))
        for index in 1...4 { h.hook(delegateHook("m", "a\(index)"), at: Double(index)) }
        h.run(until: 30)
        let row = h.team("m")
        #expect(h.stage.layout.rows[0].desks == 5)
        let positions = Dictionary(uniqueKeysWithValues: h.stage.actors.values.map { ($0.id, $0.position) })
        // 2번 책상(member-3) 퇴근 → 4번 책상(member-5)이 2번으로
        h.hook(finishHook("m", "a2"), at: 31)
        h.run(until: 60)
        #expect(h.actor("member-3") == nil)
        #expect(h.actor("member-5")?.position == h.stage.layout.seat(row, Seat(desk: 2)).final)
        #expect(h.actor("member-5")?.seated == true)
        for id in ["lead-1", "member-2", "member-4"] { #expect(h.actor(id)?.position == positions[AgentID(id)]) }
        #expect(h.stage.layout.rows[0].desks == 4)
        // 새 서브는 오른쪽 끝 책상
        h.hook(delegateHook("m", "a9"), at: 61)
        h.run(until: 80)
        #expect(h.stage.layout.rows[0].desks == 5)
        #expect(h.actor("member-6")?.agent.seat == Seat(desk: 4))
        #expect(h.actor("member-6")?.position == h.stage.layout.seat(row, Seat(desk: 4)).final)
    }

    @Test("한 행에 들어가지 않는 서브는 그리지 않고 행 끝에 +N. 자리가 나면 숨어 있던 서브가 출입문으로 들어와 앉는다")
    func overflowSubs() throws {
        var h = FloorHarness()  // 1140×648: 한 행 11명
        h.hook(hook("SessionStart", session: "m"))
        for index in 1...14 { h.hook(delegateHook("m", "a\(index)"), at: Double(index) * 0.3) }
        h.run(until: 40)
        #expect(h.engine.state.agents.count == 15)
        #expect(h.stage.actors.count == 11)
        #expect(h.floor.plan.hiddenCount == 4)
        #expect(h.stage.layout.rows[0].desks == 11)
        #expect(h.stage.layout.rows[0].hidden == 4)
        #expect(h.stage.hiddenCounts[h.team("m")] == 4)
        // 그림에도 "+4"
        let art = OfficeArt.layers(layout: h.stage.layout, teams: h.stage.sortedTeams)
        #expect(art.contains { $0.name.hasPrefix("row-more-") && $0.shapes.contains { if case .text("+4", _, _, _, _, _) = $0.geometry { true } else { false } } })
        // 3번 책상 서브가 퇴근 → 맨 끝(14번 책상, 숨어 있던) 서브가 3번 책상으로 걸어 들어옵니다
        let hiddenOne = try #require(h.engine.state.agents.values.first { $0.seat.desk == 14 })
        #expect(h.stage.actors[hiddenOne.id] == nil)
        h.hook(finishHook("m", "a3"), at: 41)
        h.run(until: 41.2)
        #expect(h.stage.actors[hiddenOne.id]?.isWalking == true)
        h.run(until: 70)
        #expect(h.stage.actors[hiddenOne.id]?.position == h.stage.layout.seat(h.team("m"), Seat(desk: 3)).final)
        #expect(h.floor.plan.hiddenCount == 3)
        #expect(h.stage.layout.rows[0].hidden == 3)
    }

    @Test("행은 최대 3개: 넷째 메인은 숨기고, 위 행이 닫히면 올라와 보인다")
    func overflowRows() throws {
        var h = FloorHarness(width: 1140, height: 1200)
        for (index, session) in ["a", "b", "c", "d"].enumerated() {
            h.hook(hook("SessionStart", session: session), at: Double(index) * 0.2)
        }
        h.hook(delegateHook("d", "x1"), at: 1)
        h.run(until: 20)
        #expect(h.stage.layout.rows.count == 3)
        #expect(h.floor.plan.hiddenTeams == [h.team("d")])
        #expect(h.floor.plan.hiddenCount == 2)
        #expect(h.actor("lead-4") == nil)
        h.hook(hook("SessionEnd", session: "a"), at: 21)
        h.run(until: 45)
        #expect(h.stage.layout.rows.map(\.team) == [h.team("b"), h.team("c"), h.team("d")])
        #expect(h.actor("lead-4")?.position == h.stage.layout.seat(h.team("d"), .main).final)
        #expect(h.floor.plan.hiddenCount == 0)
        // b가 첫 행으로 올라와 메인 책상에 그대로 앉아 있습니다
        #expect(h.actor("lead-2")?.position == MapPoint(OfficeLayout.deskX(0), OfficeLayout.firstDeskY))
    }

    @Test("디렉토리를 고르면 그 디렉토리에서 연 메인(들)과 서브만 보이고, 메인마다 한 행. '모두'로 돌아가면 그 자리에 바로 다시 선다")
    func selection() throws {
        var h = FloorHarness()
        for (index, session) in ["a", "b", "c"].enumerated() {
            h.hook(hook("SessionStart", session: session, cwd: "/w/\(session)"), at: Double(index) * 0.2)
        }
        h.hook(delegateHook("b", "x1"), at: 1)
        h.hook(delegateHook("c", "y1"), at: 1.1)
        h.run(until: 30)
        #expect(h.stage.actors.count == 5)
        let (a, b, c) = (h.team("a"), h.team("b"), h.team("c"))
        h.select(FloorSelection(all: false, folders: ["/w/c", "/w/a"]))
        h.run(until: 30.1)
        // 고른 순서가 아니라 메인이 온 순서로 행을 놓습니다
        #expect(h.stage.layout.rows.map(\.team) == [a, c])
        #expect(Set(h.stage.actors.keys.map(\.raw)) == ["lead-1", "lead-3", "member-5"])
        #expect(h.actor("member-5")?.position == h.stage.layout.seat(c, Seat(desk: 1)).final)
        #expect(h.floor.plan.hiddenCount == 0)
        // 고르지 않은 행의 일은 무대에 오지 않습니다
        h.hook(tool("PreToolUse", "Edit", "e1", #"{"file_path":"/x/A.swift"}"#).replacingOccurrences(of: "\"s1\"", with: "\"b\""), at: 31)
        h.run(until: 32)
        #expect(h.actor("lead-2") == nil)
        // 모두 보기: 숨었던 사람은 걷지 않고 지금 자리에 바로 섭니다
        h.select(.everyone)
        #expect(h.stage.layout.rows.map(\.team) == [a, b, c])
        let lead2 = try #require(h.actor("lead-2"))
        #expect(!lead2.isWalking)
        #expect(lead2.position == h.stage.layout.seat(b, .main).final)
        #expect(lead2.pill?.text == "Edit · A.swift")
        #expect(h.actor("member-4")?.position == h.stage.layout.seat(b, Seat(desk: 1)).final)
        // 같은 디렉토리에서 연 메인(워크트리 포함)은 모두 그 디렉토리에 속합니다
        h.select(FloorSelection(all: false, folders: ["/w/a"]))
        h.hook(hook("SessionStart", session: "a2", cwd: "/w/a/.claude/worktrees/x"), at: 33)
        #expect(h.stage.layout.rows.map(\.team) == [a, h.team("a2")])
    }

    @Test("새로 온 메인은 '모두'면 자동으로 보이고, 디렉토리를 골라 둔 상태면 고르지 않은 디렉토리의 메인은 보이지 않는다")
    func newMainFollowsSelection() {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "a", cwd: "/w/a"))
        h.run(until: 1)
        h.hook(hook("SessionStart", session: "b", cwd: "/w/b"), at: 2)
        #expect(h.actor("lead-2") != nil)
        h.select(FloorSelection(all: false, folders: ["/w/a"]))
        h.hook(hook("SessionStart", session: "c", cwd: "/w/c"), at: 3)
        #expect(h.actor("lead-3") == nil)
        #expect(h.stage.layout.rows.count == 1)
    }

    @Test("창 크기가 바뀌면 들어가는 수를 다시 센다 (사무실은 줄이지 않음)")
    func viewportChanges() {
        var h = FloorHarness(width: 1500, height: 708)
        h.hook(hook("SessionStart", session: "m"))
        for index in 1...14 { h.hook(delegateHook("m", "a\(index)"), at: Double(index) * 0.3) }
        h.run(until: 40)
        #expect(h.stage.actors.count == 15)
        // 좁히면 오른쪽 서브가 숨고
        h.resize(1140, 708)
        let narrow = OfficeLayout.capacity(width: 1140, height: 708).columns
        #expect(narrow == 11)
        #expect(h.stage.actors.count == narrow)
        #expect(h.floor.plan.hiddenCount == 15 - narrow)
        #expect(h.stage.layout.width == 1140)
        // 넓히면 모두 보이고 바로 자기 책상에 있습니다
        h.resize(1500, 708)
        #expect(h.stage.actors.count == 15)
        #expect(h.floor.plan.hiddenCount == 0)
        #expect(h.stage.actors.values.allSatisfy { !$0.isWalking })
        #expect(OfficeLayout.displayScale(viewWidth: 1500, viewHeight: 708) == 1)
    }

    @Test("메인이 퇴근하면 가장 먼저 온 서브 세션이 메인 책상으로 걸어가 앉고, 명패가 '★ 메인'이 된다")
    func promotionWalksToMainDesk() throws {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m"))
        h.hook(hook("SessionStart", session: "c"), hint: SessionHint(ancestors: [SessionID("m")]), at: 0.5)
        h.run(until: 12)
        #expect(h.actor("lead-2")?.agent.displayName == "서브")
        h.hook(hook("SessionEnd", session: "m"), at: 12)
        h.run(until: 30)
        let promoted = try #require(h.actor("lead-2"))
        #expect(promoted.agent.displayName == "메인")
        #expect(promoted.position == h.stage.layout.seat(team, .main).final)
        #expect(promoted.seated)
        #expect(h.stage.nameplates[team] == [.main: "★ 메인"])
        #expect(h.stage.layout.rows[0].desks == 1)
    }

    @Test("빈 행은 마지막 직원이 문을 나간 뒤 닫히고, 아래 행이 직원과 함께 올라온다")
    func rowClosesAfterLeaving() throws {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "a", cwd: "/w/a"))
        h.hook(hook("SessionStart", session: "b", cwd: "/w/b"))
        h.hook(hook("SessionStart", session: "c", cwd: "/w/c"))
        h.run(until: 12)
        #expect(h.stage.layout.rows.count == 3)
        h.hook(hook("SessionEnd", session: "a", cwd: "/w/a"), at: 13)
        // 아직 문으로 걸어가는 중이면 행이 남아 있습니다
        #expect(h.stage.layout.rows.count == 3)
        h.run(until: 30)
        #expect(h.stage.layout.rows.map(\.team.raw) == ["/w/b#2", "/w/c#3"])
        #expect(h.events.contains(.teamClosed(TeamID("/w/a#1"))))
        #expect(h.actor("lead-2")?.position == MapPoint(OfficeLayout.deskX(0), OfficeLayout.firstDeskY))
        #expect(h.actor("lead-3")?.position == MapPoint(OfficeLayout.deskX(0), OfficeLayout.firstDeskY + h.stage.layout.rowSpacing))
    }

    @Test("웹 검색은 자기 책상에서 한다 (리서치 데스크 없음)")
    func webSearchAtDesk() {
        var h = FloorHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        h.hook(tool("PreToolUse", "WebSearch", "w1", #"{"query":"swift"}"#), at: 10)
        h.run(until: 14)
        #expect(h.actor("lead-1")?.position == h.stage.layout.seat(team, .main).final)
        #expect(h.actor("lead-1")?.pill?.category == .web)
    }

    @Test("공용 구역 자리가 넘치면 한 점에 겹치지 않게 흩어 서고, 칩은 '화이트보드 · N명 계획 중' 하나로 묶는다")
    func crowdedZoneSpreads() throws {
        var h = StageHarness()
        let sessions = (1...6).map { "s\($0)" }
        for (index, session) in sessions.enumerated() { h.hook(hook("SessionStart", session: session), at: Double(index) * 0.1) }
        h.run(until: 15)
        for round in 0..<6 {
            for session in sessions {
                h.hook(hook("PreToolUse", #""tool_name":"TodoWrite","tool_use_id":"\#(session)-r\#(round)","tool_input":{"todos":[]}"#, session: session), at: 15 + Double(round) * 1.2)
            }
        }
        h.run(until: 40)
        let readers = h.stage.actors.values.filter { OfficeLayout.zone(ofKey: $0.place?.key) == .whiteboard }
        #expect(readers.count == 6)
        let points = readers.map(\.position)
        for (index, point) in points.enumerated() {
            for other in points[(index + 1)...] { #expect(point.distance(to: other) > 12, "\(point) \(other)") }
        }
        let items = Overlay.items(for: h.stage)
        let pills = items.filter { $0.kind == .pill }
        let group = try #require(pills.first { $0.text?.hasPrefix("화이트보드 · ") == true })
        #expect(group.text == "화이트보드 · 6명 계획 중")
        #expect(pills.count == 1)
        // 묶음 칩은 화면 안에 있습니다
        #expect((group.frame?.y ?? -1) >= 0)
    }

    @Test("긴 명령을 기다리는 동안 모니터에 진행 표시가 깜빡이고, 안마 의자 롤러는 앉은 사람이 있을 때만 움직인다")
    func liveFurniture() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        h.hook(tool("PreToolUse", "Bash", "b1", #"{"command":"swift build"}"#))
        h.run(until: 13)
        let lead = h.actor("lead-1")!
        #expect(lead.pose == .watching)
        #expect(lead.emote == .hourglass)
        #expect(lead.position == h.stage.layout.seat(team, .main).final)
        let live = OfficeArt.liveLayers(stage: h.stage)
        #expect(live.contains { $0.name == "monitor-lead-1" })
        // 빈 안마 의자의 롤러는 시간이 지나도 그대로
        let roller = live.first { $0.name == "massage-roller" }!
        h.run(until: 14)
        #expect(OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" } == roller)
        h.hook(tool("PostToolUse", "Bash", "b1"))
        h.run(until: 16)
        #expect(!OfficeArt.liveLayers(stage: h.stage).contains { $0.name == "monitor-lead-1" })
    }

    @Test("안마 의자에 앉으면 롤러가 오르내리고 안마 자세가 된다")
    func massageChair() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("Stop"), at: 10)
        h.run(until: 200)
        let lead = h.actor("lead-1")!
        #expect(lead.pose == .massage)
        #expect(lead.position == OfficeLayout.massageSeat)
        let a = OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" }
        h.run(until: 200.6)
        let b = OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" }
        #expect(a != b)
        let pose = RigAnimator.pose(for: h.actor("lead-1")!, time: h.stage.time)
        #expect(pose.leftArm > 20 && pose.rightArm < -20)  // 팔은 팔걸이에
    }

    @Test("소파·안마 의자에 앉으면 무릎과 발이 보이는 앉은 다리를 가구 앞판 앞(책상보다는 뒤)에 그린다")
    func seatedLegs() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        // 책상에 앉으면 다리는 책상 뒤에 가려지므로 서 있는 다리 그대로
        #expect(h.actor("lead-1")!.seated && h.actor("lead-1")!.loungeSeat == nil)
        h.hook(hook("Stop"))
        // 소파로 걸어가는 동안은 서 있는 다리
        var sawWalking = false
        while h.now < 90, h.actor("lead-1")!.loungeSeat == nil {
            h.run(until: h.now + 0.5)
            if h.actor("lead-1")!.isWalking { sawWalking = true }
        }
        #expect(sawWalking)
        #expect(h.actor("lead-1")!.loungeSeat == .sofa)
        var svg = SVGRenderer.render(stage: h.stage)
        #expect(svg.components(separatedBy: "class=\"seated-legs\"").count == 2)
        h.run(until: 200)
        #expect(h.actor("lead-1")!.loungeSeat == .massageChair)
        svg = SVGRenderer.render(stage: h.stage)
        #expect(svg.components(separatedBy: "class=\"seated-legs\"").count == 2)

        // 깊이: 소파 좌판·안마 의자 앞판보다 앞, 책상보다 뒤
        let layers = OfficeArt.layers(layout: h.stage.layout, teams: h.stage.sortedTeams, nameplates: h.stage.nameplates)
        let sofaSeatY = h.stage.layout.slots(.lounge)[0].final.y
        let sofaFront = layers.first { $0.name == "sofa-front-0" }!.depth
        let chairFront = layers.first { $0.name == "massage-front-0" }!.depth
        #expect(sofaSeatY < sofaFront && sofaFront < sofaSeatY + CharacterArt.seatedLegsDepth)
        #expect(OfficeLayout.massageSeat.y + CharacterArt.seatedLegsDepth > chairFront)
        #expect(CharacterArt.seatedLegsDepth < 3)  // 책상 깊이 = 발 위치 + 3

        // 발은 앉는 자리보다 아래(소파는 좌판 밑 바닥, 안마 의자는 발판), 허벅지는 몸 아랫단(-14)을 덮음
        for seat in [LoungeSeat.sofa, .massageChair] {
            let rects = CharacterArt.seatedLegs(seat).compactMap { shape -> MapRect? in
                if case .rect(let rect, _) = shape.geometry { return rect }
                return nil
            }
            #expect(rects.map(\.maxY).max()! > 0)
            #expect(rects.map(\.y).min()! < -14)
        }
        #expect(CharacterArt.seatedFootY(.sofa) > OfficeLayout.sofas[0].maxY - sofaSeatY)
    }

}
