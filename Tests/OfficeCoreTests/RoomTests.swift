import Foundation
import Testing

@testable import OfficeCore

/// M4.5a: 방(메인 세션 단위), 팀장·파트장 직함, 승진, 방 닫기 (설계서 §5.1)
@Suite("방과 직함")
struct RoomTests {
    static let folder = "/Users/demo/work/claude-office"

    func apply(
        _ state: inout OfficeState, session: String, _ name: String = "SessionStart", cwd: String = folder,
        hint: SessionHint? = nil, _ extra: JSONObject = JSONObject(), at seconds: Double = 0
    ) -> [Beat] {
        let payload = Hook(session: session, cwd: cwd).make(name, extra)
        guard var event = HookParser.parse(payload, receivedAt: Fixture.epoch.addingTimeInterval(seconds)) else { return [] }
        event.hint = hint
        return state.apply(event)
    }

    func end(_ state: inout OfficeState, _ session: String) -> [Beat] {
        apply(&state, session: session, "SessionEnd", ["reason": "other"])
    }

    func name(_ state: OfficeState, _ session: String) -> String? {
        state.lead(of: SessionID(session))?.displayName
    }

    func names(_ state: OfficeState) -> [String] {
        state.agents.values.filter { $0.role == .lead }.sorted { $0.serial < $1.serial }.map(\.displayName)
    }

    // MARK: - 폴더 규칙 (데스크톱 정보가 없을 때)

    @Test("같은 폴더에 먼저 온 세션이 팀장, 나중 세션은 파트장. 둘째 파트장이 오면 번호가 붙는다")
    func fallbackTitles() throws {
        var state = OfficeState()
        _ = apply(&state, session: "s1")
        let second = apply(&state, session: "s2")
        #expect(state.teams.count == 1)
        guard case .arrived(let partLead) = second.last else { Issue.record("\(second)"); return }
        #expect(partLead.displayName == "파트장")
        #expect(partLead.title == .partLead(nil))
        #expect(partLead.part == 1)
        #expect(partLead.seat == Seat(part: 1, desk: 0))
        #expect(name(state, "s1") == "팀장")
        #expect(state.lead(of: SessionID("s1"))?.seat == .office)

        let third = apply(&state, session: "s3")
        // 첫 파트장은 "파트장" → "파트장1"로 바뀌고, 새 사람은 "파트장2"
        #expect(third.count == 2)
        guard case .retitled(let renamed) = third[0], case .arrived(let newcomer) = third[1] else { Issue.record("\(third)"); return }
        #expect(renamed.displayName == "파트장1")
        #expect(renamed.seat == partLead.seat)
        #expect(newcomer.displayName == "파트장2")
        #expect(state.parts(in: TeamID(Self.folder)).map(\.number) == [0, 1, 2])

        // 다른 폴더는 다른 방
        _ = apply(&state, session: "s4", cwd: "/Users/demo/work/other")
        #expect(state.sortedTeams.map(\.island) == [0, 1])
        #expect(name(state, "s4") == "팀장")
    }

    @Test("워크트리 세션은 원래 폴더의 방에 합쳐지고 방 이름도 원래 폴더")
    func worktreeMerge() {
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter") == "/w/proj")
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter/") == "/w/proj")
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter/sub") == "/w/proj/sub")
        #expect(Team.folder(for: "/w/proj/") == "/w/proj")
        #expect(Team.folder(for: nil) == "(알 수 없는 프로젝트)")

        var state = OfficeState()
        _ = apply(&state, session: "main", cwd: "/w/proj")
        let beats = apply(&state, session: "wt", cwd: "/w/proj/.claude/worktrees/happy-otter")
        #expect(state.teams.count == 1)
        #expect(state.teams.values.first?.name == "proj")
        guard case .arrived(let agent) = beats.last else { Issue.record("\(beats)"); return }
        #expect(agent.displayName == "파트장")
        #expect(agent.teamID == TeamID("/w/proj"))

        // 워크트리 세션이 먼저 와도 방 이름은 원래 폴더
        var other = OfficeState()
        _ = apply(&other, session: "wt", cwd: "/w/proj/.claude/worktrees/x")
        #expect(other.teams.values.first?.name == "proj")
    }

    // MARK: - 데스크톱 정보 (힌트)

    @Test("힌트의 부모가 사무실에 있으면 폴더가 달라도 부모의 방에 파트장으로 들어간다")
    func hintParentRoom() {
        var state = OfficeState()
        _ = apply(&state, session: "main", hint: SessionHint(hostSession: "local_m", title: "메인 작업"))
        let child = SessionHint(hostSession: "local_c", ancestors: [SessionID("main")], rootCwd: Self.folder, title: "검토")
        _ = apply(&state, session: "child", cwd: "/somewhere/else", hint: child)
        #expect(state.teams.count == 1)
        #expect(name(state, "child") == "파트장")
        #expect(state.parts[SessionID("child")]?.title == "검토")
        #expect(state.parts[SessionID("main")]?.title == "메인 작업")

        // 손자 세션도 가까운 조상의 방
        let grand = SessionHint(ancestors: [SessionID("child"), SessionID("main")], rootCwd: Self.folder)
        _ = apply(&state, session: "grand", cwd: "/third", hint: grand)
        #expect(state.teams.count == 1)
        #expect(names(state) == ["팀장", "파트장1", "파트장2"])
    }

    @Test("부모가 아직 없으면 최상위 세션 폴더의 방")
    func hintRootCwd() {
        var state = OfficeState()
        let child = SessionHint(ancestors: [SessionID("main")], rootCwd: "/w/root-project")
        _ = apply(&state, session: "child", cwd: "/w/elsewhere", hint: child)
        #expect(state.teams.keys.map(\.raw) == ["/w/root-project"])
        // 부모가 없으니 일단 팀장
        #expect(name(state, "child") == "팀장")
    }

    @Test("나중에 메인 세션이 나타나면 팀장 자리를 넘겨받고, 먼저 온 하위 세션은 파트장이 된다")
    func lateMainTakesOver() throws {
        var state = OfficeState()
        _ = apply(&state, session: "child", hint: SessionHint(ancestors: [SessionID("main")], rootCwd: Self.folder))
        let childSeat = try #require(state.lead(of: SessionID("child"))).seat
        #expect(childSeat == .office)

        let beats = apply(&state, session: "main", hint: SessionHint(rootCwd: Self.folder))
        guard case .retitled(let demoted) = beats.first, case .arrived(let main) = beats.last else { Issue.record("\(beats)"); return }
        #expect(demoted.displayName == "파트장")
        #expect(demoted.seat == Seat(part: 1, desk: 0))
        #expect(main.displayName == "팀장")
        #expect(main.seat == .office)
        #expect(state.agents.values.filter { $0.seat == .office }.count == 1)
    }

    @Test("힌트가 늦게 와도 (정보 파일이 나중에 생김) 메인 세션에게 팀장 자리를 돌려준다")
    func lateHintReconciles() {
        var state = OfficeState()
        _ = apply(&state, session: "child")  // 힌트 없음 → 폴더 규칙으로 팀장
        _ = apply(&state, session: "main")  // 폴더 규칙으로 파트장
        #expect(name(state, "child") == "팀장")
        #expect(name(state, "main") == "파트장")

        let beats = apply(&state, session: "child", "UserPromptSubmit", hint: SessionHint(ancestors: [SessionID("main")], rootCwd: Self.folder))
        #expect(name(state, "main") == "팀장")
        #expect(name(state, "child") == "파트장")
        #expect(state.lead(of: SessionID("main"))?.seat == .office)
        #expect(beats.contains { if case .promoted(let agent) = $0 { agent.session == SessionID("main") } else { false } })
        #expect(beats.contains { if case .retitled(let agent) = $0 { agent.session == SessionID("child") } else { false } })
        // 같은 힌트가 다시 와도 아무 일 없음
        let again = apply(&state, session: "child", "UserPromptSubmit", hint: SessionHint(ancestors: [SessionID("main")], rootCwd: Self.folder))
        #expect(!again.contains { if case .retitled = $0 { true } else { false } })
    }

    // MARK: - 번호, 승진, 이름 중복

    @Test("파트장 번호는 출근 때 정해 고정하고, 빈 번호는 다시 쓴다")
    func partNumberReuse() {
        var state = OfficeState()
        for session in ["s1", "s2", "s3"] { _ = apply(&state, session: session) }
        #expect(names(state) == ["팀장", "파트장1", "파트장2"])

        let left = end(&state, "s2")
        #expect(name(state, "s3") == "파트장")  // 혼자 남으면 번호 없이
        #expect(state.parts[SessionID("s3")]?.number == 2)  // 번호 자체는 그대로
        #expect(left.contains { if case .retitled(let agent) = $0 { agent.displayName == "파트장" } else { false } })

        _ = apply(&state, session: "s4")
        #expect(name(state, "s4") == "파트장1")  // 빈 1번을 다시 씀
        #expect(name(state, "s3") == "파트장2")
    }

    @Test("팀장이 먼저 퇴근하면 가장 먼저 온 파트장이 팀장석으로 승진한다")
    func promotion() throws {
        var state = OfficeState()
        for session in ["s1", "s2", "s3"] { _ = apply(&state, session: session) }
        let s2Seat = try #require(state.lead(of: SessionID("s2"))).seat

        let beats = end(&state, "s1")
        guard case .left = beats.first else { Issue.record("\(beats)"); return }
        guard case .promoted(let promoted) = beats[1] else { Issue.record("\(beats)"); return }
        #expect(promoted.session == SessionID("s2"))
        #expect(promoted.displayName == "팀장")
        #expect(promoted.seat == .office)
        #expect(promoted.part == 0)
        #expect(s2Seat == Seat(part: 1, desk: 0))
        #expect(name(state, "s3") == "파트장")
        #expect(state.teams.count == 1)  // 방은 남은 사람이 있는 동안 유지
    }

    @Test("팀장이 퇴근한 뒤 온 세션도 이름이 겹치지 않는다 (예전 버그: '팀장 2'가 둘)")
    func noDuplicateNames() {
        var state = OfficeState()
        for session in ["s1", "s2", "s3"] { _ = apply(&state, session: session) }
        _ = end(&state, "s1")
        _ = apply(&state, session: "s4")
        _ = apply(&state, session: "s5")
        _ = end(&state, "s3")
        _ = apply(&state, session: "s6")
        let all = names(state)
        #expect(Set(all).count == all.count, "\(all)")
        #expect(all.filter { $0 == "팀장" }.count == 1)
        #expect(state.agents.values.filter { $0.seat == .office }.count == 1)
        let seats = state.agents.values.map(\.seat)
        #expect(Set(seats).count == seats.count)
    }

    @Test("같은 종류 고정 직원의 번호도 빈 번호를 다시 쓴다")
    func memberNames() {
        var state = OfficeState()
        _ = apply(&state, session: "s1")
        func delegate(_ id: String) {
            _ = apply(&state, session: "s1", "PreToolUse", JSONObject([
                ("tool_name", .string("Agent")), ("tool_use_id", .string(id)),
                ("tool_input", .object(JSONObject([("description", .string("리뷰")), ("subagent_type", .string("code-reviewer"))]))),
            ]))
        }
        delegate("t1")
        delegate("t2")
        #expect(state.agents.values.filter { $0.role == .member }.map(\.displayName).sorted() == ["code-reviewer", "code-reviewer (2)"])
        _ = apply(&state, session: "s1", "PostToolUse", JSONObject([("tool_name", .string("Agent")), ("tool_use_id", .string("t1")), ("tool_input", .object(JSONObject()))]))
        delegate("t3")
        #expect(state.agents.values.filter { $0.role == .member }.map(\.displayName).sorted() == ["code-reviewer", "code-reviewer (2)"])
    }

    // MARK: - 방 닫기

    @Test("사람이 모두 떠난 방은 닫히고, 다음 방이 그 섬을 다시 쓴다")
    func emptyRoomCloses() {
        var state = OfficeState()
        _ = apply(&state, session: "a", cwd: "/w/a")
        _ = apply(&state, session: "b", cwd: "/w/b")
        let beats = end(&state, "a")
        #expect(beats.contains { if case .teamClosed(let team) = $0 { team.id == TeamID("/w/a") } else { false } })
        #expect(state.teams.keys.map(\.raw) == ["/w/b"])
        #expect(state.parts[SessionID("a")] == nil)

        _ = apply(&state, session: "c", cwd: "/w/c")
        #expect(state.teams[TeamID("/w/c")]?.island == 0)
        #expect(state.teams[TeamID("/w/b")]?.island == 1)

        // 워크트리 세션 여러 개가 오가도 섬이 쌓이지 않습니다
        for index in 0..<5 {
            _ = apply(&state, session: "w\(index)", cwd: "/w/x\(index)/.claude/worktrees/t\(index)")
            _ = end(&state, "w\(index)")
        }
        #expect(state.teams.count == 2)
        #expect(Set(state.teams.values.map(\.island)) == [0, 1])
    }

    // MARK: - 파트원

    @Test("파트원은 자기를 부른 세션의 파트에 속하고, 승진하면 파트 번호도 따라 바뀐다")
    func membersFollowPart() throws {
        var state = OfficeState()
        _ = apply(&state, session: "s1")
        _ = apply(&state, session: "s2")
        _ = apply(&state, session: "s2", "PreToolUse", JSONObject([
            ("tool_name", .string("Agent")), ("tool_use_id", .string("t1")),
            ("tool_input", .object(JSONObject([("description", .string("조사")), ("subagent_type", .string("Explore"))]))),
        ]))
        let member = try #require(state.agents.values.first { $0.role == .member })
        #expect(member.part == 1)
        #expect(member.title == .member)

        let roster = Roster.make(from: state, privacy: .detailed)
        #expect(roster.teams.first?.rows.map(\.name) == ["팀장", "파트장", "Explore"])
        #expect(roster.teams.first?.rows.last?.partLead == "파트장")

        _ = end(&state, "s1")
        #expect(state.agents[member.id]?.part == 0)
        #expect(Roster.make(from: state, privacy: .detailed).teams.first?.rows.last?.partLead == "팀장")
    }

    @Test("목록: 팀장과 그 파트원, 그다음 파트장 순서. 세션 제목은 상세 표시에서만")
    func rosterOrder() {
        var state = OfficeState()
        func delegate(_ session: String, _ id: String, _ type: String) {
            _ = apply(&state, session: session, "PreToolUse", JSONObject([
                ("tool_name", .string("Agent")), ("tool_use_id", .string(id)),
                ("tool_input", .object(JSONObject([("description", .string("일")), ("subagent_type", .string(type))]))),
            ]))
        }
        _ = apply(&state, session: "s1", hint: SessionHint(title: "메인"))
        _ = apply(&state, session: "s2")
        _ = apply(&state, session: "s3")
        delegate("s3", "t3", "Plan")
        delegate("s1", "t1", "Explore")
        delegate("s2", "t2", "code-reviewer")
        let rows = Roster.make(from: state, privacy: .detailed).teams[0].rows
        #expect(rows.map(\.name) == ["팀장", "Explore", "파트장1", "code-reviewer", "파트장2", "Plan"])
        #expect(rows[0].sessionTitle == "메인")
        #expect(Roster.make(from: state, privacy: .summary).teams[0].rows[0].sessionTitle == nil)
    }
}
