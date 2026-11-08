import Foundation
import Testing

@testable import OfficeCore

/// 파트 칸 배정과 빈 책상 빌리기 (설계서 §8.1, M4.5b):
/// 파트원은 자기 세션의 칸에 앉고, 넘치면 자기 칸의 빈 책상 → 빈 칸(파트가 없는 칸)의 책상을 빌리고, 그래도 없으면 칸 앞에 서서 일합니다.
@Suite("파트 칸과 빈 책상 빌리기")
struct DeskBorrowTests {
    static let folder = "/Users/demo/work/claude-office"
    let team = TeamID(Self.folder)

    func hook(_ index: Int) -> Hook { Hook(session: "s\(index)", cwd: Self.folder) }

    func spot(_ h: EngineHarness, _ id: String) -> Spot? { h.engine.choreographer.spot(of: AgentID(id)) }

    /// 세션 `session`이 일반 서브에이전트를 `count`명 부릅니다 (백그라운드라 응답이 끝나도 남음). 만든 파트원 id를 돌려줍니다.
    func delegate(_ h: inout EngineHarness, _ session: Int, count: Int, from: Int = 0, at time: Double) -> [AgentID] {
        var ids: [AgentID] = []
        for index in 0..<count {
            let directives = h.send(
                hook(session).tool("PreToolUse", "Agent", id: "a\(session)-\(from + index)",
                    input: ["subagent_type": "general-purpose", "description": "작업", "run_in_background": true]),
                at: time + Double(index) * 0.01)
            for directive in directives {
                if case .spawn(let agent, _) = directive.action, agent.role == .member { ids.append(agent.id) }
            }
            h.send(hook(session).make("SubagentStart", ["agent_id": .string("x\(session)-\(from + index)"), "agent_type": "general-purpose"]),
                at: time + Double(index) * 0.01 + 0.005)
        }
        return ids
    }

    @Test("파트원은 자기 세션의 칸에 앉는다: 팀장 파트원은 0번 칸, 파트장 파트원은 파트장 칸")
    func podsBySession() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        h.send(hook(2).make("SessionStart"), at: 0.1)
        let mainMembers = delegate(&h, 1, count: 2, at: 1)
        let partMembers = delegate(&h, 2, count: 2, at: 2)
        #expect(mainMembers.map { h.engine.state.agents[$0]?.seat } == [Seat(part: 0, desk: 1), Seat(part: 0, desk: 2)])
        #expect(partMembers.map { h.engine.state.agents[$0]?.seat } == [Seat(part: 1, desk: 1), Seat(part: 1, desk: 2)])
        #expect(spot(h, "lead-1") == .seat(team, .office))
        #expect(spot(h, "lead-2") == .seat(team, Seat(part: 1, desk: 0)))
        #expect(spot(h, mainMembers[0].raw) == .seat(team, Seat(part: 0, desk: 1)))
        #expect(spot(h, partMembers[1].raw) == .seat(team, Seat(part: 1, desk: 2)))
    }

    @Test("칸이 넘치면 자기 칸의 빈 ★ 자리 → 빈 칸의 책상을 빌린다")
    func borrowsFromEmptyPod() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        let members = delegate(&h, 1, count: 6, at: 1)
        let seats = members.map { h.engine.state.agents[$0]!.seat }
        #expect(seats == (1...6).map { Seat(part: 0, desk: $0) })
        // 3명은 자기 책상, 4번째는 팀장 파트 칸의 비어 있는 ★ 자리, 5·6번째는 옆의 빈 칸(1번 칸) 책상
        #expect(spot(h, members[3].raw) == .seat(team, Seat(part: 0, desk: 0)))
        #expect(spot(h, members[4].raw) == .seat(team, Seat(part: 1, desk: 0)))
        #expect(spot(h, members[5].raw) == .seat(team, Seat(part: 1, desk: 1)))
    }

    @Test("빈 칸이 없으면 칸 앞에 서서 일한다 (다른 파트 칸의 책상은 빌리지 않음)")
    func standsWhenNoFreePod() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        h.send(hook(2).make("SessionStart"), at: 0.1)  // 1번 칸 = 파트장 칸 → 빈 칸 없음
        let members = delegate(&h, 1, count: 5, at: 1)
        #expect(spot(h, members[3].raw) == .seat(team, Seat(part: 0, desk: 0)))
        #expect(spot(h, members[4].raw) == .seat(team, Seat(part: 0, desk: 5)))
    }

    @Test("파트장이 쉬러 가면 그 칸 파트원이 ★ 자리를 빌리고, 파트장이 돌아오면 비켜 준다")
    func yieldsToPartLead() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        h.send(hook(2).make("SessionStart"), at: 0.1)
        let members = delegate(&h, 2, count: 4, at: 1)
        let fourth = members[3]
        #expect(spot(h, fourth.raw) == .seat(team, Seat(part: 1, desk: 4)))
        h.send(hook(2).make("Stop"), at: 2)
        h.advance(to: 64)
        #expect(spot(h, "lead-2") == .lounge)
        // 다음 일을 시작하면 비어 있는 ★ 자리를 빌린다
        h.send(hook(2).tool("PreToolUse", "Write", id: "w1", input: ["file_path": "/x/A.swift"], agent: (id: "x2-3", type: "general-purpose")), at: 65)
        #expect(spot(h, fourth.raw) == .seat(team, Seat(part: 1, desk: 0)))
        // 파트장이 돌아오면 칸 앞으로 비켜 서서 하던 일을 이어 간다
        h.send(hook(2).make("UserPromptSubmit"), at: 70)
        #expect(spot(h, "lead-2") == .seat(team, Seat(part: 1, desk: 0)))
        #expect(spot(h, fourth.raw) == .seat(team, Seat(part: 1, desk: 4)))
        #expect(h.actions(of: fourth).last == .pose(.typing))
    }

    @Test("팀장이 퇴근하면 파트장은 팀장실로, 그 파트원은 팀장 파트 칸(0번)으로 옮긴다")
    func promotionMovesPod() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        h.send(hook(2).make("SessionStart"), at: 0.1)
        let members = delegate(&h, 2, count: 2, at: 1)
        h.advance(to: 10)
        h.send(hook(1).make("SessionEnd", ["reason": "other"]), at: 11)
        #expect(h.engine.state.agents[AgentID("lead-2")]?.seat == .office)
        #expect(members.map { h.engine.state.agents[$0]?.seat } == [Seat(part: 0, desk: 1), Seat(part: 0, desk: 2)])
        #expect(spot(h, "lead-2") == .seat(team, .office))
        #expect(spot(h, members[0].raw) == .seat(team, Seat(part: 0, desk: 1)))
        #expect(h.actions(of: members[1]).contains { if case .refresh(let agent) = $0 { agent.part == 0 } else { false } })
    }
}
