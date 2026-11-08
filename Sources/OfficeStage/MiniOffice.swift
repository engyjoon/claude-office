import Foundation
import OfficeCore

/// 미니 사무실 (설계서 §10.1, M5(4)): 화면 구석에 띄우는 작은 패널.
///
/// 사무실은 줄이지 않는다는 원칙(배율 1)에 따라, 메인 한 명의 행만 사무실 그림 그대로 잘라 보여 줍니다.
/// 미니 전용 `OfficeFloor`(한 행 띠, `band: true`)가 그 행을 첫 행 자리에 놓고, 패널은 그 위의 휴게 공간부터
/// 행 아래까지(지도 y `top`~`bottom`)를 배율 1로 보여 줍니다. 위에는 24pt 머리줄(지금 행, 다른 메인 칩, 승인 대기 버튼)이 붙습니다.
/// 화이트보드·출입문·탕비 코너는 패널 오른쪽 밖에 있어, 그쪽으로 가는 사람은 오른쪽으로 걸어 나갔다 돌아옵니다.
public enum MiniOffice {
    /// 보여 주는 지도 영역 위쪽 (뒷벽 아래 걸레받이 바로 위, 휴게 공간 소파·안마 의자가 다 보임)
    public static let top = 146.0
    /// 보여 주는 지도 영역 아래쪽 (첫 행 띠의 아래 끝)
    public static let bottom = OfficeLayout.firstDeskY + 40
    public static var sceneHeight: Double { bottom - top }
    /// 패널 위 머리줄 높이
    public static let headerHeight = 24.0
    /// 패널 높이 (고정: 배율 1이라 높이를 늘려도 빈 바닥만 보임)
    public static var panelHeight: Double { headerHeight + sceneHeight }
    /// 기본 폭 (메인 + 서브 4명, 안마 의자 둘이 다 보임)
    public static let defaultWidth = 620.0
    /// 가장 좁은 폭 (메인 + 서브 1명 + "+N")
    public static let minWidth = 320.0

    /// 패널 폭에서 보이는 지도 폭 (왼쪽 둘레 여백만 뺌, 지도 x 0부터)
    public static func visibleMapWidth(panelWidth: Double) -> Double {
        max(panelWidth - OfficeLayout.padding, 1)
    }

    /// 패널에 보이는 지도 영역 (왼쪽 둘레 여백부터)
    public static func extent(panelWidth: Double) -> MapRect {
        MapRect(-OfficeLayout.padding, top, panelWidth, sceneHeight)
    }

    /// 한 행에 보이는 책상 수 (메인 포함)
    public static func columns(panelWidth: Double) -> Int {
        OfficeLayout.columns(width: visibleMapWidth(panelWidth: panelWidth))
    }
}

/// 미니 사무실이 지금 보여 줄 행과 그 까닭 (순수 계산, M5(4)).
///
/// 1. **승인 대기** (자동 전환을 켰을 때): 승인을 기다리는 사람이 있는 행. 지금 보는 행에도 기다리는 사람이 있으면 그대로 두고,
///    아니면 가장 오래 기다린 사람의 행으로 바꿉니다 (머무름 시간을 기다리지 않음).
/// 2. **고정**: 사용자가 머리줄에서 고른 행 (그 행이 닫히면 고정이 풀린 것처럼 다음 규칙으로).
/// 3. **최근 활동**: 가장 최근에 일한 행. 지금 보는 행이 최근 `quietAfter`초 안에 일했거나 바꾼 지 `minimumDwell`초가 안 됐으면
///    그대로 두어, 두 메인이 번갈아 일할 때 화면이 이리저리 바뀌지 않게 합니다. 기록이 없으면 먼저 온 행.
public struct MiniFocus: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case waiting, pinned, recent, none
    }

    public var team: TeamID?
    public var reason: Reason
    /// 이 행을 보여 주기 시작한 때
    public var since: Date

    public init(team: TeamID?, reason: Reason, since: Date) {
        self.team = team
        self.reason = reason
        self.since = since
    }

    public static let empty = MiniFocus(team: nil, reason: .none, since: .distantPast)

    /// 다른 행으로 바꾼 뒤 최소한 머무르는 시간 (승인 대기는 예외)
    public static let minimumDwell: TimeInterval = 8
    /// 지금 보는 행이 이만큼 조용하면 다른 행의 활동으로 바꿉니다
    public static let quietAfter: TimeInterval = 20

    public static func next(
        previous: MiniFocus, state: OfficeState, journal: ActivityJournal, pinned: TeamID?, autoSwitch: Bool, now: Date
    ) -> MiniFocus {
        let teams = state.sortedTeams.filter { !state.agents(in: $0.id).isEmpty }
        let open = Set(teams.map(\.id))
        func keep(_ team: TeamID, _ reason: Reason) -> MiniFocus {
            MiniFocus(team: team, reason: reason, since: previous.team == team ? previous.since : now)
        }
        guard !teams.isEmpty else { return MiniFocus(team: nil, reason: .none, since: now) }

        // 1) 승인 대기
        if autoSwitch {
            let waiting = state.agents.values
                .filter { if case .waitingForPermission = $0.activity { open.contains($0.teamID) } else { false } }
                .sorted { ($0.activitySince, $0.id) < ($1.activitySince, $1.id) }
            if let current = previous.team, waiting.contains(where: { $0.teamID == current }) {
                return keep(current, .waiting)
            }
            if let first = waiting.first { return keep(first.teamID, .waiting) }
        }

        // 2) 고정
        if let pinned, open.contains(pinned) { return keep(pinned, .pinned) }

        // 3) 최근 활동
        var lastActive: [TeamID: Date] = [:]
        for entry in journal.entries {
            guard let team = state.agents[entry.agent]?.teamID, open.contains(team) else { continue }
            let at = max(entry.at, entry.since)
            if at > lastActive[team] ?? .distantPast { lastActive[team] = at }
        }
        if let current = previous.team, open.contains(current), previous.reason != .waiting {
            let dwelling = now.timeIntervalSince(previous.since) < minimumDwell
            let busy = lastActive[current].map { now.timeIntervalSince($0) < quietAfter } ?? false
            if dwelling || busy { return keep(current, .recent) }
        }
        let latest = teams.max { (lastActive[$0.id] ?? .distantPast, -$0.order) < (lastActive[$1.id] ?? .distantPast, -$1.order) }
        return keep(latest?.id ?? teams[0].id, .recent)
    }
}
