import Foundation
import OfficeCore

/// 사무실 창에서 고른 메인 (설계서 §10, M5(1)). 처음에는 모두.
public struct FloorSelection: Hashable, Sendable {
    /// 모두 보기. 새로 온 메인도 자동으로 들어갑니다.
    public var all: Bool
    /// `all`이 아닐 때 고른 행
    public var teams: Set<TeamID>

    public init(all: Bool = true, teams: Set<TeamID> = []) {
        self.all = all
        self.teams = teams
    }

    public static let everyone = FloorSelection()

    public func contains(_ team: TeamID) -> Bool { all || teams.contains(team) }
}

/// 화면에 무엇을 보여 줄지 (순수 계산). 고른 메인의 행을 온 순서대로 위에서부터 놓고,
/// 화면에 들어가는 행 수·책상 수를 넘는 행과 서브는 숨깁니다 (숨긴 사람은 행 끝 "+N", 직원 현황 패널에 수만 알림).
public struct FloorPlan: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var team: TeamID
        /// 보여 주는 사람 (책상 순서)
        public var visible: [AgentID]
        /// 책상이 화면 밖이라 숨긴 서브 수
        public var hidden: Int
    }

    /// 보여 주는 행 (위에서부터)
    public var rows: [Row]
    /// 고른 메인이지만 화면에 행이 모자라 숨긴 행
    public var hiddenTeams: [TeamID]
    public var visible: Set<AgentID>
    /// 고른 메인의 사람 중 화면에 다 못 보여 준 수 (넘친 서브 + 숨긴 행의 모든 사람)
    public var hiddenCount: Int

    public static let empty = FloorPlan(rows: [], hiddenTeams: [], visible: [], hiddenCount: 0)

    public static func make(state: OfficeState, selection: FloorSelection, capacity: OfficeLayout.Capacity) -> FloorPlan {
        var plan = FloorPlan.empty
        for team in state.sortedTeams where selection.contains(team.id) {
            let people = state.agents(in: team.id)
            guard !people.isEmpty else { continue }
            if plan.rows.count >= capacity.rows {
                plan.hiddenTeams.append(team.id)
                plan.hiddenCount += people.count
                continue
            }
            // 책상은 0번부터 빈자리 없이 이어지므로, 화면에 들어가는 책상 번호까지만 보여 줍니다
            let shown = people.filter { $0.seat.desk < capacity.columns }.map(\.id)
            plan.rows.append(Row(team: team.id, visible: shown, hidden: people.count - shown.count))
            plan.visible.formUnion(shown)
            plan.hiddenCount += people.count - shown.count
        }
        return plan
    }
}

/// 연출 엔진의 지시를 화면에 보일 사람만 골라 무대에 넘기는 층 (M5(1)).
///
/// - 엔진은 모든 사람을 계속 연출하고, 무대에는 고른 메인의 행 중 화면에 들어가는 사람만 섭니다.
/// - 숨어 있던 사람이 보이게 되면(자리가 났거나 선택·창 크기가 바뀜) 엔진이 아는 지금 모습으로 다시 세웁니다:
///   일하는 중 자리가 나면 출입문에서 걸어 들어오고, 선택이나 창 크기가 바뀌면 그 자리에 바로 놓습니다.
/// - 보이던 사람이 숨으면 바로 사라집니다.
public struct OfficeFloor: Sendable {
    public private(set) var stage: Stage
    public private(set) var selection: FloorSelection
    public private(set) var plan = FloorPlan.empty
    public private(set) var viewport: (width: Double, height: Double)

    public init(config: StageConfig = .init(), selection: FloorSelection = .everyone,
                width: Double = OfficeLayout.defaultWidth, height: Double = OfficeLayout.defaultHeight) {
        stage = Stage(config: config)
        self.selection = selection
        viewport = (width, height)
        stage.setViewport(width: width, height: height)
    }

    public var capacity: OfficeLayout.Capacity { OfficeLayout.capacity(width: viewport.width, height: viewport.height) }

    // MARK: - 지시 흘리기

    /// 엔진이 낸 지시를 넘깁니다. `engine`은 지시를 낸 뒤의 상태입니다.
    public mutating func apply(_ directives: [Directive], engine: OfficeEngine) {
        let next = FloorPlan.make(state: engine.state, selection: selection, capacity: capacity)
        let previous = plan
        plan = next
        let state = engine.state

        // 숨게 된 사람은 바로 내립니다
        for id in previous.visible.subtracting(next.visible).sorted() where state.agents[id] != nil {
            stage.remove(id)
        }
        syncTeams(state)

        var spawned = Set<AgentID>()
        for directive in directives {
            if case .spawn(let agent, _) = directive.action { spawned.insert(agent.id) }
        }
        var restored = Set<AgentID>()
        var passed: [Directive] = []
        for directive in directives {
            guard let id = directive.agent else {
                // 행 열기·닫기는 위에서 직접 맞췄습니다. 효과음·효과는 그대로.
                switch directive.action {
                case .openTeam, .closeTeam: continue
                default: passed.append(directive)
                }
                continue
            }
            if let agent = state.agents[id] {
                guard next.visible.contains(id) else { continue }
                if stage.knows(id) || spawned.contains(id) {
                    passed.append(directive)
                } else if restored.insert(id).inserted {
                    // 보이게 된 사람 (예: 가운데 서브가 퇴근해 오른쪽 끝 사람이 화면 안 책상으로 옮김)
                    passed += engine.choreographer.restoreDirectives(for: agent, entering: true)
                }
            } else if stage.knows(id) {
                // 퇴근하는 사람의 마지막 연출
                passed.append(directive)
            }
        }
        stage.enqueue(passed)

        // 지시와 상관없이 보이게 된 사람 (다른 행이 닫혀 행이 올라옴 등)
        var entering: [Directive] = []
        for id in next.visible.sorted() where !stage.knows(id) && !restored.contains(id) {
            if let agent = state.agents[id] {
                entering += engine.choreographer.restoreDirectives(for: agent, entering: true)
            }
        }
        if !entering.isEmpty { stage.enqueue(entering) }
    }

    public mutating func update(dt: Double) {
        stage.update(dt: dt)
    }

    public mutating func drainEvents() -> [StageEvent] {
        stage.drainEvents()
    }

    // MARK: - 선택과 화면 크기

    /// 고른 메인이 바뀜: 숨은 사람은 내리고, 새로 보이는 사람은 그 자리에 바로 놓습니다.
    public mutating func setSelection(_ selection: FloorSelection, engine: OfficeEngine) {
        guard selection != self.selection else { return }
        self.selection = selection
        resync(engine: engine)
    }

    /// 화면(사무실 영역) 크기가 바뀜: 사무실은 줄이지 않고 들어가는 수를 다시 셉니다.
    public mutating func setViewport(width: Double, height: Double, engine: OfficeEngine) {
        guard viewport.width != width || viewport.height != height else { return }
        viewport = (width, height)
        stage.setViewport(width: width, height: height)
        resync(engine: engine)
    }

    private mutating func resync(engine: OfficeEngine) {
        let next = FloorPlan.make(state: engine.state, selection: selection, capacity: capacity)
        let previous = plan
        plan = next
        for id in previous.visible.subtracting(next.visible).sorted() {
            stage.remove(id)
        }
        // 무대에 남아 있지만 이제 보이지 않을 사람 (퇴근 중인 사람은 그대로 나가게 둡니다)
        for actor in stage.sortedActors where engine.state.agents[actor.id] != nil && !next.visible.contains(actor.id) {
            stage.remove(actor.id)
        }
        syncTeams(engine.state)
        var placed: [Directive] = []
        for id in next.visible.sorted() where !stage.knows(id) {
            if let agent = engine.state.agents[id] {
                placed += engine.choreographer.restoreDirectives(for: agent, entering: false)
            }
        }
        if !placed.isEmpty { stage.enqueue(placed) }
    }

    /// 보여 줄 행을 무대에 맞춥니다 (순서, 숨긴 사람 수)
    private mutating func syncTeams(_ state: OfficeState) {
        let teams = plan.rows.compactMap { state.teams[$0.team] }
        var hidden: [TeamID: Int] = [:]
        for row in plan.rows { hidden[row.team] = row.hidden }
        stage.setTeams(teams, hidden: hidden)
    }
}
