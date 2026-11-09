import Foundation
import Testing

@testable import OfficeCore

/// M6(5): MCP 도구 이름이 보이는 모든 곳이 `MCPNames` 한 곳의 말을 씁니다.
@Suite("MCP 도구 이름")
struct MCPNamesTests {
    let hook = Hook()
    let lead = AgentID("lead-1")

    // MARK: - 사전

    @Test("전체 이름: 상세면 종류 + 동작, 요약·비공개면 종류만", arguments: [
        ("mcp__ccd_turn__update_plan", "할 일 목록 정리", "할 일 목록 정리"),
        ("mcp__ccd_turn__wrap_up", "마무리 요약", "마무리 요약"),
        ("mcp__ccd_session_mgmt__list_events", "세션 소식 보기", "세션 소식 보기"),
        ("mcp__ccd_session_mgmt__set_session_model", "세션 관리 set session model", "세션 관리"),
        ("mcp__ccd_view__show_pane", "패널 열기", "패널 열기"),
        ("mcp__Claude_Browser__navigate", "브라우저 페이지 이동", "브라우저"),
        ("mcp__Claude_Browser__read_page", "브라우저 페이지 읽기", "브라우저"),
        ("mcp__Claude_Browser__computer", "브라우저 클릭·입력", "브라우저"),
        ("mcp__claude-in-chrome__tabs_context_mcp", "Chrome 탭 목록", "Chrome"),
        ("mcp__computer-use__app_screenshot", "화면 조작 화면 보기", "화면 조작"),
        ("mcp__terminal__read_terminal", "터미널 읽기", "터미널"),
        ("mcp__scheduled-tasks__create_scheduled_task", "예약 작업 만들기", "예약 작업"),
        ("mcp__claude_ai_Claude_Docs__batch", "문서 고치기", "문서"),
        ("mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__guide", "문서 안내 읽기", "문서"),
        // 모르는 커넥터(UUID)는 "커넥터", 모르는 서버는 상세에서만 서버 이름
        ("mcp__0b5e7d21-9f3c-4c2a-8e11-7a0c3d9e4f52__create_issue", "커넥터 create issue", "커넥터"),
        ("mcp__my_server__create_issue", "my server create issue", "MCP"),
        ("mcp__plugin_context7_context7__query-docs", "context7 query docs", "MCP"),
        ("mcp__claude_ai_Gmail__search_threads", "Gmail search threads", "MCP"),
    ])
    func text(_ name: String, _ detailed: String, _ brief: String) {
        #expect(MCPNames.text(name, detailed: true) == detailed)
        #expect(MCPNames.text(name, detailed: false) == brief)
        #expect(!detailed.contains("_") && !detailed.contains("mcp"))
    }

    @Test("UUID처럼 생긴 서버만 커넥터로 본다")
    func connectorID() {
        #expect(MCPNames.isConnectorID("1a59c906-04da-521d-bda7-7f71b9f9e01c"))
        #expect(MCPNames.isConnectorID("1a59c906-04da"))
        #expect(!MCPNames.isConnectorID("computer-use"))
        #expect(!MCPNames.isConnectorID("deadbeef"))
        #expect(!MCPNames.isConnectorID("cafe-babe-dead"))  // 숫자가 없으면 낱말로 봄
    }

    @Test("좁은 곳(칩)은 긴 서버 이름과 동작을 자른다")
    func short() {
        #expect(MCPNames.short("mcp__Claude_Browser__navigate", detailed: true) == "브라우저 페이지 이동")
        let long = MCPNames.short("mcp__very_long_internal_server_name__do_a_very_long_operation_now", detailed: true)
        #expect(long == "very long int… do a very lon…")
        #expect(MCPNames.short("mcp__very_long_internal_server_name__x", detailed: false) == "MCP")
    }

    @Test("요약 칩: 한 동작인 말은 그대로, 서버는 \"… 사용 중\", 모르면 nil")
    func summary() {
        #expect(MCPNames.summary("mcp__ccd_turn__update_plan") == "할 일 목록 정리")
        #expect(MCPNames.summary("mcp__Claude_Browser__navigate") == "브라우저 사용 중")
        #expect(MCPNames.summary("mcp__0b5e7d21-9f3c__x") == "커넥터 사용 중")
        #expect(MCPNames.summary("mcp__my_server__x") == nil)
    }

    // MARK: - 화면마다

    @Test("머리 위 칩: 상세는 사전의 말, 요약은 요약 말, 비공개는 없음", arguments: PrivacyLevel.allCases)
    func pill(_ level: PrivacyLevel) {
        var h = EngineHarness(privacy: level)
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "mcp__Claude_Browser__navigate", id: "n", input: ["url": "https://x.dev"]), at: 1)
        let pills: [StatusPill] = h.actions(of: lead).compactMap { if case .status(let pill?) = $0 { pill } else { nil } }
        switch level {
        case .detailed: #expect(pills.map(\.text) == ["브라우저 페이지 이동"])
        case .summary: #expect(pills.map(\.text) == ["브라우저 사용 중"])
        case .hidden: #expect(pills.isEmpty)
        }
        // 설정을 요약으로 바꿔 그릴 때 쓰는 말
        if level != .hidden { #expect(pills.map(\.summary) == ["브라우저 사용 중"]) }
    }

    @Test("모르는 MCP 칩의 요약은 종류 말 \"도구 사용 중\"")
    func unknownPillSummary() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "mcp__my_server__create_issue", id: "n", input: [:]), at: 1)
        let pill = h.actions(of: lead).compactMap { if case .status(let pill?) = $0 { pill } else { nil } }.last
        #expect(pill?.text == "my server create issue")
        #expect(pill?.summary == "도구 사용 중")
    }

    @Test("승인 대기 말풍선: 동작인 말은 \"~ 해도 될까요?\", 서버는 \"~ 써도 될까요?\"", arguments: [
        ("mcp__ccd_session__start_session", "새 세션 시작 해도"),
        ("mcp__computer-use__app_click", "화면 조작 써도"),
        ("mcp__Claude_Browser__navigate", "브라우저 써도"),
        ("mcp__0b5e7d21-9f3c-4c2a-8e11-7a0c3d9e4f52__create_issue", "커넥터 써도"),
        ("mcp__my_server__create_issue", "my server 써도"),
    ])
    func permissionBubble(_ name: String, _ start: String) {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        let asked = h.send(hook.tool("PermissionRequest", name, id: nil, input: [:]), at: 1)
        let shout = asked.bubbles.first { $0.kind == .shout }
        #expect(shout?.text.hasPrefix(start) == true, "\(shout?.text ?? "nil")")
        #expect(shout?.text.contains("mcp") == false)
        #expect(shout?.text.contains("_") == false)
    }

    @Test("승인 대기 말풍선: 요약이면 도구 이름 없이")
    func permissionBubbleSummary() {
        var h = EngineHarness(privacy: .summary)
        h.send(hook.make("SessionStart"))
        let asked = h.send(hook.tool("PermissionRequest", "mcp__Claude_Browser__navigate", id: nil, input: [:]), at: 1)
        let text = asked.bubbles.first { $0.kind == .shout }?.text ?? ""
        #expect(["이거 해도 될까요?", "승인 부탁드려요!"].contains(text))
    }

    @Test("직원 패널·인스펙터·메뉴의 상세 줄 (Roster.detail)")
    func rosterDetail() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "mcp__terminal__read_terminal", id: "t", input: [:]), at: 1)
        #expect(Roster.make(from: h.engine.state, privacy: .detailed).teams.first?.rows.first?.detail == "터미널 읽기")
        #expect(Roster.make(from: h.engine.state, privacy: .summary).teams.first?.rows.first?.detail == nil)
        h.send(hook.tool("PermissionRequest", "mcp__ccd_view__show_pane", id: nil, input: [:]), at: 2)
        #expect(Roster.make(from: h.engine.state, privacy: .detailed).teams.first?.rows.first?.detail == "패널 열기")
    }

    @Test("승인 알림 본문", arguments: PrivacyLevel.allCases)
    func notice(_ level: PrivacyLevel) throws {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PermissionRequest", "mcp__Claude_Browser__navigate", id: nil, input: [:]), at: 1)
        let agent = try #require(h.engine.state.agents[lead])
        guard case .waitingForPermission(let call) = agent.activity else { Issue.record("\(agent.activity)"); return }
        let notice = NotificationPlanner.permissionNotice(
            id: "x", agent: agent, call: call, state: h.engine.state, privacy: level, isUpdate: false)
        #expect(notice.body == (level == .detailed ? "브라우저 페이지 이동 · 승인이 필요해요" : "브라우저 · 승인이 필요해요"))
    }
}
