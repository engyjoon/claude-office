import Foundation
import Testing

@testable import OfficeCore

@Suite("인스펙터 최근 일 타임라인")
struct AgentTimelineTests {
    let hook = Hook()
    let reviewer = (id: "r1", type: "code-reviewer")

    struct Office {
        var engine = OfficeEngine(seed: 7)
        var clock = 0.0

        mutating func send(_ payload: JSONValue, at seconds: Double? = nil) {
            clock = seconds ?? clock + 1
            let event = HookParser.parse(payload, term: "iTerm.app", receivedAt: Fixture.epoch.addingTimeInterval(clock))!
            _ = engine.handle(event)
        }

        func timeline(_ agent: AgentID, _ privacy: PrivacyLevel = .detailed, limit: Int = AgentTimeline.maxItems) -> AgentTimeline {
            AgentTimeline.make(agent: agent, state: engine.state, journal: engine.journal, privacy: privacy, limit: limit)
        }

        func lines(_ agent: AgentID, _ privacy: PrivacyLevel = .detailed, at seconds: Double) -> [String] {
            timeline(agent, privacy).items.map { $0.text(now: Fixture.epoch.addingTimeInterval(seconds)) }
        }

        var main: AgentID { engine.state.lead(of: SessionID("s1"))!.id }
    }

    func done(_ tool: String, _ id: String, _ input: JSONValue, agent: (id: String, type: String)? = nil, at: Double? = nil) -> [JSONValue] {
        [
            hook.tool("PreToolUse", tool, id: id, input: input, agent: agent),
            hook.tool("PostToolUse", tool, id: id, input: input, agent: agent, extra: [("tool_response", [:])]),
        ]
    }

    /// 1~6초 Read 3개(시작 1·3·5초), 7~8초 Edit auth.ts, 20초 Bash npm test 시작
    func working() -> Office {
        var office = Office()
        for (n, file) in ["a.ts", "b.ts", "c.ts"].enumerated() {
            for payload in done("Read", "r\(n)", ["file_path": .string("/w/\(file)")]) { office.send(payload) }
        }
        for payload in done("Edit", "e1", ["file_path": "/w/src/auth.ts"]) { office.send(payload) }
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]), at: 20)
        return office
    }

    @Test("시간 순서대로, 같은 도구는 묶고, 줄마다 언제 했는지")
    func chronological() {
        let office = working()
        #expect(office.lines(office.main, at: 32) == [
            "27초 전 · Read 3개",
            "25초 전 · Edit auth.ts",
            "지금 · Bash npm test (12초째)",
        ])
        let timeline = office.timeline(office.main)
        #expect(timeline.hasRunning)
        #expect(!timeline.truncated)
        #expect(timeline.items.map(\.count) == [3, 1, 1])
        // 묶음의 때는 마지막 기록을 시작한 때 (5초)
        #expect(timeline.items[0].at == Fixture.epoch.addingTimeInterval(5))
    }

    @Test("현황 줄과 같은 묶기·같은 말을 쓴다")
    func matchesStatusLine() {
        let office = working()
        let line = StatusLine.make(
            state: office.engine.state, journal: office.engine.journal, privacy: .detailed, selected: office.main, folder: nil)
        #expect(office.timeline(office.main).items.map(\.text) == line.segments.map(\.text))
    }

    @Test("최근 것만 남기고 더 오래된 일이 있으면 잘렸다고 알림")
    func limit() {
        var office = Office()
        let tools = ["Read", "Grep", "Glob", "Edit", "Bash", "WebSearch", "TodoWrite", "Write"]
        for round in 0..<3 {
            for (index, tool) in tools.enumerated() {
                for payload in done(tool, "t\(round)-\(index)", [:]) { office.send(payload) }
            }
        }
        let timeline = office.timeline(office.main)
        #expect(timeline.items.count == AgentTimeline.maxItems)
        #expect(timeline.truncated)
        #expect(timeline.items.last?.text == "Write")
        #expect(timeline.items.first?.text == tools[(24 - AgentTimeline.maxItems) % tools.count])
        // 시간 순서
        #expect(timeline.items.map(\.at) == timeline.items.map(\.at).sorted())

        let short = office.timeline(office.main, limit: 3)
        #expect(short.items.map(\.text) == ["WebSearch", "TodoWrite", "Write"])
        #expect(short.truncated)
    }

    @Test("승인 대기는 노랑, 실패·거부는 빨강")
    func tones() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm test"]))
        office.send(hook.tool("PostToolUseFailure", "Bash", id: "b1", input: ["command": "npm test"], extra: [("error", "exit 1")]))
        office.send(hook.tool("PreToolUse", "Bash", id: "b2", input: ["command": "rm -rf build"]))
        office.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm -rf build"]), at: 10)
        var timeline = office.timeline(office.main)
        #expect(timeline.items.map(\.tone) == [.error, .attention])
        #expect(office.lines(office.main, at: 15) == ["14초 전 · Bash npm test 실패", "지금 · Bash rm -rf build 승인 대기 (5초째)"])

        office.send(hook.tool("PermissionDenied", "Bash", id: "b2", input: ["command": "rm -rf build"]), at: 12)
        timeline = office.timeline(office.main)
        #expect(timeline.items.map(\.tone) == [.error, .error])
        #expect(!timeline.hasRunning)
        #expect(office.lines(office.main, at: 72)[1] == "1분 전 · Bash rm -rf build 거부됨")
    }

    @Test("요약·비공개면 파일명과 명령을 숨긴다", arguments: [PrivacyLevel.summary, .hidden])
    func privacy(_ level: PrivacyLevel) {
        let office = working()
        let lines = office.lines(office.main, level, at: 32)
        #expect(lines == ["27초 전 · Read 3개", "25초 전 · Edit", "지금 · Bash (12초째)"])
        for secret in ["auth.ts", "npm", "a.ts"] {
            #expect(!lines.joined().contains(secret))
        }
    }

    @Test("서브는 자기 기록만, 위임·보고 줄도 남는다")
    func subagent() throws {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "리뷰", "subagent_type": "code-reviewer"]))
        office.send(hook.make("SubagentStart", ["agent_id": "r1", "agent_type": "code-reviewer"]))
        for payload in done("Edit", "e1", ["file_path": "/w/auth.ts"], agent: reviewer) { office.send(payload) }
        let sub = try #require(office.engine.state.member(subagentID: "r1", in: SessionID("s1"))).id
        office.send(hook.make("SubagentStop", ["agent_id": "r1", "agent_type": "code-reviewer"]), at: 9)

        #expect(office.lines(sub, at: 9) == ["6초 전 · Edit auth.ts", "방금 · 메인에게 보고"])
        #expect(office.timeline(office.main).items.map(\.text) == ["서브에게 위임"])
        // 에이전트 종류·맡긴 일은 타임라인에 쓰지 않습니다
        #expect(!office.lines(sub, at: 9).joined().contains("code-reviewer"))
    }

    @Test("기록이 없으면 비어 있다 (화면이 안내 문구)")
    func empty() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "안녕"]))
        #expect(office.timeline(office.main).items.isEmpty)
        #expect(AgentTimeline.make(agent: AgentID("없음"), state: office.engine.state, journal: office.engine.journal, privacy: .detailed) == .empty)
    }

    @Test("상대 시간 문구")
    func ago() {
        #expect(AgentTimeline.ago(-3) == "방금")
        #expect(AgentTimeline.ago(4.9) == "방금")
        #expect(AgentTimeline.ago(12) == "12초 전")
        #expect(AgentTimeline.ago(60) == "1분 전")
        #expect(AgentTimeline.ago(3599) == "59분 전")
        #expect(AgentTimeline.ago(7200) == "2시간 전")
        #expect(AgentTimeline.ago(86400 * 3 + 5) == "3일 전")
    }
}
