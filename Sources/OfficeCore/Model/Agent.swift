import Foundation

public struct AgentID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: AgentID, rhs: AgentID) -> Bool { lhs.raw < rhs.raw }
}

public enum Role: String, Hashable, Sendable {
    case lead, member
}

/// 직원 종류 (설계서 §1.3 ①)
public enum StaffKind: String, Hashable, Sendable {
    /// Claude Code 세션 (메인 또는 서브 세션)
    case lead
    /// `.claude/agents/*.md`로 직접 정의한 에이전트 = 항상 같은 얼굴의 고정 직원
    case fixed
    /// general-purpose처럼 기본 제공 서브에이전트 = 출근할 때마다 바뀌는 임시 직원 (머리에 새싹)
    case temporary
}

public enum Accessory: String, Hashable, Sendable, CaseIterable {
    case glasses, headphones, beanie, ribbon, sprout
}

/// 종이인형 리그의 부위 선택 (설계서 §9.4). 실제 색과 모양은 씬의 에셋 표에서 고릅니다.
public struct Appearance: Hashable, Sendable {
    public static let skinToneCount = 4
    public static let hairStyleCount = 5
    public static let hairColorCount = 8
    public static let topColorCount = 6
    public static let voiceCount = 5

    public var skinTone: Int
    public var hairStyle: Int
    public var hairColor: Int
    public var topColor: Int
    public var accessory: Accessory?
    /// 말풍선 블립의 음높이 단계 (0 = 가장 낮음)
    public var voice: Int

    public init(skinTone: Int, hairStyle: Int, hairColor: Int, topColor: Int, accessory: Accessory?, voice: Int) {
        self.skinTone = skinTone
        self.hairStyle = hairStyle
        self.hairColor = hairColor
        self.topColor = topColor
        self.accessory = accessory
        self.voice = voice
    }

    /// 같은 키는 언제나 같은 외형이 됩니다.
    public static func make(key: String, kind: StaffKind) -> Appearance {
        let seed = StableHash.fnv1a(key)
        let accessories: [Accessory?] = [nil, .glasses, .headphones, .beanie, .ribbon, nil]
        return Appearance(
            skinTone: Int(seed % UInt64(skinToneCount)),
            hairStyle: Int((seed >> 8) % UInt64(hairStyleCount)),
            hairColor: Int((seed >> 16) % UInt64(hairColorCount)),
            topColor: Int((seed >> 24) % UInt64(topColorCount)),
            accessory: kind == .temporary ? .sprout : accessories[Int((seed >> 32) % UInt64(accessories.count))],
            voice: Int((seed >> 40) % UInt64(voiceCount))
        )
    }
}

public struct AgentProfile: Hashable, Sendable {
    /// 외형과 고정 좌석을 정하는 키
    public var key: String
    public var displayName: String
    public var kind: StaffKind
    /// 서브에이전트 종류 (`code-reviewer`, `general-purpose` …). 세션 직원은 nil.
    public var agentType: String?
    public var appearance: Appearance

    public init(key: String, displayName: String, kind: StaffKind, agentType: String?, appearance: Appearance) {
        self.key = key
        self.displayName = displayName
        self.kind = kind
        self.agentType = agentType
        self.appearance = appearance
    }

    /// Claude Code에 기본으로 들어 있는 서브에이전트. 이 목록에 있으면 임시 직원입니다.
    public static let builtInAgentTypes: Set<String> = [
        "general-purpose", "Explore", "Plan", "statusline-setup", "output-style-setup",
        "claude-code-guide", "claude", "fork", "web-fetch",
    ]

    /// 세션 직원(메인·서브 세션)의 프로필. 외형은 세션 id로 정해지고, 메인 ↔ 서브가 바뀌어도 그대로입니다.
    static func session(_ session: SessionID) -> AgentProfile {
        let key = "session#\(session.raw)"
        return AgentProfile(key: key, displayName: "세션", kind: .lead, agentType: nil, appearance: .make(key: key, kind: .lead))
    }

    static func member(agentType: String?, serial: Int, duplicateIndex: Int) -> AgentProfile {
        let type = agentType ?? "general-purpose"
        if builtInAgentTypes.contains(type) {
            let key = "temp#\(serial)"
            return AgentProfile(key: key, displayName: type, kind: .temporary, agentType: type, appearance: .make(key: key, kind: .temporary))
        }
        let name = duplicateIndex == 0 ? type : "\(type) (\(duplicateIndex + 1))"
        return AgentProfile(key: type, displayName: name, kind: .fixed, agentType: type, appearance: .make(key: type, kind: .fixed))
    }
}

/// 직함 (설계서 §1.3 ①, 2026-11-08 결정 "메인·서브").
///
/// - 메인 = 사용자가 직접 연 세션 (데스크톱 세션 정보에 `spawnedFrom`이 없는 세션, 터미널 CLI 세션). 사무실에 메인이 하나면 "메인",
///   여럿이면 "메인1", "메인2"… (번호는 방이 열릴 때 비어 있는 가장 작은 번호로 정해 고정).
/// - 서브 = 그 메인이 띄운 세션(후손 세션)과, 메인·서브 세션이 부른 모든 서브에이전트(기본·직접 만든 에이전트).
///   메인마다 따로 번호를 매겨 서브가 하나면 "서브", 둘 이상이면 "서브1", "서브2"… (출근 때 고정, 빈 번호 재사용).
/// 에이전트 종류(code-reviewer, Explore …)는 화면의 이름에 쓰지 않고 신원 카드에만 보여 줍니다.
public enum JobTitle: Hashable, Sendable {
    /// 메인 번호. 사무실에 메인이 하나뿐이면 nil ("메인")
    case main(Int?)
    /// 서브 번호. 그 메인의 서브가 하나뿐이면 nil ("서브")
    case sub(Int?)

    public var isMain: Bool {
        if case .main = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .main(let number): number.map { "메인\($0)" } ?? "메인"
        case .sub(let number): number.map { "서브\($0)" } ?? "서브"
        }
    }
}

/// 실제로 무엇을 하고 있는지 (연출 전의 의미 상태)
public enum Activity: Hashable, Sendable {
    case arriving
    case thinking
    case working(ToolCall)
    case delegating
    case waitingForPermission(ToolCall?)
    case idle
    case waitingForInput
    case compacting
    case reporting
}

/// 행 안의 책상 (설계서 §8.1, M5(1)).
///
/// 행 하나 = 메인 하나. 0번(가장 왼쪽)이 메인 책상이고, 서브는 1번부터 오른쪽으로 사람 수만큼 앉습니다.
/// 빈 책상은 없습니다: 새 서브는 오른쪽 끝에 책상을 붙이고, 가운데 서브가 퇴근하면 오른쪽 끝 사람이 그 책상으로 옮겨 앉고
/// 끝 책상을 치웁니다 (앉아 있는 사람들이 줄줄이 밀려나지 않게).
public struct Seat: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// 메인 책상
    public static let main = Seat(desk: 0)

    /// 행 안 책상 번호 (0 = 메인)
    public var desk: Int

    public init(desk: Int) {
        self.desk = desk
    }

    public var isMain: Bool { desk == 0 }

    public var description: String { "책상\(desk)" }

    public static func < (lhs: Seat, rhs: Seat) -> Bool { lhs.desk < rhs.desk }
}

public struct Agent: Identifiable, Hashable, Sendable {
    public let id: AgentID
    public let role: Role
    public let profile: AgentProfile
    /// 행(메인 하나와 그 서브들). 코드에서는 예전 이름 그대로 팀이라고 부릅니다.
    /// 늦게 온 데스크톱 정보로 다른 메인의 서브로 밝혀지면 그 행으로 옮깁니다.
    public internal(set) var teamID: TeamID
    /// 세션 (데스크톱 앱이 같은 세션의 CLI 세션 id를 바꾸면 따라 바뀜, M5(5))
    public internal(set) var session: SessionID
    /// 0 = 메인, 1… = 그 행의 서브 번호 (출근 때 정해 고정, 빈 번호 재사용)
    public internal(set) var number: Int
    /// 직함 ("메인", "메인2", "서브", "서브3"). 승진하거나 메인·서브 수가 1 ↔ 여럿으로 바뀌면 달라집니다.
    public internal(set) var title: JobTitle
    public internal(set) var seat: Seat
    /// 훅의 `agent_id`. 아직 SubagentStart를 못 받았으면 nil.
    public internal(set) var subagentID: String?
    public internal(set) var delegatedBy: AgentID?
    public internal(set) var task: String?
    public internal(set) var delegationToolUseID: String?
    public internal(set) var runsInBackground: Bool
    /// SubagentStart를 실제로 받았는지. 받았으면 끝도 SubagentStop으로 옵니다.
    /// (M0: web-fetch처럼 시작·종료 신호 없이 툴 이벤트만 보내는 서브에이전트가 있습니다)
    public internal(set) var announcedByHook: Bool = false
    public internal(set) var activity: Activity
    public internal(set) var activitySince: Date
    public internal(set) var runningTools: [ToolCall]
    public internal(set) var consecutiveErrors: Int
    public internal(set) var term: String?
    let serial: Int

    /// 화면에 보이는 이름: 언제나 직함 ("메인1", "서브2"). 에이전트 종류는 `profile.agentType` (신원 카드에만)
    public var displayName: String { title.label }
    public var isMain: Bool { number == 0 }
}

public struct TeamID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: TeamID, rhs: TeamID) -> Bool { lhs.raw < rhs.raw }
}

/// 행 하나 = 메인 하나와 그 서브들 (설계서 §1.3 ②, §5.1). 코드에서는 예전 이름 그대로 `Team`이라고 부릅니다.
///
/// 메인은 사용자가 직접 연 세션이라, 같은 폴더에서 직접 연 두 번째 세션이나 터미널 세션도 각자 행을 엽니다.
/// 데스크톱 앱이 알려 준 부모가 사무실에 있으면 그 부모의 행에 서브로 들어갑니다.
public struct Team: Identifiable, Hashable, Sendable {
    public static let colorCount = 4

    public let id: TeamID
    /// 폴더 이름 (예: "claude-office")
    public let name: String
    /// 폴더 (워크트리는 원래 폴더로 합친 것)
    public let folder: String
    /// 메인 번호 자리 (0부터). 메인 번호 = `island + 1`. 행이 닫히면 다음 행이 그 번호를 다시 씁니다.
    public let island: Int
    /// 행이 열린 순서. 사무실은 이 순서로 위에서 아래로 행을 쌓습니다 (새 메인은 다음 행).
    public let order: Int
    public let colorIndex: Int

    /// 메인 번호 (1부터)
    public var mainNumber: Int { island + 1 }

    /// 워크트리 표시. `…/proj/.claude/worktrees/<이름>/…`는 `…/proj/…`로 합칩니다.
    public static let worktreeMarker = "/.claude/worktrees/"

    /// 방을 정하는 폴더: 끝의 `/`를 떼고, 워크트리는 원래 폴더로 합칩니다.
    public static func folder(for cwd: String?) -> String {
        var path = (cwd?.isEmpty == false ? cwd! : "(알 수 없는 프로젝트)")
        if let range = path.range(of: worktreeMarker), range.lowerBound > path.startIndex {
            let rest = path[range.upperBound...]
            // 워크트리 이름 다음의 하위 경로는 원래 폴더 아래에 그대로 붙입니다
            let tail = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
            path = String(path[..<range.lowerBound]) + tail
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// 세션 하나의 기록 (메인 세션 또는 서브 세션). 서브에이전트는 자기를 부른 세션에 딸립니다.
public struct Part: Hashable, Sendable {
    public internal(set) var session: SessionID
    public internal(set) var teamID: TeamID
    /// 사무실에 들어온 순서. 메인이 퇴근하면 그 행에서 가장 먼저 온 서브 세션이 메인으로 승진합니다.
    public let order: Int
    /// 세션 직원 (메인 또는 서브 세션)
    public internal(set) var lead: AgentID
    /// 데스크톱 앱이 알려 준 조상 세션 (가까운 부모부터)
    public internal(set) var ancestors: [SessionID]
    /// 데스크톱 앱의 세션 제목
    public internal(set) var title: String?
    /// Claude 데스크톱 앱 세션 id (`local_…`). 터미널 CLI 세션은 nil. 알림을 누르면 데스크톱 앱으로 갈지 정합니다 (M5(3)).
    public internal(set) var hostSession: String?
    /// 마지막으로 요청(UserPromptSubmit)을 받은 때 (미니 사무실 "가장 마지막에 요청한 세션", M5(4))
    public internal(set) var lastPromptAt: Date?
    /// 응답을 끝낸 때(Stop). 다음 요청이 오면 지웁니다 (미니 사무실 "완료한 세션", M5(4))
    public internal(set) var completedAt: Date?
}
