import Foundation
import Testing

@testable import OfficeCore

/// M5(1): 메인·서브 판별, 번호, 행과 책상 (설계서 §5.1)
@Suite("메인과 서브")
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

    func child(of ancestors: String...) -> SessionHint {
        SessionHint(hostSession: "local_x", ancestors: ancestors.map(SessionID.init))
    }

    func end(_ state: inout OfficeState, _ session: String) -> [Beat] {
        apply(&state, session: session, "SessionEnd", ["reason": "other"])
    }

    @discardableResult
    func delegate(_ state: inout OfficeState, _ session: String, _ id: String, _ type: String = "Explore") -> [Beat] {
        apply(&state, session: session, "PreToolUse", JSONObject([
            ("tool_name", .string("Agent")), ("tool_use_id", .string(id)),
            ("tool_input", .object(JSONObject([("description", .string("일")), ("subagent_type", .string(type))]))),
        ]))
    }

    @discardableResult
    func finish(_ state: inout OfficeState, _ session: String, _ id: String) -> [Beat] {
        apply(&state, session: session, "PostToolUse", JSONObject([("tool_name", .string("Agent")), ("tool_use_id", .string(id)), ("tool_input", .object(JSONObject()))]))
    }

    func name(_ state: OfficeState, _ session: String) -> String? {
        state.lead(of: SessionID(session))?.displayName
    }

    /// 행마다 책상 순서대로 이름
    func rows(_ state: OfficeState) -> [[String]] {
        state.sortedTeams.map { state.agents(in: $0.id).map(\.displayName) }
    }

    func desks(_ state: OfficeState, _ team: TeamID) -> [Int] {
        state.agents(in: team).map(\.seat.desk)
    }

    // MARK: - 쉬고 있는 메인 불러오기 (M5(4) 화면 확인)

    @Test("서브 세션이 먼저 와도, 데스크톱 앱에 열려 있는 메인을 먼저 입력 대기로 앉히고 서브로 들어간다")
    func summonsOpenRoot() throws {
        var state = OfficeState()
        let hint = SessionHint(
            hostSession: "local_side", ancestors: [SessionID("main")], rootCwd: Self.folder, title: "M5(4) 검토",
            rootHostSession: "local_main", rootTitle: "클로드 오피스 개발", rootIsOpen: true)
        _ = apply(&state, session: "side", hint: hint)
        #expect(rows(state) == [["메인", "서브"]])
        let main = try #require(state.lead(of: SessionID("main")))
        #expect(main.isMain && main.activity == .waitingForInput)
        #expect(state.parts[SessionID("main")]?.title == "클로드 오피스 개발")
        #expect(state.parts[SessionID("main")]?.hostSession == "local_main")
        // 나중에 메인이 일을 시작하면 같은 사람
        _ = apply(&state, session: "main", "UserPromptSubmit", JSONObject([("prompt", .string("x"))]), at: 5)
        #expect(state.lead(of: SessionID("main"))?.id == main.id)
        #expect(rows(state) == [["메인", "서브"]])
    }

    @Test("서브가 이미 메인 자리에 있었으면 다음 훅 때 열린 메인이 메인 자리를 넘겨받는다. 보관한 메인은 불러오지 않는다")
    func summonsRootLater() throws {
        var state = OfficeState()
        _ = apply(&state, session: "side", hint: child(of: "main"))
        #expect(rows(state) == [["메인"]])
        let open = SessionHint(hostSession: "local_side", ancestors: [SessionID("main")], rootCwd: Self.folder, rootIsOpen: true)
        _ = apply(&state, session: "side", "UserPromptSubmit", hint: open, JSONObject([("prompt", .string("x"))]), at: 2)
        #expect(rows(state) == [["메인", "서브"]])
        #expect(state.lead(of: SessionID("main"))?.isMain == true)

        var closed = OfficeState()
        _ = apply(&closed, session: "side", hint: SessionHint(hostSession: "local_side", ancestors: [SessionID("main")], rootIsOpen: false))
        #expect(rows(closed) == [["메인"]])
        #expect(closed.lead(of: SessionID("main")) == nil)
    }

    // MARK: - 메인 판별

    @Test("직접 연 세션은 각자 메인 (같은 폴더·터미널 세션도). 메인이 둘이 되면 '메인' → '메인1', '메인2'")
    func directSessionsAreMains() throws {
        var state = OfficeState()
        _ = apply(&state, session: "s1")
        #expect(name(state, "s1") == "메인")
        #expect(state.lead(of: SessionID("s1"))?.seat == .main)
        let second = apply(&state, session: "s2")
        #expect(state.teams.count == 2)
        #expect(name(state, "s1") == "메인1")
        #expect(name(state, "s2") == "메인2")
        // 먼저 온 메인의 표시가 바뀌었다고 알립니다
        #expect(second.contains { if case .retitled(let agent) = $0 { agent.session == SessionID("s1") } else { false } })
        // 터미널 세션(데스크톱 정보 없음)도 메인, 다른 폴더도 메인
        _ = apply(&state, session: "cli", cwd: "/Users/demo/work/other")
        #expect(name(state, "cli") == "메인3")
        #expect(state.sortedTeams.map(\.name) == ["claude-office", "claude-office", "other"])
        #expect(state.agents.values.allSatisfy { $0.isMain && $0.seat == .main })
    }

    @Test("메인이 띄운 세션과 모든 서브에이전트는 그 메인의 서브. 서브 번호는 메인마다 따로")
    func subsBelongToMain() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m1")
        _ = apply(&state, session: "m2")
        // 메인1이 띄운 세션 (손자 세션도)
        _ = apply(&state, session: "c1", hint: child(of: "m1"))
        #expect(name(state, "c1") == "서브")
        _ = apply(&state, session: "g1", hint: child(of: "c1", "m1"))
        #expect(name(state, "c1") == "서브1")
        #expect(name(state, "g1") == "서브2")
        // 메인과 서브 세션이 부른 서브에이전트(기본·직접 만든 에이전트)도 같은 번호 줄
        delegate(&state, "m1", "t1", "code-reviewer")
        delegate(&state, "c1", "t2", "Explore")
        #expect(rows(state)[0] == ["메인1", "서브1", "서브2", "서브3", "서브4"])
        // 메인2의 서브는 따로 번호: 하나면 "서브"
        delegate(&state, "m2", "t3", "Plan")
        #expect(rows(state)[1] == ["메인2", "서브"])
        // 에이전트 종류는 이름에 쓰지 않습니다 (신원 카드용)
        let reviewer = try #require(state.agents.values.first { $0.profile.agentType == "code-reviewer" })
        #expect(reviewer.displayName == "서브3")
        #expect(reviewer.teamID == state.lead(of: SessionID("m1"))?.teamID)
        // ★(메인)은 직접 연 세션만
        #expect(Set(state.agents.values.filter(\.isMain).map(\.session)) == [SessionID("m1"), SessionID("m2")])
    }

    @Test("메인 번호는 출근 순서로 고정, 빈 번호는 다시 쓰고, 새 메인의 행은 맨 아래")
    func mainNumberReuse() {
        var state = OfficeState()
        _ = apply(&state, session: "a")
        _ = apply(&state, session: "b")
        _ = apply(&state, session: "c")
        _ = end(&state, "a")
        #expect(name(state, "b") == "메인2")
        #expect(name(state, "c") == "메인3")
        _ = apply(&state, session: "d")
        #expect(name(state, "d") == "메인1")
        // 행 순서는 메인이 온 순서 (새 메인은 다음 행)
        #expect(rows(state).map { $0[0] } == ["메인2", "메인3", "메인1"])
        _ = end(&state, "b")
        _ = end(&state, "c")
        #expect(name(state, "d") == "메인")
    }

    @Test("서브 번호는 책상 번호: 가운데가 빠지면 옮겨 앉는 끝 사람이 그 번호를 받고, 혼자 남으면 다시 '서브' (M6(14))")
    func subNumbers() {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        delegate(&state, "m", "t1")
        delegate(&state, "m", "t2")
        delegate(&state, "m", "t3")
        finish(&state, "m", "t1")  // t3이 1번 책상으로 옮겨 서브1
        delegate(&state, "m", "t4")
        let numbers = state.agents.values.filter { !$0.isMain }.sorted { $0.serial < $1.serial }.map(\.displayName)
        #expect(numbers == ["서브2", "서브1", "서브3"])
        #expect(rows(state) == [["메인", "서브1", "서브2", "서브3"]])
        finish(&state, "m", "t2")
        finish(&state, "m", "t3")
        #expect(rows(state) == [["메인", "서브"]])
    }

    @Test("서브 4명 중 서브1·서브3이 빠지면 남은 둘은 왼쪽부터 서브1·서브2, 이름이 바뀌는 사람은 옮겨 앉는 사람뿐 (M6(14))")
    func renumbersByDesk() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        let team = try #require(state.lead(of: SessionID("m"))?.teamID)
        for index in 1...4 { delegate(&state, "m", "t\(index)") }
        let ids = state.agents(in: team).dropFirst().map(\.id)  // 서브1~4
        #expect(rows(state) == [["메인", "서브1", "서브2", "서브3", "서브4"]])

        // 서브1이 빠짐 → 서브4가 1번 책상으로 옮기며 서브1이 됨. 비트는 옮긴 사람의 reseated 하나 (새 직함을 담음)
        let beats = finish(&state, "m", "t1")
        let changed = beats.compactMap { beat -> Agent? in
            switch beat {
            case .reseated(let agent), .retitled(let agent): agent
            default: nil
            }
        }
        #expect(changed.map(\.id) == [ids[3]])
        #expect(changed.first?.displayName == "서브1")
        #expect(changed.first?.seat == Seat(desk: 1))
        #expect(beats.contains { if case .reseated = $0 { true } else { false } })
        #expect(state.agents[ids[1]]?.displayName == "서브2")
        #expect(state.agents[ids[2]]?.displayName == "서브3")

        // 서브3(끝 책상)이 빠짐 → 아무도 옮기지 않고 이름도 그대로
        let tail = finish(&state, "m", "t3")
        #expect(!tail.contains { if case .reseated = $0 { true } else if case .retitled = $0 { true } else { false } })
        #expect(rows(state) == [["메인", "서브1", "서브2"]])
        #expect(state.agents[ids[3]]?.displayName == "서브1")
        #expect(state.agents[ids[1]]?.displayName == "서브2")
        for agent in state.agents(in: team) { #expect(agent.number == agent.seat.desk) }

        // 새 서브는 오른쪽 끝 책상 번호
        delegate(&state, "m", "t5")
        #expect(rows(state) == [["메인", "서브1", "서브2", "서브3"]])
    }

    @Test("데스크톱 서브 세션을 보관(퇴근)해도 같은 규칙: 남은 서브는 왼쪽부터 1..n (M6(14))")
    func renumbersSessionsByDesk() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        for index in 1...4 { _ = apply(&state, session: "c\(index)", hint: child(of: "m")) }
        #expect(rows(state) == [["메인", "서브1", "서브2", "서브3", "서브4"]])
        _ = end(&state, "c1")
        _ = end(&state, "c3")
        #expect(rows(state) == [["메인", "서브1", "서브2"]])
        #expect(name(state, "c4") == "서브1")
        #expect(name(state, "c2") == "서브2")
        _ = end(&state, "c2")
        #expect(rows(state) == [["메인", "서브"]])
        #expect(name(state, "c4") == "서브")
    }

    // MARK: - 책상

    @Test("책상은 0번(메인)부터 사람 수만큼: 새 서브는 오른쪽 끝, 가운데가 빠지면 오른쪽 끝 사람이 옮겨 앉는다")
    func desksHaveNoGaps() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        let team = try #require(state.lead(of: SessionID("m"))?.teamID)
        for index in 1...4 { delegate(&state, "m", "t\(index)") }
        #expect(desks(state, team) == [0, 1, 2, 3, 4])
        let last = try #require(state.agents(in: team).last)
        // 2번 책상 사람이 퇴근 → 오른쪽 끝(4번) 사람만 2번으로 옮기고, 나머지는 그대로
        let before = Dictionary(uniqueKeysWithValues: state.agents(in: team).map { ($0.id, $0.seat) })
        let beats = finish(&state, "m", "t2")
        #expect(desks(state, team) == [0, 1, 2, 3])
        #expect(state.agents[last.id]?.seat == Seat(desk: 2))
        let moved = beats.compactMap { if case .reseated(let agent) = $0 { agent.id } else { nil } }
        #expect(moved == [last.id])
        for agent in state.agents(in: team) where agent.id != last.id { #expect(before[agent.id] == agent.seat) }
        // 오른쪽 끝 사람이 퇴근하면 아무도 옮기지 않음
        let rightmost = try #require(state.agents(in: team).last)
        let tail = finish(&state, "m", rightmost.delegationToolUseID!)
        #expect(!tail.contains { if case .reseated = $0 { true } else { false } })
        #expect(desks(state, team) == [0, 1, 2])
        // 새 서브는 오른쪽 끝에
        delegate(&state, "m", "t9")
        #expect(desks(state, team) == [0, 1, 2, 3])
        #expect(state.agents(in: team).last?.delegationToolUseID == "t9")
    }

    @Test("메인이 퇴근하면 가장 먼저 온 서브 세션이 메인 책상으로 승진하고, 빈 책상은 메운다")
    func promotion() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        _ = apply(&state, session: "other")
        _ = apply(&state, session: "c1", hint: child(of: "m"))
        delegate(&state, "c1", "t1")
        _ = apply(&state, session: "c2", hint: child(of: "m"))
        delegate(&state, "m", "t2")  // 메인의 서브에이전트는 메인과 함께 퇴근
        let team = try #require(state.lead(of: SessionID("m"))?.teamID)
        #expect(desks(state, team) == [0, 1, 2, 3, 4])
        let beats = end(&state, "m")
        let promoted = beats.compactMap { if case .promoted(let agent) = $0 { agent } else { nil } }
        #expect(promoted.map(\.session) == [SessionID("c1")])
        #expect(promoted.first?.seat == .main)
        #expect(name(state, "c1") == "메인1")
        #expect(desks(state, team) == [0, 1, 2])
        // 서브 번호는 책상 번호라 빈 책상을 메운 사람이 그 번호를 받음 (M6(14))
        #expect(state.agents(in: team).map(\.displayName) == ["메인1", "서브1", "서브2"])
        #expect(state.teams.count == 2)
    }

    // MARK: - 늦게 온 부모

    @Test("하위 세션이 먼저 와서 메인이 됐다가, 부모가 오면 부모가 메인 책상을 넘겨받는다")
    func lateParent() throws {
        var state = OfficeState()
        _ = apply(&state, session: "c", hint: child(of: "m"))
        #expect(name(state, "c") == "메인")
        let beats = apply(&state, session: "m")
        #expect(state.teams.count == 1)
        #expect(name(state, "m") == "메인")
        #expect(name(state, "c") == "서브")
        #expect(state.lead(of: SessionID("m"))?.seat == .main)
        #expect(state.lead(of: SessionID("c"))?.seat == Seat(desk: 1))
        #expect(beats.contains { if case .retitled(let agent) = $0 { agent.session == SessionID("c") && !agent.isMain } else { false } })
    }

    @Test("부모의 하위 세션 둘이 각자 행을 열었다가, 부모가 오면 한 행으로 합친다")
    func lateParentMergesRows() throws {
        var state = OfficeState()
        _ = apply(&state, session: "c1", hint: child(of: "m"))
        delegate(&state, "c1", "t1")
        _ = apply(&state, session: "c2", hint: child(of: "m"))
        #expect(state.teams.count == 2)
        let beats = apply(&state, session: "m")
        #expect(state.teams.count == 1)
        #expect(beats.contains { if case .teamClosed = $0 { true } else { false } })
        #expect(rows(state) == [["메인", "서브1", "서브2", "서브3"]])
        let team = try #require(state.sortedTeams.first?.id)
        #expect(desks(state, team) == [0, 1, 2, 3])
    }

    @Test("정보 파일이 늦게 생겨 다른 메인의 하위 세션으로 밝혀지면 그 행으로 옮긴다")
    func lateHintMerges() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m")
        _ = apply(&state, session: "c")
        delegate(&state, "c", "t1")
        #expect(rows(state) == [["메인1"], ["메인2", "서브"]])
        let beats = apply(&state, session: "c", "UserPromptSubmit", hint: child(of: "m"), ["prompt": "x"])
        #expect(rows(state) == [["메인", "서브1", "서브2"]])
        let closed = beats.compactMap { if case .teamClosed(let team) = $0 { team } else { nil } }
        #expect(closed.count == 1)
        let movers = beats.compactMap { if case .retitled(let agent) = $0 { agent } else { nil } }.filter { !$0.isMain }
        #expect(movers.count == 2)
        #expect(movers.allSatisfy { $0.teamID == state.lead(of: SessionID("m"))?.teamID })
    }

    @Test("정보가 서로를 부모로 가리켜도(순환) 멈추지 않고 행이 그대로 남는다")
    func cyclicHints() {
        var state = OfficeState()
        _ = apply(&state, session: "x")
        _ = apply(&state, session: "y", hint: child(of: "x"))
        _ = apply(&state, session: "x", "UserPromptSubmit", hint: child(of: "y"), ["prompt": "x"])
        #expect(state.teams.count == 1)
        #expect(name(state, "x") == "메인")
        #expect(name(state, "y") == "서브")
    }

    @Test("워크트리 폴더는 원래 폴더 이름으로 보여 준다")
    func worktreeFolder() {
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter") == "/w/proj")
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter/") == "/w/proj")
        #expect(Team.folder(for: "/w/proj/.claude/worktrees/happy-otter/sub") == "/w/proj/sub")
        #expect(Team.folder(for: "/w/proj/") == "/w/proj")
        #expect(Team.folder(for: nil) == "(알 수 없는 프로젝트)")
        var state = OfficeState()
        _ = apply(&state, session: "wt", cwd: "/w/proj/.claude/worktrees/happy-otter")
        #expect(state.sortedTeams.first?.name == "proj")
        #expect(state.sortedTeams.first?.folder == "/w/proj")
    }

    @Test("같은 종류 고정 직원의 내부 이름도 빈 번호를 다시 쓴다 (화면 이름은 서브 번호)")
    func memberNames() {
        var state = OfficeState()
        _ = apply(&state, session: "s1")
        delegate(&state, "s1", "t1", "code-reviewer")
        delegate(&state, "s1", "t2", "code-reviewer")
        #expect(state.agents.values.filter { $0.role == .member }.map(\.displayName).sorted() == ["서브1", "서브2"])
        #expect(state.agents.values.filter { $0.role == .member }.map(\.profile.displayName).sorted() == ["code-reviewer", "code-reviewer (2)"])
        finish(&state, "s1", "t1")
        delegate(&state, "s1", "t3", "code-reviewer")
        #expect(state.agents.values.filter { $0.role == .member }.map(\.profile.displayName).sorted() == ["code-reviewer", "code-reviewer (2)"])
    }

    // MARK: - 목록

    @Test("직원 목록은 행마다 메인부터 책상 순서, 선택한 행만 거를 수 있다")
    func rosterRows() throws {
        var state = OfficeState()
        _ = apply(&state, session: "m1", hint: SessionHint(hostSession: "local_a", title: "설계 정리"))
        _ = apply(&state, session: "m2")
        delegate(&state, "m1", "t1", "code-reviewer")
        _ = apply(&state, session: "c1", hint: child(of: "m1"))
        let roster = Roster.make(from: state, privacy: .detailed)
        #expect(roster.teams.map(\.label) == ["메인1 · claude-office", "메인2 · claude-office"])
        #expect(roster.teams[0].rows.map(\.name) == ["메인1", "서브1", "서브2"])
        #expect(roster.teams[0].rows.map(\.seat.desk) == [0, 1, 2])
        #expect(roster.teams[0].mainTitle == "설계 정리")
        #expect(roster.teams[0].rows[1].agentType == "code-reviewer")
        #expect(roster.teams[0].rows[1].calledBy == "메인1")
        #expect(roster.teams[0].rows.map(\.isMain) == [true, false, false])
        #expect(roster.teams[0].rows.allSatisfy { $0.mainName == "메인1" })
        // 디렉토리로 거르기: 두 메인 모두 claude-office 폴더
        #expect(roster.filtered(folders: [Self.folder]) == roster)
        #expect(roster.filtered(folders: ["/elsewhere"]).agentCount == 0)
        #expect(roster.filtered(folders: nil) == roster)
    }
}
