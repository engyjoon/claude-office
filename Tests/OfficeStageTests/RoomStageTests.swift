import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M4.5a: 승진하면 팀장석으로 옮기고, 명패가 직함을 따르고, 빈 방은 직원이 나간 뒤 닫힙니다.
@Suite("무대: 방과 직함")
struct RoomStageTests {
    @Test("파트장 명패가 붙고, 팀장이 퇴근하면 파트장이 팀장석으로 걸어가 앉는다")
    func promotionWalksToLeadSeat() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart", session: "s1"))
        h.hook(hook("SessionStart", session: "s2"), at: 0.5)
        h.run(until: 10)
        let partLead = try #require(h.actor("lead-2"))
        #expect(partLead.agent.displayName == "파트장")
        #expect(partLead.seated)
        let oldSeat = partLead.agent.seat
        #expect(h.stage.nameplates[TeamID("/w/a-sdn-portal")]?[oldSeat] == "파트장")
        #expect(h.stage.nameplates[TeamID("/w/a-sdn-portal")]?[0] == "★ 팀장")

        h.hook(hook("SessionEnd", session: "s1"), at: 12)
        h.run(until: 30)
        let promoted = try #require(h.actor("lead-2"))
        #expect(promoted.agent.displayName == "팀장")
        #expect(promoted.agent.seat == 0)
        #expect(promoted.position == OfficeLayout.seat(island: 0, index: 0).final)
        #expect(promoted.seated)
        #expect(h.actor("lead-1") == nil)
        // 파트장 명패는 떼고 팀장석 명패는 그대로
        #expect(h.stage.nameplates[TeamID("/w/a-sdn-portal")]?[oldSeat] == nil)
        #expect(h.stage.nameplates[TeamID("/w/a-sdn-portal")]?[0] == "★ 팀장")
        #expect(h.stage.teams.count == 1)
    }

    @Test("빈 방은 마지막 직원이 문을 나간 뒤 닫히고, 맨 아래 줄이 비면 사무실이 줄어든다")
    func roomClosesAfterLeaving() {
        var h = StageHarness()
        h.hook(hook("SessionStart", session: "a", cwd: "/w/a"))
        h.hook(hook("SessionStart", session: "b", cwd: "/w/b"))
        h.hook(hook("SessionStart", session: "c", cwd: "/w/c"))
        h.run(until: 10)
        #expect(h.stage.layout.rows == 2)
        #expect(h.stage.teams.count == 3)

        h.hook(hook("SessionEnd", session: "c", cwd: "/w/c"), at: 11)
        // 아직 문으로 걸어가는 중이면 섬이 남아 있습니다
        #expect(h.stage.teams[TeamID("/w/c")] != nil)
        h.run(until: 30)
        #expect(h.stage.teams[TeamID("/w/c")] == nil)
        #expect(h.events.contains(.teamClosed(TeamID("/w/c"))))
        #expect(h.stage.layout.rows == 1)

        // 다음 방은 빈 섬을 다시 씁니다
        h.hook(hook("SessionEnd", session: "a", cwd: "/w/a"), at: 31)
        h.hook(hook("SessionStart", session: "d", cwd: "/w/d"), at: 31.5)
        h.run(until: 45)
        #expect(h.stage.teams[TeamID("/w/d")]?.island == 0)
        #expect(h.stage.teams[TeamID("/w/a")] == nil)
        #expect(h.stage.sortedTeams.map(\.name) == ["d", "b"])
    }

    @Test("연출: 승진하면 정보 갱신, 팀장석으로 이동, 축하 대사")
    func promotionDirectives() {
        var engine = OfficeEngine(seed: 5)
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        func send(_ json: String, _ t: Double) -> [Directive] {
            (try? engine.handle(hookPayload: Data(json.utf8), at: epoch.addingTimeInterval(t))) ?? []
        }
        _ = send(hook("SessionStart", session: "s1"), 0)
        _ = send(hook("SessionStart", session: "s2"), 1)
        let directives = send(hook("SessionEnd", session: "s1"), 5)
        let promoted = AgentID("lead-2")
        let actions = directives.filter { $0.agent == promoted }.map(\.action)
        #expect(actions.contains { if case .refresh(let agent) = $0 { agent.displayName == "팀장" && agent.seat == 0 } else { false } })
        #expect(actions.contains(.walk(to: .seat(TeamID("/w/a-sdn-portal"), 0))))
        #expect(actions.contains(.gesture(.cheer)))
        #expect(actions.contains { if case .say = $0 { true } else { false } })
    }
}
