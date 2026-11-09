import Foundation

/// 메뉴바 드롭다운과 인스펙터에 보여줄 직원 상태 (설계서 §10)
public enum RosterStatus: String, Hashable, Sendable, CaseIterable {
    case arriving, thinking, reading, editing, running, browsing, planning, reporting, usingTool
    case delegating, waitingForPermission, waitingForInput, idle, compacting
    /// 응답을 끝냈고 내 답을 기다림 / 아직 확인하지 않은 응답 (M6(4), `SessionCue`)
    case awaitingReply, unread

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
        case .awaitingReply: "답변 필요"
        case .unread: "새 응답"
        }
    }

    /// 상태 칩 색을 고르는 기준
    public var tone: Tone {
        switch self {
        case .waitingForPermission: .attention
        case .awaitingReply: .reply
        case .idle, .waitingForInput, .arriving, .unread: .calm
        case .reading, .browsing, .planning: .reading
        case .running: .running
        default: .working
        }
    }

    public enum Tone: String, Hashable, Sendable {
        case working, reading, running, attention, calm
        /// 답변 필요 (파랑, M6(4))
        case reply
    }

    /// 직원의 상태: 응답을 끝낸 세션의 표시(답변 필요·새 응답)가 있으면 그것, 아니면 활동
    static func from(_ agent: Agent) -> RosterStatus {
        switch agent.cue {
        case .reply?: .awaitingReply
        case .unread?: .unread
        case nil: from(agent.activity)
        }
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
    /// 메인(사용자가 직접 연 세션)인지. 가슴의 별 배지는 메인만 답니다.
    public var isMain: Bool { title.isMain }

    public let id: AgentID
    /// 직함 ("메인", "메인1", "서브", "서브2"). 에이전트 종류는 `agentType`
    public let name: String
    public let role: Role
    public let title: JobTitle
    /// 행 안 책상 (0 = 메인)
    public let seat: Seat
    /// 데스크톱 앱의 세션 제목 (세션 직원만, 알 때만)
    public let sessionTitle: String?
    /// 서브에이전트를 부른 세션 직원의 직함 ("메인", "서브1")
    public let calledBy: String?
    /// 이 사람이 속한 행의 메인 직함 ("메인", "메인2")
    public let mainName: String
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
    /// Claude 데스크톱 앱 세션 id (`local_…`). 터미널 CLI 세션은 nil (M5(3): 알림·메뉴에서 데스크톱 앱으로 이동)
    public let hostSession: String?

    /// 앞으로 가져올 곳이 있는지 (데스크톱 앱 세션이거나 터미널을 앎)
    public var canFocus: Bool { hostSession != nil || term != nil }
}

/// 행 하나 (메인 하나와 그 서브들)
public struct RosterTeam: Identifiable, Hashable, Sendable {
    public let id: TeamID
    /// 폴더 이름
    public let name: String
    /// 폴더 경로
    public let folder: String
    public let colorIndex: Int
    /// 메인 직함 ("메인", "메인1")
    public let mainName: String
    /// 메인 세션의 데스크톱 제목 (표시 수준 "상세"에서 알 때만)
    public let mainTitle: String?
    /// 메인부터 책상 순서
    public let rows: [RosterRow]

    /// 선택기·목록 머리에 쓰는 이름 ("메인1 · claude-office")
    public var label: String { "\(mainName) · \(name)" }
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
            let main = state.main(of: team.id)
            let mainName = main?.displayName ?? "메인"
            let rows = agents.map { row(for: $0, team: team, mainName: mainName, privacy: privacy, state: state) }
            teams.append(RosterTeam(
                id: team.id, name: team.name, folder: team.folder, colorIndex: team.colorIndex, mainName: mainName,
                mainTitle: rows.first { $0.isMain }?.sessionTitle, rows: rows))
        }
        let waiting = teams.flatMap(\.rows).filter { $0.status == .waitingForPermission }.sorted { $0.since < $1.since }
        return Roster(teams: teams, waiting: waiting)
    }

    /// 고른 디렉토리(폴더)의 메인 행만 남긴 목록 (직원 현황 패널). nil이면 모두.
    public func filtered(folders: Set<String>?) -> Roster {
        guard let folders else { return self }
        let kept = teams.filter { folders.contains($0.folder) }
        return Roster(teams: kept, waiting: kept.flatMap(\.rows).filter { $0.status == .waitingForPermission }.sorted { $0.since < $1.since })
    }

    static func row(for agent: Agent, team: Team, mainName: String, privacy: PrivacyLevel, state: OfficeState) -> RosterRow {
        let part = state.parts[agent.session]
        let sessionTitle = agent.role == .lead && privacy == .detailed ? part?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        return RosterRow(
            id: agent.id,
            name: agent.displayName,
            role: agent.role,
            title: agent.title,
            seat: agent.seat,
            sessionTitle: sessionTitle,
            calledBy: agent.role == .member ? state.lead(of: agent.session)?.displayName : nil,
            mainName: mainName,
            agentType: agent.role == .member ? agent.profile.agentType : nil,
            kind: agent.profile.kind,
            status: RosterStatus.from(agent),
            detail: privacy == .detailed ? detail(for: agent) : nil,
            since: agent.cue != nil ? part?.completedAt ?? agent.activitySince : agent.activitySince,
            appearance: agent.profile.appearance,
            teamName: team.name,
            session: agent.session,
            term: agent.term,
            hostSession: part?.hostSession
        )
    }

    static func detail(for agent: Agent) -> String? {
        switch agent.activity {
        case .working(let call) where call.category == .mcp:
            return MCPNames.text(call.name, detailed: true)  // "브라우저 페이지 이동" (M6(5))
        case .working(let call) where call.category != .report:
            return call.subject ?? call.name
        case .waitingForPermission(let call):
            guard let call else { return "승인이 필요해요" }
            if call.asksUser { return call.waitRequest }
            if call.category == .mcp { return MCPNames.text(call.name, detailed: true) }
            return call.subject.map { "\(call.name) · \($0)" } ?? call.name
        default:
            return agent.role == .member ? agent.task : nil
        }
    }
}
