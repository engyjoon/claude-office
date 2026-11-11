import Foundation
import Testing

@testable import OfficeCore

/// 개선 11: 상태 → 모습 규칙은 `Choreographer.look(for:)` 하나입니다.
/// 일을 시작할 때 낸 모습과, 자리를 옮기거나 화면에 다시 세울 때 낸 모습이 어긋나지 않는지 봅니다.
@Suite("모습 규칙 (look)")
struct LookTests {
    static let folder = "/Users/demo/work/claude-office"
    let hook = Hook(session: "s1", cwd: Self.folder)
    let lead = AgentID("lead-1")
    func leadHook(_ index: Int) -> Hook { Hook(session: "s\(index)", cwd: Self.folder) }

    /// 지시 목록에서 마지막 자세·소품·표정·머리 위 아이콘
    struct Worn: Equatable {
        var pose: Pose?
        var prop: Prop?
        var expression: FacialExpression?
        var emote: Emote?
    }

    func worn(_ actions: [Directive.Action]) -> Worn {
        var worn = Worn()
        for action in actions {
            switch action {
            case .pose(let value): worn.pose = value
            case .prop(let value): worn.prop = value
            case .express(let value): worn.expression = value
            case .emote(let value): worn.emote = value
            default: break
            }
        }
        return worn
    }

    func restored(_ h: EngineHarness, _ id: AgentID) -> Worn {
        worn(h.engine.choreographer.restoreDirectives(for: h.engine.state.agents[id]!, entering: false).map(\.action))
    }

    @Test("웹 검색: 일을 시작할 때도, 화면에 다시 세울 때도 자기 책상에서 타이핑")
    func webSearch() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit", ["prompt": "찾아 줘"]), at: 1)
        h.send(hook.tool("PreToolUse", "WebSearch", id: "w1", input: ["query": "swift"]), at: 5)
        let live = worn(h.actions(of: lead))
        #expect(live.pose == .typing)
        #expect(live.prop == nil)
        #expect(restored(h, lead) == Worn(pose: .typing, prop: nil, expression: .focus, emote: nil))
    }

    @Test("웹 검색 중인 서브가 앞자리로 당겨 앉아도 타이핑 자세 그대로 (예전에는 읽는 자세로 바뀜)")
    func webSearchReseated() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit", ["prompt": "나눠서 해 줘"]), at: 1)
        var members: [AgentID] = []
        for (index, id) in ["x1", "x2"].enumerated() {
            let at = 2 + Double(index)
            h.send(hook.tool("PreToolUse", "Agent", id: "a-\(id)", input: ["subagent_type": "general-purpose"]), at: at)
            let directives = h.send(hook.make("SubagentStart", ["agent_id": .string(id), "agent_type": "general-purpose"]), at: at + 0.2)
            for directive in h.all + directives {
                if case .spawn(let agent, _) = directive.action, agent.role == .member, !members.contains(agent.id) { members.append(agent.id) }
            }
        }
        #expect(members.count == 2)
        let second = members[1]
        h.send(hook.tool("PreToolUse", "WebSearch", id: "w1", input: ["query": "swift"], agent: (id: "x2", type: "general-purpose")), at: 6)
        #expect(worn(h.actions(of: second)).pose == .typing)
        let before = h.actions(of: second).count
        // 앞자리 서브가 퇴근하면 뒷자리 서브가 당겨 앉습니다
        h.send(hook.make("SubagentStop", ["agent_id": "x1", "agent_type": "general-purpose"]), at: 12)
        h.advance(to: 14)
        let after = Array(h.actions(of: second).dropFirst(before))
        #expect(after.contains { if case .walk = $0 { true } else { false } }, "자리를 옮기지 않았습니다: \(after)")
        #expect(worn(after).pose == .typing)
        #expect(!after.contains(.pose(.reading)))
    }

    @Test("냉장고에서 꺼낸 음료는 대화 정리가 끝난 뒤에도, 화면에 다시 세울 때도 음료 그대로 (예전에는 컵으로 바뀜)")
    func drinkStays() throws {
        var h = EngineHarness()
        for index in 1...8 { h.send(leadHook(index).make("SessionStart"), at: Double(index) * 0.1) }
        for index in 1...8 { h.send(leadHook(index).make("Stop"), at: 2) }
        h.advance(to: 70)
        let drinker = try #require((1...8).first { h.actions(of: AgentID("lead-\($0)")).contains(.prop(.drink)) })
        let other = try #require((1...8).first { !h.actions(of: AgentID("lead-\($0)")).contains(.prop(.drink)) })
        let id = AgentID("lead-\(drinker)")
        #expect(restored(h, id) == Worn(pose: .holdingCup, prop: .drink, expression: .happy, emote: .note))
        #expect(restored(h, AgentID("lead-\(other)")).prop == .cup)

        // 소파에서 대화를 정리하고 나면 다시 음료를 든 모습
        h.send(leadHook(drinker).make("PreCompact", JSONObject([("trigger", .string("auto"))])), at: 80)
        #expect(restored(h, id).prop == .documents)
        let before = h.actions(of: id).count
        h.send(leadHook(drinker).make("PostCompact", JSONObject([("trigger", .string("auto"))])), at: 85)
        let after = worn(Array(h.actions(of: id).dropFirst(before)))
        #expect(after.pose == .holdingCup)
        #expect(after.prop == .drink)
        #expect(restored(h, id).prop == .drink)
    }

    @Test("긴 명령을 기다리는 모습(모니터 보기·평온한 표정·⏳)은 다시 세워도 같다 (예전에는 집중한 표정)")
    func watchingShell() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.advance(to: 12)
        h.send(hook.make("UserPromptSubmit", ["prompt": "빌드해 줘"]), at: 12)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "swift build"]), at: 16)
        h.advance(to: 20)
        let live = worn(h.actions(of: lead))
        #expect(live.pose == .watching)
        #expect(live.expression == .neutral)
        #expect(live.emote == .hourglass)
        #expect(restored(h, lead) == Worn(pose: .watching, prop: nil, expression: .neutral, emote: .hourglass))
    }

    @Test("화이트보드 앞에서 계획을 마치고 생각 중이면 다시 세워도 생각하는 모습 (예전에는 판서 자세와 마커)")
    func thinkingAtWhiteboard() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit", ["prompt": "계획 세워 줘"]), at: 1)
        h.send(hook.tool("PreToolUse", "TodoWrite", id: "p1", input: ["todos": []]), at: 5)
        #expect(h.engine.choreographer.spot(of: lead) == .whiteboard)
        #expect(restored(h, lead) == Worn(pose: .writingBoard, prop: .marker, expression: .focus, emote: nil))
        h.send(hook.tool("PostToolUse", "TodoWrite", id: "p1", input: ["todos": []]), at: 9)
        #expect(h.engine.choreographer.spot(of: lead) == .whiteboard)
        let live = worn(h.actions(of: lead))
        #expect(live.pose == .thinking)
        #expect(live.prop == nil)
        #expect(restored(h, lead) == Worn(pose: .thinking, prop: nil, expression: .think, emote: nil))
    }

    @Test("쉼 단계의 모습은 들어갈 때와 다시 세울 때가 같다: 소파 → 안마 의자 → 잠듦")
    func restStages() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        #expect(restored(h, lead) == Worn(pose: .sitting, prop: nil, expression: .neutral, emote: nil))
        for (time, pose, emote) in [(64.0, Pose.holdingCup, Emote.note), (186, .massage, .note), (606, .sleeping, .zzz)] {
            h.advance(to: time)
            let live = worn(h.actions(of: lead))
            let again = restored(h, lead)
            #expect(live.pose == pose)
            #expect(again.pose == pose)
            #expect(again.emote == emote)
            #expect(again.prop == live.prop)
            #expect(again.expression == live.expression)
        }
    }

    @Test("승인 대기는 무엇보다 먼저: 손을 들고 간절한 표정, 다시 세워도 같다")
    func waitingWins() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit", ["prompt": "지워 줘"]), at: 1)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "rm -rf build"]), at: 5)
        h.send(hook.tool("PermissionRequest", "Bash", id: "b1", input: ["command": "rm -rf build"]), at: 5.2)
        let live = worn(h.actions(of: lead))
        #expect(live.pose == .raisingHand)
        #expect(live.expression == .eager)
        #expect(live.emote == .exclamation)
        let again = restored(h, lead)
        #expect(again.pose == .raisingHand)
        #expect(again.expression == .eager)
        #expect(again.emote == .exclamation)
    }
}
