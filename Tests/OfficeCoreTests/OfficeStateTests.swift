import Foundation
import Testing

@testable import OfficeCore

@Suite("사무실 상태 리듀서")
struct OfficeStateTests {
    let hook = Hook()
    let reviewer = (id: "a-rev-1", type: "code-reviewer")

    func apply(_ state: inout OfficeState, _ payload: JSONValue, at seconds: Double = 0) -> [Beat] {
        guard let event = HookParser.parse(payload, receivedAt: Fixture.epoch.addingTimeInterval(seconds)) else { return [] }
        return state.apply(event)
    }

    @Test("세션 시작: 행을 열고 메인이 출근한다")
    func sessionStart() throws {
        var state = OfficeState()
        let beats = apply(&state, hook.make("SessionStart"))
        #expect(beats.count == 2)
        guard case .teamOpened(let team) = beats[0], case .arrived(let lead) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(team.name == "a-sdn-portal")
        #expect(team.island == 0)
        #expect(lead.role == .lead)
        #expect(lead.seat == .main)
        #expect(lead.profile.kind == .lead)
        // 같은 세션의 SessionStart(resume)가 또 와도 새로 출근하지 않습니다
        #expect(apply(&state, hook.make("SessionStart", ["source": "resume"])).isEmpty)
    }

    @Test("앱을 세션 중간에 켜도 첫 이벤트에서 메인을 만든다")
    func lateJoin() {
        var state = OfficeState()
        let beats = apply(&state, hook.tool("PreToolUse", "Edit", id: "t1", input: ["file_path": "/x/A.swift"]))
        #expect(beats.count == 3)
        if case .working(let lead, let call) = beats[2] {
            #expect(lead.role == .lead)
            #expect(call.subject == "A.swift")
        } else {
            Issue.record("\(beats)")
        }
    }

    @Test("같은 폴더에서 직접 연 두 번째 세션도 메인 (각자 행)")
    func secondMain() {
        var state = OfficeState()
        _ = apply(&state, Hook(session: "s1").make("SessionStart"))
        let beats = apply(&state, Hook(session: "s2").make("SessionStart"))
        #expect(state.teams.count == 2)
        guard case .arrived(let second) = beats.last else { Issue.record("\(beats)"); return }
        #expect(second.displayName == "메인2")
        #expect(second.seat == .main)
        _ = apply(&state, Hook(session: "s3", cwd: "/Users/demo/work/other").make("SessionStart"))
        #expect(state.sortedTeams.map(\.island) == [0, 1, 2])
    }

    @Test("위임 → SubagentStart → 팀원 활동 → SubagentStop → PostToolUse(Agent)")
    func delegationFlow() throws {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        let delegated = apply(&state, hook.tool("PreToolUse", "Agent", id: "tu-a", input: ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]), at: 1)
        guard case .delegated(let lead, let member) = try #require(delegated.first) else { Issue.record("\(delegated)"); return }
        #expect(lead.activity == .delegating)
        #expect(member.profile.kind == .fixed)
        #expect(member.profile.displayName == "code-reviewer")
        #expect(member.task == "RouterConfig 리뷰")
        #expect(member.subagentID == nil)

        // SubagentStart는 위임한 팀원에 agent_id를 묶을 뿐 새 직원을 만들지 않습니다
        #expect(apply(&state, hook.make("SubagentStart", ["agent_id": "a-rev-1", "agent_type": "code-reviewer"]), at: 1.1).isEmpty)
        #expect(state.member(subagentID: "a-rev-1", in: SessionID("s1"))?.id == member.id)

        let working = apply(&state, hook.tool("PreToolUse", "Grep", id: "tu-g", input: ["pattern": "null"], agent: reviewer), at: 2)
        guard case .working(let actor, _) = try #require(working.first) else { Issue.record("\(working)"); return }
        #expect(actor.id == member.id)

        let stopped = apply(&state, hook.make("SubagentStop", ["agent_id": "a-rev-1", "agent_type": "code-reviewer"]), at: 5)
        guard case .reported(let reporter, let to) = try #require(stopped.first) else { Issue.record("\(stopped)"); return }
        #expect(reporter.id == member.id)
        #expect(to?.id == lead.id)
        #expect(state.agents[member.id] == nil)
        #expect(state.lead(of: SessionID("s1"))?.activity == .thinking)

        // 뒤따르는 PostToolUse(Agent)는 이미 보고했으므로 아무 일도 없습니다
        #expect(apply(&state, hook.tool("PostToolUse", "Agent", id: "tu-a", input: [:], extra: [("tool_response", [:])]), at: 5.1).isEmpty)
    }

    @Test("구버전: SubagentStart 없이 PostToolUse(Task)로 보고를 마친다")
    func legacyDelegation() {
        var state = OfficeState()
        let delegated = apply(&state, hook.tool("PreToolUse", "Task", id: "tu-t", input: ["description": "README", "subagent_type": "general-purpose"]))
        guard case .delegated(_, let member) = delegated.last else { Issue.record("\(delegated)"); return }
        #expect(member.profile.kind == .temporary)
        #expect(member.profile.appearance.accessory == .sprout)
        let finished = apply(&state, hook.tool("PostToolUse", "Task", id: "tu-t", input: [:], extra: [("tool_response", [:])]), at: 3)
        guard case .reported(let reporter, _) = finished.first else { Issue.record("\(finished)"); return }
        #expect(reporter.id == member.id)
    }

    @Test("백그라운드 위임은 PostToolUse(Agent)가 먼저 와도 SubagentStop까지 남아 있다")
    func backgroundDelegation() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "tu-b", input: ["description": "긴 조사", "subagent_type": "Explore", "run_in_background": true]))
        #expect(apply(&state, hook.tool("PostToolUse", "Agent", id: "tu-b", input: [:], extra: [("tool_response", [:])]), at: 1).isEmpty)
        #expect(state.agents.values.filter { $0.role == .member }.count == 1)
        let stopped = apply(&state, hook.make("SubagentStop", ["agent_id": "x9", "agent_type": "Explore"]), at: 30)
        guard case .reported = stopped.first else { Issue.record("\(stopped)"); return }
    }

    @Test("위임 정보 없이 서브에이전트 훅이 오면 서브가 나타난다")
    func memberWithoutDelegation() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        let beats = apply(&state, hook.tool("PreToolUse", "Read", id: "r", input: ["file_path": "/a"], agent: (id: "zz", type: "researcher")))
        #expect(beats.count == 2)
        guard case .memberAppeared(let member) = beats[0], case .working(let actor, _) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(member.id == actor.id)
        #expect(member.profile.displayName == "researcher")
    }

    @Test("고정 직원은 퇴근 후 다시 와도 같은 얼굴이고, 책상은 오른쪽 끝에 새로 붙는다")
    func fixedMemberFace() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        let first = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "general-purpose"]))
        guard case .delegated(_, let reviewer1) = first.first else { Issue.record("\(first)"); return }
        _ = apply(&state, hook.tool("PostToolUse", "Agent", id: "a1", input: [:]))
        let again = apply(&state, hook.tool("PreToolUse", "Agent", id: "a3", input: ["subagent_type": "code-reviewer"]))
        guard case .delegated(_, let reviewer2) = again.last else { Issue.record("위임 없음"); return }
        #expect(reviewer2.profile.appearance == reviewer1.profile.appearance)
        #expect(reviewer2.seat == Seat(desk: 2))
    }

    @Test("서브는 1번 책상부터 사람 수만큼 앉는다 (빈 책상 없음)")
    func seatsGrow() {
        var state = OfficeState()
        for index in 0..<5 {
            _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a\(index)", input: ["subagent_type": "general-purpose"]))
        }
        let members = state.agents.values.filter { $0.role == .member }.map(\.seat).sorted()
        #expect(members == (1...5).map { Seat(desk: $0) })
        #expect(Set(state.agents.values.map(\.seat)).count == 6)
    }

    @Test("권한 요청은 PermissionRequest와 Notification이 둘 다 와도 한 번만 알린다")
    func permissionOnce() {
        var state = OfficeState()
        let first = apply(&state, hook.make("Notification", ["notification_type": "permission_prompt", "message": "x"]))
        #expect(first.contains { if case .permissionAsked = $0 { true } else { false } })
        let second = apply(&state, hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"]))
        #expect(second.isEmpty)
        if case .waitingForPermission(let call) = state.lead(of: SessionID("s1"))?.activity {
            #expect(call?.subject == "npm test")
        } else {
            Issue.record("승인 대기 상태가 아님")
        }
    }

    @Test("연속 오류 횟수를 세고, 성공하거나 새 프롬프트가 오면 초기화한다")
    func errorCounting() {
        var state = OfficeState()
        for index in 0..<3 {
            _ = apply(&state, hook.tool("PostToolUseFailure", "Read", id: "r\(index)", input: [:], extra: [("error", "nope")]))
        }
        #expect(state.lead(of: SessionID("s1"))?.consecutiveErrors == 3)
        _ = apply(&state, hook.tool("PostToolUse", "Read", id: "ok", input: [:]))
        #expect(state.lead(of: SessionID("s1"))?.consecutiveErrors == 0)
    }

    @Test("세션 종료: 팀원 먼저, 팀장 마지막으로 퇴근하고, 빈 방은 닫힌다")
    func sessionEnd() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        let beats = apply(&state, hook.make("SessionEnd", ["reason": "exit"]))
        #expect(beats.count == 3)
        guard case .left(let first) = beats[0], case .left(let last) = beats[1], case .teamClosed(let team) = beats[2] else {
            Issue.record("\(beats)")
            return
        }
        #expect(first.role == .member)
        #expect(last.role == .lead)
        #expect(team.name == "a-sdn-portal")
        #expect(state.agents.isEmpty)
        #expect(state.teams.isEmpty)  // 사람이 모두 떠난 방은 섬과 함께 정리합니다 (M4.5a)
    }
}

@Suite("M0 실제 데이터에서 발견한 경우")
struct M0FindingsTests {
    let hook = Hook()

    func apply(_ state: inout OfficeState, _ payload: JSONValue) -> [Beat] {
        guard let event = HookParser.parse(payload, receivedAt: Fixture.epoch) else { return [] }
        return state.apply(event)
    }

    @Test("위임 없이 끝나는 서브에이전트의 SubagentStop은 다른 팀원을 퇴근시키지 않는다")
    func orphanStopIsIgnored() throws {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        // 종류가 다른 SubagentStop
        #expect(apply(&state, hook.make("SubagentStop", ["agent_id": "x1", "agent_type": "web-fetch"])).isEmpty)
        // 종류가 빈 SubagentStop (합성 픽스처와 같은 모양)
        let orphan = try Fixture.payload("SubagentStop-orphan")
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "general-purpose"]))
        #expect(apply(&state, orphan.withSession("s1")).isEmpty)
        #expect(state.agents.values.filter { $0.role == .member }.count == 2)
    }

    @Test("종류가 빈 SubagentStart/Stop(내부 작업)은 후보가 하나여도 무시한다")
    func untypedSignalsAreIgnored() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        #expect(apply(&state, hook.make("SubagentStart", ["agent_id": "x0", "agent_type": ""])).isEmpty)
        #expect(apply(&state, hook.make("SubagentStop", ["agent_id": "x1"])).isEmpty)
        #expect(apply(&state, hook.make("SubagentStop", ["agent_id": "x2", "agent_type": ""])).isEmpty)
        #expect(state.agents.values.filter { $0.role == .member }.count == 1)
    }

    @Test("web-fetch처럼 시작·종료 신호가 없는 서브에이전트는 위임 툴이 끝날 때 보고하고 퇴근한다")
    func silentSubagent() {
        var state = OfficeState()
        let webFetch = (id: "w1", type: "web-fetch")
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "문서 조회", "subagent_type": "web-fetch"]))
        // 툴 이벤트의 agent_id로 위임 팀원에 연결됩니다 (새 직원이 생기지 않음)
        let working = apply(&state, hook.tool("PreToolUse", "WebFetch", id: "f1", input: ["url": "https://example.com"], agent: webFetch))
        #expect(working.count == 1)
        _ = apply(&state, hook.tool("PostToolUse", "WebFetch", id: "f1", input: [:], agent: webFetch))
        let finished = apply(&state, hook.tool("PostToolUse", "Agent", id: "a1", input: [:], extra: [("tool_response", [:])]))
        guard case .reported(let member, _) = finished.first else { Issue.record("\(finished)"); return }
        #expect(member.profile.agentType == "web-fetch")
        #expect(member.profile.kind == .temporary)
        #expect(state.agents.values.filter { $0.role == .member }.isEmpty)
    }

    @Test("SubagentStart를 받은 팀원은 PostToolUse(Agent)가 먼저 와도 SubagentStop을 기다린다")
    func announcedSubagentWaitsForStop() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]))
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]))
        #expect(apply(&state, hook.tool("PostToolUse", "Agent", id: "a1", input: [:])).isEmpty)
        let stopped = apply(&state, hook.make("SubagentStop", ["agent_id": "g1", "agent_type": "general-purpose"]))
        guard case .reported = stopped.first else { Issue.record("\(stopped)"); return }
    }

    @Test("안전장치: 팀장 응답이 끝나면 남은 팀원은 보고하고 퇴근한다 (백그라운드 제외)")
    func turnEndCleansUp() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]))
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "Explore", "run_in_background": true]))
        let beats = apply(&state, hook.make("Stop"))
        let reported = beats.filter { if case .reported = $0 { true } else { false } }
        #expect(reported.count == 1)
        #expect(state.agents.values.filter { $0.role == .member }.map(\.profile.agentType) == ["Explore"])
        // 응답 끝 다음에는 "확인 안 함" 표시가 붙습니다 (M6(4))
        guard case .turnEnded = beats.dropLast().last, case .cueChanged(let lead) = beats.last, lead.cue == .unread else {
            Issue.record("\(beats)"); return
        }
    }

    @Test("SubagentHandback은 보고 정리 연출이 되고, 메시지 내용은 보여주지 않는다")
    func handback() throws {
        let event = try Fixture.event("PreToolUse-SubagentHandback-subagent")
        guard case .toolStarted(let call) = event.kind else { Issue.record("\(event.kind)"); return }
        #expect(call.category == .report)
        #expect(call.subject == nil)

        var h = EngineHarness()
        h.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        let directives = h.send(hook.tool("PreToolUse", "SubagentHandback", id: "hb", input: ["message": "긴 보고 내용"], agent: (id: "r1", type: "code-reviewer")), at: 1)
        let member = AgentID("member-2")
        #expect(directives.contains(Directive(member, .pose(.sorting))))
        #expect(directives.contains(Directive(member, .status(StatusPill(category: .report, text: "보고 정리 중")))))
        #expect(!directives.bubbles.contains { $0.text.contains("긴 보고") })
    }
}

extension JSONValue {
    func withSession(_ id: String) -> JSONValue {
        guard var object = objectValue else { return self }
        object["session_id"] = .string(id)
        return .object(object)
    }
}

@Suite("도착 순서가 뒤바뀐 훅")
struct OutOfOrderTests {
    let hook = Hook()

    @Test("PostToolUse가 PreToolUse보다 먼저 와도 툴이 계속 진행 중으로 남지 않는다")
    func postBeforePre() {
        var state = OfficeState()
        func apply(_ payload: JSONValue) -> [Beat] {
            state.apply(HookParser.parse(payload, receivedAt: Fixture.epoch)!)
        }
        _ = apply(hook.tool("PostToolUse", "Read", id: "r1", input: [:]))
        #expect(apply(hook.tool("PreToolUse", "Read", id: "r1", input: [:])).isEmpty)
        #expect(state.lead(of: SessionID("s1"))?.runningTools.isEmpty == true)
        // 위임도 같습니다
        _ = apply(hook.tool("PostToolUse", "Agent", id: "a1", input: [:]))
        #expect(apply(hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"])).isEmpty)
        #expect(state.agents.values.filter { $0.role == .member }.isEmpty)
    }
}

/// 개선 4: 끝 이벤트(Stop·PostToolUse·SubagentStop·SessionEnd)가 오지 않아도 바쁜 상태가 남지 않게 하는 "암묵적 종료" 규칙
@Suite("끝 이벤트 없는 턴·도구·세션")
struct ImplicitEndTests {
    let hook = Hook()
    let session = SessionID("s1")
    let worker = (id: "g1", type: "general-purpose")
    let idle: JSONObject = ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]
    let permission: JSONObject = ["notification_type": "permission_prompt", "message": "Claude needs your permission"]

    func apply(_ state: inout OfficeState, _ payload: JSONValue, at seconds: Double) -> [Beat] {
        guard let event = HookParser.parse(payload, receivedAt: Fixture.epoch.addingTimeInterval(seconds)) else { return [] }
        return state.apply(event)
    }

    func at(_ seconds: Double) -> Date { Fixture.epoch.addingTimeInterval(seconds) }

    func names(_ beats: [Beat]) -> [String] {
        beats.map { String(describing: $0).prefix { $0 != "(" }.description }
    }

    // MARK: - Stop 없이 끝난 턴

    @Test("Stop 없이 끝난 턴: 일하던 메인에 idle_prompt가 오면 앞 턴을 닫고 입력 대기로")
    func idlePromptEndsTurn() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]), at: 2)
        let beats = apply(&state, hook.make("Notification", idle), at: 70)
        #expect(names(beats) == ["turnAbandoned", "waitingForInput"])
        let lead = state.lead(of: session)
        #expect(lead?.activity == .waitingForInput)
        #expect(lead?.runningTools.isEmpty == true)
        // 사용자가 직접 멈춘 턴이라 "확인 안 함"·"답변 필요"는 붙지 않고, 응답 중도 아닙니다
        #expect(lead?.cue == nil)
        #expect(!state.isResponding(session))
    }

    @Test("Stop이 제대로 온 뒤의 idle_prompt는 지금처럼 입력 대기만")
    func idlePromptAfterStop() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.make("Stop"), at: 5)
        #expect(names(apply(&state, hook.make("Notification", idle), at: 65)) == ["waitingForInput"])
        #expect(state.lead(of: session)?.cue == .unread)
    }

    @Test("방금 온 요청보다 늦게 도착한 지난 턴의 idle_prompt는 버린다")
    func staleIdlePrompt() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 100)
        #expect(apply(&state, hook.make("Notification", idle), at: 100.5).isEmpty)
        #expect(state.lead(of: session)?.activity == .thinking)
    }

    @Test("암묵적 종료: 남은 포그라운드 서브는 퇴근하고 백그라운드 서브는 남는다 (idle_prompt·새 요청 모두)", arguments: [false, true])
    func implicitEndDismissesForegroundMembers(byPrompt: Bool) {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 1)
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]), at: 1.1)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "Explore", "run_in_background": true]), at: 1.2)
        let beats = apply(&state, byPrompt ? hook.make("UserPromptSubmit") : hook.make("Notification", idle), at: 80)
        #expect(names(beats).prefix(1) == ["left"])
        #expect(names(beats).contains("turnAbandoned"))
        #expect(!names(beats).contains("reported"))  // 끝내지 못한 일이라 보고 연출은 하지 않습니다
        #expect(names(beats).last == (byPrompt ? "promptArrived" : "waitingForInput"))
        #expect(state.agents.values.filter { $0.role == .member }.map(\.profile.agentType) == ["Explore"])
        #expect(state.lead(of: session)?.activity == (byPrompt ? .thinking : .waitingForInput))
    }

    @Test("서브에이전트 안에서 난 UserPromptSubmit은 세션의 새 요청으로 치지 않는다")
    func promptInsideSubagent() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 1)
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]), at: 1.1)
        #expect(apply(&state, hook.make("UserPromptSubmit", agent: worker), at: 30).isEmpty)
        #expect(state.lead(of: session)?.activity == .delegating)
        #expect(state.agents.count == 2)
    }

    @Test("쉬는 메인에 온 새 요청은 지금처럼 요청 도착만")
    func promptAfterStop() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.make("Stop"), at: 5)
        #expect(names(apply(&state, hook.make("UserPromptSubmit"), at: 9)) == ["promptArrived", "cueChanged"])
    }

    @Test("승인 대기 중이던 턴도 idle_prompt가 오면 닫힌다 (질문을 Esc로 닫은 경우)")
    func idlePromptEndsPermissionWait() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "AskUserQuestion", id: "q1", input: [:]), at: 2)
        if case .waitingForPermission = state.lead(of: session)?.activity {} else { Issue.record("질문 답 대기가 아님") }
        _ = apply(&state, hook.make("Notification", idle), at: 90)
        #expect(state.lead(of: session)?.activity == .waitingForInput)
    }

    @Test("쉬던 중의 압축에 idle_prompt가 와도 턴을 닫지 않는다: 답변 필요 배지는 그대로")
    func idlePromptDuringRestingCompaction() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.make("Stop", ["last_assistant_message": "어느 쪽으로 할까요?"]), at: 5)
        _ = apply(&state, hook.make("PreCompact"), at: 20)
        let beats = apply(&state, hook.make("Notification", idle), at: 65)
        #expect(names(beats) == ["compactionEnded", "waitingForInput", "cueChanged"])
        #expect(state.lead(of: session)?.activity == .waitingForInput)
        #expect(state.lead(of: session)?.cue == .reply)
    }

    @Test("응답 중의 압축 도중 끊긴 턴은 압축을 풀고 턴을 닫는다")
    func idlePromptDuringTurnCompaction() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]), at: 2)
        _ = apply(&state, hook.make("PreCompact"), at: 3)
        let beats = apply(&state, hook.make("Notification", idle), at: 90)
        #expect(names(beats) == ["compactionEnded", "turnAbandoned", "waitingForInput"])
        #expect(state.lead(of: session)?.runningTools.isEmpty == true)
        #expect(!state.isResponding(session))
    }

    @Test("앱을 턴 도중에 켜서 첫 훅이 도구의 끝이면 출근 중이 아니라 생각 중")
    func firstHookIsToolEnd() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PostToolUse", "Read", id: "r1", input: [:]), at: 0)
        #expect(state.lead(of: session)?.activity == .thinking)
    }

    // MARK: - PostToolUse가 빠진 도구

    @Test("PostToolUse가 빠진 도구: 새 묶음의 Pre가 오면 버려서, 뒤 도구가 끝나도 되살아나지 않는다")
    func leftoverToolIsDropped() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/x/missing.txt"]), at: 1)
        // r1은 실패했고 PostToolUseFailure 훅이 등록돼 있지 않아 끝 이벤트가 없음 → 다음 응답의 도구
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]), at: 6)
        #expect(state.lead(of: session)?.runningTools.map(\.id) == ["b1"])
        let ended = apply(&state, hook.tool("PostToolUse", "Bash", id: "b1", input: [:]), at: 7)
        guard case .toolEnded(let lead, _, _) = ended.first else { Issue.record("\(ended)"); return }
        #expect(lead.activity == .thinking)
        #expect(lead.runningTools.isEmpty)
    }

    @Test("같은 묶음의 병렬 도구는 지금처럼: 하나가 끝나면 남은 도구로 돌아간다")
    func parallelToolsAreKept() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/x/a.txt"]), at: 1)
        _ = apply(&state, hook.tool("PreToolUse", "Grep", id: "g1", input: ["pattern": "x"]), at: 1.3)
        _ = apply(&state, hook.tool("PreToolUse", "Glob", id: "g2", input: ["pattern": "*.md"]), at: 1.9)
        #expect(state.lead(of: session)?.runningTools.count == 3)
        _ = apply(&state, hook.tool("PostToolUse", "Glob", id: "g2", input: [:]), at: 4)
        _ = apply(&state, hook.tool("PostToolUse", "Grep", id: "g1", input: [:]), at: 6)
        if case .working(let call) = state.lead(of: session)?.activity { #expect(call.id == "r1") } else { Issue.record("남은 도구로 돌아가지 않음") }
    }

    @Test("백그라운드 위임은 묶음이 바뀌어도 남는다")
    func backgroundMemberSurvivesNewBatch() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "Explore", "run_in_background": true]), at: 1)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]), at: 9)
        #expect(state.agents.values.filter { $0.role == .member }.count == 1)
    }

    @Test("버린 도구와 닫힌 턴의 기록은 열린 채 남지 않는다")
    func journalClosesDroppedTools() {
        var h = EngineHarness()
        h.send(hook.make("UserPromptSubmit"), at: 0)
        h.send(hook.tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/x/missing.txt"]), at: 1)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]), at: 6)
        let lead = AgentID("lead-1")
        #expect(h.engine.journal.entries(of: lead).map(\.state) == [.closed, .running])
        h.send(hook.make("Notification", idle), at: 80)
        #expect(h.engine.journal.entries(of: lead).allSatisfy { !$0.state.isOpen })
    }

    // MARK: - 서브의 승인 요청

    @Test("서브의 승인 요청 알림(agent_id 없음)은 도구를 돌리던 서브에게 붙고, 그 도구가 끝나면 풀린다")
    func subagentPermissionNotification() throws {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 1)
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]), at: 1.1)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"], agent: worker), at: 2)
        let asked = apply(&state, hook.make("Notification", permission), at: 8)
        guard case .permissionAsked(let asker, let call) = try #require(asked.first) else { Issue.record("\(asked)"); return }
        #expect(asker.role == .member)
        #expect(call?.subject == "npm test")
        #expect(state.lead(of: session)?.activity == .delegating)

        _ = apply(&state, hook.tool("PostToolUse", "Bash", id: "b1", input: [:], agent: worker), at: 30)
        #expect(state.member(subagentID: "g1", in: session)?.activity == .thinking)
        #expect(state.lead(of: session)?.activity == .delegating)
    }

    @Test("서브의 PermissionRequest 뒤에 오는 알림은 메인을 승인 대기로 만들지 않는다")
    func subagentPermissionRequestThenNotification() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 1)
        _ = apply(&state, hook.make("SubagentStart", ["agent_id": "g1", "agent_type": "general-purpose"]), at: 1.1)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"], agent: worker), at: 2)
        _ = apply(&state, hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"], agent: worker), at: 2.1)
        #expect(apply(&state, hook.make("Notification", permission), at: 8.1).isEmpty)
        #expect(state.lead(of: session)?.activity == .delegating)
    }

    @Test("도는 도구가 없을 때의 승인 알림은 지금처럼 메인에게 (무엇을 기다리는지 모름)")
    func permissionNotificationWithoutTools() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.make("Notification", permission), at: 8)
        #expect(state.lead(of: session)?.activity == .waitingForPermission(nil))
    }

    // MARK: - 끝난 세션

    @Test("SessionEnd 뒤 늦게 온 훅은 새 메인을 만들지 않는다. 다시 시작하면(SessionStart·새 요청) 출근한다")
    func lateHookAfterSessionEnd() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"), at: 0)
        _ = apply(&state, hook.make("SessionEnd", ["reason": "exit"]), at: 10)
        #expect(apply(&state, hook.make("Stop"), at: 10.4).isEmpty)
        #expect(apply(&state, hook.make("SubagentStop", ["agent_id": "g1", "agent_type": "general-purpose"]), at: 11).isEmpty)
        #expect(apply(&state, hook.make("Notification", idle), at: 12).isEmpty)
        #expect(state.agents.isEmpty && state.teams.isEmpty)
        // 같은 id로 다시 시작(resume)
        #expect(names(apply(&state, hook.make("SessionStart", ["source": "resume"]), at: 13)) == ["teamOpened", "arrived"])
        _ = apply(&state, hook.make("SessionEnd"), at: 20)
        #expect(names(apply(&state, hook.make("UserPromptSubmit"), at: 21)).contains("arrived"))
    }

    @Test("끝난 세션은 잠깐만, 정해진 수만 기억한다")
    func endedSessionsAreBounded() {
        var state = OfficeState()
        for index in 0..<(OfficeState.endedSessionCapacity + 40) {
            _ = apply(&state, Hook(session: "old-\(index)").make("SessionEnd"), at: Double(index) * 0.01)
        }
        #expect(state.endedSessionCount == OfficeState.endedSessionCapacity)
        // 기억하는 시간이 지나면 늦게 온 훅도 지금처럼 메인을 만든다 (앱을 세션 중간에 켠 것과 같음)
        var later = OfficeState()
        _ = apply(&later, hook.make("SessionEnd"), at: 0)
        #expect(!apply(&later, hook.tool("PreToolUse", "Read", id: "r", input: [:]), at: OfficeState.endedSessionMemory + 1).isEmpty)
    }

    // MARK: - 시간 경과

    @Test("출근 중은 잠깐 뒤 쉬는 중(세션)·생각 중(서브)으로 넘어간다")
    func arrivingSettles() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 100)
        state.settleArrivals(at: at(5))
        #expect(state.lead(of: session)?.activity == .delegating)
        var fresh = OfficeState()
        _ = apply(&fresh, hook.make("SessionStart"), at: 0)
        fresh.settleArrivals(at: at(OfficeState.arrivalGrace - 1))
        #expect(fresh.lead(of: session)?.activity == .arriving)
        fresh.settleArrivals(at: at(OfficeState.arrivalGrace))
        #expect(fresh.lead(of: session)?.activity == .idle)
        #expect(fresh.lead(of: session)?.activitySince == at(0))  // 쉰 시간은 출근한 때부터

        let member = state.agents.values.first { $0.role == .member }
        #expect(member?.activity == .arriving)
        state.settleArrivals(at: at(100 + OfficeState.arrivalGrace))
        #expect(state.agents.values.first { $0.role == .member }?.activity == .thinking)
    }

    @Test("tick이 상태를 바꿀 때만 tickChanges가 오른다: 연출만 흘러갈 때(쉬러 가기)는 그대로 (앱이 목록·현황 줄을 다시 만들지 정함)")
    func tickChangesOnlyWhenStateChanges() {
        var h = EngineHarness()
        h.advance(to: 1)
        #expect(h.engine.tickChanges == 0)
        h.send(hook.make("SessionStart"), at: 1)
        h.advance(to: 1 + OfficeState.arrivalGrace - 0.5)
        #expect(h.engine.tickChanges == 0)
        #expect(h.engine.state.lead(of: session)?.activity == .arriving)
        // 출근 중 → 쉬는 중: 지시는 없지만 상태가 바뀜
        h.advance(to: 1 + OfficeState.arrivalGrace + 0.5)
        #expect(h.engine.state.lead(of: session)?.activity == .idle)
        #expect(h.engine.tickChanges == 1)
        // 1분 뒤 소파로 쉬러 감: 연출 지시는 나오지만 상태는 그대로
        let before = h.log.count
        h.advance(to: 200)
        #expect(h.log.count > before)
        #expect(h.engine.tickChanges == 1)
        // 훅으로 바뀐 것은 세지 않음 (앱이 훅마다 맞춤)
        h.send(hook.make("UserPromptSubmit", ["prompt": "해 줘"]), at: 201)
        #expect(h.engine.tickChanges == 1)
        // 1시간 침묵으로 턴을 닫음
        h.advance(to: 201 + OfficeState.silenceLimit + 1)
        #expect(h.engine.state.lead(of: session)?.isResting == true)
        #expect(h.engine.tickChanges == 2)
    }

    @Test("아주 오래 조용한 서브는 퇴근한다 (SubagentStop을 못 받은 백그라운드 서브). 승인을 기다리는 세션은 그대로")
    func silentMemberLeaves() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "Explore", "run_in_background": true]), at: 1)
        _ = apply(&state, hook.tool("PreToolUse", "Grep", id: "g", input: ["pattern": "x"], agent: (id: "e1", type: "Explore")), at: 2)
        _ = apply(&state, hook.make("Stop"), at: 3)
        #expect(state.expireSilence(at: at(OfficeState.silenceLimit)).isEmpty)
        let beats = state.expireSilence(at: at(2 + OfficeState.silenceLimit))
        #expect(names(beats).first == "left")
        #expect(state.agents.values.filter { $0.role == .member }.isEmpty)

        var waiting = OfficeState()
        _ = apply(&waiting, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "Explore", "run_in_background": true]), at: 1)
        _ = apply(&waiting, hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm x"], agent: (id: "e1", type: "Explore")), at: 2)
        #expect(waiting.expireSilence(at: at(10 * OfficeState.silenceLimit)).isEmpty)
    }

    @Test("아주 오래 훅이 없는 바쁜 세션은 턴이 끝난 것으로 본다 (kill -9, idle_prompt도 못 받은 중단)")
    func silentBusySessionEndsTurn() {
        var state = OfficeState()
        _ = apply(&state, hook.make("UserPromptSubmit"), at: 0)
        _ = apply(&state, hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "sleep 99"]), at: 2)
        #expect(state.expireSilence(at: at(OfficeState.silenceLimit)).isEmpty)
        #expect(names(state.expireSilence(at: at(2 + OfficeState.silenceLimit))) == ["turnAbandoned"])
        #expect(state.lead(of: session)?.activity == .idle)
        #expect(state.agents.count == 1)  // 세션은 퇴근시키지 않습니다 (§5.2)
        #expect(state.expireSilence(at: at(9 * OfficeState.silenceLimit)).isEmpty)
    }
}
