import Foundation
import OfficeCore

public enum Facing: String, Hashable, Sendable {
    case front, left, right
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
    /// 팀 구역의 말풍선이 꽉 차서 기다리는 말풍선 (설계서 §7.2)
    public internal(set) var queuedBubble: QueuedBubble?

    public var isWalking: Bool { !path.isEmpty }

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
    /// 팀 구역 자리가 모자랄 때 남길 순서 (설계서 §6.3 우선순위: 승인 대기 > 대화 > 생각 > 잡담)
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
    case spawned(AgentID)
    case despawned(AgentID)
    case sound(SoundCue, AgentID?)
    case effect(Effect)
}

public struct StageConfig: Hashable, Sendable {
    /// 걷는 속도 (pt/초)
    public var walkSpeed = 120.0
    public var gestureDuration = 1.2
    /// 팀 구역마다 동시에 보이는 말풍선 수 (설계서 §7.2)
    public var maxBubblesPerTeam = 3
    /// 대기열에서 이보다 오래 기다린 말풍선은 버립니다 (외침 풍선은 버리지 않음)
    public var bubbleQueueTimeout = 6.0
    public var paperPlaneDuration = 1.3
    public var sparkleDuration = 0.9
    /// 발소리·타이핑 소리 간격 (둘 다 기본으로 꺼져 있는 장식 소리, 설계서 §11.2)
    public var footstepInterval = 0.42
    public var typingInterval = 1.4

    public init() {}
}

/// 연출 지시(Directive)를 시간에 따라 실행하는 무대 (설계서 §6.4).
///
/// - 직원마다 대기열이 있고 지시를 순서대로 실행합니다.
/// - `walk`는 도착할 때까지, `wait`는 그 시간만큼, `await`는 신호가 오거나 시간이 다 될 때까지 다음 지시를 막습니다.
/// - `clearQueue`는 아직 실행하지 않은 지시를 버리고 막힘을 풉니다. 걷던 중이면 목적지까지 걸으면서 새 지시를 바로 실행합니다.
/// - 같은 구역(책장, 휴게실 …)에는 자리를 예약해서 겹쳐 서지 않게 합니다.
///
/// 순수 값 타입이라 Linux에서 시간을 직접 흘려가며 테스트할 수 있습니다.
public struct Stage: Sendable {
    public var config: StageConfig
    public private(set) var layout: OfficeLayout
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var actors: [AgentID: StageActor] = [:]
    public private(set) var time: Double = 0
    /// 책상 명패 (팀 → 좌석 → 이름). 고정 직원의 지정석은 퇴근해도 명패가 남습니다 (설계서 §6.2).
    public private(set) var nameplates: [TeamID: [Int: String]] = [:]
    /// 지금 그리는 효과
    public private(set) var effects: [StageEffect] = []
    private var nextEffectID = 0

    private var pathfinder: Pathfinder
    private var queues: [AgentID: [Directive.Action]] = [:]
    private var blocks: [AgentID: Block] = [:]
    private var signals: Set<String> = []
    private var reservations: [String: AgentID] = [:]
    private var events: [StageEvent] = []

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

    public var sortedTeams: [Team] {
        teams.values.sorted { $0.island < $1.island }
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
        case .spawn, .openTeam, .clearQueue:
            break
        case .despawn:
            release(id)
            let team = actors[id]!.agent.teamID
            actors[id] = nil
            promoteQueuedBubbles(in: team)
            blocks[id] = nil
            queues[id] = nil
            events.append(.despawned(id))
        case .walk(let spot):
            walk(id, to: spot)
        case .sit:
            actors[id]!.seated = true
            actors[id]!.facing = .front
            if actors[id]!.pose == .standing { actors[id]!.pose = .sitting }
        case .stand:
            actors[id]!.seated = false
            if actors[id]!.pose == .sitting { actors[id]!.pose = .standing }
        case .pose(let pose):
            actors[id]!.pose = pose
        case .gesture(let gesture):
            actors[id]!.gesture = gesture
            actors[id]!.gestureStartedAt = time
            actors[id]!.gestureUntil = time + config.gestureDuration
            if gesture == .highFive { sparkle(near: actors[id]!.position + MapPoint(0, -98)) }
        case .express(let expression):
            actors[id]!.expression = expression
        case .emote(let emote):
            if actors[id]!.emote != emote { actors[id]!.emoteShownAt = time }
            actors[id]!.emote = emote
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
            teams[team.id] = team
            if team.island >= layout.islandCount {
                layout.ensureIsland(team.island)
                pathfinder = Pathfinder(layout: layout)
            }
            events.append(.teamOpened(team))
        case .effect(let effect):
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
        let place = resolve(spot, for: agent.id)
        actors[agent.id] = StageActor(id: agent.id, agent: agent, position: place.final, place: place)
        reserve(place, for: agent.id)
        blocks[agent.id] = nil
        if agent.role == .lead, agent.seat == 0 {
            nameplates[agent.teamID, default: [:]][0] = "★ 팀장"
        } else if agent.profile.kind == .fixed, let key = agent.profile.agentType {
            nameplates[agent.teamID, default: [:]][agent.seat] = key
        }
        events.append(.spawned(agent.id))
    }

    private mutating func walk(_ id: AgentID, to spot: Spot) {
        guard let actor = actors[id] else { return }
        let target = resolve(spot, for: id)
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
        actors[id]!.path = path
        actors[id]!.walkedDistance = 0
        if !path.isEmpty {
            blocks[id] = .walking
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

    /// 팀 구역에서 지금 보이는 말풍선 수 (자기 것은 빼고 셉니다)
    private func visibleBubbles(in team: TeamID, excluding id: AgentID? = nil) -> [StageActor] {
        actors.values.filter { $0.agent.teamID == team && $0.bubble != nil && $0.id != id }
    }

    /// 말풍선을 띄웁니다. 팀 구역이 꽉 찼으면 덜 중요한 말풍선의 자리를 빼앗거나, 대기열에서 기다립니다.
    private mutating func present(_ bubble: Bubble, blip: SoundCue?, for id: AgentID) {
        guard let actor = actors[id] else { return }
        actors[id]!.queuedBubble = nil
        let team = actor.agent.teamID
        let others = visibleBubbles(in: team, excluding: id)
        if others.count >= config.maxBubblesPerTeam {
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
        let team = actors[id]!.agent.teamID
        let hadBubble = actors[id]!.bubble != nil
        actors[id]!.bubble = nil
        actors[id]!.bubbleUntil = nil
        actors[id]!.bubbleBlip = nil
        if hadBubble, promote { promoteQueuedBubbles(in: team, skipping: id) }
    }

    /// 자리가 난 팀 구역에 기다리던 말풍선을 중요한 것, 오래 기다린 것부터 띄웁니다
    private mutating func promoteQueuedBubbles(in team: TeamID? = nil, skipping skipped: AgentID? = nil) {
        let teams = team.map { [$0] } ?? Array(Set(actors.values.map(\.agent.teamID))).sorted { $0.raw < $1.raw }
        for team in teams {
            var free = config.maxBubblesPerTeam - visibleBubbles(in: team).count
            guard free > 0 else { continue }
            let waiting = actors.values
                .filter { $0.agent.teamID == team && $0.queuedBubble != nil && $0.id != skipped }
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

    private func resolve(_ spot: Spot, for id: AgentID) -> Place {
        switch spot {
        case .door:
            return Place(final: OfficeLayout.doorPoint)
        case .seat(let teamID, let index):
            let island = teams[teamID]?.island ?? 0
            return OfficeLayout.seat(island: island, index: index)
        case .beside(let other):
            guard let target = actors[other] else { return Place(final: OfficeLayout.doorPoint) }
            let anchor = target.place?.approach ?? target.position
            // 책상에 앉은 직원이면 책상 뒤 통로에서 옆에 섭니다
            let candidates = [anchor + MapPoint(40, 0), anchor + MapPoint(-40, 0), anchor + MapPoint(0, 34), anchor + MapPoint(40, 30)]
            let spot = candidates.first { layout.isWalkable($0) } ?? anchor
            return Place(final: spot)
        case .bookshelf, .whiteboard, .serverRack, .research, .lounge:
            let zone = OfficeLayout.zone(for: spot)!
            let slots = layout.slots(zone)
            let free = slots.first { slot in
                guard let key = slot.key else { return true }
                return reservations[key] == nil || reservations[key] == id
            }
            // 자리가 모두 찼으면 첫 자리 근처에 조금 비켜 섭니다
            return free ?? Place(final: slots[0].approach + MapPoint(Double(id.raw.count % 3) * 18 - 18, 22))
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
