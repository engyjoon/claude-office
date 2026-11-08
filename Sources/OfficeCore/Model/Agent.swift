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

    /// 세션 직원(팀장·파트장)의 프로필. 외형은 방과 출근 순번으로 정해지고, 승진해도 바뀌지 않습니다.
    static func lead(roomName: String, number: Int) -> AgentProfile {
        let key = number == 0 ? "lead@\(roomName)" : "part@\(roomName)#\(number)"
        return AgentProfile(
            key: key,
            displayName: JobTitle.lead(number: number, partLeadCount: 1).label,
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

/// 방 안의 직함 (설계서 §1.3 ②). 메인 세션 = 팀장, 같은 방의 다른 세션 = 파트장, 서브에이전트 = 파트원.
public enum JobTitle: Hashable, Sendable {
    case teamLead
    /// 파트장 번호. 방에 파트장이 한 명뿐이면 nil ("파트장")
    case partLead(Int?)
    case member

    /// 파트 번호(0 = 팀장)와 방의 파트장 수로 직함을 정합니다.
    static func lead(number: Int, partLeadCount: Int) -> JobTitle {
        if number == 0 { return .teamLead }
        return .partLead(partLeadCount > 1 ? number : nil)
    }

    public var label: String {
        switch self {
        case .teamLead: "팀장"
        case .partLead(let number): number.map { "파트장\($0)" } ?? "파트장"
        case .member: "파트원"
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

public struct Agent: Identifiable, Hashable, Sendable {
    public let id: AgentID
    public let role: Role
    public let profile: AgentProfile
    /// 방 (설계서 §1.3 ②). 이름은 예전 그대로 팀이라고 부릅니다.
    public let teamID: TeamID
    public let session: SessionID
    /// 이 직원이 속한 파트 번호 (자기 세션의 파트). 0 = 팀장 파트, 1… = 파트장 번호
    public internal(set) var part: Int
    /// 직함. 팀장·파트장은 승진하거나 파트장 수가 바뀌면 달라집니다.
    public internal(set) var title: JobTitle
    public internal(set) var seat: Int
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

    /// 화면에 보이는 이름: 팀장·파트장은 직함, 파트원은 에이전트 종류
    public var displayName: String {
        role == .lead ? title.label : profile.displayName
    }
}

public struct TeamID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (lhs: TeamID, rhs: TeamID) -> Bool { lhs.raw < rhs.raw }
}

/// 방 하나 = 사무실의 책상 섬 하나 (설계서 §1.3 ②, §5).
///
/// 방은 메인 세션(팀장) 단위입니다. 데스크톱 앱 정보로 부모를 알면 부모의 방에, 모르면 같은 폴더의 방에 들어갑니다.
/// 워크트리(`…/.claude/worktrees/<이름>`)는 원래 폴더로 합칩니다. 코드에서는 예전 이름 그대로 `Team`이라고 부릅니다.
public struct Team: Identifiable, Hashable, Sendable {
    public static let colorCount = 4
    public static let minimumSeats = 3

    public let id: TeamID
    public let name: String
    /// 사무실 안 책상 섬의 순서 (0부터). 방이 닫히면 다음 방이 그 섬을 다시 씁니다.
    public let island: Int
    public let colorIndex: Int
    /// 좌석 수. 0번은 팀장석. 사람이 늘면 늘어납니다.
    public internal(set) var seatCount: Int
    /// 고정 직원의 지정석 (프로필 키 → 좌석 번호). 퇴근해도 명패가 남습니다.
    public internal(set) var reservedSeats: [String: Int]

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

/// 방 안의 파트 = 세션 하나 (설계서 §5). 팀장의 파트(0번)와 파트장들의 파트(1번~).
/// 파트원(서브에이전트)은 자기를 부른 세션의 파트에 속합니다.
public struct Part: Hashable, Sendable {
    public let session: SessionID
    public let teamID: TeamID
    /// 0 = 팀장 파트, 1… = 파트장 번호 (출근 때 정해 고정, 빈 번호 재사용)
    public internal(set) var number: Int
    /// 방에 들어온 순서. 팀장이 퇴근하면 가장 먼저 온 파트장이 승진합니다.
    public let order: Int
    /// 세션 직원(팀장·파트장)
    public internal(set) var lead: AgentID
    /// 데스크톱 앱이 알려 준 조상 세션 (가까운 부모부터)
    public internal(set) var ancestors: [SessionID]
    /// 데스크톱 앱의 세션 제목
    public internal(set) var title: String?
}
