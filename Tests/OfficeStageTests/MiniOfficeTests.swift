import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M5(4): 미니 사무실 — 한 행 띠(배율 1)와 보여 줄 행 고르기
@Suite("미니 사무실")
struct MiniOfficeTests {
    func session(_ event: String, _ extra: String = "", _ session: String) -> String {
        hook(event, extra, session: session, cwd: "/w/\(session)")
    }

    func start(_ session: String) -> String { self.session("SessionStart", "", session) }

    func edit(_ session: String, _ id: String) -> String {
        self.session("PreToolUse", #""tool_name":"Edit","tool_use_id":"\#(id)","tool_input":{"file_path":"/x/A.swift"}"#, session)
    }

    func bash(_ event: String, _ session: String, _ id: String) -> String {
        self.session(event, #""tool_name":"Bash","tool_use_id":"\#(id)","tool_input":{"command":"npm test"}"#, session)
    }

    func next(_ h: FloorHarness, _ previous: MiniFocus, pinned: TeamID? = nil, autoSwitch: Bool = true) -> MiniFocus {
        MiniFocus.next(
            previous: previous, state: h.engine.state, journal: h.engine.journal, pinned: pinned, autoSwitch: autoSwitch,
            now: h.epoch.addingTimeInterval(h.now))
    }

    @Test("패널 폭으로 책상 수를 센다 (배율 1, 최소 폭으로 올려 잡지 않음)")
    func columns() {
        #expect(MiniOffice.columns(panelWidth: MiniOffice.defaultWidth) == 5)
        #expect(MiniOffice.columns(panelWidth: 700) == 6)
        #expect(MiniOffice.columns(panelWidth: MiniOffice.minWidth) == 2)
        #expect(OfficeLayout.columns(width: 1140) == OfficeLayout.capacity(width: 1140, height: 708).columns)
        // 보이는 영역: 휴게 공간부터 첫 행 아래까지, 높이 고정
        let extent = MiniOffice.extent(panelWidth: 620)
        #expect(extent.y < OfficeLayout.sofas[0].y && extent.maxY == OfficeLayout.firstDeskY + 40)
        #expect(MiniOffice.panelHeight == MiniOffice.headerHeight + extent.height)
    }

    @Test("한 행 띠: 고른 행만 첫 행 자리에 놓고, 넘친 서브는 +N")
    func bandShowsOneRow() throws {
        var h = FloorHarness(width: MiniOffice.visibleMapWidth(panelWidth: 620), height: OfficeLayout.minHeight, band: true)
        h.hook(start("m1"))
        h.hook(start("m2"), at: 0.5)
        for index in 1...6 { h.hook(delegateHook("m1", "a\(index)").replacingOccurrences(of: "/w/a-sdn-portal", with: "/w/m1"), at: Double(index) * 0.3) }
        h.hook(delegateHook("m2", "b1").replacingOccurrences(of: "/w/a-sdn-portal", with: "/w/m2"), at: 3)
        h.run(until: 30)
        let (m1, m2) = (h.team("m1"), h.team("m2"))

        h.select(.only(m2))
        #expect(h.stage.layout.rows.map(\.team) == [m2])
        #expect(h.stage.layout.rows[0].deskY == OfficeLayout.firstDeskY)
        #expect(h.stage.actors.count == 2)
        #expect(h.floor.plan.hiddenCount == 0)

        h.select(.only(m1))
        h.run(until: 40)
        #expect(h.stage.layout.rows.map(\.team) == [m1])
        #expect(h.stage.actors.count == 5)
        #expect(h.floor.plan.hiddenCount == 2)
        #expect(h.stage.hiddenCounts[m1] == 2)
        // 보이는 사람은 모두 패널 안, 출입문은 패널 오른쪽 밖 (사무실과 같은 배치)
        let extent = MiniOffice.extent(panelWidth: 620)
        for actor in h.stage.actors.values { #expect(extent.contains(actor.position)) }
        #expect(h.stage.layout.doorX > extent.maxX)

        h.select(.only(nil))
        #expect(h.stage.actors.isEmpty)
    }

    @Test("보여 줄 행: 승인 대기 > 고정 > 최근 활동, 조용해질 때까지 바꾸지 않음")
    func focusRules() throws {
        var h = FloorHarness()
        #expect(next(h, .empty).team == nil)
        h.hook(start("m1"))
        h.hook(start("m2"), at: 0.5)
        h.hook(edit("m1", "e1"), at: 1)
        h.hook(edit("m2", "e2"), at: 5)
        let (m1, m2) = (h.team("m1"), h.team("m2"))

        // 최근 활동: 가장 최근에 일한 행
        h.run(until: 6)
        var focus = next(h, .empty)
        #expect(focus.team == m2 && focus.reason == .recent)
        // 다른 행이 일해도 지금 행이 최근 20초 안에 일했으면 그대로
        h.hook(edit("m1", "e3"), at: 7)
        h.run(until: 12)
        focus = next(h, focus)
        #expect(focus.team == m2)
        // 지금 행이 20초 넘게 조용하면 최근에 일한 행으로
        h.run(until: 30)
        focus = next(h, focus)
        #expect(focus.team == m1)
        let switched = focus.since
        #expect(switched == h.epoch.addingTimeInterval(30))

        // 고정한 행이 최근 활동보다 먼저
        #expect(next(h, focus, pinned: m2).team == m2)
        #expect(next(h, focus, pinned: m2).reason == .pinned)

        // 승인 대기는 고정보다 먼저 (자동 전환을 켰을 때만)
        h.hook(bash("PreToolUse", "m2", "b1"), at: 31)
        h.hook(bash("PermissionRequest", "m2", "b1"), at: 31.1)
        focus = next(h, focus, pinned: m1)
        #expect(focus.team == m2 && focus.reason == .waiting)
        #expect(next(h, focus, pinned: m1, autoSwitch: false).team == m1)
        // 다른 행도 대기를 시작해도 지금 보는 행에 대기가 남아 있으면 그대로
        h.hook(bash("PreToolUse", "m1", "b2"), at: 32)
        h.hook(bash("PermissionRequest", "m1", "b2"), at: 32.1)
        focus = next(h, focus, pinned: m1)
        #expect(focus.team == m2 && focus.reason == .waiting)
        // 지금 행의 대기가 풀리면 남은 대기의 행으로
        h.hook(bash("PostToolUse", "m2", "b1"), at: 33)
        focus = next(h, focus)
        #expect(focus.team == m1 && focus.reason == .waiting)
        // 모두 풀리면 최근 활동 (머무름 시간은 대기에서 돌아올 때 적용하지 않음)
        h.hook(bash("PostToolUse", "m1", "b2"), at: 34)
        h.hook(edit("m2", "e4"), at: 35)
        focus = next(h, focus)
        #expect(focus.team == m2 && focus.reason == .recent)
    }
}
