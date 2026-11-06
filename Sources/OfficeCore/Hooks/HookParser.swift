import Foundation

/// Claude Code 훅 페이로드(JSON)를 `OfficeEvent`로 바꿉니다.
///
/// 버전마다 필드가 다를 수 있으므로 관대하게 읽습니다.
/// - 필수 필드는 `session_id`와 `hook_event_name` 두 개뿐입니다.
/// - 모르는 이벤트, 화면에 쓸모없는 이벤트는 `nil`을 돌려줍니다 (무시).
/// - 프롬프트 내용, 파일 내용, 명령 출력은 읽지 않습니다.
public enum HookParser {
    public static func parse(_ data: Data, term: String? = nil, receivedAt: Date) throws -> OfficeEvent? {
        parse(try JSONValue.parse(data), term: term, receivedAt: receivedAt)
    }

    public static func parse(_ payload: JSONValue, term: String? = nil, receivedAt: Date) -> OfficeEvent? {
        guard let sessionRaw = payload["session_id"]?.stringValue, !sessionRaw.isEmpty,
            let eventName = payload["hook_event_name"]?.stringValue
        else { return nil }

        guard let kind = kind(for: eventName, payload: payload) else { return nil }

        // SubagentStart/Stop의 agent_id는 "그 서브에이전트 자신"이고, 그 밖의 이벤트에서 agent_id는
        // "이 훅이 어느 서브에이전트 안에서 발생했는지"를 뜻합니다.
        var context: SubagentRef?
        switch kind {
        case .subagentStarted, .subagentStopped:
            context = nil
        default:
            if let agentID = payload["agent_id"]?.stringValue, !agentID.isEmpty {
                context = SubagentRef(id: agentID, type: payload["agent_type"]?.stringValue)
            }
        }

        let trimmedTerm = term?.trimmingCharacters(in: .whitespaces)
        return OfficeEvent(
            session: SessionID(sessionRaw),
            cwd: payload["cwd"]?.stringValue,
            subagent: context,
            term: (trimmedTerm?.isEmpty ?? true) || trimmedTerm == "unknown" ? nil : trimmedTerm,
            at: receivedAt,
            kind: kind
        )
    }

    static func kind(for eventName: String, payload: JSONValue) -> OfficeEvent.Kind? {
        switch eventName {
        case "SessionStart":
            return .sessionStarted(source: payload["source"]?.stringValue)
        case "SessionEnd":
            return .sessionEnded(reason: payload["reason"]?.stringValue)
        case "UserPromptSubmit":
            return .promptSubmitted
        case "PreToolUse":
            guard let call = toolCall(payload) else { return nil }
            if call.category == .delegate {
                return .delegationStarted(call, subagentType: payload["tool_input"]?["subagent_type"]?.stringValue)
            }
            return .toolStarted(call)
        case "PostToolUse":
            guard let call = toolCall(payload) else { return nil }
            let outcome = outcome(fromResponse: payload["tool_response"])
            return call.category == .delegate ? .delegationFinished(call, outcome) : .toolFinished(call, outcome)
        case "PostToolUseFailure":
            guard let call = toolCall(payload) else { return nil }
            let outcome: ToolOutcome =
                payload["is_interrupt"]?.boolValue == true
                ? .interrupted
                : .failure(payload["error"]?.stringValue.map { ToolCatalog.truncate(Redactor.redact($0), 80) })
            return call.category == .delegate ? .delegationFinished(call, outcome) : .toolFinished(call, outcome)
        case "PermissionRequest":
            return .permissionRequested(toolCall(payload))
        case "PermissionDenied":
            return .permissionDenied(toolCall(payload))
        case "Notification":
            return notificationKind(payload)
        case "Stop":
            return .turnEnded(failed: false)
        case "StopFailure":
            return .turnEnded(failed: true)
        case "SubagentStart":
            guard let ref = subagentRef(payload) else { return nil }
            return .subagentStarted(ref)
        case "SubagentStop":
            guard let ref = subagentRef(payload) else { return nil }
            return .subagentStopped(ref)
        case "PreCompact":
            return .compacting
        default:
            return nil
        }
    }

    static func toolCall(_ payload: JSONValue) -> ToolCall? {
        guard let name = payload["tool_name"]?.stringValue, !name.isEmpty else { return nil }
        return ToolCatalog.makeCall(name: name, input: payload["tool_input"], id: payload["tool_use_id"]?.stringValue)
    }

    static func subagentRef(_ payload: JSONValue) -> SubagentRef? {
        guard let id = payload["agent_id"]?.stringValue, !id.isEmpty else { return nil }
        return SubagentRef(id: id, type: payload["agent_type"]?.stringValue)
    }

    static func outcome(fromResponse response: JSONValue?) -> ToolOutcome {
        guard let response else { return .success }
        if response["interrupted"]?.boolValue == true { return .interrupted }
        if response["is_error"]?.boolValue == true || response["isError"]?.boolValue == true {
            return .failure(nil)
        }
        return .success
    }

    static func notificationKind(_ payload: JSONValue) -> OfficeEvent.Kind? {
        switch payload["notification_type"]?.stringValue {
        case "permission_prompt":
            return .permissionRequested(nil)
        case "idle_prompt":
            return .waitingForInput
        case .some:
            return nil  // auth_success, elicitation_dialog 등은 사무실 연출과 무관
        case .none:
            // notification_type이 없던 구버전: 메시지로 추정
            let message = payload["message"]?.stringValue?.lowercased() ?? ""
            if message.contains("permission") { return .permissionRequested(nil) }
            if message.contains("waiting for your input") { return .waitingForInput }
            return nil
        }
    }
}
