import Foundation
import OfficeCore

/// 미니 사무실 (설계서 §10.1, M5(4) v2): 화면 구석에 띄우는 작은 패널.
///
/// 사무실은 줄이지 않는다는 원칙(배율 1)에 따라, 메인 한 명과 쉬지 않는 서브 2명만 사무실 그림 그대로 보여 줍니다.
/// 미니 전용 `OfficeFloor`(한 행 띠, `band: true`)가 그 행을 첫 행 자리에 놓고, 고른 서브를 1·2번 칸에 앉힙니다(`MiniCast`).
/// 휴게 공간은 보여 주지 않고, 쉬러 가는 동작은 자기 책상에서 합니다(`StageConfig.commonAreasAtDesk`).
/// 패널은 머리 위 말풍선부터 행 아래까지(지도 y `top`~`bottom`)를 배율 1로 보여 주고, 위에 24pt 머리줄이 붙습니다.
public enum MiniOffice {
    /// 보여 주는 지도 영역 위쪽 (첫 행 직원의 말풍선·상태 칩이 들어가는 높이)
    public static let top = OfficeLayout.firstDeskY - 140
    /// 보여 주는 지도 영역 아래쪽 (첫 행 띠의 아래 끝)
    public static let bottom = OfficeLayout.firstDeskY + 40
    public static var sceneHeight: Double { bottom - top }
    /// 패널 위 머리줄 높이
    public static let headerHeight = 20.0
    /// 패널 크기 (고정): 메인 + 서브 2명 + 행 끝 "+N"
    public static var panelHeight: Double { headerHeight + sceneHeight }
    public static let panelWidth = 390.0
    /// 보여 주는 서브 수
    public static let subSlots = 2

    /// 패널 폭에서 보이는 지도 폭 (왼쪽 둘레 여백만 뺌, 지도 x 0부터)
    public static func visibleMapWidth(panelWidth: Double = panelWidth) -> Double {
        max(panelWidth - OfficeLayout.padding, 1)
    }

    /// 패널에 보이는 지도 영역 (왼쪽 둘레 여백부터)
    public static func extent(panelWidth: Double = panelWidth) -> MapRect {
        MapRect(-OfficeLayout.padding, top, panelWidth, sceneHeight)
    }
}

/// 미니 사무실의 서브 칸 고르기 (순수 계산, M5(4) v2).
///
/// - 쉬는 서브(쉬는 중·입력 대기)는 빼고, 답변을 기다리는 서브(승인 대기·질문)를 먼저, 그다음 최근에 일한 서브를 넣습니다.
/// - 한 번 칸을 받은 서브는 쉬거나 퇴근할 때까지 그 칸을 지킵니다 (서브가 자꾸 바뀌지 않게).
///   답변을 기다리는 서브가 칸을 못 받았으면, 답변을 기다리지 않는 서브 중 가장 오래 조용한 서브의 칸을 넘겨받습니다.
/// - 돌려주는 값: 서브 → 칸(책상 1번부터)
public enum MiniCast {
    public static func pick(subs: [Agent], previous: [AgentID: Seat], journal: ActivityJournal, slots: Int) -> [AgentID: Seat] {
        guard slots > 0 else { return [:] }
        var lastActive: [AgentID: Date] = [:]
        for agent in subs { lastActive[agent.id] = agent.activitySince }
        for entry in journal.entries where lastActive[entry.agent] != nil {
            lastActive[entry.agent] = max(lastActive[entry.agent]!, entry.at, entry.since)
        }
        let active = subs.filter { !isResting($0) }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var cast = previous.filter { byID[$0.key] != nil && (1...slots).contains($0.value.desk) }
        let candidates = active.filter { cast[$0.id] == nil }.sorted { a, b in
            let (wa, wb) = (needsAnswer(a), needsAnswer(b))
            if wa != wb { return wa }
            if wa { return (a.activitySince, a.id) < (b.activitySince, b.id) }
            return (lastActive[a.id]!, b.id) > (lastActive[b.id]!, a.id)
        }
        for agent in candidates {
            let used = Set(cast.values.map(\.desk))
            if let free = (1...slots).first(where: { !used.contains($0) }) {
                cast[agent.id] = Seat(desk: free)
            } else if needsAnswer(agent),
                let victim = cast.keys.filter({ !needsAnswer(byID[$0]!) }).min(by: { (lastActive[$0]!, $0) < (lastActive[$1]!, $1) })
            {
                cast[agent.id] = cast.removeValue(forKey: victim)
            }
        }
        return cast
    }

    /// 쉬는 중 (응답을 끝냈거나 입력을 기다림)
    public static func isResting(_ agent: Agent) -> Bool {
        switch agent.activity {
        case .idle, .waitingForInput: true
        default: false
        }
    }

    /// 내 답을 기다림 (승인 대기, 질문, 계획 승인)
    public static func needsAnswer(_ agent: Agent) -> Bool {
        if case .waitingForPermission = agent.activity { return true }
        return false
    }
}

/// 미니 사무실이 지금 보여 줄 행과 그 까닭 (순수 계산, M5(4) v2).
///
/// 1. **답변 필요** (자동 전환을 켰을 때): 내 답을 기다리는 사람(승인 대기·질문·계획 승인)이 있는 행.
///    지금 보는 행에도 있으면 그대로, 아니면 가장 오래 기다린 사람의 행.
/// 2. **고정**: 사용자가 머리줄에서 고른 행.
/// 3. **완료**: 메인 세션이 응답을 끝내고 다음 요청을 기다리는 행. 가장 최근에 완료한 행.
///    `completionWindow`(10분)가 지났거나 사용자가 확인했으면(`acknowledged`) 완료로 보지 않습니다.
/// 4. **최근 요청**: 가장 마지막에 요청(UserPromptSubmit)을 받은 행 (행 안의 메인·서브 세션 중 가장 최근).
/// 5. 아무것도 없으면 먼저 온 행.
public struct MiniFocus: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case answer, pinned, completed, requested, none
    }

    /// 행마다의 상태 (머리줄 칩)
    public enum Tier: String, Hashable, Sendable {
        case answer, completed, requested, none
    }

    public var team: TeamID?
    public var reason: Reason
    /// 이 행을 보여 주기 시작한 때
    public var since: Date
    /// 보여 주는 행의 상태와 그 시각 (답변을 기다린 때, 완료한 때, 요청한 때)
    public var tier: Tier
    public var tierAt: Date?
    /// 모든 행의 상태 (머리줄 칩)
    public var tiers: [TeamID: Tier]

    public init(team: TeamID?, reason: Reason, since: Date, tier: Tier = .none, tierAt: Date? = nil, tiers: [TeamID: Tier] = [:]) {
        self.team = team
        self.reason = reason
        self.since = since
        self.tier = tier
        self.tierAt = tierAt
        self.tiers = tiers
    }

    public static let empty = MiniFocus(team: nil, reason: .none, since: .distantPast)

    /// 완료를 우선으로 보여 주는 시간
    public static let completionWindow: TimeInterval = 10 * 60

    /// 행 하나의 상태
    public struct Status: Hashable, Sendable {
        public var tier: Tier
        public var at: Date?
        /// 답변을 가장 오래 기다린 때
        public var answerSince: Date?
        /// 완료한 때 (아직 완료로 볼 때만)
        public var completedAt: Date?
        public var lastPromptAt: Date?
        /// 완료한 메인 세션
        public var completedSession: SessionID?
    }

    public static func status(
        of team: Team, state: OfficeState, acknowledged: [SessionID: Date], now: Date
    ) -> Status {
        let people = state.agents(in: team.id)
        let answerSince = people.filter(MiniCast.needsAnswer).map(\.activitySince).min()
        var completedAt: Date?
        var completedSession: SessionID?
        if let main = state.main(of: team.id), let part = state.parts[main.session], let done = part.completedAt,
            MiniCast.isResting(main), now.timeIntervalSince(done) < completionWindow, acknowledged[main.session] != done
        {
            completedAt = done
            completedSession = main.session
        }
        let sessions = Set(people.map(\.session))
        let lastPromptAt = sessions.compactMap { state.parts[$0]?.lastPromptAt }.max()
        let tier: Tier = answerSince != nil ? .answer : completedAt != nil ? .completed : lastPromptAt != nil ? .requested : .none
        let at = answerSince ?? completedAt ?? lastPromptAt
        return Status(
            tier: tier, at: at, answerSince: answerSince, completedAt: completedAt, lastPromptAt: lastPromptAt,
            completedSession: completedSession)
    }

    public static func next(
        previous: MiniFocus, state: OfficeState, pinned: TeamID?, acknowledged: [SessionID: Date] = [:], autoSwitch: Bool, now: Date
    ) -> MiniFocus {
        let teams = state.sortedTeams.filter { !state.agents(in: $0.id).isEmpty }
        guard !teams.isEmpty else { return MiniFocus(team: nil, reason: .none, since: now) }
        var statuses: [TeamID: Status] = [:]
        for team in teams { statuses[team.id] = status(of: team, state: state, acknowledged: acknowledged, now: now) }
        let tiers = statuses.mapValues(\.tier)
        func pick(_ team: TeamID, _ reason: Reason) -> MiniFocus {
            let status = statuses[team]!
            return MiniFocus(
                team: team, reason: reason, since: previous.team == team ? previous.since : now, tier: status.tier, tierAt: status.at,
                tiers: tiers)
        }
        // 같은 조건이면 먼저 온 행
        func best(_ key: (Status) -> Date?, latest: Bool) -> TeamID? {
            let scored = teams.compactMap { team in key(statuses[team.id]!).map { (team, $0) } }
            let chosen = latest
                ? scored.max { ($0.1, -$0.0.order) < ($1.1, -$1.0.order) }
                : scored.min { ($0.1, $0.0.order) < ($1.1, $1.0.order) }
            return chosen?.0.id
        }

        // 1) 답변 필요
        if autoSwitch {
            if let current = previous.team, statuses[current]?.answerSince != nil { return pick(current, .answer) }
            if let team = best({ $0.answerSince }, latest: false) { return pick(team, .answer) }
        }
        // 2) 고정
        if let pinned, statuses[pinned] != nil { return pick(pinned, .pinned) }
        // 3) 완료 (가장 최근)
        if let team = best({ $0.completedAt }, latest: true) { return pick(team, .completed) }
        // 4) 최근 요청
        if let team = best({ $0.lastPromptAt }, latest: true) { return pick(team, .requested) }
        return pick(teams[0].id, .none)
    }
}
