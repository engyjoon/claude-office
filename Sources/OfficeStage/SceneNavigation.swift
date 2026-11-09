import Foundation
import OfficeCore

/// 사무실 장면의 키보드 이동과 VoiceOver 읽는 순서 (M6(7)).
///
/// 화면에 서 있는 사람을 행(위에서부터) → 책상(왼쪽부터) 순서로 늘어놓습니다. 쉬러 가 걷거나 소파에 앉아 있어도
/// 자기 행·책상 자리로 셉니다(어디 있든 순서가 바뀌지 않게).
public enum SceneNavigation {
    public enum Move: Hashable, Sendable {
        /// → · Tab
        case next
        /// ← · ⇧Tab
        case previous
        /// ↑: 윗행에서 가장 가까운 책상
        case up
        /// ↓: 아랫행에서 가장 가까운 책상
        case down
    }

    /// 행마다 보이는 사람 (책상 순서). 무대 행에 없는 사람(행이 막 바뀌는 중)은 맨 끝 한 줄로 모읍니다.
    public static func rows(_ stage: Stage) -> [[AgentID]] {
        let order = Dictionary(uniqueKeysWithValues: stage.layout.rows.enumerated().map { ($0.element.team, $0.offset) })
        var grouped: [Int: [(desk: Int, id: AgentID)]] = [:]
        for actor in stage.actors.values {
            let row = order[actor.agent.teamID] ?? order.count
            let desk = (stage.seatMap[actor.id] ?? actor.agent.seat).desk
            grouped[row, default: []].append((desk, actor.id))
        }
        return grouped.keys.sorted().map { key in
            grouped[key]!.sorted { ($0.desk, $0.id) < ($1.desk, $1.id) }.map(\.id)
        }
    }

    /// 읽는 순서 그대로 한 줄로
    public static func order(_ stage: Stage) -> [AgentID] {
        rows(stage).flatMap { $0 }
    }

    /// 다음에 고를 사람. 끝을 넘으면 nil (Tab이면 장면 밖으로 초점을 넘기고, 화살표면 그대로 둡니다).
    /// 아무도 안 골랐으면 → ↓ Tab은 첫 사람, ← ↑ ⇧Tab은 마지막 사람.
    public static func target(from current: AgentID?, move: Move, stage: Stage) -> AgentID? {
        target(from: current, move: move, rows: rows(stage))
    }

    static func target(from current: AgentID?, move: Move, rows: [[AgentID]]) -> AgentID? {
        let flat = rows.flatMap { $0 }
        guard !flat.isEmpty else { return nil }
        guard let current, let index = flat.firstIndex(of: current) else {
            switch move {
            case .next, .down: return flat.first
            case .previous, .up: return flat.last
            }
        }
        switch move {
        case .next: return index + 1 < flat.count ? flat[index + 1] : nil
        case .previous: return index > 0 ? flat[index - 1] : nil
        case .up, .down:
            guard let row = rows.firstIndex(where: { $0.contains(current) }), let column = rows[row].firstIndex(of: current) else { return nil }
            let next = move == .up ? row - 1 : row + 1
            guard rows.indices.contains(next) else { return nil }
            return rows[next][min(column, rows[next].count - 1)]
        }
    }
}
