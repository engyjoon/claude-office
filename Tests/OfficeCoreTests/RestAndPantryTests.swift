import Foundation
import Testing

@testable import OfficeCore

/// M4.5b: 쉼 단계(소파 → 안마 의자 → 잠듦), 안마 의자 점유, 탕비 코너 들르기
@Suite("쉼 단계와 탕비 코너")
struct RestAndPantryTests {
    static let folder = "/Users/demo/work/claude-office"
    /// 직접 연 세션은 각자 행 (n번째로 열린 행)
    func team(_ index: Int) -> TeamID { TeamID("\(Self.folder)#\(index)") }

    func hook(_ index: Int) -> Hook { Hook(session: "s\(index)", cwd: Self.folder) }
    func lead(_ index: Int) -> AgentID { AgentID("lead-\(index)") }

    @Test("안마 의자는 둘이라 먼저 온 두 사람만 앉고, 셋째는 소파에 남았다가 10분이 되면 자기 자리에서 존다")
    func massageChairOccupancy() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        h.send(hook(2).make("SessionStart"), at: 0.1)
        h.send(hook(3).make("SessionStart"), at: 0.2)
        h.send(hook(1).make("Stop"), at: 1)
        h.send(hook(2).make("Stop"), at: 2)
        h.send(hook(3).make("Stop"), at: 3)
        h.advance(to: 64)
        for index in 1...3 { #expect(h.engine.choreographer.spot(of: lead(index)) == .lounge) }
        h.advance(to: 186)
        #expect(h.engine.choreographer.spot(of: lead(1)) == .massageChair)
        #expect(h.engine.choreographer.spot(of: lead(2)) == .massageChair)
        #expect(h.engine.choreographer.spot(of: lead(3)) == .lounge)
        #expect(!h.actions(of: lead(3)).walks.contains(.massageChair))
        h.advance(to: 606)
        #expect(h.engine.choreographer.spot(of: lead(1)) == .massageChair)
        #expect(h.actions(of: lead(1)).last == .emote(.zzz) || h.actions(of: lead(1)).contains(.pose(.sleeping)))
        #expect(h.engine.choreographer.spot(of: lead(3)) == .seat(team(3), .main))
        #expect(h.actions(of: lead(3)).contains(.pose(.sleeping)))

        // 안마 의자에서 자다가 새 프롬프트가 오면 깨어 자리로 돌아가고, 의자가 빕니다
        h.send(hook(1).make("UserPromptSubmit"), at: 610)
        #expect(h.engine.choreographer.spot(of: lead(1)) == .seat(team(1), .main))
    }

    @Test("쉬러 가는 길에 가끔 탕비 코너 냉장고에서 음료를 꺼내 들고 간다 (동시에 2명까지)")
    func drinkOnTheWay() {
        var h = EngineHarness()
        for index in 1...8 { h.send(hook(index).make("SessionStart"), at: Double(index) * 0.1) }
        for index in 1...8 { h.send(hook(index).make("Stop"), at: 2) }
        h.advance(to: 70)
        let viaPantry = (1...8).filter { h.actions(of: lead($0)).walks.contains(.pantry) }
        #expect(!viaPantry.isEmpty)
        #expect(viaPantry.count <= 2)
        for index in 1...8 {
            let actions = h.actions(of: lead(index))
            #expect(h.engine.choreographer.spot(of: lead(index)) == .lounge)
            if viaPantry.contains(index) {
                #expect(actions.walks.suffix(2) == [.pantry, .lounge])
                #expect(actions.contains(.prop(.drink)))
            } else {
                #expect(actions.contains(.prop(.cup)))
            }
        }
    }

    @Test("일을 끝낸 파트원은 가끔 탕비 코너에서 물 한 잔 마시고 퇴근한다")
    func waterBeforeLeaving() {
        var h = EngineHarness()
        h.send(hook(1).make("SessionStart"), at: 0)
        var members: [AgentID] = []
        for index in 0..<8 {
            let directives = h.send(hook(1).tool("PreToolUse", "Agent", id: "a\(index)", input: ["subagent_type": "general-purpose"]), at: 1 + Double(index))
            for directive in directives {
                if case .spawn(let agent, _) = directive.action, agent.role == .member { members.append(agent.id) }
            }
            h.send(hook(1).tool("PostToolUse", "Agent", id: "a\(index)", input: [:]), at: 1.5 + Double(index))
        }
        let thirsty = members.filter { h.actions(of: $0).walks.contains(.pantry) }
        #expect(!thirsty.isEmpty && thirsty.count < members.count)
        for id in thirsty {
            let actions = h.actions(of: id)
            #expect(actions.walks.suffix(2) == [.pantry, .door])
            #expect(actions.contains(.pose(.holdingCup)))
            #expect(actions.last == .despawn)
        }
    }
}
