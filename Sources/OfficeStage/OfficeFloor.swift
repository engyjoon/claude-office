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

    /// 보이는 행이 조용하면 숨은 행에 자리를 내주기까지 기다리는 시간 (개선 5)
    public static let linger: TimeInterval = 45

    /// 행이 화면에 다 들어가지 않으면 **급하고 최근에 활동한 행**들을 보여 줍니다 (M5(5) 화면 확인, 개선 5에서 머무름 추가).
    /// 보여 주는 행의 위아래 순서와 메인 번호는 그대로(메인이 온 순서)입니다.
    ///
    /// `previous`에서 보이던 행은 그대로 머물고, 숨은 행은 빈자리를 채우거나 아래 조건으로 보이던 행을 밀어냅니다
    /// (바쁜 행이 4개 이상일 때 숨은 행에 훅이 올 때마다 보이는 행이 통째로 바뀌지 않게):
    /// - 행의 급함(`Urgency`): 승인 대기 > 일하는 중·답변 필요 > 쉬는 중. 숨은 행은 급함과 마지막 활동이 앞서야 밀어냅니다.
    /// - 밀려나는 행: 승인 대기는 밀려나지 않고, 쉬는 행은 바로, 일하는 행은 `linger`초 넘게 조용할 때만.
    ///   승인을 기다리는 숨은 행은 조용하지 않은 행도 바로 밀어냅니다 (보이는 행이 모두 승인 대기면 현황 줄의 "[화면 밖]" 알림, §10.2).
    /// - 밀어낼 행이 여럿이면 가장 덜 급하고 가장 오래 조용한 행.
    /// 조용한 시간은 고른 행들의 가장 최근 활동(보통 방금 온 훅)부터 셉니다.
    public static func make(
        state: OfficeState, selection: FloorSelection, capacity: OfficeLayout.Capacity, previous: FloorPlan = .empty,
        linger: TimeInterval = FloorPlan.linger
    ) -> FloorPlan {
        var plan = FloorPlan.empty
        let teams = state.sortedTeams.filter { selection.contains($0) && !state.agents(in: $0.id).isEmpty }
        let shownTeams = pickRows(teams, state: state, rows: capacity.rows, previous: Set(previous.rows.map(\.team)), linger: linger)
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

    /// 행의 급함: 숨은 행이 보이던 행을 밀어낼 수 있는지 가립니다
    enum Urgency: Int, Comparable {
        /// 모두 출근 중·쉬는 중·입력 대기 (확인 안 한 응답 포함)
        case resting
        /// 누군가 일하는 중이거나 답변을 기다림
        case busy
        /// 누군가 승인을 기다림
        case asking

        static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    static func urgency(of team: TeamID, in state: OfficeState) -> Urgency {
        let people = state.agents(in: team)
        if people.contains(where: MiniCast.isAsking) { return .asking }
        // 출근 중(요청을 받기 전)도 쉬는 중으로 칩니다: 새로 연 세션이 쉬는 행 대신 보이게
        if people.contains(where: { !MiniCast.isResting($0) && $0.activity != .arriving || $0.cue == .reply }) { return .busy }
        return .resting
    }

    /// 보여 줄 행을 고릅니다 (`make` 설명 참고)
    static func pickRows(_ teams: [Team], state: OfficeState, rows: Int, previous: Set<TeamID>, linger: TimeInterval) -> Set<TeamID> {
        guard teams.count > rows else { return Set(teams.map(\.id)) }
        struct Candidate {
            let team: Team
            let urgency: Urgency
            let activity: Date
        }
        let all = teams.map { Candidate(team: $0, urgency: urgency(of: $0.id, in: state), activity: lastActivity(of: $0.id, in: state)) }
        let now = all.map(\.activity).max() ?? .distantPast
        /// 더 보여 줄 만한 행이 앞에: 급함 → 최근 활동 → 먼저 온 행
        func before(_ a: Candidate, _ b: Candidate) -> Bool {
            (a.urgency, a.activity, -a.team.order) > (b.urgency, b.activity, -b.team.order)
        }
        func yields(_ shown: Candidate, to hidden: Candidate) -> Bool {
            guard shown.urgency != .asking, before(hidden, shown) else { return false }
            return hidden.urgency == .asking || shown.urgency == .resting || now.timeIntervalSince(shown.activity) >= linger
        }
        // 보이던 행은 머뭅니다 (행 수가 줄었으면 덜 보여 줄 만한 행부터 숨김)
        var shown = Array(all.filter { previous.contains($0.team.id) }.sorted(by: before).prefix(rows))
        var hidden = all.filter { candidate in !shown.contains { $0.team.id == candidate.team.id } }.sorted(by: before)
        // 빈자리는 가장 보여 줄 만한 숨은 행으로
        while shown.count < rows, !hidden.isEmpty { shown.append(hidden.removeFirst()) }
        // 숨은 행이 보이던 행을 밀어냄
        for candidate in hidden {
            let victims = shown.indices.filter { yields(shown[$0], to: candidate) }
            guard let victim = victims.min(by: { before(shown[$1], shown[$0]) }) else { continue }
            shown[victim] = candidate
        }
        return Set(shown.map(\.team.id))
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
    /// 말풍선은 띄우지 않습니다(`StageConfig.showsBubbles`).
    public let isBand: Bool
    public let subSlots: Int

    public init(config: StageConfig = .init(), selection: FloorSelection = .everyone,
                width: Double = OfficeLayout.defaultWidth, height: Double = OfficeLayout.defaultHeight, band: Bool = false,
                subSlots: Int = MiniOffice.subSlots) {
        var config = config
        if band {
            config.commonAreasAtDesk = true
            config.showsBubbles = false
        }
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
        guard isBand else { return FloorPlan.make(state: engine.state, selection: selection, capacity: capacity, previous: plan) }
        var plan = FloorPlan.band(state: engine.state, selection: selection, journal: engine.journal, previous: self.plan.seatMap, slots: subSlots)
        // 앞 칸이 비면 뒤 칸 서브를 당겨 앉힙니다 (M6(9b)). 퇴근하는 사람(엔진에는 없고 무대에만 남음)이 보고하고
        // 자기 책상에서 물을 마신 뒤 문 밖으로 나갈 때까지 기다립니다. 바로 당기면 그 책상에서 두 사람이 겹칩니다.
        let leaving = stage.actors.keys.filter { engine.state.agents[$0] == nil }
        if leaving.isEmpty {
            plan.seatMap = MiniCast.packed(plan.seatMap)
        }
        // 퇴근하는 사람은 무대를 떠날 때까지 앉아 있던 칸을 지킵니다 (M6(12)). 칸이 빠지면 무대가 사무실의 실제 책상 번호로
        // 돌아가, 그 번호까지 책상이 늘고 오른쪽 끝에 명패 없는 책상이 생겼습니다 (데스크톱 서브가 많은 행에서 보관할 때).
        for id in leaving {
            if let seat = self.plan.seatMap[id] { plan.seatMap[id] = seat }
        }
        return plan
    }

    // MARK: - 지시 흘리기

    /// 엔진이 낸 지시를 넘깁니다. `engine`은 지시를 낸 뒤의 상태입니다.
    public mutating func apply(_ directives: [Directive], engine: OfficeEngine) {
        // 행·"+N"·칸을 맞추고 지시를 넘기는 동안 배치가 여러 번 바뀌어도 길찾기는 끝에 한 번만 (개선 5)
        stage.beginBatch()
        defer { stage.endBatch() }
        let next = makePlan(engine)
        let previous = plan
        plan = next
        let state = engine.state

        // 숨게 된 사람은 바로 내립니다
        for id in previous.visible.subtracting(next.visible).sorted() where state.agents[id] != nil {
            stage.remove(id)
        }
        clearLeavingElsewhere(state)
        syncTeams(state)
        // 미니에서 칸을 당겨 앉을 때는 걸어서 옮깁니다 (M6(9b))
        stage.setSeatMap(next.seatMap, walking: isBand)

        var spawned = Set<AgentID>()
        for directive in directives {
            if case .spawn(let agent, _) = directive.action { spawned.insert(agent.id) }
        }
        var restored = Set<AgentID>()
        var passed: [Directive] = []
        /// 무대에 넘기지 않은 사람이 보낼 신호 (화면 밖 서브의 보고)
        var unsent: [String] = []
        for directive in directives {
            guard let id = directive.agent else {
                // 행 열기·닫기는 위에서 직접 맞췄습니다. 효과음·효과는 그대로.
                switch directive.action {
                case .openTeam, .closeTeam: continue
                default: passed.append(directive)
                }
                continue
            }
            var kept = false
            if let agent = state.agents[id] {
                if !next.visible.contains(id) {
                    // 숨은 사람의 지시는 버립니다
                } else if stage.knows(id) || spawned.contains(id) {
                    passed.append(directive)
                    kept = true
                } else if restored.insert(id).inserted {
                    // 보이게 된 사람 (예: 가운데 서브가 퇴근해 오른쪽 끝 사람이 화면 안 책상으로 옮김)
                    passed += engine.choreographer.restoreDirectives(for: agent, entering: true)
                }
            } else if stage.knows(id) {
                // 퇴근하는 사람의 마지막 연출
                passed.append(directive)
                kept = true
            }
            if !kept, case .signal(let name) = directive.action { unsent.append(name) }
        }
        stage.enqueue(passed)
        // 숨은 서브의 보고를 기다리던 메인은 기다리지 않고 함께하는 연출(하이파이브)을 건너뜁니다 (개선 5).
        // 넘기지 않으면 메인의 대기열이 시간 제한(8초)까지 막혀 상태 칩·자세가 늦고, 그 뒤 아무도 없는 곳에 하이파이브합니다.
        for name in unsent { stage.withdraw(signal: name) }

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
        stage.beginBatch()
        defer { stage.endBatch() }
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
        clearLeavingElsewhere(engine.state)
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

    /// 띠(미니)에서 고른 행이 아닌 행의 퇴근하던 사람을 바로 치웁니다 (개선 5). 사무실 창은 그대로 문까지 걸어 나가게 둡니다.
    /// 남겨 두면 그 사람의 행이 닫히지 않고 지도 첫 행 자리를 차지해, 새로 고른 행이 띠 아래(보이지 않는 곳)로 내려갔습니다.
    private mutating func clearLeavingElsewhere(_ state: OfficeState) {
        guard isBand, let shown = plan.rows.first?.team else { return }
        for actor in stage.sortedActors where state.agents[actor.id] == nil && actor.agent.teamID != shown {
            stage.remove(actor.id)
        }
    }

    /// 보여 줄 행을 무대에 맞춥니다 (순서, 숨긴 사람 수)
    private mutating func syncTeams(_ state: OfficeState) {
        let teams = plan.rows.compactMap { state.teams[$0.team] }
        var hidden: [TeamID: Int] = [:]
        for row in plan.rows { hidden[row.team] = row.hidden }
        stage.setTeams(teams, hidden: hidden)
    }
}
