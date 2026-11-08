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
        return truncate(collapsed, 40)
    }

    static func host(_ url: String) -> String {
        if let host = URL(string: url)?.host { return host }
        return truncate(url, 28)
    }

    public static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
