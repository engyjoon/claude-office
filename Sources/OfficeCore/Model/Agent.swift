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
    /// Claude Code 세션 = 팀장
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
    /// 서브에이전트 종류 (`code-reviewer`, `general-purpose` …). 팀장은 nil.
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

    static func lead(teamName: String, index: Int) -> AgentProfile {
        let key = index == 0 ? "lead@\(teamName)" : "lead@\(teamName)#\(index + 1)"
        return AgentProfile(
            key: key,
            displayName: index == 0 ? "팀장" : "팀장 \(index + 1)",
            kind: .lead,
            agentType: nil,
            appearance: .make(key: key, kind: .lead)
        )
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

public struct Agent: Identifiable, Hashable, Sendable {
    public let id: AgentID
    public let role: Role
    public let profile: AgentProfile
    public let teamID: TeamID
    public let session: SessionID
    public internal(set) var seat: Int
    /// 훅의 `agent_id`. 아직 SubagentStart를 못 받았으면 nil.
    public internal(set) var subagentID: String?
    public internal(set) var delegatedBy: AgentID?
    public internal(set) var task: String?
    public internal(set) var delegationToolUseID: String?
    public internal(set) var runsInBackground: Bool
    public internal(set) var activity: Activity
    public internal(set) var activitySince: Date
    public internal(set) var runningTools: [ToolCall]
    public internal(set) var consecutiveErrors: Int
    public internal(set) var term: String?
    let serial: Int
}

public struct TeamID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: TeamID, rhs: TeamID) -> Bool { lhs.raw < rhs.raw }
}

/// 프로젝트(cwd) 하나 = 팀 하나 = 사무실의 책상 섬 하나 (설계서 §1.3 ②)
public struct Team: Identifiable, Hashable, Sendable {
    public static let colorCount = 4
    public static let minimumSeats = 3

    public let id: TeamID
    public let name: String
    /// 사무실 안 책상 섬의 순서 (0부터)
    public let island: Int
    public let colorIndex: Int
    /// 좌석 수. 0번은 팀장석. 사람이 늘면 늘어납니다.
    public internal(set) var seatCount: Int
    /// 고정 직원의 지정석 (프로필 키 → 좌석 번호). 퇴근해도 명패가 남습니다.
    public internal(set) var reservedSeats: [String: Int]
}
