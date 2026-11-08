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
        if category == .mcp {
            // mcp__server__tool → "server · tool"
            let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
            return parts.count >= 2 ? "\(parts[0]) · \(parts[1...].joined(separator: "_"))" : parts.first
        }
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

/// MCP 도구 이름을 사람이 읽는 말로 (M5(9)). `mcp__ccd_turn__update_plan` → "할 일 목록 정리".
///
/// - 알려진 도구는 그 도구의 말, 알려진 서버는 서버의 말("브라우저") + 상세면 도구 이름("브라우저 navigate").
/// - 모르는 것은 도구 이름만 ("create_issue"). 요약·비공개에서는 모르는 도구의 이름 대신 "MCP".
public enum MCPNames {
    /// 알려진 도구 ("서버__도구")
    static let tools: [String: String] = [
        "ccd_turn__update_plan": "할 일 목록 정리",
        "ccd_turn__wrap_up": "마무리 요약",
        "ccd_session__start_session": "새 세션 시작",
        "ccd_session__hand_off_to_session": "세션 넘기기",
        "ccd_session__mark_chapter": "단원 나누기",
        "ccd_session__dismiss_task": "제안 거두기",
        "ccd_session__read_widget_context": "위젯 읽기",
        "visualize__show_widget": "그림 그리기",
        "visualize__read_me": "그림 안내 읽기",
    ]

    /// 알려진 서버
    static let servers: [String: String] = [
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
        "github": "GitHub",
        "slack": "Slack",
        "linear": "Linear",
        "notion": "Notion",
    ]

    /// "mcp__server__tool" → ("server", "tool"). 서버 이름 다음 첫 "__"에서 나눕니다.
    public static func split(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return (String(rest), "") }
        return (String(rest[..<range.lowerBound]), String(rest[range.upperBound...]))
    }

    /// 도구 종류 이름 (묶는 기준): "할 일 목록 정리", "브라우저", "create_issue" / 모르는 도구는 요약·비공개면 "MCP"
    public static func label(_ name: String, detailed: Bool) -> String {
        guard let (server, tool) = split(name) else { return name }
        if let known = tools["\(server)__\(tool)"] { return known }
        if let known = servers[server] { return known }
        return detailed && !tool.isEmpty ? tool : "MCP"
    }

    /// 상세일 때 종류 이름 뒤에 붙일 말: 서버만 아는 도구의 이름 ("브라우저" + "navigate")
    public static func detail(_ name: String) -> String? {
        guard let (server, tool) = split(name), tools["\(server)__\(tool)"] == nil, servers[server] != nil, !tool.isEmpty else { return nil }
        return tool
    }
}
