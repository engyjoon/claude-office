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

/// 세션이 어느 방에 속하는지 알려 주는 힌트 (설계서 §4.4).
///
/// 훅 페이로드에는 부모 세션 정보가 없어서, 앱이 Claude 데스크톱 앱의 세션 정보 파일을 읽어 만듭니다.
/// 코어는 파일을 모르고 이 값만 받습니다. 없으면 "같은 폴더에 먼저 온 세션이 팀장" 규칙을 씁니다.
public struct SessionHint: Hashable, Sendable {
    /// 데스크톱 앱 세션 id (`local_…`)
    public var hostSession: String?
    /// 이 세션을 띄운 세션들의 훅 `session_id`. 가까운 부모부터 최상위(메인 세션)까지.
    public var ancestors: [SessionID]
    /// 최상위 세션의 폴더. 이 폴더로 방을 정합니다.
    public var rootCwd: String?
    /// 데스크톱 앱이 붙인 세션 제목
    public var title: String?
    /// 최상위 세션(메인)의 데스크톱 세션 id·제목과, 데스크톱 앱에 아직 열려 있는지(보관하지 않음).
    /// 열려 있는 메인이 아직 훅을 보내지 않았으면(쉬고 있음) 서브가 올 때 메인을 먼저 앉힙니다 (M5(4) 화면 확인).
    public var rootHostSession: String?
    public var rootTitle: String?
    public var rootIsOpen: Bool
    /// 데스크톱 정보 파일이 지금 이 데스크톱 세션의 CLI 세션이라고 적은 id (`cliSessionId`).
    /// 훅의 `session_id`와 같으면, 같은 데스크톱 세션으로 앉아 있던 사람을 이 id로 이어 갑니다 (M5(5)).
    public var hostCliSession: SessionID?

    public init(
        hostSession: String? = nil, ancestors: [SessionID] = [], rootCwd: String? = nil, title: String? = nil,
        rootHostSession: String? = nil, rootTitle: String? = nil, rootIsOpen: Bool = false, hostCliSession: SessionID? = nil
    ) {
        self.hostCliSession = hostCliSession
        self.hostSession = hostSession
        self.ancestors = ancestors
        self.rootCwd = rootCwd
        self.title = title
        self.rootHostSession = rootHostSession
        self.rootTitle = rootTitle
        self.rootIsOpen = rootIsOpen
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
        /// 응답 끝 (`Stop`·`StopFailure`). `asksUser`: 마지막 응답이 질문·결정 요청으로 끝남 (`ReplyRequest`, M6(4))
        case turnEnded(failed: Bool, asksUser: Bool = false)
        /// 대화 압축 시작 (`PreCompact`, 수동 `/compact`·자동 압축 모두)
        case compacting
        /// 대화 압축 끝 (`PostCompact`). 설치하는 훅 목록에는 아직 없고, 받으면 `SessionStart`(source `compact`)와 같이 처리합니다 (M6(2)).
        case compactFinished
    }

    public var session: SessionID
    public var cwd: String?
    /// 서브에이전트 안에서 발생한 훅이면 그 서브에이전트. 메인 스레드면 nil.
    public var subagent: SubagentRef?
    /// `TERM_PROGRAM` (iTerm.app, vscode, Apple_Terminal …)
    public var term: String?
    public var at: Date
    public var kind: Kind
    /// 앱이 붙인 방 힌트 (데스크톱 세션 정보). 없으면 nil.
    public var hint: SessionHint?

    public init(
        session: SessionID, cwd: String?, subagent: SubagentRef? = nil, term: String? = nil, at: Date, kind: Kind,
        hint: SessionHint? = nil
    ) {
        self.hint = hint
        self.session = session
        self.cwd = cwd
        self.subagent = subagent
        self.term = term
        self.at = at
        self.kind = kind
    }
}
