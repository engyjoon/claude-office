import Foundation
import Testing

@testable import OfficeCore

@Suite("실시간 현황 줄")
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

        func line(_ privacy: PrivacyLevel = .detailed, selected: AgentID? = nil, folder: String? = nil) -> StatusLine {
            StatusLine.make(state: engine.state, journal: engine.journal, privacy: privacy, selected: selected, folder: folder)
        }

        func text(_ privacy: PrivacyLevel = .detailed, selected: AgentID? = nil, folder: String? = nil, at seconds: Double? = nil) -> String {
            line(privacy, selected: selected, folder: folder).text(now: Fixture.epoch.addingTimeInterval(seconds ?? clock))
        }

        var main: AgentID { engine.state.lead(of: SessionID("s1"))!.id }
    }

    func read(_ id: String, _ file: String, agent: (id: String, type: String)? = nil) -> [JSONValue] {
        [
            hook.tool("PreToolUse", "Read", id: id, input: ["file_path": .string("/w/\(file)")], agent: agent),
            hook.tool("PostToolUse", "Read", id: id, input: ["file_path": .string("/w/\(file)")], agent: agent, extra: [("tool_response", [:])]),
        ]
    }

    /// Read 3개 → Edit auth.ts → Bash npm test (진행 중)
    func working() -> Office {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "고쳐 줘"]))
        for payload in read("r1", "a.ts") + read("r2", "b.ts") + read("r3", "c.ts") { office.send(payload) }
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/src/auth.ts"]))
        office.send(hook.tool("PostToolUse", "Edit", id: "e1", input: ["file_path": "/w/src/auth.ts"], extra: [("tool_response", [:])]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]), at: 20)
        return office
    }

    // MARK: - 고른 사람

    @Test("고른 사람: 직함으로 시작하고 같은 도구는 묶고 진행 중인 동작에 경과 시간")
    func agentFlow() {
        let office = working()
        #expect(office.text(selected: office.main, at: 32) == "a-sdn-portal · 메인 Read 3개 → Edit auth.ts → Bash npm test (12초째)")
        let line = office.line(selected: office.main)
        #expect(line.mode == .agent)
        #expect(line.head == "메인")
        #expect(line.hasRunning)
        #expect(line.segments.map(\.tone) == [.normal, .normal, .normal])
        // 1초가 안 되면 경과 시간을 붙이지 않습니다
        #expect(office.text(selected: office.main, at: 20.5) == "a-sdn-portal · 메인 Read 3개 → Edit auth.ts → Bash npm test")
    }

    @Test("끝난 동작은 경과 시간이 없고, 같은 도구라도 사이에 다른 도구가 끼면 따로")
    func groupingBreaks() {
        var office = Office()
        for payload in read("r1", "a.ts") { office.send(payload) }
        office.send(hook.tool("PreToolUse", "Grep", id: "g1", input: ["pattern": "TODO"]))
        office.send(hook.tool("PostToolUse", "Grep", id: "g1", input: ["pattern": "TODO"], extra: [("tool_response", [:])]))
        for payload in read("r2", "b.ts") + read("r3", "c.ts") { office.send(payload) }
        #expect(office.text(selected: office.main, at: 100) == "a-sdn-portal · 메인 Read a.ts → Grep \"TODO\" → Read 2개")
        #expect(!office.line(selected: office.main).hasRunning)
    }

    @Test("오래된 동작은 앞에서 잘라 낸다")
    func truncation() {
        var office = Office()
        let tools = ["Read", "Grep", "Glob", "Edit", "Bash", "WebSearch", "TodoWrite", "Write"]
        for (index, tool) in tools.enumerated() {
            office.send(hook.tool("PreToolUse", tool, id: "t\(index)", input: [:]))
            office.send(hook.tool("PostToolUse", tool, id: "t\(index)", input: [:], extra: [("tool_response", [:])]))
        }
        let line = office.line(selected: office.main)
        #expect(line.truncated)
        #expect(line.segments.count == StatusLine.maxAgentSegments)
        #expect(line.segments.first?.text == "Glob")
        #expect(line.segments.last?.text == "Write")
        #expect(office.text(selected: office.main).hasPrefix("a-sdn-portal · 메인 … Glob → Edit"))
    }

    @Test("승인 대기는 노랑, 실패·거부는 빨강")
    func tones() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]))
        office.send(hook.tool("PostToolUseFailure", "Bash", id: "b1", input: ["command": "npm test"], extra: [("error", "exit 1")]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b2", input: ["command": "rm -rf build"]))
        office.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm -rf build"]), at: 10)
        var line = office.line(selected: office.main)
        #expect(line.segments.map(\.text) == ["Bash npm test 실패", "Bash rm -rf build 승인 대기"])
        #expect(line.segments.map(\.tone) == [.error, .attention])
        #expect(office.text(selected: office.main, at: 15) == "a-sdn-portal · 메인 Bash npm test 실패 → Bash rm -rf build 승인 대기 (5초째)")

        office.send(hook.tool("PermissionDenied", "Bash", id: "b2", input: ["command": "rm -rf build"]))
        line = office.line(selected: office.main)
        #expect(line.segments.last == StatusLine.Segment(text: "Bash rm -rf build 거부됨", tone: .error))
    }

    @Test("툴 시작 없이 온 승인 요청도 승인 대기로 보인다")
    func bareRequest() {
        var office = Office()
        office.send(hook.make("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        let line = office.line(selected: office.main)
        #expect(line.segments == [StatusLine.Segment(text: "승인 대기", tone: .attention, since: Fixture.epoch.addingTimeInterval(1))])
    }

    @Test("위임은 서브가 보고할 때까지 진행 중이고, 서브의 줄은 서브 직함으로")
    func delegation() throws {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "비밀 리뷰", "subagent_type": "code-reviewer"]))
        office.send(hook.make("SubagentStart", ["agent_id": "r1", "agent_type": "code-reviewer"]))
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"], agent: reviewer), at: 5)
        let sub = try #require(office.engine.state.member(subagentID: "r1", in: SessionID("s1"))).id
        #expect(office.text(selected: office.main, at: 6) == "a-sdn-portal · 메인 서브에게 위임 (5초째)")
        #expect(office.text(selected: sub, at: 6) == "a-sdn-portal · 서브 Edit auth.ts (1초째)")
        // 에이전트 종류(code-reviewer)와 맡긴 일은 현황 줄에 쓰지 않습니다
        #expect(!office.text(selected: sub).contains("code-reviewer"))
        #expect(!office.text(selected: office.main).contains("비밀"))

        office.send(hook.make("SubagentStop", ["agent_id": "r1", "agent_type": "code-reviewer"]), at: 9)
        #expect(office.text(selected: office.main, at: 30) == "a-sdn-portal · 메인 서브에게 위임")
        #expect(office.text(at: 30) == "방금: a-sdn-portal · 서브가 메인에게 보고 · 서브가 auth.ts 편집 · 메인이 서브에게 위임")
    }

    @Test("고른 사람이 아직 아무것도 안 했으면 지금 상태")
    func noHistory() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.text(selected: office.main) == "a-sdn-portal · 메인 생각 중")
        #expect(office.line(selected: office.main).segments.first?.tone == .muted)
    }

    // MARK: - 표시 수준

    @Test("요약·비공개면 파일명과 명령을 숨기고 도구 종류만", arguments: [PrivacyLevel.summary, .hidden])
    func privacy(_ level: PrivacyLevel) {
        let office = working()
        #expect(office.text(level, selected: office.main, at: 32) == "a-sdn-portal · 메인 Read 3개 → Edit → Bash (12초째)")
        let feed = office.text(level, at: 32)
        #expect(feed == "방금: a-sdn-portal · 메인이 명령 실행 (12초째) · 메인이 파일 편집 · 메인이 파일 3개 읽음")
        for secret in ["auth.ts", "npm", "a.ts"] {
            #expect(!office.text(level, selected: office.main).contains(secret))
            #expect(!feed.contains(secret))
        }
    }

    @Test("요약이면 승인 대기와 실패에도 대상 없이 도구 이름만")
    func privacyTones() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "deploy.sh --prod"]))
        office.send(hook.tool("PostToolUseFailure", "Bash", id: "b1", input: ["command": "deploy.sh --prod"], extra: [("error", "x")]))
        office.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "deploy.sh --force"]))
        #expect(office.text(.summary, selected: office.main, at: 3) == "a-sdn-portal · 메인 Bash 실패 → Bash 승인 대기")
        #expect(office.text(.summary, at: 3) == "방금: a-sdn-portal · 메인이 Bash 승인 기다림 · 메인의 Bash 실패")
        #expect(office.text(.detailed, at: 3) == "방금: a-sdn-portal · 메인이 deploy.sh --force 승인 기다림 · 메인의 deploy.sh --prod 실패")
    }

    // MARK: - 아무도 안 골랐을 때

    @Test("사무실 줄: 새 일부터, 같은 사람의 같은 일은 묶음")
    func officeFeed() {
        let office = working()
        let line = office.line()
        #expect(line.mode == .office)
        #expect(office.text(at: 32) == "방금: a-sdn-portal · 메인이 npm test 실행 (12초째) · 메인이 auth.ts 편집 · 메인이 파일 3개 읽음")
    }

    @Test("사무실 줄은 최근 일 몇 개만 보이고 뒤를 자른다")
    func officeTruncation() {
        var office = Office()
        for (index, tool) in ["Read", "Edit", "Bash", "WebSearch", "TodoWrite", "Write"].enumerated() {
            office.send(hook.tool("PreToolUse", tool, id: "t\(index)", input: [:]))
            office.send(hook.tool("PostToolUse", tool, id: "t\(index)", input: [:], extra: [("tool_response", [:])]))
        }
        office.send(hook.tool("PreToolUse", "Grep", id: "g", input: [:]))
        let line = office.line()
        #expect(line.segments.count == StatusLine.maxOfficeSegments)
        #expect(line.truncated)
        #expect(office.text().hasSuffix(" …"))
        #expect(line.segments.first?.text == "메인이 파일 읽음")
    }

    @Test("조용하면 모두 쉬는 중, 직원이 없으면 안내")
    func quiet() {
        var office = Office()
        #expect(office.text() == "아직 출근한 직원이 없어요")
        #expect(office.line().head == nil)
        for payload in read("r1", "a.ts") { office.send(payload) }
        office.send(hook.make("Stop"))
        #expect(office.text() == "모두 쉬는 중이에요")
        #expect(office.line().segments.first?.tone == .muted)
    }

    @Test("기록 없이 생각만 하는 중이면 지금 상태")
    func thinkingOnly() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.text() == "지금: a-sdn-portal · 메인 생각 중")
    }

    @Test("디렉토리 필터: 고른 디렉토리 사람들의 일만")
    func folderFilter() {
        var office = Office()
        let other = Hook(session: "s2", cwd: "/Users/demo/work/claude-office")
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"]))
        office.send(other.tool("PreToolUse", "Bash", id: "b1", input: ["command": "make test"]))
        #expect(office.text(at: 3) == "방금: claude-office · 메인2가 make test 실행 (1초째) · a-sdn-portal · 메인1이 auth.ts 편집 (2초째)")
        #expect(office.text(folder: "/Users/demo/work/a-sdn-portal", at: 3) == "방금: 메인1이 auth.ts 편집 (2초째)")
        #expect(office.text(folder: "/Users/demo/work/claude-office", at: 3) == "방금: 메인2가 make test 실행 (1초째)")
        #expect(office.text(folder: "/Users/demo/work/없는-폴더") == "고른 디렉토리에 출근한 직원이 없어요")

        // 다른 디렉토리 사람만 일하면 고른 디렉토리는 쉬는 중
        office.send(hook.make("Stop"))
        #expect(office.text(folder: "/Users/demo/work/a-sdn-portal") == "모두 쉬는 중이에요")
        #expect(office.text(folder: "/Users/demo/work/claude-office", at: 4) == "방금: 메인2가 make test 실행 (2초째)")
    }

    // MARK: - 디렉토리 표시 (M5(7a))

    @Test("모두: 디렉토리가 바뀌는 항목마다 폴더 이름과 행 색, 같은 디렉토리가 이어지면 한 번만")
    func folderLabels() {
        var office = Office()
        let other = Hook(session: "s2", cwd: "/Users/demo/work/claude-office")
        office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"]))
        office.send(hook.tool("PostToolUse", "Edit", id: "e1", input: ["file_path": "/w/auth.ts"], extra: [("tool_response", [:])]))
        office.send(other.tool("PreToolUse", "Grep", id: "g1", input: ["pattern": "TODO"]))
        office.send(other.tool("PostToolUse", "Grep", id: "g1", input: ["pattern": "TODO"], extra: [("tool_response", [:])]))
        office.send(other.tool("PreToolUse", "Bash", id: "b1", input: ["command": "make test"]))
        let line = office.line()
        #expect(line.segments.map(\.folder) == ["claude-office", nil, "a-sdn-portal"])
        let teams = office.engine.state.teams.values
        let color = { (name: String) in teams.first { $0.name == name }?.colorIndex }
        #expect(line.segments.map(\.colorIndex) == [color("claude-office"), nil, color("a-sdn-portal")])
        #expect(office.text(at: 6) == "방금: claude-office · 메인2가 make test 실행 (1초째) · 메인2가 \"TODO\" 읽음 · a-sdn-portal · 메인1이 auth.ts 편집")
        // 디렉토리를 하나 고르면 드롭다운에 이미 보이므로 붙이지 않습니다
        #expect(office.line(folder: "/Users/demo/work/claude-office").segments.allSatisfy { $0.folder == nil && $0.colorIndex == nil })
    }

    @Test("고른 사람 줄: 모두면 맨 앞에 디렉토리, 디렉토리를 골랐으면 직함만")
    func agentFolder() {
        let office = working()
        let line = office.line(selected: office.main)
        #expect(line.folder == "a-sdn-portal")
        #expect(line.segments.allSatisfy { $0.folder == nil })
        #expect(office.text(selected: office.main, folder: "/Users/demo/work/a-sdn-portal", at: 32) == "메인 Read 3개 → Edit auth.ts → Bash npm test (12초째)")
        #expect(office.line(selected: office.main, folder: "/Users/demo/work/a-sdn-portal").folder == nil)
    }

    @Test("디렉토리 이름은 표시 수준과 상관없이 보인다 (패널·드롭다운과 같음)", arguments: PrivacyLevel.allCases)
    func folderPrivacy(_ level: PrivacyLevel) {
        let office = working()
        #expect(office.text(level, at: 32).hasPrefix("방금: a-sdn-portal · "))
        #expect(office.line(level, selected: office.main).folder == "a-sdn-portal")
    }

    @Test("긴 디렉토리 이름은 줄인다")
    func longFolder() {
        var office = Office()
        let long = Hook(session: "s3", cwd: "/Users/demo/work/a-very-long-directory-name-here")
        office.send(long.tool("PreToolUse", "Bash", id: "b1", input: ["command": "ls"]))
        #expect(StatusLine.shortFolder("a-very-long-directory-name-here") == "a-very-long-dir…")
        #expect(StatusLine.shortFolder("a-very-long-dir…").count == StatusLine.maxFolderLength)
        #expect(StatusLine.shortFolder("claude-office") == "claude-office")
        #expect(office.line().segments.first?.folder == "a-very-long-dir…")
        let main = office.engine.state.lead(of: SessionID("s3"))!.id
        #expect(office.text(selected: main, at: 2) == "a-very-long-dir… · 메인 Bash ls (1초째)")
    }

    @Test("퇴근한 사람의 일은 기록할 때 폴더 이름으로 (색 없음)")
    func leftFolder() throws {
        var office = Office()
        let other = Hook(session: "s2", cwd: "/Users/demo/work/claude-office")
        office.send(hook.tool("PreToolUse", "Bash", id: "b0", input: ["command": "make"]))
        office.send(other.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/x.ts"]))
        office.send(other.tool("PostToolUse", "Edit", id: "e1", input: ["file_path": "/w/x.ts"], extra: [("tool_response", [:])]))
        office.send(other.make("SessionEnd", ["reason": "exit"]))
        let line = office.line()
        let left = try #require(line.segments.first { $0.folder == "claude-office" })
        #expect(left.colorIndex == nil)
    }

    @Test("고른 사람이 퇴근하면 사무실 줄로")
    func selectedLeft() {
        var office = Office()
        for payload in read("r1", "a.ts") { office.send(payload) }
        let main = office.main
        office.send(hook.make("SessionEnd", ["reason": "exit"]))
        #expect(office.line(selected: main).mode == .office)
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
}
