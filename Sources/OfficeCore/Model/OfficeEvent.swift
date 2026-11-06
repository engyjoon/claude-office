import Foundation

public struct SessionID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: SessionID, rhs: SessionID) -> Bool { lhs.raw < rhs.raw }
}

/// 서브에이전트 식별 정보. `agent_id`는 훅 페이로드의 값, `type`은 `agent_type` 또는 `subagent_type`입니다.
public struct SubagentRef: Hashable, Sendable {
    public let id: String
    public let type: String?
    public init(id: String, type: String?) {
        self.id = id
        self.type = type
    }
}

public enum ToolOutcome: Hashable, Sendable {
    case success
    case failure(String?)
    case interrupted

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// 훅 페이로드를 정규화한 이벤트. `HookParser`의 출력이자 `OfficeState`의 입력입니다.
public struct OfficeEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case sessionStarted(source: String?)
        case sessionEnded(reason: String?)
        case promptSubmitted
        case toolStarted(ToolCall)
        case toolFinished(ToolCall, ToolOutcome)
        /// `Agent`(구 `Task`) 툴로 서브에이전트에게 일을 맡김
        case delegationStarted(ToolCall, subagentType: String?)
        case delegationFinished(ToolCall, ToolOutcome)
        case subagentStarted(SubagentRef)
        case subagentStopped(SubagentRef)
        case permissionRequested(ToolCall?)
        case permissionDenied(ToolCall?)
        /// Claude Code가 한동안 입력을 기다린다고 알려줄 때 (`idle_prompt`)
        case waitingForInput
        case turnEnded(failed: Bool)
        case compacting
    }

    public var session: SessionID
    public var cwd: String?
    /// 서브에이전트 안에서 발생한 훅이면 그 서브에이전트. 메인 스레드면 nil.
    public var subagent: SubagentRef?
    /// `TERM_PROGRAM` (iTerm.app, vscode, Apple_Terminal …)
    public var term: String?
    public var at: Date
    public var kind: Kind

    public init(session: SessionID, cwd: String?, subagent: SubagentRef? = nil, term: String? = nil, at: Date, kind: Kind) {
        self.session = session
        self.cwd = cwd
        self.subagent = subagent
        self.term = term
        self.at = at
        self.kind = kind
    }
}
