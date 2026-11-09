import Foundation
import Testing

@testable import OfficeCore

/// M6(2): 대화 압축("정리 중")이 끝 신호(SessionStart source `compact`, PostCompact)나 시간 초과로 풀리고,
/// 쉬던 사람은 원래 쉼 단계로, 응답 중이던 사람은 하던 일로 돌아가는지
@Suite("대화 압축 (정리 중)")
struct CompactionTests {
    static let folder = "/Users/demo/work/claude-office"
    let hook = Hook(session: "s1", cwd: Self.folder)
    let lead = AgentID("lead-1")
    var seat: Spot { .seat(TeamID("\(Self.folder)#1"), .main) }

    func compactStart(_ trigger: String = "manual") -> JSONValue {
        hook.make("PreCompact", JSONObject([("trigger", .string(trigger))]))
    }

    var compactDone: JSONValue { hook.make("SessionStart", JSONObject([("source", .string("compact"))])) }

    func activity(_ h: EngineHarness) -> Activity? { h.engine.state.agents[lead]?.activity }

    /// 지시 목록에서 마지막 자세·소품·표정·머리 위 표시
    func last(_ actions: [Directive.Action]) -> (pose: Pose?, prop: Prop??, emote: Emote??) {
        var pose: Pose?
        var prop: Prop??
        var emote: Emote??
        for action in actions {
            switch action {
            case .pose(let value): pose = value
            case .prop(let value): prop = .some(value)
            case .emote(let value): emote = .some(value)
            default: break
            }
        }
        return (pose, prop, emote)
    }

    @Test("PostCompact 훅은 압축 끝으로 읽는다")
    func parsesPostCompact() throws {
        let event = try #require(HookParser.parse(hook.make("PostCompact", JSONObject([("trigger", .string("manual"))])), term: nil, receivedAt: Fixture.epoch))
        #expect(event.kind == .compactFinished)
    }

    @Test("쉬던 중(자기 자리에서 잠듦) 압축하면 Zz를 내리고 깨어 정리하다가, SessionStart compact가 오면 다시 잠든다")
    func idleCompactionAtDesk() {
        var config = ChoreographyConfig()
        config.massageChairs = 0  // 안마 의자가 차 있어 소파에서 쉬다가 자기 자리에서 잠듦
        var h = EngineHarness(config: config)
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 700)
        #expect(h.engine.choreographer.spot(of: lead) == seat)
        let spotBefore = h.engine.choreographer.spot(of: lead)
        let napped = last(h.actions(of: lead))
        #expect(napped.pose == .sleeping)
        #expect(napped.emote == .some(.zzz))

        let compacting = h.send(compactStart(), at: 700).filter { $0.agent == lead }.map(\.action)
        #expect(activity(h) == .compacting)
        #expect(RosterStatus.from(activity(h)!) == .compacting)
        let sorting = last(compacting)
        #expect(sorting.pose == .sorting)
        #expect(sorting.prop == .some(.documents))
        #expect(sorting.emote == .some(nil))  // Zz를 내림
        #expect(compacting.walks.isEmpty)  // 그 자리에서 정리
        #expect(h.engine.choreographer.spot(of: lead) == spotBefore)

        let count = h.actions(of: lead).count
        h.send(compactDone, at: 760)
        #expect(activity(h) == .idle)
        // 쉬기 시작한 때(Stop)를 그대로 이어 갑니다
        #expect(h.engine.state.agents[lead]?.activitySince == Fixture.epoch.addingTimeInterval(1))
        let restored = last(Array(h.actions(of: lead).dropFirst(count)))
        #expect(restored.pose == .sleeping)
        #expect(restored.prop == .some(nil))
        #expect(restored.emote == .some(.zzz))
        #expect(h.engine.choreographer.spot(of: lead) == spotBefore)
    }

    @Test("안마 의자에서 압축하면 의자에 앉은 채 서류를 보고, 끝나면 안마로 돌아갔다가 10분이 되면 그 의자에서 잠든다")
    func idleCompactionOnMassageChair() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 200)
        #expect(h.engine.choreographer.spot(of: lead) == .massageChair)

        let compacting = h.send(compactStart(), at: 200).filter { $0.agent == lead }.map(\.action)
        #expect(compacting.walks.isEmpty)
        #expect(last(compacting).emote == .some(nil))  // ♪를 내림
        #expect(last(compacting).pose == .sorting)

        // 정리하는 동안은 쉼 단계가 나아가지 않습니다
        h.advance(to: 230)
        let count = h.actions(of: lead).count
        h.send(compactDone, at: 230)
        let restored = last(Array(h.actions(of: lead).dropFirst(count)))
        #expect(restored.pose == .massage)
        #expect(restored.prop == .some(nil))
        #expect(restored.emote == .some(.note))
        #expect(h.engine.choreographer.spot(of: lead) == .massageChair)

        h.advance(to: 605)
        #expect(h.engine.choreographer.spot(of: lead) == .massageChair)
        #expect(last(h.actions(of: lead)).pose == .sleeping)
    }

    @Test("소파에서 압축하면 컵을 내려놓고 서류를 보다가, 끝나면 다시 컵을 든다")
    func idleCompactionOnLounge() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 90)
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
        let compacting = h.send(compactStart(), at: 90).filter { $0.agent == lead }.map(\.action)
        #expect(last(compacting).prop == .some(.documents))
        let count = h.actions(of: lead).count
        h.send(compactDone, at: 100)
        let restored = last(Array(h.actions(of: lead).dropFirst(count)))
        #expect(restored.pose == .holdingCup)
        #expect(restored.prop == .some(.cup))
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
    }

    @Test("입력 대기 중 압축하면 끝난 뒤 입력 대기로 돌아간다")
    func waitingForInputCompaction() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit"), at: 1)
        h.send(hook.make("Stop"), at: 5)
        h.send(hook.make("Notification", JSONObject([("notification_type", .string("idle_prompt")), ("message", .string("Claude is waiting for your input"))])), at: 65)
        let before = activity(h)
        #expect(before == .waitingForInput)
        h.send(compactStart(), at: 70)
        h.send(compactDone, at: 80)
        #expect(activity(h) == before)
        #expect(activity(h).map { RosterStatus.from($0).tone } == .calm)
    }

    @Test("응답 중(자동 압축)이면 끝난 뒤 하던 일로 돌아간다")
    func respondingCompaction() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit"), at: 1)
        h.send(hook.tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/tmp/a.swift"]), at: 2)
        h.send(hook.tool("PostToolUse", "Read", id: "r1", input: ["file_path": "/tmp/a.swift"]), at: 3)
        #expect(activity(h) == .thinking)
        h.send(compactStart("auto"), at: 4)
        #expect(activity(h) == .compacting)
        let count = h.actions(of: lead).count
        h.send(compactDone, at: 40)
        #expect(activity(h) == .thinking)
        let after = Array(h.actions(of: lead).dropFirst(count))
        #expect(last(after).pose == .thinking)
        #expect(last(after).prop == .some(nil))  // 서류를 내려놓음

        // 이어서 Stop이 오면 평소처럼 쉬는 상태
        h.send(hook.make("Stop"), at: 50)
        #expect(activity(h) == .idle)
    }

    @Test("응답 중 압축 뒤 바로 다음 도구가 오면 서류 자세를 풀고 일한다")
    func toolAfterCompaction() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit"), at: 1)
        h.send(compactStart("auto"), at: 2)
        let count = h.actions(of: lead).count
        h.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/tmp/a.swift"]), at: 10)
        #expect(activity(h).map { RosterStatus.from($0) } == .editing)
        let after = last(Array(h.actions(of: lead).dropFirst(count)))
        #expect(after.pose == .typing)
        #expect(after.prop == .some(nil))
        // 늦게 온 압축 끝 신호는 하던 일을 바꾸지 않습니다
        h.send(compactDone, at: 12)
        #expect(activity(h).map { RosterStatus.from($0) } == .editing)
    }

    @Test("끝 신호가 오지 않으면 5분 뒤 쉬는 상태로 풀고 원래 쉼 단계로 돌아간다")
    func compactionTimesOut() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 700)
        h.send(compactStart(), at: 700)
        h.advance(to: 700 + OfficeState.compactionTimeout - 1)
        #expect(activity(h) == .compacting)
        let count = h.actions(of: lead).count
        h.advance(to: 700 + OfficeState.compactionTimeout + 1)
        #expect(activity(h) == .idle)
        #expect(h.engine.state.agents[lead]?.activitySince == Fixture.epoch.addingTimeInterval(1))
        let restored = last(Array(h.actions(of: lead).dropFirst(count)))
        #expect(restored.pose == .sleeping)
        #expect(restored.emote == .some(.zzz))
    }

    @Test("응답 중에 압축하고 아무 신호도 없으면 5분 뒤 쉬는 상태로 풀린다")
    func respondingCompactionTimesOut() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("UserPromptSubmit"), at: 1)
        h.send(compactStart("auto"), at: 2)
        h.advance(to: 2 + OfficeState.compactionTimeout + 1)
        #expect(activity(h) == .idle)
        #expect(h.engine.choreographer.spot(of: lead) == seat)
        #expect(last(h.actions(of: lead)).prop == .some(nil))
        // 그 뒤로 쉼 단계가 다시 흘러갑니다
        h.advance(to: 2 + OfficeState.compactionTimeout + 70)
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
    }

    @Test("PostCompact도 압축을 끝낸다")
    func postCompactEnds() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.send(compactStart(), at: 10)
        h.send(hook.make("PostCompact", JSONObject([("trigger", .string("manual"))])), at: 20)
        #expect(activity(h) == .idle)
    }

    @Test("압축 중 화면에 다시 세우면 서류를 든 정리 자세이고 Zz가 없다")
    func restoreWhileCompacting() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 700)
        h.send(compactStart(), at: 700)
        let agent = h.engine.state.agents[lead]!
        let actions = h.engine.choreographer.restoreDirectives(for: agent, entering: false).map(\.action)
        #expect(actions.contains(.pose(.sorting)))
        #expect(actions.contains(.prop(.documents)))
        #expect(!actions.contains { if case .emote = $0 { true } else { false } })
    }
}
