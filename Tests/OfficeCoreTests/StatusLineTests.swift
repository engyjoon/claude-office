import Foundation
import Testing

@testable import OfficeCore

@Suite("실시간 현황 줄 (세 줄)")
struct StatusLineTests {
    let hook = Hook()
    let reviewer = (id: "r1", type: "code-reviewer")

    /// 훅을 1초 간격(또는 지정 시각)으로 엔진에 넣습니다
    struct Office {
        var engine = OfficeEngine(seed: 7)
        var clock = 0.0

        mutating func send(_ payload: JSONValue, at seconds: Double? = nil) {
            clock = seconds ?? clock + 1
            let event = HookParser.parse(payload, term: "iTerm.app", receivedAt: Fixture.epoch.addingTimeInterval(clock))!
            _ = engine.handle(event)
        }

        func line(
            _ privacy: PrivacyLevel = .detailed, selected: AgentID? = nil, folder: String? = nil, rows: [TeamID]? = nil, hidden: [TeamID] = []
        ) -> StatusLine {
            StatusLine.make(
                state: engine.state, journal: engine.journal, privacy: privacy, selected: selected, folder: folder, rows: rows, hiddenRows: hidden)
        }

        func texts(
            _ privacy: PrivacyLevel = .detailed, selected: AgentID? = nil, folder: String? = nil, rows: [TeamID]? = nil, hidden: [TeamID] = [],
            at seconds: Double? = nil
        ) -> [String] {
            line(privacy, selected: selected, folder: folder, rows: rows, hidden: hidden)
                .texts(now: Fixture.epoch.addingTimeInterval(seconds ?? clock))
        }

        /// 사용자가 그 세션의 응답을 봄 (M6(4))
        mutating func acknowledge(_ session: String = "s1", at seconds: Double) {
            _ = engine.acknowledge(SessionID(session), at: Fixture.epoch.addingTimeInterval(seconds))
        }

        var main: AgentID { engine.state.lead(of: SessionID("s1"))!.id }
        func team(_ session: String) -> TeamID { engine.state.lead(of: SessionID(session))!.teamID }
        func color(_ session: String) -> Int? { engine.state.teams[team(session)]?.colorIndex }
    }

    func read(_ id: String, _ file: String, agent: (id: String, type: String)? = nil) -> [JSONValue] {
        [
            hook.tool("PreToolUse", "Read", id: id, input: ["file_path": .string("/w/\(file)")], agent: agent),
            hook.tool("PostToolUse", "Read", id: id, input: ["file_path": .string("/w/\(file)")], agent: agent, extra: [("tool_response", [:])]),
        ]
    }

    /// 1초 요청, 2~7초 Read 3개(마지막 시작 6초), 8~9초 Edit auth.ts, 20초 Bash npm test 시작
    func working() -> Office {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "고쳐 줘"]))
        for payload in read("r1", "a.ts") + read("r2", "b.ts") + read("r3", "c.ts") { office.send(payload) }
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/src/auth.ts"]))
        office.send(hook.tool("PostToolUse", "Edit", id: "e1", input: ["file_path": "/w/src/auth.ts"], extra: [("tool_response", [:])]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]), at: 20)
        return office
    }

    /// 디렉토리 `name`에서 연 세션
    func session(_ id: String, _ name: String) -> Hook {
        Hook(session: id, cwd: "/Users/demo/work/\(name)")
    }

    // MARK: - 고른 사람

    @Test("고른 사람: 최근 일 세 개를 한 줄에 하나씩 (최신이 아래), 첫 줄 맨 앞에 디렉토리 · 직함")
    func agentLines() {
        let office = working()
        #expect(office.texts(selected: office.main, at: 32) == [
            "a-sdn-portal · 메인 · Read 3개 (26초 전)",
            "Edit auth.ts (24초 전)",
            "Bash npm test (12초째)",
        ])
        let line = office.line(selected: office.main)
        #expect(line.mode == .agent)
        #expect(line.lines.map(\.head) == ["메인", nil, nil])
        #expect(line.lines[0].colorIndex == office.color("s1"))
        #expect(line.ticks)
        // 1초가 안 되면 경과 시간을 붙이지 않습니다
        #expect(office.texts(selected: office.main, at: 20.5).last == "Bash npm test")
    }

    @Test("같은 도구라도 사이에 다른 도구가 끼면 따로, 세 개보다 오래된 일은 줄에 없음")
    func agentGrouping() {
        var office = Office()
        for payload in read("r1", "a.ts") { office.send(payload) }
        office.send(hook.tool("PreToolUse", "Grep", id: "g1", input: ["pattern": "TODO"]))
        office.send(hook.tool("PostToolUse", "Grep", id: "g1", input: ["pattern": "TODO"], extra: [("tool_response", [:])]))
        for payload in read("r2", "b.ts") + read("r3", "c.ts") { office.send(payload) }
        #expect(office.line(selected: office.main).lines.map(\.segment.text) == ["Read a.ts", "Grep \"TODO\"", "Read 2개"])

        for (index, tool) in ["Glob", "Edit", "WebSearch", "Write"].enumerated() {
            office.send(hook.tool("PreToolUse", tool, id: "t\(index)", input: [:]))
            office.send(hook.tool("PostToolUse", tool, id: "t\(index)", input: [:], extra: [("tool_response", [:])]))
        }
        #expect(office.line(selected: office.main).lines.map(\.segment.text) == ["Edit", "WebSearch", "Write"])
    }

    @Test("승인 대기는 노랑, 실패·거부는 빨강")
    func tones() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]))
        office.send(hook.tool("PostToolUseFailure", "Bash", id: "b1", input: ["command": "npm test"], extra: [("error", "exit 1")]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b2", input: ["command": "rm -rf build"]))
        office.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm -rf build"]), at: 10)
        var line = office.line(selected: office.main)
        #expect(line.lines.map(\.segment.text) == ["Bash npm test 실패", "Bash rm -rf build 승인 대기"])
        #expect(line.lines.map(\.segment.tone) == [.error, .attention])
        #expect(office.texts(selected: office.main, at: 15).last == "Bash rm -rf build 승인 대기 (5초째)")

        office.send(hook.tool("PermissionDenied", "Bash", id: "b2", input: ["command": "rm -rf build"]))
        line = office.line(selected: office.main)
        #expect(line.lines.last?.segment.text == "Bash rm -rf build 거부됨")
        #expect(line.lines.last?.segment.tone == .error)
    }

    @Test("툴 시작 없이 온 승인 요청도 승인 대기로 보인다")
    func bareRequest() {
        var office = Office()
        office.send(hook.make("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        let line = office.line(selected: office.main)
        #expect(line.lines.map(\.segment) == [StatusLine.Segment(text: "승인 대기", tone: .attention, since: Fixture.epoch.addingTimeInterval(1))])
    }

    @Test("위임은 서브가 보고할 때까지 진행 중이고, 서브의 줄은 서브 직함으로")
    func delegation() throws {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "비밀 리뷰", "subagent_type": "code-reviewer"]))
        office.send(hook.make("SubagentStart", ["agent_id": "r1", "agent_type": "code-reviewer"]))
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"], agent: reviewer), at: 5)
        let sub = try #require(office.engine.state.member(subagentID: "r1", in: SessionID("s1"))).id
        #expect(office.texts(selected: office.main, at: 6) == ["a-sdn-portal · 메인 · 서브에게 위임 (5초째)"])
        #expect(office.texts(selected: sub, at: 6) == ["a-sdn-portal · 서브 · Edit auth.ts (1초째)"])
        // 행 줄: 그 행에서 가장 최근 일, 서브가 했으면 "서브가 …"
        #expect(office.texts(at: 6) == ["a-sdn-portal · 메인 · 서브가 Edit auth.ts (1초째)"])
        // 에이전트 종류(code-reviewer)와 맡긴 일은 현황 줄에 쓰지 않습니다
        for text in office.texts(selected: sub) + office.texts(selected: office.main) + office.texts() {
            #expect(!text.contains("code-reviewer") && !text.contains("비밀"))
        }

        office.send(hook.make("SubagentStop", ["agent_id": "r1", "agent_type": "code-reviewer"]), at: 9)
        // 끝난 일의 때는 시작한 때 (위임은 1초)
        #expect(office.texts(selected: office.main, at: 30) == ["a-sdn-portal · 메인 · 서브에게 위임 (29초 전)"])
    }

    @Test("고른 사람이 아직 아무것도 안 했으면 지금 상태")
    func noHistory() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.texts(selected: office.main) == ["a-sdn-portal · 메인 · 생각 중"])
        #expect(office.line(selected: office.main).lines.first?.segment.tone == .muted)
    }

    @Test("고른 사람 줄: 디렉토리를 골랐으면 직함만")
    func agentFolder() {
        let office = working()
        #expect(office.line(selected: office.main).lines[0].folder == "a-sdn-portal")
        #expect(office.texts(selected: office.main, folder: "/Users/demo/work/a-sdn-portal", at: 32).first == "메인 · Read 3개 (26초 전)")
    }

    @Test("고른 사람이 퇴근하면 행 줄로")
    func selectedLeft() {
        var office = Office()
        for payload in read("r1", "a.ts") { office.send(payload) }
        let main = office.main
        office.send(hook.make("SessionEnd", ["reason": "exit"]))
        #expect(office.line(selected: main).mode == .office)
    }

    // MARK: - 표시 수준

    @Test("요약·비공개면 파일명과 명령을 숨기고 도구 종류만", arguments: [PrivacyLevel.summary, .hidden])
    func privacy(_ level: PrivacyLevel) {
        let office = working()
        #expect(office.texts(level, selected: office.main, at: 32) == ["a-sdn-portal · 메인 · Read 3개 (26초 전)", "Edit (24초 전)", "Bash (12초째)"])
        #expect(office.texts(level, at: 32) == ["a-sdn-portal · 메인 · Bash (12초째)"])
        for text in office.texts(level, selected: office.main) + office.texts(level) {
            for secret in ["auth.ts", "npm", "a.ts"] { #expect(!text.contains(secret)) }
        }
    }

    @Test("디렉토리 이름은 표시 수준과 상관없이 보인다 (패널·드롭다운과 같음)", arguments: PrivacyLevel.allCases)
    func folderPrivacy(_ level: PrivacyLevel) {
        let office = working()
        #expect(office.texts(level, at: 32).first?.hasPrefix("a-sdn-portal · 메인 · ") == true)
        #expect(office.line(level, selected: office.main).lines[0].folder == "a-sdn-portal")
    }

    // MARK: - 행 줄 (아무도 안 골랐을 때)

    @Test("행 줄: 행 색 점 · 디렉토리 · 메인 직함 · 그 행의 가장 최근 일과 시간")
    func rowLine() {
        var office = working()
        let line = office.line()
        #expect(line.mode == .office)
        #expect(line.lines.count == 1)
        #expect(line.lines[0].colorIndex == office.color("s1"))
        #expect(line.lines[0].head == "메인")
        #expect(office.texts(at: 32) == ["a-sdn-portal · 메인 · Bash npm test (12초째)"])
        office.send(hook.tool("PostToolUse", "Bash", id: "b1", input: ["command": "npm test"], extra: [("tool_response", [:])]), at: 33)
        #expect(office.texts(at: 35) == ["a-sdn-portal · 메인 · Bash npm test (15초 전)"])
    }

    @Test("행 순서는 사무실의 행과 같고, 행이 모자라면 남는 줄은 비운다")
    func rowOrder() {
        var office = Office()
        let a = session("s1", "a-sdn-portal"), b = session("s2", "claude-office"), c = session("s3", "workspace")
        office.send(a.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"]))
        office.send(b.tool("PreToolUse", "Bash", id: "b1", input: ["command": "make test"]))
        office.send(c.make("UserPromptSubmit", ["prompt": "안녕"]))
        office.send(c.make("Stop"))
        // 사무실이 준 순서 그대로
        let rows = [office.team("s2"), office.team("s1"), office.team("s3")]
        let line = office.line(rows: rows)
        #expect(line.lines.map(\.colorIndex) == [office.color("s2"), office.color("s1"), office.color("s3")])
        #expect(office.texts(rows: rows, at: 6) == [
            "claude-office · 메인2 · Bash make test (4초째)",
            "a-sdn-portal · 메인1 · Edit auth.ts (5초째)",
            "workspace · 메인3 · 새 응답 (방금)",
        ])
        // 보이는 행이 하나면 한 줄
        #expect(office.texts(rows: [office.team("s1")], at: 6) == ["a-sdn-portal · 메인1 · Edit auth.ts (5초째)"])
        // 사무실이 행을 안 주면 온 순서대로
        #expect(office.line().lines.map(\.head) == ["메인1", "메인2", "메인3"])
    }

    @Test("조용한 행은 (응답을 확인한 뒤) 쉬는 중, 10분이 지나면 잠든 중")
    func quietRow() {
        var office = Office()
        for payload in read("r1", "a.ts") { office.send(payload) }
        office.send(hook.make("Stop"), at: 10)
        office.acknowledge(at: 11)
        let line = office.line()
        #expect(line.lines[0].segment.tone == .muted)
        #expect(line.ticks)
        #expect(office.texts(at: 20) == ["a-sdn-portal · 메인 · 쉬는 중"])
        #expect(office.texts(at: 10 + StatusLine.napAfter) == ["a-sdn-portal · 메인 · 잠든 중"])
    }

    @Test("직원이 없으면 안내 한 줄")
    func empty() {
        var office = Office()
        #expect(office.texts() == ["아직 출근한 직원이 없어요"])
        #expect(office.line().lines[0].head == nil)
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.texts(folder: "/Users/demo/work/없는-폴더") == ["고른 디렉토리에 출근한 직원이 없어요"])
    }

    @Test("기록 없이 생각만 하는 중이면 지금 상태와 경과 시간")
    func thinkingOnly() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.texts(at: 4) == ["a-sdn-portal · 메인 · 생각 중 (3초째)"])
    }

    @Test("승인 대기가 있으면 그 행의 더 최근 일보다 먼저")
    func waitingFirst() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "리뷰", "subagent_type": "code-reviewer"]))
        office.send(hook.make("SubagentStart", ["agent_id": "r1", "agent_type": "code-reviewer"]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "rm -rf build"], agent: reviewer))
        office.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm -rf build"], agent: reviewer), at: 4)
        for payload in read("r2", "a.ts") { office.send(payload) }
        let line = office.line()
        #expect(line.lines[0].segment.tone == .attention)
        #expect(office.texts(at: 10) == ["a-sdn-portal · 메인 · 서브가 Bash rm -rf build 승인 대기 (6초째)"])
    }

    @Test("notify-demo 흐름: 명령 승인 대기 중에는 행 줄도 승인 대기, 끝나면 새 응답, 확인하면 쉬는 중")
    func notifyDemo() {
        var office = Office()
        let demo = session("s1", "notify-demo")
        office.send(demo.make("SessionStart", ["source": "startup"]), at: 0)
        office.send(demo.make("UserPromptSubmit", ["prompt": "(생략)"]), at: 1)
        office.send(demo.tool("PreToolUse", "Bash", id: "t1", input: ["command": "npm test"]), at: 3)
        office.send(demo.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"]), at: 3.5)
        office.send(demo.make("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]), at: 4)
        #expect(office.texts(at: 10) == ["notify-demo · 메인 · Bash npm test 승인 대기 (6초째)"])
        #expect(office.line().lines[0].segment.tone == .attention)
        office.send(demo.tool("PostToolUse", "Bash", id: "t1", input: ["command": "npm test"], extra: [("tool_response", [:])]), at: 44)
        office.send(demo.make("Stop"), at: 47)
        #expect(office.texts(at: 50) == ["notify-demo · 메인 · 새 응답 (방금)"])
        office.acknowledge(at: 51)
        #expect(office.texts(at: 52) == ["notify-demo · 메인 · 쉬는 중"])
    }

    @Test("디렉토리를 고르면 그 디렉토리의 행만, 디렉토리 이름은 생략")
    func folderFilter() {
        var office = Office()
        let a = session("s1", "a-sdn-portal"), b = session("s2", "claude-office")
        office.send(a.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"]))
        office.send(b.tool("PreToolUse", "Bash", id: "b1", input: ["command": "make test"]))
        #expect(office.texts(folder: "/Users/demo/work/claude-office", at: 3) == ["메인2 · Bash make test (1초째)"])
        let line = office.line(folder: "/Users/demo/work/claude-office")
        #expect(line.lines[0].folder == nil)
        #expect(line.lines[0].colorIndex == office.color("s2"))
    }

    @Test("긴 디렉토리 이름은 줄인다")
    func longFolder() {
        var office = Office()
        office.send(session("s3", "a-very-long-directory-name-here").tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]))
        #expect(StatusLine.shortFolder("a-very-long-directory-name-here") == "a-very-long-dir…")
        #expect(StatusLine.shortFolder("a-very-long-dir…").count == StatusLine.maxFolderLength)
        #expect(StatusLine.shortFolder("claude-office") == "claude-office")
        #expect(office.line().lines[0].folder == "a-very-long-dir…")
    }

    @Test("퇴근한 서브의 일도 그 행의 줄에 남는다")
    func departedSub() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "리뷰", "subagent_type": "code-reviewer"]))
        office.send(hook.make("SubagentStart", ["agent_id": "r1", "agent_type": "code-reviewer"]))
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"], agent: reviewer))
        office.send(hook.make("SubagentStop", ["agent_id": "r1", "agent_type": "code-reviewer"]), at: 5)
        #expect(office.engine.journal.entries.allSatisfy { $0.team == office.team("s1") })
        #expect(office.texts(at: 6).first?.hasPrefix("a-sdn-portal · 메인 · ") == true)
    }

    // MARK: - 화면 밖 행의 승인 대기

    @Test("화면에 못 보여 준 행의 승인 대기: 행이 셋이면 셋째 줄을 그 알림으로")
    func hiddenWaitingReplacesThird() {
        var office = Office()
        let hooks = ["one", "two", "three", "four"].enumerated().map { session("s\($0.offset + 1)", $0.element) }
        for (index, h) in hooks.enumerated() {
            office.send(h.tool("PreToolUse", "Read", id: "r\(index)", input: ["file_path": "/w/x.ts"]))
        }
        office.send(hooks[3].tool("PreToolUse", "Bash", id: "b4", input: ["command": "deploy"]))
        office.send(hooks[3].tool("PermissionRequest", "Bash", id: nil, input: ["command": "deploy"]), at: 10)
        let rows = ["s1", "s2", "s3"].map(office.team)
        let hidden = [office.team("s4")]
        let line = office.line(rows: rows, hidden: hidden)
        #expect(line.lines.count == 3)
        #expect(line.lines[2].offscreen)
        #expect(line.lines[2].colorIndex == office.color("s4"))
        #expect(line.lines[2].segment.tone == .attention)
        #expect(office.texts(rows: rows, hidden: hidden, at: 12)[2] == "[화면 밖] four · 메인4 · Bash deploy 승인 대기 (2초째)")
        #expect(line.lines[0...1].allSatisfy { !$0.offscreen })

        // 승인을 기다리지 않는 숨긴 행은 줄에 없음
        #expect(!office.line(rows: ["s1", "s2", "s4"].map(office.team), hidden: [office.team("s3")]).lines.contains { $0.offscreen })
    }

    @Test("보이는 행이 셋보다 적으면 빈 줄에, 여러 행이 기다리면 가장 오래 기다린 행과 나머지 수")
    func hiddenWaitingAppends() {
        var office = Office()
        let hooks = ["one", "two", "three"].enumerated().map { session("s\($0.offset + 1)", $0.element) }
        office.send(hooks[0].tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/w/x.ts"]))
        office.send(hooks[1].tool("PermissionRequest", "Bash", id: nil, input: ["command": "a"]))
        office.send(hooks[2].tool("PermissionRequest", "Bash", id: nil, input: ["command": "b"]))
        let line = office.line(rows: [office.team("s1")], hidden: [office.team("s3"), office.team("s2")])
        #expect(line.lines.count == 2)
        #expect(line.lines[1].offscreen)
        #expect(line.lines[1].more == 1)
        #expect(line.lines[1].head == "메인2")
        #expect(line.lines[1].note == "화면 밖 외 1행")
    }

    @Test("사무실이 행을 안 주면 넷째 행부터 숨긴 행으로 본다")
    func defaultHidden() {
        var office = Office()
        let hooks = ["one", "two", "three", "four"].enumerated().map { session("s\($0.offset + 1)", $0.element) }
        for (index, h) in hooks.enumerated() {
            office.send(h.tool("PreToolUse", "Read", id: "r\(index)", input: ["file_path": "/w/x.ts"]))
        }
        office.send(hooks[3].tool("PermissionRequest", "Bash", id: nil, input: ["command": "deploy"]))
        #expect(office.line().lines.map(\.head) == ["메인1", "메인2", "메인4"])
        #expect(office.line().lines[2].offscreen)
    }

    // MARK: - 문구 다듬기

    @Test("MCP 도구는 사람이 읽는 말로, 모르는 것은 도구 이름만")
    func mcpNames() {
        #expect(MCPNames.label("mcp__ccd_turn__update_plan", detailed: true) == "할 일 목록 정리")
        #expect(MCPNames.label("mcp__ccd_turn__update_plan", detailed: false) == "할 일 목록 정리")
        #expect(MCPNames.label("mcp__ccd_session__start_session", detailed: true) == "새 세션 시작")
        #expect(MCPNames.label("mcp__Claude_Browser__navigate", detailed: true) == "브라우저")
        #expect(MCPNames.detail("mcp__Claude_Browser__navigate") == "navigate")
        #expect(MCPNames.detail("mcp__ccd_turn__update_plan") == nil)
        #expect(MCPNames.label("mcp__1a59c906-04da__create_issue", detailed: true) == "create_issue")
        #expect(MCPNames.detail("mcp__1a59c906-04da__create_issue") == nil)
        // 요약·비공개에서 모르는 도구는 이름 대신 "MCP"
        #expect(MCPNames.label("mcp__1a59c906-04da__create_issue", detailed: false) == "MCP")
        #expect(MCPNames.split("mcp__srv__a__b")! == ("srv", "a__b"))
    }

    @Test("현황 줄·타임라인의 MCP 문구", arguments: PrivacyLevel.allCases)
    func mcpInLines(_ level: PrivacyLevel) {
        var office = Office()
        for id in ["p1", "p2"] {
            office.send(hook.tool("PreToolUse", "mcp__ccd_turn__update_plan", id: id, input: ["items": []]))
            office.send(hook.tool("PostToolUse", "mcp__ccd_turn__update_plan", id: id, input: ["items": []], extra: [("tool_response", [:])]))
        }
        office.send(hook.tool("PreToolUse", "mcp__claude-in-chrome__navigate", id: "n1", input: ["url": "https://x.dev"]))
        let texts = office.line(level, selected: office.main).lines.map(\.segment.text)
        #expect(texts == ["할 일 목록 정리 2개", level == .detailed ? "Chrome navigate" : "Chrome"])
        let timeline = AgentTimeline.make(agent: office.main, state: office.engine.state, journal: office.engine.journal, privacy: level)
        #expect(timeline.items.map(\.text) == texts)
        for text in texts { #expect(!text.contains("ccd_turn") && !text.contains("mcp__")) }
    }

    @Test("명령의 절대 경로는 마지막 이름으로", arguments: [
        ("cd /Users/me/work/claude-office", "cd claude-office"),
        ("cd /Users/me/work/claude-office && make test", "cd claude-office && make test"),
        ("open \"/Applications/Claude Office.app\"", "open \"Claude Office.app\""),
        ("cat ~/notes/todo.md", "cat todo.md"),
        ("rm -rf /tmp/build/", "rm -rf build"),
        ("swift build --scratch-path=/tmp/x/.build", "swift build --scratch-path=.build"),
        ("ls 2>/dev/null", "ls 2>/dev/null"),
        ("curl https://example.com/a/b", "curl https://example.com/a/b"),
        ("ls src/a/b", "ls src/a/b"),
        ("ls /", "ls /"),
    ])
    func shortenPaths(_ pair: (String, String)) {
        #expect(ToolCatalog.shortenPaths(pair.0) == pair.1)
    }

    @Test("Bash 대상에도 줄인 경로가 들어간다 (줄인 뒤에 자름)")
    func bashSubject() {
        let call = ToolCatalog.makeCall(
            name: "Bash", input: ["command": "cd /Users/engyjoon/project/workspace/claude-office && swift build"], id: nil)
        #expect(call.subject == "cd claude-office && swift build")
    }

    // MARK: - 조각

    @Test("경과 시간 표현")
    func elapsed() {
        #expect(StatusLine.elapsed(0.4) == nil)
        #expect(StatusLine.elapsed(12) == "12초째")
        #expect(StatusLine.elapsed(185) == "3분째")
        #expect(StatusLine.elapsed(3720) == "1시간 2분째")
    }

    @Test("주격 조사", arguments: [
        ("메인", "메인이"), ("서브", "서브가"), ("메인1", "메인1이"), ("서브2", "서브2가"), ("서브3", "서브3이"),
        ("서브4", "서브4가"), ("서브10", "서브10이"),
    ])
    func particle(_ pair: (String, String)) {
        #expect(Korean.subject(pair.0) == pair.1)
    }

    @Test("기록은 정해진 수만 남긴다")
    func capacity() {
        var office = Office()
        for index in 0..<(ActivityJournal.capacity + 10) {
            for payload in read("r\(index)", "f\(index).ts") { office.send(payload) }
        }
        #expect(office.engine.journal.entries.count == ActivityJournal.capacity)
    }

    @Test("다음에 글자가 바뀌는 때: 1분 안쪽은 1초 단위, 그 뒤는 1분 단위, 쉬는 중은 잠드는 순간 (M6(1))")
    func nextChange() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ segment: StatusLine.Segment) -> StatusLine {
            StatusLine(mode: .office, lines: [StatusLine.Line(segment: segment)])
        }
        #expect(line(StatusLine.Segment(text: "생각 중")).nextChange(after: t0) == nil)
        #expect(StatusLine.empty.nextChange(after: t0) == nil)

        let working = line(StatusLine.Segment(text: "Bash", since: t0))
        #expect(working.nextChange(after: t0.addingTimeInterval(12.3)) == t0.addingTimeInterval(13))
        #expect(working.nextChange(after: t0.addingTimeInterval(59.5)) == t0.addingTimeInterval(60))
        #expect(working.nextChange(after: t0.addingTimeInterval(61)) == t0.addingTimeInterval(120))
        #expect(working.nextChange(after: t0.addingTimeInterval(3_700)) == t0.addingTimeInterval(3_720))

        let done = line(StatusLine.Segment(text: "Edit", at: t0))
        #expect(done.nextChange(after: t0.addingTimeInterval(200)) == t0.addingTimeInterval(240))

        // 쉬는 중: 시간은 없고 잠드는 순간만
        let resting = line(StatusLine.Segment(text: "쉬는 중", restingSince: t0))
        #expect(resting.nextChange(after: t0.addingTimeInterval(30)) == t0.addingTimeInterval(StatusLine.napAfter))
        #expect(resting.nextChange(after: t0.addingTimeInterval(StatusLine.napAfter + 1)) == nil)

        // 여러 줄이면 가장 이른 때
        let both = StatusLine(mode: .office, lines: [
            StatusLine.Line(segment: StatusLine.Segment(text: "Edit", at: t0)),
            StatusLine.Line(segment: StatusLine.Segment(text: "Bash", since: t0.addingTimeInterval(290))),
        ])
        #expect(both.nextChange(after: t0.addingTimeInterval(300.5)) == t0.addingTimeInterval(301))
    }
}
