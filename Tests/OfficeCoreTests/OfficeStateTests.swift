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

    @Test("세션 시작: 팀을 열고 팀장이 출근한다")
    func sessionStart() throws {
        var state = OfficeState()
        let beats = apply(&state, hook.make("SessionStart"))
        #expect(beats.count == 2)
        guard case .teamOpened(let team) = beats[0], case .arrived(let lead) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(team.name == "a-sdn-portal")
        #expect(team.island == 0)
        #expect(lead.role == .lead)
        #expect(lead.seat == 0)
        #expect(lead.profile.kind == .lead)
        // 같은 세션의 SessionStart(resume)가 또 와도 새로 출근하지 않습니다
        #expect(apply(&state, hook.make("SessionStart", ["source": "resume"])).isEmpty)
    }

    @Test("앱을 세션 중간에 켜도 첫 이벤트에서 팀장을 만든다")
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

    @Test("같은 폴더의 두 번째 세션은 같은 팀의 공동 팀장이 된다")
    func coLead() {
        var state = OfficeState()
        _ = apply(&state, Hook(session: "s1").make("SessionStart"))
        let beats = apply(&state, Hook(session: "s2").make("SessionStart"))
        #expect(state.teams.count == 1)
        guard case .arrived(let second) = beats.first else { Issue.record("\(beats)"); return }
        #expect(second.profile.displayName == "팀장 2")
        #expect(second.seat != 0)
        _ = apply(&state, Hook(session: "s3", cwd: "/Users/demo/work/other").make("SessionStart"))
        #expect(state.sortedTeams.map(\.island) == [0, 1])
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

    @Test("위임 정보 없이 서브에이전트 훅이 오면 팀원이 나타난다")
    func memberWithoutDelegation() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        let beats = apply(&state, hook.tool("PreToolUse", "Read", id: "r", input: ["file_path": "/a"], agent: (id: "zz", type: "researcher")))
        #expect(beats.count == 2)
        guard case .memberAppeared(let member) = beats[0], case .working(let actor, _) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(member.id == actor.id)
        #expect(member.profile.displayName == "researcher")
    }

    @Test("고정 직원은 지정석을 갖고, 퇴근 후 다시 와도 같은 자리에 앉는다")
    func reservedSeat() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        let first = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "general-purpose"]))
        guard case .delegated(_, let reviewer1) = first.first else { Issue.record("\(first)"); return }
        _ = apply(&state, hook.tool("PostToolUse", "Agent", id: "a1", input: [:]))
        _ = apply(&state, hook.tool("PostToolUse", "Agent", id: "a2", input: [:]))
        // 임시 직원이 먼저 와도 code-reviewer의 지정석에는 앉지 않습니다
        let temp = apply(&state, hook.tool("PreToolUse", "Agent", id: "a3", input: ["subagent_type": "general-purpose"]))
        let again = apply(&state, hook.tool("PreToolUse", "Agent", id: "a4", input: ["subagent_type": "code-reviewer"]))
        guard case .delegated(_, let tempMember) = temp.first, case .delegated(_, let reviewer2) = again.first else { Issue.record("위임 없음"); return }
        #expect(reviewer2.seat == reviewer1.seat)
        #expect(tempMember.seat != reviewer1.seat)
        #expect(reviewer2.profile.appearance == reviewer1.profile.appearance)
    }

    @Test("자리가 모자라면 좌석이 늘어난다")
    func seatsGrow() {
        var state = OfficeState()
        for index in 0..<5 {
            _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a\(index)", input: ["subagent_type": "general-purpose"]))
        }
        let team = state.sortedTeams[0]
        #expect(team.seatCount == 6)
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

    @Test("세션 종료: 팀원 먼저, 팀장 마지막으로 퇴근한다")
    func sessionEnd() {
        var state = OfficeState()
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        let beats = apply(&state, hook.make("SessionEnd", ["reason": "exit"]))
        #expect(beats.count == 2)
        guard case .left(let first) = beats[0], case .left(let last) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(first.role == .member)
        #expect(last.role == .lead)
        #expect(state.agents.isEmpty)
        #expect(state.teams.count == 1)  // 책상 섬과 명패는 남습니다
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
        guard case .turnEnded = beats.last else { Issue.record("\(beats)"); return }
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
