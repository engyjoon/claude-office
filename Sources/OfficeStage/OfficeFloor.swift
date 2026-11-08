import Foundation
import OfficeCore

/// 사무실 창에서 고른 디렉토리 (직원 현황 패널 위 디렉토리 목록, 2026-11-08). 처음에는 모두.
/// 고른 디렉토리에서 연 메인과 그 서브가 사무실에 놓입니다.
public struct FloorSelection: Hashable, Sendable {
    /// 모두 보기. 새로 열린 디렉토리의 메인도 자동으로 들어갑니다.
    public var all: Bool
    /// `all`이 아닐 때 고른 디렉토리 (`Team.folder`와 같은 형식: 워크트리는 원래 폴더)
    public var folders: Set<String>
    /// 행 하나만 고름 (미니 사무실, M5(4)). 정해져 있으면 `all`·`folders`보다 우선합니다.
    public var team: TeamID?

    public init(all: Bool = true, folders: Set<String> = [], team: TeamID? = nil) {
        self.all = all
        self.folders = folders
        self.team = team
    }

    public static let everyone = FloorSelection()
    /// 아무도 보여 주지 않음
    public static let nobody = FloorSelection(all: false)

    /// 행 하나만 (nil이면 아무도)
    public static func only(_ team: TeamID?) -> FloorSelection {
        team.map { FloorSelection(all: false, team: $0) } ?? .nobody
    }

    public func contains(folder: String) -> Bool { team == nil && (all || folders.contains(folder)) }
    public func contains(_ team: Team) -> Bool {
        if let only = self.team { return team.id == only }
        return contains(folder: team.folder)
    }
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
    /// 실제 책상 대신 앉힐 책상 (한 행 띠에서 고른 서브 → 1·2번 칸)
    public var seatMap: [AgentID: Seat] = [:]

    public static let empty = FloorPlan(rows: [], hiddenTeams: [], visible: [], hiddenCount: 0)

    /// 한 행 띠 (미니 사무실 v2, M5(4)): 고른 행의 메인과 쉬지 않는 서브 `slots`명만 1번 칸부터 앉힙니다 (`MiniCast`).
    public static func band(
        state: OfficeState, selection: FloorSelection, journal: ActivityJournal, previous: [AgentID: Seat], slots: Int
    ) -> FloorPlan {
        var plan = FloorPlan.empty
        guard let team = state.sortedTeams.first(where: { selection.contains($0) && !state.agents(in: $0.id).isEmpty }) else { return plan }
        let people = state.agents(in: team.id)
        let main = people.filter(\.isMain)
        let cast = MiniCast.pick(subs: people.filter { !$0.isMain }, previous: previous, journal: journal, slots: slots)
        let shown = main.map(\.id) + cast.sorted { $0.value < $1.value }.map(\.key)
        plan.rows = [Row(team: team.id, visible: shown, hidden: people.count - shown.count)]
        plan.visible = Set(shown)
        plan.hiddenCount = people.count - shown.count
        plan.seatMap = cast
        return plan
    }

    /// 행이 화면에 다 들어가지 않으면 **가장 최근에 활동한 행**들을 보여 주고, 가장 오래 조용한 행부터 숨깁니다 (M5(5) 화면 확인).
    /// 보여 주는 행의 위아래 순서와 메인 번호는 그대로(메인이 온 순서)입니다.
    public static func make(state: OfficeState, selection: FloorSelection, capacity: OfficeLayout.Capacity) -> FloorPlan {
        var plan = FloorPlan.empty
        let teams = state.sortedTeams.filter { selection.contains($0) && !state.agents(in: $0.id).isEmpty }
        let shownTeams = Set(
            teams.map { ($0, lastActivity(of: $0.id, in: state)) }
                .sorted { ($0.1, -$0.0.order) > ($1.1, -$1.0.order) }
                .prefix(capacity.rows)
                .map(\.0.id))
        for team in teams {
            let people = state.agents(in: team.id)
            if !shownTeams.contains(team.id) {
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

    /// 행의 마지막 활동: 그 행 사람들의 활동이 바뀐 때와 세션이 요청을 받은 때 중 가장 최근.
    /// 미리 앉힌 데스크톱 세션은 데스크톱 앱의 마지막 활동 시각입니다 (§5.2).
    public static func lastActivity(of team: TeamID, in state: OfficeState) -> Date {
        let people = state.agents(in: team)
        let activity = people.map(\.activitySince).max() ?? .distantPast
        let prompt = Set(people.map(\.session)).compactMap { state.parts[$0]?.lastPromptAt }.max() ?? .distantPast
        return max(activity, prompt)
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
    /// 한 행 띠 (미니 사무실, M5(4)): 고른 행의 메인과 쉬지 않는 서브 `subSlots`명만 첫 행 자리에 앉힙니다.
    /// 무대 배치는 사무실과 같고(출입문은 오른쪽 밖), 공용 구역에 가는 대신 자기 책상에서 쉽니다(`StageConfig.commonAreasAtDesk`).
    public let isBand: Bool
    public let subSlots: Int

    public init(config: StageConfig = .init(), selection: FloorSelection = .everyone,
                width: Double = OfficeLayout.defaultWidth, height: Double = OfficeLayout.defaultHeight, band: Bool = false,
                subSlots: Int = MiniOffice.subSlots) {
        var config = config
        if band { config.commonAreasAtDesk = true }
        stage = Stage(config: config)
        self.selection = selection
        isBand = band
        self.subSlots = subSlots
        viewport = (width, height)
        stage.setViewport(width: width, height: height)
    }

    /// 동작 줄이기 (M5(8))
    public mutating func setReducedMotion(_ on: Bool) {
        stage.setReducedMotion(on)
    }

    public var capacity: OfficeLayout.Capacity {
        isBand
            ? OfficeLayout.Capacity(columns: 1 + subSlots, rows: 1)
            : OfficeLayout.capacity(width: viewport.width, height: viewport.height)
    }

    private func makePlan(_ engine: OfficeEngine) -> FloorPlan {
        isBand
            ? FloorPlan.band(state: engine.state, selection: selection, journal: engine.journal, previous: plan.seatMap, slots: subSlots)
            : FloorPlan.make(state: engine.state, selection: selection, capacity: capacity)
    }

    // MARK: - 지시 흘리기

    /// 엔진이 낸 지시를 넘깁니다. `engine`은 지시를 낸 뒤의 상태입니다.
    public mutating func apply(_ directives: [Directive], engine: OfficeEngine) {
        let next = makePlan(engine)
        let previous = plan
        plan = next
        let state = engine.state

        // 숨게 된 사람은 바로 내립니다
        for id in previous.visible.subtracting(next.visible).sorted() where state.agents[id] != nil {
            stage.remove(id)
        }
        syncTeams(state)
        stage.setSeatMap(next.seatMap)

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

    /// 고른 디렉토리가 바뀜: 숨은 사람은 내리고, 새로 보이는 사람은 그 자리에 바로 놓습니다.
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
        let next = makePlan(engine)
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
        stage.setSeatMap(next.seatMap)
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
