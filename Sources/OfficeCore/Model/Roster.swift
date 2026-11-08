import Foundation

/// 메뉴바 드롭다운과 인스펙터에 보여줄 직원 상태 (설계서 §10)
public enum RosterStatus: String, Hashable, Sendable, CaseIterable {
    case arriving, thinking, reading, editing, running, browsing, planning, reporting, usingTool
    case delegating, waitingForPermission, waitingForInput, idle, compacting

    public var label: String {
        switch self {
        case .arriving: "출근 중"
        case .thinking: "생각 중"
        case .reading: "읽는 중"
        case .editing: "편집 중"
        case .running: "실행 중"
        case .browsing: "검색 중"
        case .planning: "계획 중"
        case .reporting: "보고 정리 중"
        case .usingTool: "도구 사용 중"
        case .delegating: "위임 중"
        case .waitingForPermission: "승인 대기"
        case .waitingForInput: "입력 대기"
        case .idle: "쉬는 중"
        case .compacting: "정리 중"
        }
    }

    /// 상태 칩 색을 고르는 기준
    public var tone: Tone {
        switch self {
        case .waitingForPermission: .attention
        case .idle, .waitingForInput, .arriving: .calm
        case .reading, .browsing, .planning: .reading
        case .running: .running
        default: .working
        }
    }

    public enum Tone: String, Hashable, Sendable {
        case working, reading, running, attention, calm
    }

    static func from(_ activity: Activity) -> RosterStatus {
        switch activity {
        case .arriving: .arriving
        case .thinking: .thinking
        case .working(let call):
            switch call.category {
            case .read: .reading
            case .write: .editing
            case .shell: .running
            case .web: .browsing
            case .plan: .planning
            case .report: .reporting
            case .delegate: .delegating
            case .mcp, .other: .usingTool
            }
        case .delegating: .delegating
        case .waitingForPermission: .waitingForPermission
        case .idle: .idle
        case .waitingForInput: .waitingForInput
        case .compacting: .compacting
        case .reporting: .reporting
        }
    }
}

public struct RosterRow: Identifiable, Hashable, Sendable {
    /// 팀장(메인 세션)인지. 가슴의 별 배지는 팀장만 답니다.
    public var isTeamLead: Bool { title == .teamLead }

    public let id: AgentID
    /// 직함 ("팀장", "팀원", "팀원2"). 에이전트 종류는 `agentType`
    public let name: String
    public let role: Role
    public let title: JobTitle
    /// 칸 번호 (0 = 팀장 칸)
    public let part: Int
    /// 데스크톱 앱의 세션 제목 (세션 직원만, 알 때만)
    public let sessionTitle: String?
    /// 서브에이전트를 부른 세션 직원의 직함 ("팀장", "팀원1"). 그 사람의 칸에 앉습니다.
    public let calledBy: String?
    /// 서브에이전트 종류 ("code-reviewer", "Explore"). 세션 직원은 nil. 신원 카드에만 보여 줍니다.
    public let agentType: String?
    public let kind: StaffKind
    public let status: RosterStatus
    /// 표시 수준이 "상세"일 때만: 툴 대상, 승인 대기 중인 명령, 팀원이 맡은 일
    public let detail: String?
    public let since: Date
    public let appearance: Appearance
    public let teamName: String
    public let session: SessionID
    public let term: String?
}

public struct RosterTeam: Identifiable, Hashable, Sendable {
    public let id: TeamID
    public let name: String
    public let colorIndex: Int
    public let rows: [RosterRow]
}

/// 사무실 상태를 목록으로 정리한 것. 메뉴바 앱이 그대로 그립니다.
public struct Roster: Hashable, Sendable {
    public enum Mood: String, Hashable, Sendable {
        /// 아무도 없음
        case empty
        /// 모두 쉬는 중
        case idle
        case working
        /// 승인 대기가 있음
        case attention
    }

    public let teams: [RosterTeam]
    /// 승인 대기 중인 직원 (맨 위에 고정해서 보여줍니다)
    public let waiting: [RosterRow]

    public var agentCount: Int { teams.reduce(0) { $0 + $1.rows.count } }

    public var mood: Mood {
        if !waiting.isEmpty { return .attention }
        let rows = teams.flatMap(\.rows)
        if rows.isEmpty { return .empty }
        return rows.contains { $0.status.tone != .calm } ? .working : .idle
    }

    public static let empty = Roster(teams: [], waiting: [])

    /// 사무실 창에서 클릭한 직원을 찾을 때 씁니다
    public func row(for id: AgentID) -> RosterRow? {
        for team in teams { if let row = team.rows.first(where: { $0.id == id }) { return row } }
        return nil
    }

    public func team(of id: AgentID) -> RosterTeam? {
        teams.first { $0.rows.contains { $0.id == id } }
    }

    public static func make(from state: OfficeState, privacy: PrivacyLevel) -> Roster {
        var teams: [RosterTeam] = []
        for team in state.sortedTeams {
            let agents = state.agents(in: team.id)
            guard !agents.isEmpty else { continue }
            // 팀장과 그 서브에이전트, 그다음 세션 팀원과 그 서브에이전트 … 순서 (칸 순서)
            var ordered: [Agent] = []
            for part in state.parts(in: team.id) {
                let inPart = agents.filter { $0.session == part.session }
                ordered += inPart.filter { $0.role == .lead } + inPart.filter { $0.role == .member }.sorted { $0.seat < $1.seat }
            }
            ordered += agents.filter { agent in !ordered.contains { $0.id == agent.id } }
            let rows = ordered.map { row(for: $0, teamName: team.name, privacy: privacy, state: state) }
            teams.append(RosterTeam(id: team.id, name: team.name, colorIndex: team.colorIndex, rows: rows))
        }
        let waiting = teams.flatMap(\.rows).filter { $0.status == .waitingForPermission }.sorted { $0.since < $1.since }
        return Roster(teams: teams, waiting: waiting)
    }

    static func row(for agent: Agent, teamName: String, privacy: PrivacyLevel, state: OfficeState) -> RosterRow {
        let part = state.parts[agent.session]
        let sessionTitle = agent.role == .lead && privacy == .detailed ? part?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        return RosterRow(
            id: agent.id,
            name: agent.displayName,
            role: agent.role,
            title: agent.title,
            part: agent.part,
            sessionTitle: sessionTitle,
            calledBy: agent.role == .member ? state.lead(of: agent.session)?.displayName : nil,
            agentType: agent.role == .member ? agent.profile.agentType : nil,
            kind: agent.profile.kind,
            status: RosterStatus.from(agent.activity),
            detail: privacy == .detailed ? detail(for: agent) : nil,
            since: agent.activitySince,
            appearance: agent.profile.appearance,
            teamName: teamName,
            session: agent.session,
            term: agent.term
        )
    }

    static func detail(for agent: Agent) -> String? {
        switch agent.activity {
        case .working(let call) where call.category != .report:
            return call.subject ?? call.name
        case .waitingForPermission(let call):
            guard let call else { return "승인이 필요해요" }
            return call.subject.map { "\(call.name) · \($0)" } ?? call.name
        default:
            return agent.role == .member ? agent.task : nil
        }
    }
}
