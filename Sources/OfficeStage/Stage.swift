import Foundation
import OfficeCore

public enum Facing: String, Hashable, Sendable {
    case front, left, right
}

/// 휴게 공간에서 앉는 가구
public enum LoungeSeat: String, Hashable, Sendable {
    case sofa, massageChair
}

/// 무대 위 직원 한 명의 지금 모습. 렌더러(SpriteKit, SVG)는 이것만 보고 그립니다.
public struct StageActor: Identifiable, Hashable, Sendable {
    public let id: AgentID
    public internal(set) var agent: Agent
    public internal(set) var position: MapPoint
    public internal(set) var facing: Facing = .front
    public internal(set) var seated = false
    public internal(set) var pose: Pose = .standing
    public internal(set) var expression: FacialExpression = .neutral
    public internal(set) var emote: Emote?
    /// 머리 왼쪽 위 배지 (답변 필요 "?", 확인 안 함 ✉, M6(4))
    public internal(set) var badge: SessionCue?
    public internal(set) var bubble: Bubble?
    public internal(set) var pill: StatusPill?
    public internal(set) var prop: Prop?
    public internal(set) var gesture: BodyGesture?
    /// 제스처를 시작한 무대 시각 (렌더러가 애니메이션 진행도를 계산)
    public internal(set) var gestureStartedAt: Double = 0
    /// 걷기 시작부터 누적한 거리 (렌더러가 다리 흔들림 위상을 계산)
    public internal(set) var walkedDistance: Double = 0
    public internal(set) var path: [MapPoint] = []
    /// 말풍선이 화면에 뜬 무대 시각 (렌더러가 톡 튀어나오는 애니메이션을 계산)
    public internal(set) var bubbleShownAt: Double = 0
    public internal(set) var emoteShownAt: Double = 0
    public internal(set) var badgeShownAt: Double = 0
    /// 행의 말풍선이 꽉 차서 기다리는 말풍선 (설계서 §7.2)
    public internal(set) var queuedBubble: QueuedBubble?

    public var isWalking: Bool { !path.isEmpty }

    /// 휴게 공간의 소파·안마 의자 자리에 앉아 있으면 그 가구. 렌더러는 이때 서 있는 다리 대신 앉은 다리를 가구 앞에 그립니다.
    /// (책상에 앉으면 다리가 책상 뒤에 가려지므로 서 있는 다리 그대로 둡니다.)
    public var loungeSeat: LoungeSeat? {
        guard !isWalking, let place, position.distance(to: place.final) < 1, let key = place.key else { return nil }
        let parts = key.split(separator: ":")
        guard parts.count == 2, Int(parts[1]) != nil else { return nil }  // 넘친 자리("lounge:x0")는 서 있습니다
        switch parts[0] {
        case "lounge": return .sofa
        case "massageChair": return .massageChair
        default: return nil
        }
    }

    var place: Place?
    var bubbleUntil: Double?
    var gestureUntil: Double?
    /// 다음 `say`와 함께 울릴 말풍선 블립. 말풍선이 실제로 보일 때 울립니다.
    var pendingBlip: SoundCue?
    /// 이 말풍선과 함께 울릴 블립 (자리를 빼앗겨 대기열로 갈 때 같이 옮깁니다)
    var bubbleBlip: SoundCue?
    var nextFootstepAt: Double = 0
    var nextTypingAt: Double = 0
}

/// 자리가 날 때까지 기다리는 말풍선
public struct QueuedBubble: Hashable, Sendable {
    public var bubble: Bubble
    /// 대기열에 들어간 무대 시각
    public var since: Double
    var blip: SoundCue?
}

extension BubbleKind {
    /// 행의 말풍선 자리가 모자랄 때 남길 순서 (설계서 §6.3 우선순위: 승인 대기 > 대화 > 생각 > 잡담)
    public var priority: Int {
        switch self {
        case .shout: 3
        case .speech: 2
        case .thought: 1
        case .whisper: 0
        }
    }
}

/// 잠깐 그렸다가 사라지는 효과 (종이비행기, 하이파이브 반짝임)
public struct StageEffect: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// 새 프롬프트가 날아와 팀장에게 도착합니다. 도착 지점은 그 직원의 지금 위치로 계산합니다.
        case paperPlane(to: AgentID)
        case sparkle(at: MapPoint)
    }

    public let id: Int
    public var kind: Kind
    public var startedAt: Double
    public var duration: Double

    public func progress(at time: Double) -> Double {
        min(max((time - startedAt) / duration, 0), 1)
    }
}

/// 렌더러에 알릴 일회성 사건
public enum StageEvent: Hashable, Sendable {
    case teamOpened(Team)
    case teamClosed(TeamID)
    case spawned(AgentID)
    case despawned(AgentID)
    case sound(SoundCue, AgentID?)
    case effect(Effect)
}

public struct StageConfig: Hashable, Sendable {
    /// 걷는 속도 (pt/초)
    public var walkSpeed = 120.0
    public var gestureDuration = 1.2
    /// 행(메인 하나와 그 서브들)마다 동시에 보이는 말풍선 수 (설계서 §7.2, M5(1))
    public var maxBubblesPerUnit = 3
    /// 대기열에서 이보다 오래 기다린 말풍선은 버립니다 (외침 풍선은 버리지 않음)
    public var bubbleQueueTimeout = 6.0
    public var paperPlaneDuration = 1.3
    public var sparkleDuration = 0.9
    /// 발소리·타이핑 소리 간격 (둘 다 기본으로 꺼져 있는 장식 소리, 설계서 §11.2)
    public var footstepInterval = 0.42
    public var typingInterval = 1.4
    /// 공용 구역(소파·안마 의자·탕비 코너·화이트보드)에 가는 대신 자기 책상에서 합니다. 미니 사무실은 휴게 공간을 보여 주지 않으므로 켭니다 (M5(4) v2).
    /// 안마는 졸기로, 화이트보드에 쓰기는 타이핑으로 바꿉니다.
    public var commonAreasAtDesk = false
    /// 동작 줄이기 (설계서 §10, M5(8)): 걷는 대신 도착할 자리로 바로 옮기고(순간이동), 제스처를 생략합니다.
    public var reducedMotion = false

    public init() {}
}

/// 연출 지시(Directive)를 시간에 따라 실행하는 무대 (설계서 §6.4).
///
/// - 직원마다 대기열이 있고 지시를 순서대로 실행합니다.
/// - `walk`는 도착할 때까지, `wait`는 그 시간만큼, `await`는 신호가 오거나 시간이 다 될 때까지 다음 지시를 막습니다.
/// - `clearQueue`는 아직 실행하지 않은 지시를 버리고 막힘을 풉니다. 걷던 중이면 목적지까지 걸으면서 새 지시를 바로 실행합니다.
/// - 같은 구역(화이트보드, 휴게 공간 …)에는 자리를 예약해서 겹쳐 서지 않게 하고, 자리가 넘치면 구역 가까이 흩어 섭니다.
///
/// 순수 값 타입이라 Linux에서 시간을 직접 흘려가며 테스트할 수 있습니다.
public struct Stage: Sendable {
    public var config: StageConfig
    public private(set) var layout: OfficeLayout
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var actors: [AgentID: StageActor] = [:]
    public private(set) var time: Double = 0
    /// 행 끝 "+N": 화면에 다 못 보여 줘서 숨긴 사람 수 (`OfficeFloor`가 정함)
    public private(set) var hiddenCounts: [TeamID: Int] = [:]
    /// 실제 책상 대신 앉힐 책상 (미니 사무실: 고른 서브를 1·2번 칸에, `OfficeFloor`가 정함)
    public private(set) var seatMap: [AgentID: Seat] = [:]
    /// 지금 그리는 효과
    public private(set) var effects: [StageEffect] = []
    private var nextEffectID = 0

    private var pathfinder: Pathfinder
    private var queues: [AgentID: [Directive.Action]] = [:]
    private var blocks: [AgentID: Block] = [:]
    private var signals: Set<String> = []
    private var reservations: [String: AgentID] = [:]
    private var events: [StageEvent] = []
    /// 닫으라는 지시를 받았지만 아직 직원이 문을 나가는 중인 방
    private var closingTeams: Set<TeamID> = []
    /// 행이 닫혀 아래 행을 올릴 수 있음 → 그 자리에 아무도 없을 때 올립니다
    private var compactionPending = false
    /// 행 순서 (닫히는 중인 행도 자리를 지키도록 기억해 둠)
    private var teamOrders: [TeamID: Int] = [:]
    /// 화면(사무실 영역) 크기
    private var viewport = (width: OfficeLayout.defaultWidth, height: OfficeLayout.defaultHeight)

    private enum Block: Hashable, Sendable {
        case walking
        case waitUntil(Double)
        case awaiting(String, deadline: Double)
    }

    public init(config: StageConfig = .init()) {
        self.config = config
        layout = OfficeLayout()
        pathfinder = Pathfinder(layout: layout)
    }

    public var sortedActors: [StageActor] {
        actors.values.sorted { $0.position.y == $1.position.y ? $0.id < $1.id : $0.position.y < $1.position.y }
    }

    /// 행 순서 (메인이 온 순서)
    public var sortedTeams: [Team] {
        teams.values.sorted { $0.order < $1.order }
    }

    /// 쌓인 사건을 꺼냅니다 (렌더러가 매 프레임 호출)
    public mutating func drainEvents() -> [StageEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - 지시 받기

    public mutating func enqueue(_ directives: [Directive]) {
        var touched: [AgentID] = []
        for directive in directives {
            guard let id = directive.agent else {
                performGlobal(directive.action)
                continue
            }
            if directive.action == .clearQueue {
                queues[id] = []
                interrupt(id)
            } else if case .refresh = directive.action, actors[id] != nil {
                // 직함·자리 정보는 걷는 중에도 바로 바꿉니다 (명패가 앉은 뒤에야 "서브" → "서브1"로 바뀌지 않게).
                // 이미 줄 서 있던 옛 정보는 버립니다.
                queues[id]?.removeAll { if case .refresh = $0 { true } else { false } }
                perform(directive.action, for: id)
            } else {
                queues[id, default: []].append(directive.action)
            }
            if !touched.contains(id) { touched.append(id) }
        }
        for id in touched {
            run(id)
        }
        settleSignals()
    }

    // MARK: - 시간 흐르기

    public mutating func update(dt: Double) {
        guard dt > 0 else { return }
        time += dt
        for id in actors.keys.sorted() {
            advanceWalk(id, dt: dt)
            ambientSounds(id)
            expire(id)
            switch blocks[id] {
            case .waitUntil(let until) where time >= until:
                blocks[id] = nil
                run(id)
            case .awaiting(_, let deadline) where time >= deadline:
                blocks[id] = nil
                run(id)
            default:
                break
            }
        }
        // 직원 없이 대기열만 남은 경우 (spawn 전 지시) 정리
        for id in queues.keys.sorted() where actors[id] == nil && blocks[id] == nil {
            run(id)
        }
        settleSignals()
        promoteQueuedBubbles()
        effects.removeAll { time >= $0.startedAt + $0.duration }
        if compactionPending { updateLayout() }
    }

    // MARK: - 실행

    private mutating func run(_ id: AgentID) {
        while blocks[id] == nil, var queue = queues[id], !queue.isEmpty {
            let action = queue.removeFirst()
            queues[id] = queue
            perform(action, for: id)
        }
        if queues[id]?.isEmpty == true, blocks[id] == nil {
            queues[id] = nil
        }
    }

    private mutating func perform(_ action: Directive.Action, for id: AgentID) {
        if case .spawn(let agent, let spot) = action {
            spawn(agent, at: spot)
            return
        }
        guard actors[id] != nil else { return }  // 등장 전이거나 퇴장한 직원의 지시는 버립니다
        switch action {
        case .spawn, .openTeam, .closeTeam, .clearQueue:
            break
        case .refresh(let agent):
            let previous = actors[id]!.agent
            let unit = Self.bubbleUnit(previous)
            actors[id]!.agent = agent
            updateLayout()
            if Self.bubbleUnit(agent) != unit { promoteQueuedBubbles(in: unit) }
        case .despawn:
            release(id)
            let agent = actors[id]!.agent
            actors[id] = nil
            promoteQueuedBubbles(in: Self.bubbleUnit(agent))
            blocks[id] = nil
            queues[id] = nil
            events.append(.despawned(id))
            compactionPending = true
            finishClosingTeams()
        case .walk(let spot):
            walk(id, to: spot)
        case .sit:
            actors[id]!.seated = true
            actors[id]!.facing = .front
            if actors[id]!.pose == .standing { actors[id]!.pose = .sitting }
        case .stand:
            // 책상에서 쉬기: 쉬러 가거나 자리로 돌아오는 걸음이 제자리면 일어나지 않습니다 (M5(4) 화면 확인: 일어났다 다시 앉음)
            if config.commonAreasAtDesk, staysPut(id) { break }
            actors[id]!.seated = false
            if actors[id]!.pose == .sitting { actors[id]!.pose = .standing }
        case .pose(let pose):
            // 책상에서 쉬기: 안마 → 졸기, 화이트보드에 쓰기 → 타이핑
            if config.commonAreasAtDesk, pose == .massage {
                actors[id]!.pose = .sleeping
            } else if config.commonAreasAtDesk, pose == .writingBoard {
                actors[id]!.pose = .typing
            } else {
                actors[id]!.pose = pose
            }
        case .gesture(let gesture):
            if config.reducedMotion { break }
            actors[id]!.gesture = gesture
            actors[id]!.gestureStartedAt = time
            actors[id]!.gestureUntil = time + config.gestureDuration
            if gesture == .highFive { sparkle(near: actors[id]!.position + MapPoint(0, -98)) }
        case .express(let expression):
            actors[id]!.expression = expression
        case .emote(let emote):
            if actors[id]!.emote != emote { actors[id]!.emoteShownAt = time }
            actors[id]!.emote = emote
        case .badge(let badge):
            if actors[id]!.badge != badge { actors[id]!.badgeShownAt = time }
            actors[id]!.badge = badge
        case .say(let bubble):
            let blip = actors[id]!.pendingBlip
            actors[id]!.pendingBlip = nil
            present(bubble, blip: blip, for: id)
        case .dismissBubble:
            actors[id]!.pendingBlip = nil
            actors[id]!.queuedBubble = nil
            hideBubble(id)
        case .status(let pill):
            actors[id]!.pill = pill
        case .prop(let prop):
            actors[id]!.prop = prop
        case .wait(let seconds):
            if seconds > 0 { blocks[id] = .waitUntil(time + seconds) }
        case .signal(let name):
            signals.insert(name)
        case .await(let name, let timeout):
            if signals.remove(name) == nil {
                blocks[id] = .awaiting(name, deadline: time + timeout)
            }
        case .effect(let effect):
            addEffect(effect)
            events.append(.effect(effect))
        case .sound(let cue):
            switch cue {
            case .bubble, .chatter:
                // 말풍선 블립은 말풍선이 실제로 뜰 때 울립니다 (자리가 없어 기다리면 그때까지 미룹니다)
                actors[id]!.pendingBlip = cue
            default:
                events.append(.sound(cue, id))
            }
        }
    }

    private mutating func performGlobal(_ action: Directive.Action) {
        switch action {
        case .openTeam(let team):
            closingTeams.remove(team.id)
            teamOrders[team.id] = team.order
            teams[team.id] = team
            updateLayout()
            events.append(.teamOpened(team))
        case .closeTeam(let id):
            guard teams[id] != nil else { break }
            closingTeams.insert(id)
            finishClosingTeams()
        case .effect(let effect):
            if case .paperPlane(let target) = effect, actors[target] == nil { break }
            addEffect(effect)
            events.append(.effect(effect))
        case .sound(let cue):
            events.append(.sound(cue, nil))
        default:
            break
        }
    }

    private mutating func spawn(_ agent: Agent, at spot: Spot) {
        release(agent.id)
        let place = resolve(spot, for: agent.id, agent: agent)
        actors[agent.id] = StageActor(id: agent.id, agent: agent, position: place.final, place: place)
        reserve(place, for: agent.id)
        blocks[agent.id] = nil
        updateLayout()
        events.append(.spawned(agent.id))
    }

    // MARK: - 화면에 보일 사람 (OfficeFloor가 씀)

    /// 이 직원이 무대에 있거나 등장 지시를 기다리는지
    public func knows(_ id: AgentID) -> Bool {
        actors[id] != nil || queues[id] != nil
    }

    /// 화면에서 숨깁니다 (메인 선택이 바뀌었거나 화면에 자리가 모자람). 걷지 않고 바로 사라집니다.
    public mutating func remove(_ id: AgentID) {
        queues[id] = nil
        blocks[id] = nil
        guard let actor = actors[id] else { return }
        release(id)
        actors[id] = nil
        promoteQueuedBubbles(in: Self.bubbleUnit(actor.agent))
        events.append(.despawned(id))
        compactionPending = true
        finishClosingTeams()
        updateLayout()
    }

    /// 보여 줄 행 (위에서부터)과 행마다 숨긴 사람 수. 빠진 행은 남은 직원이 나간 뒤 닫습니다.
    public mutating func setTeams(_ teams: [Team], hidden: [TeamID: Int]) {
        for team in teams where self.teams[team.id] == nil || closingTeams.contains(team.id) {
            performGlobal(.openTeam(team))
        }
        let kept = Set(teams.map(\.id))
        for id in self.teams.keys.sorted() where !kept.contains(id) && !closingTeams.contains(id) {
            performGlobal(.closeTeam(id))
        }
        hiddenCounts = hidden.filter { $0.value > 0 }
        updateLayout()
    }

    /// 앉힐 책상을 바꿉니다. 바뀐 사람이 예전 칸에 있거나 가는 중이면 새 칸으로 옮깁니다 (걷던 중이면 새 칸으로 걷고, 아니면 바로).
    public mutating func setSeatMap(_ map: [AgentID: Seat]) {
        guard map != seatMap else { return }
        let old = seatMap
        seatMap = map
        for (id, actor) in actors.sorted(by: { $0.key < $1.key }) {
            let agent = actor.agent
            let before = old[id] ?? agent.seat
            let after = map[id] ?? agent.seat
            guard before != after, let place = actor.place, place.team == agent.teamID, place.seat == before else { continue }
            if actor.isWalking {
                walk(id, to: .seat(agent.teamID, agent.seat))
            } else {
                release(id)
                let target = layout.seat(agent.teamID, after)
                reserve(target, for: id)
                actors[id]!.place = target
                actors[id]!.position = target.final
            }
        }
        updateLayout()
    }

    /// 이 직원이 앉는 책상 (바꿔 앉힌 책상이 있으면 그것)
    func desk(of agent: Agent) -> Seat { seatMap[agent.id] ?? agent.seat }

    /// 화면(사무실 영역) 크기를 바꿉니다. 사무실은 줄이지 않고(배율 1) 그 크기에 맞게 다시 놓습니다.
    public mutating func setViewport(width: Double, height: Double) {
        guard viewport.width != width || viewport.height != height else { return }
        viewport = (width, height)
        updateLayout()
    }

    // MARK: - 명패와 행 닫기

    /// 책상 명패 (행 → 책상 → 이름): 메인 책상 "★ 메인1", 서브 책상 "서브2". 책상은 사람마다 하나씩이라 앉은 사람의 직함을 답니다.
    /// 같은 책상을 두 사람이 가리키면(퇴근하는 사람과 옮겨 앉는 사람) 그 책상으로 가는 사람이 이깁니다.
    public var nameplates: [TeamID: [Seat: String]] {
        var plates: [TeamID: [Seat: String]] = [:]
        for actor in actors.values.sorted(by: { $0.id < $1.id }) {
            let agent = actor.agent
            guard teams[agent.teamID] != nil else { continue }
            let label = agent.isMain ? "★ " + agent.title.label : agent.title.label
            let seat = desk(of: agent)
            let heading = actor.place?.seat == seat && actor.place?.team == agent.teamID
            if plates[agent.teamID]?[seat] == nil || heading {
                plates[agent.teamID, default: [:]][seat] = label
            }
        }
        return plates
    }

    /// 닫히는 행 중 남은 직원이 모두 나간 행을 비웁니다.
    private mutating func finishClosingTeams() {
        for id in closingTeams.sorted() where !actors.values.contains(where: { $0.agent.teamID == id }) {
            closeNow(id)
        }
    }

    private mutating func closeNow(_ id: TeamID) {
        closingTeams.remove(id)
        guard teams.removeValue(forKey: id) != nil else { return }
        hiddenCounts[id] = nil
        if !layout.rooms.contains(where: { $0.team == id }) { teamOrders[id] = nil }
        events.append(.teamClosed(id))
        compactionPending = true
        updateLayout()
    }

    // MARK: - 배치 늘리기·줄이기 (설계서 §8.1)

    /// 행의 책상 수: 그 행 직원의 책상과 지금 가는 책상, 아직 앉아 있는 책상 중 가장 오른쪽까지 (빈 책상 없음)
    private func neededDesks(_ team: TeamID) -> Int {
        var maxDesk = 0
        let row = layout.row(for: team)
        for actor in actors.values {
            if actor.agent.teamID == team { maxDesk = max(maxDesk, desk(of: actor.agent).desk) }
            if let place = actor.place, place.team == team, let seat = place.seat { maxDesk = max(maxDesk, seat.desk) }
            // 자리를 옮기라는 지시를 받았지만 아직 그 책상에 앉아 있거나 막 일어선 사람
            if let row, abs(actor.position.y - row.deskY) < 2 || abs(actor.position.y - (row.deskY - OfficeLayout.approachOffset)) < 2 {
                for desk in 0..<max(row.desks, 1) where abs(OfficeLayout.deskX(desk) - actor.position.x) < 2 {
                    maxDesk = max(maxDesk, desk)
                }
            }
        }
        return maxDesk + 1
    }

    /// 행이 열리거나 책상이 필요해지면 바로 늘리고, 사람이 떠난 오른쪽 끝 책상은 바로 치웁니다.
    /// 닫힌 행 아래의 행들은 그 행 자리에 서 있거나 지나가는 직원이 없을 때 올립니다. 행 순서는 메인이 온 순서입니다.
    private mutating func updateLayout() {
        // 메인이 온 순서대로. 닫힌 행은 비울 수 있을 때까지 자리만 남겨 둡니다
        var ids = Set(layout.rooms.map(\.team)).union(teams.keys)
        ids = ids.filter { teamOrders[$0] != nil }
        let rooms = ids.sorted { (teamOrders[$0]!, $0) < (teamOrders[$1]!, $1) }.map { team in
            OfficeLayout.Room(team: team, desks: teams[team] == nil ? 1 : neededDesks(team), hidden: hiddenCounts[team] ?? 0)
        }
        let grown = OfficeLayout(width: viewport.width, height: viewport.height, rooms: rooms)
        if grown != layout { relayout(to: grown) }

        let target = OfficeLayout(width: viewport.width, height: viewport.height, rooms: rooms.filter { teams[$0.team] != nil })
        guard target != layout else {
            compactionPending = false
            return
        }
        if isBusy(removing: target) {
            compactionPending = true
        } else {
            relayout(to: target)
            compactionPending = false
            for id in teamOrders.keys where teams[id] == nil { teamOrders[id] = nil }
        }
    }

    /// 사라지는 행 자리에 직원이 있거나 지나가는 중인지
    private func isBusy(removing target: OfficeLayout) -> Bool {
        let removed = layout.rows.filter { target.row(for: $0.team) == nil }.map { MapRect(0, $0.top, layout.width, $0.bottom - $0.top) }
        guard !removed.isEmpty else { return false }
        func inside(_ point: MapPoint) -> Bool { removed.contains { $0.contains(point) } }
        return actors.values.contains { actor in
            inside(actor.position) || actor.place.map { inside($0.final) || inside($0.approach) } == true || actor.path.contains(where: inside)
        }
    }

    /// 새 배치로 바꿉니다. 자리를 옮긴 행의 직원은 행과 함께 옮기고, 걷던 직원은 새 길로 다시 걷습니다.
    private mutating func relayout(to new: OfficeLayout) {
        let old = layout
        layout = new
        pathfinder = Pathfinder(layout: new)
        func shift(_ point: MapPoint) -> Double {
            guard let index = old.rowIndex(containing: point), let moved = new.row(for: old.rows[index].team) else { return 0 }
            return moved.top - old.rows[index].top
        }
        for id in actors.keys.sorted() {
            var actor = actors[id]!
            let dy = shift(actor.position)
            actor.position.y += dy
            if let place = actor.place {
                if let team = place.team, let seat = place.seat, new.row(for: team) != nil {
                    actor.place = new.seat(team, seat)
                } else if place.team == nil {
                    actor.place = place.shifted(by: shift(place.final))
                }
            }
            if !actor.path.isEmpty, let place = actor.place {
                var path = pathfinder.route(from: actor.position, to: place.approach)
                if place.final != place.approach { path.append(place.final) }
                actor.path = path.isEmpty ? [place.final] : path
            }
            actors[id] = actor
        }
    }

    /// 대기열의 다음 걸음이 지금 서 있는(앉은) 자리 그대로인지 (책상에서 쉬기)
    private func staysPut(_ id: AgentID) -> Bool {
        guard let actor = actors[id], !actor.isWalking else { return false }
        for action in queues[id] ?? [] {
            if case .walk(let spot) = action { return resolve(spot, for: id).final.distance(to: actor.position) < 1 }
        }
        return false
    }

    private mutating func walk(_ id: AgentID, to spot: Spot) {
        guard actors[id] != nil else { return }
        let actor = actors[id]!
        let target = resolve(spot, for: id)
        if config.commonAreasAtDesk, !actor.isWalking, target.final.distance(to: actor.position) < 1 {
            // 제자리 걸음: 앉은 채로 자리만 바꿔 기록합니다
            release(id)
            reserve(target, for: id)
            actors[id]!.place = target
            return
        }
        var path: [MapPoint] = []
        var position = actor.position
        // 의자·소파처럼 가구와 겹친 자리에 있으면 먼저 그 자리의 입구로 나옵니다
        if let current = actor.place, current.approach != current.final, position.distance(to: current.final) < 1 {
            path.append(current.approach)
            position = current.approach
        }
        path += pathfinder.route(from: position, to: target.approach)
        if target.final != target.approach { path.append(target.final) }
        release(id)
        reserve(target, for: id)
        actors[id]!.place = target
        actors[id]!.seated = false
        if config.reducedMotion {
            teleport(id, to: target.final)
            if target.seat != nil { updateLayout() }
            return
        }
        actors[id]!.path = path
        actors[id]!.walkedDistance = 0
        if !path.isEmpty {
            blocks[id] = .walking
        }
        if target.seat != nil { updateLayout() }
    }

    /// 걷지 않고 바로 그 자리로 옮깁니다 (동작 줄이기)
    private mutating func teleport(_ id: AgentID, to point: MapPoint) {
        actors[id]!.position = point
        actors[id]!.path = []
        actors[id]!.walkedDistance = 0
        actors[id]!.facing = .front
    }

    /// 동작 줄이기를 켜고 끕니다. 켜는 순간 걷던 사람은 도착할 자리로 옮기고 하던 제스처를 멈춥니다.
    public mutating func setReducedMotion(_ on: Bool) {
        guard config.reducedMotion != on else { return }
        config.reducedMotion = on
        guard on else { return }
        for id in actors.keys.sorted() {
            actors[id]!.gesture = nil
            actors[id]!.gestureUntil = nil
            guard let last = actors[id]!.path.last else { continue }
            teleport(id, to: last)
            if blocks[id] == .walking {
                blocks[id] = nil
                run(id)
            }
        }
    }

    private mutating func advanceWalk(_ id: AgentID, dt: Double) {
        guard var actor = actors[id], !actor.path.isEmpty else { return }
        var budget = config.walkSpeed * dt
        while budget > 0, let next = actor.path.first {
            let delta = next - actor.position
            let distance = delta.length
            if abs(delta.x) > 0.5 {
                actor.facing = delta.x < 0 ? .left : .right
            }
            if distance <= budget {
                actor.position = next
                actor.path.removeFirst()
                actor.walkedDistance += distance
                budget -= distance
            } else {
                actor.position = actor.position + delta * (budget / distance)
                actor.walkedDistance += budget
                budget = 0
            }
        }
        if actor.path.isEmpty {
            actor.facing = .front
        }
        actors[id] = actor
        if actor.path.isEmpty, blocks[id] == .walking {
            blocks[id] = nil
            run(id)
        }
    }

    private mutating func expire(_ id: AgentID) {
        guard var actor = actors[id] else { return }
        if let until = actor.bubbleUntil, time >= until {
            actor.bubble = nil
            actor.bubbleUntil = nil
            actor.bubbleBlip = nil
        }
        if let queued = actor.queuedBubble, queued.bubble.kind != .shout, time - queued.since > config.bubbleQueueTimeout {
            actor.queuedBubble = nil
        }
        if let until = actor.gestureUntil, time >= until {
            actor.gesture = nil
            actor.gestureUntil = nil
        }
        actors[id] = actor
    }

    /// 다른 직원의 signal을 기다리던 직원을 깨웁니다
    private mutating func settleSignals() {
        var progressed = true
        while progressed {
            progressed = false
            for id in blocks.keys.sorted() {
                if case .awaiting(let name, _) = blocks[id], signals.contains(name) {
                    signals.remove(name)
                    blocks[id] = nil
                    run(id)
                    progressed = true
                }
            }
        }
    }

    /// 급한 연출(승인 요청 등)이 오면 대기열을 막고 있던 것을 풉니다.
    /// 걷던 중이면 목적지까지는 계속 걸어갑니다. 연출 엔진은 직원이 그 목적지에 있다고 알고 있으므로,
    /// 중간에 멈추면 이후 연출과 위치가 어긋나기 때문입니다 (M3 스냅숏에서 발견).
    private mutating func interrupt(_ id: AgentID) {
        blocks[id] = nil
    }

    // MARK: - 말풍선 (설계서 §7.2)

    /// 말풍선 수를 세는 단위: 행 (메인 하나와 그 서브들)
    static func bubbleUnit(_ agent: Agent) -> String {
        agent.teamID.raw
    }

    /// 같은 단위에서 지금 보이는 말풍선 (자기 것은 빼고 셉니다)
    private func visibleBubbles(in unit: String, excluding id: AgentID? = nil) -> [StageActor] {
        actors.values.filter { Self.bubbleUnit($0.agent) == unit && $0.bubble != nil && $0.id != id }
    }

    /// 말풍선을 띄웁니다. 그 행이 꽉 찼으면 덜 중요한 말풍선의 자리를 빼앗거나, 대기열에서 기다립니다.
    private mutating func present(_ bubble: Bubble, blip: SoundCue?, for id: AgentID) {
        guard let actor = actors[id] else { return }
        actors[id]!.queuedBubble = nil
        let unit = Self.bubbleUnit(actor.agent)
        let others = visibleBubbles(in: unit, excluding: id)
        if others.count >= config.maxBubblesPerUnit {
            let weakest = others.min {
                ($0.bubble!.kind.priority, -$0.bubbleShownAt, $0.id) < ($1.bubble!.kind.priority, -$1.bubbleShownAt, $1.id)
            }
            if let weakest, weakest.bubble!.kind.priority < bubble.kind.priority {
                // 밀려난 말풍선은 남은 시간을 그대로 들고 대기열에서 기다립니다
                var displaced = weakest.bubble!
                if let until = weakest.bubbleUntil { displaced.duration = max(until - time, 1) }
                hideBubble(weakest.id, promote: false)
                // 이미 울린 블립은 다시 띄울 때 울리지 않습니다
                actors[weakest.id]!.queuedBubble = QueuedBubble(bubble: displaced, since: time, blip: nil)
            } else {
                hideBubble(id)
                actors[id]!.queuedBubble = QueuedBubble(bubble: bubble, since: time, blip: blip)
                return
            }
        }
        show(bubble, blip: blip, for: id)
    }

    private mutating func show(_ bubble: Bubble, blip: SoundCue?, for id: AgentID) {
        actors[id]!.bubble = bubble
        actors[id]!.bubbleUntil = bubble.duration.map { time + $0 }
        actors[id]!.bubbleShownAt = time
        actors[id]!.bubbleBlip = blip
        if let blip { events.append(.sound(blip, id)) }
    }

    private mutating func hideBubble(_ id: AgentID, promote: Bool = true) {
        guard actors[id] != nil else { return }
        let unit = Self.bubbleUnit(actors[id]!.agent)
        let hadBubble = actors[id]!.bubble != nil
        actors[id]!.bubble = nil
        actors[id]!.bubbleUntil = nil
        actors[id]!.bubbleBlip = nil
        if hadBubble, promote { promoteQueuedBubbles(in: unit, skipping: id) }
    }

    /// 자리가 난 행에 기다리던 말풍선을 중요한 것, 오래 기다린 것부터 띄웁니다
    private mutating func promoteQueuedBubbles(in unit: String? = nil, skipping skipped: AgentID? = nil) {
        let units = unit.map { [$0] } ?? Array(Set(actors.values.map { Self.bubbleUnit($0.agent) })).sorted()
        for unit in units {
            var free = config.maxBubblesPerUnit - visibleBubbles(in: unit).count
            guard free > 0 else { continue }
            let waiting = actors.values
                .filter { Self.bubbleUnit($0.agent) == unit && $0.queuedBubble != nil && $0.id != skipped }
                .sorted {
                    let a = $0.queuedBubble!, b = $1.queuedBubble!
                    return (-a.bubble.kind.priority, a.since, $0.id) < (-b.bubble.kind.priority, b.since, $1.id)
                }
            for actor in waiting where free > 0 {
                let queued = actor.queuedBubble!
                actors[actor.id]!.queuedBubble = nil
                show(queued.bubble, blip: queued.blip, for: actor.id)
                free -= 1
            }
        }
    }

    // MARK: - 효과와 분위기 소리

    private mutating func addEffect(_ effect: Effect) {
        switch effect {
        case .paperPlane(let target):
            effects.append(StageEffect(id: nextEffectID, kind: .paperPlane(to: target), startedAt: time, duration: config.paperPlaneDuration))
            nextEffectID += 1
        }
    }

    /// 하이파이브 반짝임. 두 사람이 함께 손을 맞대므로 가까운 곳에 막 생긴 반짝임이 있으면 하나만 둡니다.
    private mutating func sparkle(near point: MapPoint) {
        let recent = effects.contains { effect in
            guard case .sparkle(let other) = effect.kind else { return false }
            return time - effect.startedAt < 0.8 && other.distance(to: point) < 90
        }
        guard !recent else { return }
        effects.append(StageEffect(id: nextEffectID, kind: .sparkle(at: point), startedAt: time, duration: config.sparkleDuration))
        nextEffectID += 1
    }

    /// 걷는 동안 발소리, 타이핑 자세에서 키보드 소리 (재생 여부는 앱의 SoundPolicy가 설정을 보고 정합니다)
    private mutating func ambientSounds(_ id: AgentID) {
        guard let actor = actors[id] else { return }
        if actor.isWalking {
            if time >= actor.nextFootstepAt {
                events.append(.sound(.footsteps, id))
                actors[id]!.nextFootstepAt = time + config.footstepInterval
            }
        } else if actor.pose == .typing {
            if time >= actor.nextTypingAt {
                events.append(.sound(.typing, id))
                actors[id]!.nextTypingAt = time + config.typingInterval
            }
        }
    }

    // MARK: - 자리 정하기

    private func resolve(_ spot: Spot, for id: AgentID, agent: Agent? = nil) -> Place {
        func isFree(_ place: Place) -> Bool {
            guard let key = place.key else { return true }
            return reservations[key] == nil || reservations[key] == id
        }
        switch spot {
        case .door:
            return Place(final: layout.doorPoint)
        case .seat(let teamID, let seat):
            // 자기 책상: 바꿔 앉힌 책상이 있으면 그 칸
            return layout.seat(teamID, seatMap[id] ?? seat)
        case .beside(let other):
            guard let target = actors[other] else { return Place(final: layout.doorPoint) }
            let anchor = target.place?.approach ?? target.position
            // 책상에 앉은 직원이면 책상 뒤 통로에서 옆에 섭니다. 여럿이 오면 옆자리를 나눠 섭니다.
            let offsets = [MapPoint(40, 0), MapPoint(-40, 0), MapPoint(0, 34), MapPoint(40, 30), MapPoint(-40, 30), MapPoint(76, -14), MapPoint(-76, -14)]
            let candidates = offsets.enumerated().map { index, offset in
                Place(final: anchor + offset, key: "beside:\(other.raw):\(index)")
            }
            return candidates.first { layout.isWalkable($0.final) && isFree($0) }
                ?? candidates.first { layout.isWalkable($0.final) }.map { Place(final: $0.final) }
                ?? Place(final: anchor)
        case .whiteboard, .lounge, .massageChair, .pantry:
            if config.commonAreasAtDesk, let agent = agent ?? actors[id]?.agent {
                return layout.seat(agent.teamID, desk(of: agent))
            }
            let zone = OfficeLayout.zone(for: spot)!
            // 정해진 자리가 다 차면 구역 가까이 흩어 섭니다 (한 점에 겹치지 않게)
            if let free = layout.slots(zone).first(where: isFree) { return free }
            let overflowZone: OfficeLayout.Zone = zone == .massageChair ? .lounge : zone
            if let free = layout.overflow(overflowZone).first(where: isFree) { return free }
            return layout.slots(zone)[0]
        }
    }

    private mutating func reserve(_ place: Place, for id: AgentID) {
        if let key = place.key { reservations[key] = id }
    }

    private mutating func release(_ id: AgentID) {
        for (key, owner) in reservations where owner == id {
            reservations[key] = nil
        }
    }
}
