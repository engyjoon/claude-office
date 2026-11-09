import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M5(4) v2: 미니 사무실 — 메인 + 쉬지 않는 서브 2명(배율 1, 휴게 공간 없음)과 보여 줄 행의 우선순위
@Suite("미니 사무실")
struct MiniOfficeTests {
    func on(_ event: String, _ extra: String = "", _ session: String) -> String {
        hook(event, extra, session: session, cwd: "/w/\(session)")
    }

    func start(_ session: String) -> String { on("SessionStart", "", session) }
    func prompt(_ session: String) -> String { on("UserPromptSubmit", #""prompt":"x""#, session) }
    func stop(_ session: String) -> String { on("Stop", "", session) }

    func edit(_ session: String, _ id: String, agent: String? = nil) -> String {
        on("PreToolUse", #""tool_name":"Edit","tool_use_id":"\#(id)","tool_input":{"file_path":"/x/A.swift"}"# + agentField(agent), session)
    }

    func toolHook(_ event: String, _ name: String, _ session: String, _ id: String, agent: String? = nil) -> String {
        on(event, #""tool_name":"\#(name)","tool_use_id":"\#(id)","tool_input":{"command":"npm test"}"# + agentField(agent), session)
    }

    func agentField(_ agent: String?) -> String {
        agent.map { #","agent_id":"\#($0)","agent_type":"general-purpose""# } ?? ""
    }

    func delegate(_ session: String, _ id: String, agent: String) -> [String] {
        [on("PreToolUse", #""tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"일","subagent_type":"general-purpose"}"#, session),
         on("SubagentStart", #""agent_id":"\#(agent)","agent_type":"general-purpose""#, session)]
    }

    func next(_ h: FloorHarness, _ previous: MiniFocus, pinned: TeamID? = nil, autoSwitch: Bool = true,
              after seconds: Double = 0) -> MiniFocus {
        MiniFocus.next(
            previous: previous, state: h.engine.state, pinned: pinned, autoSwitch: autoSwitch,
            now: h.epoch.addingTimeInterval(h.now + seconds))
    }

    static func band() -> FloorHarness {
        FloorHarness(width: MiniOffice.visibleMapWidth(), height: OfficeLayout.minHeight, band: true)
    }

    @Test("패널 390×200: 메인 + 서브 2명 + \"+N\"이 배율 1로 들어감, 휴게 공간은 보이지 않음")
    func size() {
        let extent = MiniOffice.extent()
        #expect(MiniOffice.panelWidth == 390 && MiniOffice.panelHeight == 200)
        #expect(OfficeLayout.columns(width: MiniOffice.visibleMapWidth()) >= 1 + MiniOffice.subSlots)
        #expect(extent.maxY == OfficeLayout.firstDeskY + 40)
        #expect(extent.y > OfficeLayout.sofas[0].maxY)
        #expect(OfficeLayout.columns(width: 1140) == OfficeLayout.capacity(width: 1140, height: 708).columns)
    }

    @Test("서브 2칸: 일하는 서브 먼저, 칸은 지키고, 답변을 기다리는 서브가 가장 오래 조용한 칸을 넘겨받음")
    func castSlots() throws {
        var h = Self.band()
        h.hook(start("m"))
        let team = h.team("m")
        h.select(.only(team))
        h.hook(prompt("m"), at: 0.5)
        for (index, agent) in ["g1", "g2", "g3"].enumerated() {
            for json in delegate("m", "a\(index + 1)", agent: agent) { h.hook(json, at: 1 + Double(index)) }
        }
        // 서브 세션 c1: 요청을 받고 끝내서 쉬는 중
        h.hook(start("c1").replacingOccurrences(of: "/w/c1", with: "/w/m"), hint: SessionHint(ancestors: [SessionID("m")]), at: 4)
        h.hook(prompt("c1"), at: 4.5)
        h.hook(stop("c1"), at: 5)
        h.hook(edit("m", "e1", agent: "g1"), at: 6)
        h.hook(edit("m", "e2", agent: "g2"), at: 7)
        h.hook(edit("m", "e3", agent: "g3"), at: 8)
        h.run(until: 20)

        let names = { (map: [AgentID: Seat]) in map.sorted { $0.value < $1.value }.map { h.engine.state.agents[$0.key]!.displayName } }
        // 먼저 칸을 받은 서브1·2가 그대로 (서브3은 일해도 숨김, 쉬는 서브4는 숨김)
        #expect(names(h.floor.plan.seatMap) == ["서브1", "서브2"])
        #expect(h.stage.actors.count == 3)
        #expect(h.floor.plan.hiddenCount == 2)
        #expect(h.stage.hiddenCounts[team] == 2)
        #expect(h.stage.layout.rows[0].desks == 3)
        #expect(h.stage.nameplates[team]?[Seat(desk: 2)] == "서브2")

        // 숨은 서브3이 승인 대기 → 가장 오래 조용한 서브1(칸 1)의 칸을 넘겨받고 걸어 들어옴
        h.hook(toolHook("PermissionRequest", "Bash", "m", "b1", agent: "g3"), at: 21)
        h.run(until: 40)
        #expect(names(h.floor.plan.seatMap) == ["서브3", "서브2"])
        let g3 = try #require(h.stage.actors.values.first { $0.agent.subagentID == "g3" })
        #expect(g3.position == h.stage.layout.seat(team, Seat(desk: 1)).final)
        #expect(h.stage.nameplates[team]?[Seat(desk: 1)] == "서브3")

        // 서브2가 퇴근하면 빈 칸 2는 일하는 서브1이 받음 (쉬는 서브4는 받지 않음)
        h.hook(on("SubagentStop", #""agent_id":"g2","agent_type":"general-purpose""#, "m"), at: 41)
        h.run(until: 70)
        #expect(names(h.floor.plan.seatMap) == ["서브3", "서브1"])
        let g1 = try #require(h.stage.actors.values.first { $0.agent.subagentID == "g1" })
        #expect(g1.position == h.stage.layout.seat(team, Seat(desk: 2)).final)
        #expect(h.stage.actors.values.allSatisfy { MiniOffice.extent().contains($0.position) })
    }

    @Test("M6(9b): 1번 칸 서브가 퇴근하면, 문 밖으로 나간 뒤 2번 칸 서브가 걸어서 1번 책상으로 옮겨 앉는다 (명패 없는 빈 책상 없음)")
    func packsAfterLeaving() throws {
        var h = Self.band()
        h.hook(start("m"))
        let team = h.team("m")
        h.select(.only(team))
        h.hook(prompt("m"), at: 0.5)
        for (index, agent) in ["g1", "g2"].enumerated() {
            for json in delegate("m", "a\(index + 1)", agent: agent) { h.hook(json, at: 1 + Double(index)) }
        }
        h.hook(edit("m", "e1", agent: "g1"), at: 4)
        h.hook(toolHook("PreToolUse", "Read", "m", "r2", agent: "g2"), at: 5)
        h.run(until: 12)
        // 서브1 = member-2(칸 1), 서브2 = member-3(칸 2)
        let g1 = AgentID("member-2"), g2 = AgentID("member-3")
        #expect(h.floor.plan.seatMap[g1] == Seat(desk: 1))
        #expect(h.floor.plan.seatMap[g2] == Seat(desk: 2))

        h.hook(on("SubagentStop", #""agent_id":"g1","agent_type":"general-purpose""#, "m"), at: 14)
        h.hook(on("PostToolUse", #""tool_name":"Agent","tool_use_id":"a1","tool_input":{"subagent_type":"general-purpose"},"tool_response":{"status":"completed"}"#, "m"), at: 14.2)
        // 퇴근하는 서브1이 무대에 있는 동안: 칸은 그대로라 서브1이 마무리하는 1번 책상에서 겹치지 않음
        var moved = false
        var walked = false
        while h.now < 45 {
            h.run(until: h.now + 0.25)
            let leaving = h.stage.actors[g1] != nil
            if leaving { #expect(h.floor.plan.seatMap[g2] == Seat(desk: 2)) }
            if h.floor.plan.seatMap[g2] == Seat(desk: 1) {
                moved = true
                #expect(!leaving)
            }
            if moved, h.stage.actors[g2]?.isWalking == true { walked = true }
        }
        #expect(moved && walked)
        let actor = try #require(h.stage.actors[g2])
        #expect(actor.position == h.stage.layout.seat(team, Seat(desk: 1)).final)
        #expect(actor.seated && actor.pose == .reading)
        #expect(h.stage.layout.rows[0].desks == 2)
        // 모든 책상에 명패
        for desk in 0..<h.stage.layout.rows[0].desks { #expect(h.stage.nameplates[team]?[Seat(desk: desk)] != nil) }
    }

    @Test("데스크톱 서브를 보관해도 미니 책상이 늘지 않고 명패 없는 책상이 없다 (M6(12): 칸과 실제 책상 번호가 다를 때)",
          arguments: [0, 1])
    func archiveKeepsSlot(slot: Int) throws {
        var h = Self.band()
        // 메인 + 데스크톱 서브 4명(실제 책상 1~4). 나중 서브일수록 최근에 활동해서 미니는 서브4·서브3을 1·2번 칸에 앉힘
        func residents() -> [ResidentSession] {
            let now = h.epoch.addingTimeInterval(h.now)
            let subs: [(String, String?, Double)] = ["a", "b", "c", "d"].enumerated().map { ($1, "m", 6000 - Double($0) * 60) }
            return ([("m", nil, 60)] + subs).map { cli, parent, idle in
                ResidentSession(
                    session: SessionID(cli), hostSession: "local_\(cli)", ancestors: parent.map { [SessionID($0)] } ?? [],
                    rootCwd: "/w/office", title: cli, lastActivity: now.addingTimeInterval(-idle))
            }
        }
        func sync(_ list: [ResidentSession]) {
            let now = h.epoch.addingTimeInterval(h.now)
            let roll = ResidentRoll(residents: list, openHostSessions: Set(list.map(\.hostSession)), isReliable: true, readAt: now)
            h.floor.apply(h.engine.syncResidents(roll, at: now), engine: h.engine)
        }
        let list = residents()
        sync(list)
        let team = h.team("m")
        h.select(.only(team))
        h.run(until: 5)
        let shown = h.floor.plan.seatMap.sorted { $0.value < $1.value }.map(\.key)
        #expect(shown.map { h.engine.state.agents[$0]!.seat.desk } == [4, 3])
        let gone = shown[slot]
        let session = try #require(h.engine.state.agents[gone]?.session)

        sync(list.filter { $0.session != session })
        var sawLeaving = false
        while h.now < 30 {
            h.run(until: h.now + 0.25)
            if h.stage.actors[gone] != nil { sawLeaving = true }
            let desks = h.stage.layout.rows[0].desks
            #expect(desks == 3, "\(h.now)초: 책상 \(desks)개")
            for desk in 0..<desks { #expect(h.stage.nameplates[team]?[Seat(desk: desk)] != nil, "\(h.now)초: \(desk)번 책상 명패 없음") }
        }
        #expect(sawLeaving && h.stage.actors[gone] == nil)
        #expect(h.floor.plan.seatMap.count == 2 && h.floor.plan.hiddenCount == 1)
    }

    @Test("칸 다시 매기기: 순서는 그대로, 1부터 빈틈없이")
    func packed() {
        let a = AgentID("a"), b = AgentID("b")
        #expect(MiniCast.packed([b: Seat(desk: 2)]) == [b: Seat(desk: 1)])
        #expect(MiniCast.packed([a: Seat(desk: 2), b: Seat(desk: 1)]) == [b: Seat(desk: 1), a: Seat(desk: 2)])
        #expect(MiniCast.packed([:]).isEmpty)
    }

    @Test("칸이 남으면 쉬는 서브도 보여 주고, 일하는 서브가 오면 쉬는 서브가 칸을 내줌")
    func restingFillsEmptySlots() throws {
        var h = Self.band()
        h.hook(start("m"))
        let team = h.team("m")
        h.select(.only(team))
        // 서브 세션 c1: 요청을 받고 끝내서 쉬는 중 → 칸이 남으니 보임 (M5(4) 화면 확인: 메인만 보이고 "+1")
        h.hook(start("c1").replacingOccurrences(of: "/w/c1", with: "/w/m"), hint: SessionHint(ancestors: [SessionID("m")]), at: 1)
        h.hook(prompt("c1"), at: 1.5)
        h.hook(stop("c1"), at: 2)
        h.run(until: 10)
        let names = { (map: [AgentID: Seat]) in map.sorted { $0.value < $1.value }.map { h.engine.state.agents[$0.key]!.displayName } }
        #expect(names(h.floor.plan.seatMap) == ["서브"])
        #expect(h.stage.actors.count == 2 && h.floor.plan.hiddenCount == 0)

        // 일하는 서브가 오면 빈 칸부터, 칸이 없으면 쉬는 서브의 칸을 넘겨받음
        for json in delegate("m", "a1", agent: "g1") { h.hook(json, at: 11) }
        h.run(until: 20)
        #expect(names(h.floor.plan.seatMap) == ["서브1", "서브2"])
        for json in delegate("m", "a2", agent: "g2") { h.hook(json, at: 21) }
        h.run(until: 40)
        #expect(names(h.floor.plan.seatMap) == ["서브3", "서브2"])
        #expect(h.floor.plan.hiddenCount == 1)
    }

    @Test("미니에서는 쉬러 소파에 가지 않고 자기 책상에서 쉼 (사무실 창은 소파로)")
    func restsAtDesk() throws {
        var band = Self.band()
        var office = FloorHarness()
        for h in [0, 1] {
            func drive(_ harness: inout FloorHarness) {
                harness.hook(start("m"))
                harness.hook(prompt("m"), at: 0.5)
                harness.hook(stop("m"), at: 2)
                if harness.floor.isBand { harness.select(.only(harness.team("m"))) }
                harness.run(until: 120)
            }
            if h == 0 { drive(&band) } else { drive(&office) }
        }
        let team = band.team("m")
        let main = try #require(band.stage.actors.values.first)
        #expect(main.position == band.stage.layout.seat(team, .main).final)
        #expect(main.loungeSeat == nil)
        let officeMain = try #require(office.stage.actors.values.first)
        #expect(officeMain.position != office.stage.layout.seat(office.team("m"), .main).final)
        // 쉬러 가거나(소파 → 안마 → 낮잠) 깨어 자리로 돌아올 때도 일어나지 않고 그 자리에 앉아 있음
        let seat = band.stage.layout.seat(team, .main).final
        var stoodUp = false
        for step in 1...2400 {
            if step == 2000 { band.hook(prompt("m")) }
            band.run(until: 120 + Double(step) * 0.25)
            let actor = try #require(band.stage.actors.values.first)
            if !actor.seated || actor.position != seat { stoodUp = true }
        }
        #expect(!stoodUp)
        // 휴게 공간 그림도 그리지 않음
        let names = OfficeArt.layers(layout: band.stage.layout, teams: band.stage.sortedTeams, lounge: false).map(\.name)
        #expect(!names.contains { $0.hasPrefix("sofa") || $0.hasPrefix("massage") })
    }

    @Test("질문(AskUserQuestion)·계획 승인(ExitPlanMode)은 답할 때까지 답변 필요")
    func questionNeedsAnswer() throws {
        var h = FloorHarness()
        h.hook(start("m"))
        h.hook(prompt("m"), at: 0.5)
        _ = h.engine.drainNotices()
        h.hook(toolHook("PreToolUse", "AskUserQuestion", "m", "q1"), at: 1)
        let main = try #require(h.engine.state.main(of: h.team("m")))
        #expect(MiniCast.needsAnswer(main))
        let row = try #require(Roster.make(from: h.engine.state, privacy: .detailed).waiting.first)
        #expect(row.detail == "질문에 답해 주세요")
        let titles = h.engine.drainNotices().compactMap { if case .post(let notice) = $0 { notice.title } else { nil } }
        #expect(titles == ["메인 질문 답 대기"])
        h.hook(toolHook("PostToolUse", "AskUserQuestion", "m", "q1"), at: 5)
        #expect(!MiniCast.needsAnswer(h.engine.state.main(of: h.team("m"))!))
        h.hook(toolHook("PreToolUse", "ExitPlanMode", "m", "p1"), at: 6)
        #expect(MiniCast.needsAnswer(h.engine.state.main(of: h.team("m"))!))
    }

    @Test("보여 줄 행: 답변 필요 > 고정 > 확인 안 한 응답 > 가장 마지막에 요청")
    func focusPriority() throws {
        var h = FloorHarness()
        #expect(next(h, .empty).team == nil)
        for (index, session) in ["m1", "m2", "m3"].enumerated() {
            h.hook(start(session), at: Double(index) * 0.1)
            h.hook(prompt(session), at: 1 + Double(index))
        }
        let (m1, m2, m3) = (h.team("m1"), h.team("m2"), h.team("m3"))

        // 가장 마지막에 요청한 행
        var focus = next(h, .empty)
        #expect(focus.team == m3 && focus.reason == .requested)

        // 완료한 행이 먼저
        h.hook(stop("m1"), at: 5)
        focus = next(h, focus)
        #expect(focus.team == m1 && focus.reason == .completed)
        #expect(focus.tierAt == h.epoch.addingTimeInterval(5))
        #expect(focus.tiers == [m1: .completed, m2: .requested, m3: .requested])

        // 답변 필요가 가장 먼저 (고정보다도), 자동 전환을 끄면 고정
        h.hook(toolHook("PreToolUse", "AskUserQuestion", "m2", "q1"), at: 6)
        focus = next(h, focus, pinned: m3)
        #expect(focus.team == m2 && focus.reason == .answer && focus.tiers[m2] == .answer)
        #expect(next(h, focus, pinned: m3, autoSwitch: false).team == m3)
        #expect(next(h, focus, pinned: m3, autoSwitch: false).reason == .pinned)

        // 답하면 다시 완료한 행
        h.hook(toolHook("PostToolUse", "AskUserQuestion", "m2", "q1"), at: 7)
        focus = next(h, focus)
        #expect(focus.team == m1 && focus.reason == .completed)

        // 확인 안 한 응답은 시간이 지나도 그대로이고(M6(4)), 확인하면(캐릭터를 누름) 가장 마지막에 요청한 행
        #expect(next(h, focus, after: 3600).team == m1)
        _ = h.engine.acknowledge(SessionID("m1"), at: h.epoch.addingTimeInterval(h.now))
        #expect(next(h, focus).team == m3)

        // 완료한 메인에 다음 요청을 보내면 가장 마지막에 요청한 행
        h.hook(prompt("m1"), at: 8)
        #expect(h.engine.state.parts[SessionID("m1")]?.completedAt == nil)
        focus = next(h, focus)
        #expect(focus.team == m1 && focus.reason == .requested)
    }
}
