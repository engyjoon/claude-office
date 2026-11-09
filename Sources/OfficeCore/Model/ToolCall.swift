import Foundation

public enum ToolCategory: String, Hashable, Sendable, CaseIterable {
    case read, write, shell, web, plan, delegate, mcp, other
    /// 서브에이전트가 결과를 팀장에게 넘기는 중 (`SubagentHandback`, M0에서 확인)
    case report

    /// 요약 표시 수준에서 쓰는 이름
    public var summaryLabel: String {
        switch self {
        case .read: "파일 읽는 중"
        case .write: "파일 편집 중"
        case .shell: "명령 실행 중"
        case .web: "웹 검색 중"
        case .plan: "계획 정리 중"
        case .delegate: "일 맡기는 중"
        case .report: "보고 정리 중"
        case .mcp, .other: "도구 사용 중"
        }
    }
}

public struct ToolCall: Hashable, Sendable {
    /// `tool_use_id`. PermissionRequest처럼 없는 경우도 있습니다.
    public var id: String?
    public var name: String
    public var category: ToolCategory
    /// 화면에 보여줄 대상 (파일명, 명령어 앞부분, 검색어 등). 민감 정보는 이미 가려져 있습니다.
    public var subject: String?
    /// `Agent` 툴의 `run_in_background`
    public var runsInBackground: Bool

    public init(id: String?, name: String, category: ToolCategory, subject: String?, runsInBackground: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.subject = subject
        self.runsInBackground = runsInBackground
    }

    /// 내 답을 기다리는 툴 (M5(4) 미니 사무실 v2): 질문(AskUserQuestion)과 계획 승인(ExitPlanMode).
    /// 시작하는 순간부터 끝날 때까지 승인 대기와 같은 "답변 필요" 상태로 봅니다.
    public static let answerTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    public var asksUser: Bool { Self.answerTools.contains(name) }

    /// 기다리는 까닭: "질문 답 대기", "계획 승인 대기", 그 밖에는 "승인 대기"
    public var waitLabel: String {
        switch name {
        case "AskUserQuestion": "질문 답 대기"
        case "ExitPlanMode": "계획 승인 대기"
        default: "승인 대기"
        }
    }

    /// 알림 본문·말 끝: "질문에 답해 주세요", "계획을 확인해 주세요", "승인이 필요해요"
    public var waitRequest: String {
        switch name {
        case "AskUserQuestion": "질문에 답해 주세요"
        case "ExitPlanMode": "계획을 확인해 주세요"
        default: "승인이 필요해요"
        }
    }
}

/// 툴 이름으로 분류하고, 입력에서 보여줄 대상을 뽑아냅니다.
public enum ToolCatalog {
    public static let delegateTools: Set<String> = ["Agent", "Task"]

    static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "LSP", "Search"]
    static let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let shellTools: Set<String> = ["Bash", "BashOutput", "KillShell", "KillBash", "PowerShell", "Monitor"]
    static let webTools: Set<String> = ["WebSearch", "WebFetch"]
    static let planTools: Set<String> = ["TodoWrite", "ExitPlanMode", "EnterPlanMode", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]

    public static func category(for name: String) -> ToolCategory {
        if delegateTools.contains(name) { return .delegate }
        if name == "SubagentHandback" { return .report }
        if readTools.contains(name) { return .read }
        if writeTools.contains(name) { return .write }
        if shellTools.contains(name) { return .shell }
        if webTools.contains(name) { return .web }
        if planTools.contains(name) { return .plan }
        if name.hasPrefix("mcp__") { return .mcp }
        return .other
    }

    public static func makeCall(name: String, input: JSONValue?, id: String?) -> ToolCall {
        let category = category(for: name)
        let subject = subject(name: name, category: category, input: input).map(Redactor.redact)
        let background = input?["run_in_background"]?.boolValue ?? false
        return ToolCall(id: id, name: name, category: category, subject: subject, runsInBackground: background)
    }

    static func subject(name: String, category: ToolCategory, input: JSONValue?) -> String? {
        // MCP는 도구 이름 자체가 대상을 말하므로 subject를 두지 않습니다. 화면 문구는 `MCPNames`가 만듭니다 (M6(5)).
        if category == .mcp { return nil }
        guard let input else { return nil }
        for key in ["file_path", "notebook_path"] {
            if let path = input[key]?.stringValue { return fileName(path) }
        }
        switch name {
        case "Grep", "Search":
            return input["pattern"]?.stringValue.map { "\"\(truncate($0, 22))\"" }
        case "Glob":
            return input["pattern"]?.stringValue.map { truncate($0, 28) }
        case "LS":
            return input["path"]?.stringValue.map(fileName)
        case "Bash", "PowerShell":
            return input["command"]?.stringValue.map(commandSummary)
        case "WebSearch":
            return input["query"]?.stringValue.map { truncate($0, 28) }
        case "WebFetch":
            return input["url"]?.stringValue.map(host)
        case "Agent", "Task":
            return (input["description"]?.stringValue ?? input["subagent_type"]?.stringValue).map { truncate($0, 40) }
        case "TodoWrite":
            return input["todos"]?.arrayValue.map { "할 일 \($0.count)개" }
        default:
            return nil
        }
    }

    static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func commandSummary(_ command: String) -> String {
        let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncate(shortenPaths(collapsed), 40)
    }

    /// 명령 안의 절대 경로를 마지막 폴더·파일 이름으로 줄입니다 (M5(9)):
    /// `cd /Users/me/work/claude-office` → `cd claude-office`, `open "/Applications/Claude Office.app"` → `open "Claude Office.app"`.
    /// URL(`https://…`)과 상대 경로는 그대로 둡니다.
    public static func shortenPaths(_ command: String) -> String {
        var result = command
        // 따옴표로 감싼 경로 (공백이 있을 수 있음)
        result = replace(quotedPath, in: result) { match, text in
            let quote = text[Range(match.range(at: 1), in: text)!]
            return quote + lastComponent(String(text[Range(match.range(at: 2), in: text)!])) + quote
        }
        // 맨 앞이나 공백·기호 뒤에서 시작하는 경로
        result = replace(barePath, in: result) { match, text in
            let path = String(text[Range(match.range, in: text)!])
            return path.hasPrefix("/dev/") ? path : lastComponent(path)  // 2>/dev/null은 그대로
        }
        return result
    }

    private static let quotedPath = try! NSRegularExpression(pattern: #"(["'])(~?/[^"'\n]*)\1"#)
    private static let barePath = try! NSRegularExpression(pattern: #"(?<![\w.:/~@$\-"'])~?/[^\s"'`;|&<>()]+"#)

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with make: (NSTextCheckingResult, String) -> String
    ) -> String {
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: make(match, text))
        }
        return result
    }

    /// "/Users/me/work/claude-office/" → "claude-office". "/"나 "~"처럼 이름이 없으면 그대로.
    private static func lastComponent(_ path: String) -> String {
        let name = fileName(path)
        return name.isEmpty || name == "~" ? path : name
    }

    static func host(_ url: String) -> String {
        if let host = URL(string: url)?.host { return host }
        return truncate(url, 28)
    }

    public static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// MCP 도구 이름을 사람이 읽는 말로 (M5(9), M6(5)에서 모든 화면으로). `mcp__ccd_turn__update_plan` → "할 일 목록 정리".
///
/// MCP 도구 이름이 화면에 나오는 곳(현황 줄·타임라인·알림·머리 위 칩·승인 말풍선·직원 패널·인스펙터·메뉴)은
/// 모두 이 사전을 거칩니다. `ToolCall.subject`에는 MCP 이름을 넣지 않습니다.
///
/// - 종류 이름(`label`, 묶는 기준): 알려진 도구면 그 말("할 일 목록 정리"), 알려진 서버면 서버의 말("브라우저"),
///   UUID처럼 생긴 서버는 "커넥터", 그 밖의 서버는 상세에서만 서버 이름을 읽기 좋게("my server"), 요약·비공개면 "MCP".
/// - 덧붙이는 말(`detail`, 상세에서만): 서버만 아는 도구의 동작("페이지 이동"). 사전에 없으면 도구 이름을 읽기 좋게("create issue").
/// - 전체(`text`): 종류 + 덧붙이는 말 ("브라우저 페이지 이동"). 칩처럼 좁은 곳은 `short`.
public enum MCPNames {
    /// 알려진 도구 ("서버__도구") → 그 자체로 한 동작인 말
    static let tools: [String: String] = [
        "ccd_turn__update_plan": "할 일 목록 정리",
        "ccd_turn__wrap_up": "마무리 요약",
        "ccd_session__start_session": "새 세션 시작",
        "ccd_session__hand_off_to_session": "세션 넘기기",
        "ccd_session__mark_chapter": "단원 나누기",
        "ccd_session__dismiss_task": "제안 거두기",
        "ccd_session__read_widget_context": "위젯 읽기",
        "ccd_session_mgmt__list_events": "세션 소식 보기",
        "ccd_session_mgmt__list_sessions": "세션 목록 보기",
        "ccd_session_mgmt__get_session": "세션 살펴보기",
        "ccd_session_mgmt__stop_session": "세션 멈추기",
        "ccd_session_mgmt__send_message": "세션에 메시지",
        "ccd_session_mgmt__search_session_transcripts": "세션 기록 찾기",
        "ccd_session_mgmt__export_transcript": "대화 내보내기",
        "ccd_session_mgmt__archive_session": "세션 보관",
        "ccd_session_mgmt__get_usage": "사용량 보기",
        "ccd_view__show_pane": "패널 열기",
        "ccd_view__close_pane": "패널 닫기",
        "ccd_view__get_layout": "화면 배치 보기",
        "ccd_view__set_transcript_view": "대화 보기 바꾸기",
        "ccd_pr__get_status": "PR 상태 보기",
        "ccd_pr__bind_pr": "PR 연결",
        "ccd_settings__get_settings": "설정 보기",
        "ccd_settings__set_setting": "설정 바꾸기",
        "visualize__show_widget": "그림 그리기",
        "visualize__read_me": "그림 안내 읽기",
        "mcp-registry__search_mcp_registry": "커넥터 찾기",
        "mcp-registry__list_connectors": "커넥터 목록 보기",
        "mcp-registry__suggest_connectors": "커넥터 추천",
    ]

    /// 알려진 서버
    static let servers: [String: String] = [
        "ccd_turn": "할 일 목록",
        "ccd_session": "세션",
        "ccd_session_mgmt": "세션 관리",
        "ccd_view": "화면 패널",
        "ccd_pr": "PR",
        "ccd_settings": "설정",
        "ccd_sidebar": "사이드바",
        "ccd_window": "창 배치",
        "ccd_host": "호스트",
        "ccd_directory": "폴더",
        "ccd_connectors": "커넥터",
        "Claude_Browser": "브라우저",
        "claude-in-chrome": "Chrome",
        "computer-use": "화면 조작",
        "terminal": "터미널",
        "visualize": "그림",
        "Claude_Code_iOS_Simulator": "iOS 시뮬레이터",
        "scheduled-tasks": "예약 작업",
        "mcp-registry": "커넥터 찾기",
        "claude-artifacts": "아티팩트",
        "claude_ai_Claude_Docs": "문서",
        // 이 맥의 데스크톱 앱에서 Docs 커넥터가 이 ID로 붙습니다 (도구: guide·batch·update …)
        "1a59c906-04da-521d-bda7-7f71b9f9e01c": "문서",
        "github": "GitHub",
        "slack": "Slack",
        "linear": "Linear",
        "notion": "Notion",
    ]

    static let browserActions: [String: String] = [
        "navigate": "페이지 이동", "read_page": "페이지 읽기", "get_page_text": "글 읽기", "computer": "클릭·입력",
        "find": "요소 찾기", "form_input": "입력란 채우기", "javascript_tool": "스크립트 실행", "browser_batch": "여러 동작",
        "preview_start": "미리보기 열기", "preview_stop": "미리보기 끄기", "preview_logs": "서버 로그 보기",
        "preview_list": "미리보기 목록", "resize_window": "창 크기 바꾸기", "tabs_create": "새 탭", "tabs_close": "탭 닫기",
        "tabs_select": "탭 고르기", "tabs_context": "탭 목록", "read_console_messages": "콘솔 보기",
        "read_network_requests": "네트워크 보기", "upload_image": "이미지 올리기", "file_upload": "파일 올리기",
        "gif_creator": "GIF 만들기", "list_connected_browsers": "브라우저 목록", "select_browser": "브라우저 고르기",
        "switch_browser": "브라우저 바꾸기",
    ]

    static let docsActions: [String: String] = [
        "guide": "안내 읽기", "batch": "고치기", "update": "고치기", "create": "만들기", "read": "읽기",
        "query": "찾아보기", "export": "내보내기", "delete": "지우기",
    ]

    /// 서버만 아는 도구의 동작 (서버 → 도구 → 말). claude-in-chrome의 "_mcp" 꼬리는 떼고 찾습니다.
    static let actions: [String: [String: String]] = [
        "Claude_Browser": browserActions,
        "claude-in-chrome": browserActions,
        "computer-use": [
            "app_screenshot": "화면 보기", "screenshot": "화면 보기", "app_click": "클릭", "left_click": "클릭",
            "app_type": "입력", "type": "입력", "app_key": "키 누르기", "key": "키 누르기", "app_scroll": "스크롤",
            "scroll": "스크롤", "app_batch": "여러 동작", "computer_batch": "여러 동작", "app_zoom": "확대해 보기",
            "zoom": "확대해 보기", "app_drag": "끌기", "app_menu": "메뉴 고르기", "app_focus": "앱 앞으로",
            "app_release": "앱 놓기", "app_list_windows": "창 목록", "app_ax_find": "요소 찾기",
            "app_bring_to_current_space": "앱 데려오기", "request_access": "권한 요청",
            "request_full_control": "전체 제어 요청", "release_full_control": "전체 제어 놓기", "list_apps": "앱 목록",
            "list_granted_applications": "허용한 앱 목록", "open_application": "앱 열기",
            "read_clipboard": "클립보드 읽기", "write_clipboard": "클립보드 쓰기", "switch_display": "화면 바꾸기",
            "request_teach_access": "안내 권한 요청", "teach_step": "안내하기", "teach_batch": "안내하기",
        ],
        "terminal": [
            "read_terminal": "읽기", "run_in_terminal": "명령 실행", "list_terminal_tabs": "탭 목록",
            "open_terminal_tab": "새 탭", "stop_terminal_tab": "탭 멈추기",
        ],
        "scheduled-tasks": [
            "create_scheduled_task": "만들기", "list_scheduled_tasks": "목록 보기", "update_scheduled_task": "고치기",
            "delete_scheduled_task": "지우기", "run_scheduled_task": "지금 실행", "list_task_runs": "실행 기록",
        ],
        "Claude_Code_iOS_Simulator": ["control": "조작", "build": "빌드"],
        "claude_ai_Claude_Docs": docsActions,
        "1a59c906-04da-521d-bda7-7f71b9f9e01c": docsActions,
    ]

    /// "mcp__server__tool" → ("server", "tool"). 서버 이름 다음 첫 "__"에서 나눕니다.
    public static func split(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return (String(rest), "") }
        return (String(rest[..<range.lowerBound]), String(rest[range.upperBound...]))
    }

    /// 도구 종류 이름 (묶는 기준): "할 일 목록 정리", "브라우저", "커넥터", "my server" / 모르는 서버는 요약·비공개면 "MCP"
    public static func label(_ name: String, detailed: Bool) -> String {
        guard let (server, tool) = split(name) else { return name }
        if let known = tools["\(server)__\(tool)"] { return known }
        if let known = servers[server] { return known }
        if isConnectorID(server) { return "커넥터" }
        guard detailed, let readable = readableServer(server) else { return "MCP" }
        return readable
    }

    /// 상세일 때 종류 이름 뒤에 붙일 말: "페이지 이동"(사전), "create issue"(도구 이름). 알려진 도구면 nil.
    public static func detail(_ name: String) -> String? {
        guard let (server, tool) = split(name), tools["\(server)__\(tool)"] == nil, !tool.isEmpty else { return nil }
        let bare = tool.hasSuffix("_mcp") ? String(tool.dropLast(4)) : tool
        if let word = actions[server]?[bare] { return word }
        let readable = words(bare)
        return readable.isEmpty ? nil : readable
    }

    /// 전체 이름: 상세면 "브라우저 페이지 이동", "my server create issue", 아니면 종류 이름만
    public static func text(_ name: String, detailed: Bool) -> String {
        let label = label(name, detailed: detailed)
        guard detailed, let detail = detail(name) else { return label }
        return "\(label) \(detail)"
    }

    /// 좁은 곳(머리 위 칩): `text`와 같되 모르는 서버 이름과 덧붙이는 말을 짧게 자릅니다
    public static func short(_ name: String, detailed: Bool) -> String {
        let label = ToolCatalog.truncate(label(name, detailed: detailed), 14)
        guard detailed, let detail = detail(name) else { return label }
        return "\(label) \(ToolCatalog.truncate(detail, 14))"
    }

    /// 사전에 있는 한 동작인 말인지 ("할 일 목록 정리") — 말풍선에서 "~ 해도 될까요?"로 씁니다
    public static func isAction(_ name: String) -> Bool {
        guard let (server, tool) = split(name) else { return false }
        return tools["\(server)__\(tool)"] != nil
    }

    /// 요약 칩: 한 동작인 말은 그대로, 알려진 서버·커넥터는 "브라우저 사용 중", 모르면 nil (→ "도구 사용 중")
    public static func summary(_ name: String) -> String? {
        let label = label(name, detailed: false)
        if isAction(name) { return label }
        return label == "MCP" ? nil : "\(label) 사용 중"
    }

    /// UUID처럼 생긴 서버 이름 (claude.ai 커넥터): 16진수와 "-"만, "-"가 있고 8자 넘음
    static func isConnectorID(_ server: String) -> Bool {
        server.count > 8 && server.contains("-") && server.contains(where: \.isNumber)
            && server.allSatisfy { $0 == "-" || $0.isHexDigit }
    }

    /// 모르는 서버 이름을 읽기 좋게: "claude_ai_"·"plugin_" 앞머리를 떼고 "_"·"-"를 띄어 쓰고, 이어서 겹친 낱말은 하나로.
    /// "plugin_context7_context7" → "context7", "claude_ai_Gmail" → "Gmail", "my-server" → "my server"
    static func readableServer(_ server: String) -> String? {
        var name = Substring(server)
        for prefix in ["claude_ai_", "plugin_"] where name.hasPrefix(prefix) { name = name.dropFirst(prefix.count) }
        var result: [Substring] = []
        for word in name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        where result.last?.lowercased() != word.lowercased() {
            result.append(word)
        }
        return result.isEmpty ? nil : result.joined(separator: " ")
    }

    /// 도구 이름을 읽기 좋게: "create_issue" → "create issue"
    static func words(_ tool: String) -> String {
        tool.split(whereSeparator: { $0 == "_" || $0 == "-" }).joined(separator: " ")
    }
}
