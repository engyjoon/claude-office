import Foundation
import Testing

@testable import OfficeCore

/// 빈 책상 빌리기: 책상이 없는 좌석(섬마다 4개를 넘는 사람)은 일할 때 빈 책상을 빌려 앉고, 주인이 돌아오면 비켜 준다.
@Suite("빈 책상 빌리기")
struct DeskBorrowTests {
    static let folder = "/Users/demo/work/claude-office"
    let team = TeamID(Self.folder)

    func hook(_ index: Int) -> Hook { Hook(session: "s\(index)", cwd: Self.folder) }
    func lead(_ index: Int) -> AgentID { AgentID("lead-\(index)") }

    func spot(_ h: EngineHarness, _ index: Int) -> Spot? { h.engine.choreographer.spot(of: lead(index)) }

    /// 같은 폴더 세션 5개: 팀장(0번 책상) + 파트장 4명(1~3번 책상, 5번째는 책상 없는 4번 좌석)
    func fiveSessions() -> EngineHarness {
        var h = EngineHarness()
        for index in 1...5 {
            h.send(hook(index).make("SessionStart"), at: Double(index) * 0.1)
        }
        h.advance(to: 1)
        return h
    }

    @Test("책상이 모두 차 있을 때만 섬 앞에 서서 일한다")
    func standsOnlyWhenNoDesk() {
        var h = fiveSessions()
        #expect(h.engine.state.agents[lead(5)]?.seat == 4)
        #expect(spot(h, 5) == .seat(team, 4))
        h.send(hook(5).make("UserPromptSubmit"), at: 2)
        h.send(hook(5).tool("PreToolUse", "Write", id: "w1", input: ["file_path": "/x/DesktopSessions.swift"]), at: 2.2)
        #expect(spot(h, 5) == .seat(team, 4))
    }

    @Test("주인이 휴게실에 가 비어 있는 책상을 빌려 앉고, 팀장석은 마지막에 빌린다")
    func borrowsFreeDesk() {
        var h = fiveSessions()
        for index in 1...5 { h.send(hook(index).make("Stop"), at: 2) }
        h.advance(to: 70)
        #expect((1...5).allSatisfy { spot(h, $0) == .lounge })

        h.send(hook(5).make("UserPromptSubmit"), at: 71)
        #expect(spot(h, 5) == .seat(team, 1))
        h.send(hook(5).tool("PreToolUse", "Write", id: "w1", input: ["file_path": "/x/DesktopSessions.swift"]), at: 71.5)
        // 같은 책상에서 이어서 일하고, 앉은 채로 타이핑한다
        #expect(spot(h, 5) == .seat(team, 1))
        let actions = h.actions(of: lead(5))
        #expect(actions.contains(.sit))
        #expect(actions.contains(.pose(.typing)))
    }

    @Test("주인이 돌아오면 다른 빈 책상으로 옮기고, 빈 책상이 없으면 섬 앞에 선다")
    func yieldsToOwner() {
        var h = fiveSessions()
        for index in 1...5 { h.send(hook(index).make("Stop"), at: 2) }
        h.advance(to: 70)
        h.send(hook(5).make("UserPromptSubmit"), at: 71)
        h.send(hook(5).tool("PreToolUse", "Write", id: "w1", input: ["file_path": "/x/A.swift"]), at: 71.5)
        #expect(spot(h, 5) == .seat(team, 1))

        // 1번 책상 주인(파트장, s2)이 돌아오면 2번 책상으로
        h.send(hook(2).make("UserPromptSubmit"), at: 72)
        #expect(spot(h, 2) == .seat(team, 1))
        #expect(spot(h, 5) == .seat(team, 2))
        #expect(h.actions(of: lead(5)).last == .pose(.typing))

        h.send(hook(3).make("UserPromptSubmit"), at: 73)
        #expect(spot(h, 5) == .seat(team, 3))
        // 남은 빈 책상은 팀장석뿐
        h.send(hook(4).make("UserPromptSubmit"), at: 74)
        #expect(spot(h, 5) == .seat(team, 0))
        // 팀장까지 돌아오면 빌릴 책상이 없어 섬 앞에 선다
        h.send(hook(1).make("UserPromptSubmit"), at: 75)
        #expect(spot(h, 1) == .seat(team, 0))
        #expect(spot(h, 5) == .seat(team, 4))
        #expect([1, 2, 3, 4].map { spot(h, $0) } == [0, 1, 2, 3].map { Spot.seat(team, $0) })
    }

    @Test("주인이 사무실에 없는 책상을 주인이 쉬러 간 책상보다 먼저 빌린다")
    func prefersOwnerlessDesk() {
        var h = fiveSessions()
        h.send(hook(3).make("SessionEnd", ["reason": "other"]), at: 2)  // 2번 책상 주인이 퇴근
        h.send(hook(2).make("Stop"), at: 2)
        h.advance(to: 70)
        #expect(spot(h, 2) == .lounge)
        h.send(hook(5).make("UserPromptSubmit"), at: 71)
        #expect(spot(h, 5) == .seat(team, 2))
    }

    @Test("책상이 없으면 휴게실에서 계속 쉬고, 섬 앞에 서서 졸지 않는다")
    func noStandingNap() {
        var h = fiveSessions()
        h.send(hook(5).make("Stop"), at: 2)
        h.advance(to: 700)
        #expect(spot(h, 5) == .lounge)
        #expect(!h.actions(of: lead(5)).contains(.pose(.sleeping)))
    }
}
