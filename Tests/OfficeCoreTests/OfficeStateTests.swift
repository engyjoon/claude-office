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
