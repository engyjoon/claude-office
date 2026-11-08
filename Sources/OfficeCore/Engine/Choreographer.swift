import Foundation

/// 연출 타이밍 설정 (설계서 §6.3)
public struct ChoreographyConfig: Hashable, Sendable {
    /// 한 활동을 최소로 보여주는 시간(초)
    public var dwell: Double = 2.5
    /// 셸 명령이 이보다 오래 걸리면 자기 책상에서 모니터를 보며 기다립니다 (⏳, M4.5b: 서버랙 대신)
    public var shellWatchDelay: Double = 2
    /// 다른 구역에서 일이 끝난 뒤 자리로 돌아가기 전에 머무는 시간
    public var linger: Double = 4
    /// 쉼 단계 (메인·서브 세션의 입력 대기): 60초 → 소파, 3분 → 안마 의자(비었으면), 10분 → 잠듦
    /// (안마 의자에 있으면 그 자리에서, 아니면 자기 자리에서)
    public var loungeAfter: Double = 60
    public var massageAfter: Double = 180
    public var napAfter: Double = 600
    /// 쉬러 가는 길에 탕비 코너 냉장고에서 음료를 꺼내 가는 비율(%), 일을 끝낸 서브에이전트가 물 한 잔 마시고 퇴근하는 비율(%)
    public var pantryOnBreakPercent = 40
    public var pantryOnLeavePercent = 35
    /// 탕비 코너에 동시에 들르는 최대 인원 (자리 2개)
    public var pantryCapacity = 2
    /// 안마 의자 수 (휴게 공간 오른쪽 안마 구역, 2026-11-08)
    public var massageChairs = 2
    /// 승인 요청 노크를 다시 울리는 간격과 최대 횟수(첫 노크 포함)
    public var knockInterval: Double = 30
    public var maxKnocks = 3
    public var chatterInterval: Double = 60
    /// 보고하러 오는 서브에이전트를 부른 사람이 기다리는 최대 시간
    public var reportAwaitTimeout: Double = 8
    public init() {}
}

/// 리듀서의 비트를 씬 지시로 바꾸는 연출 감독.
///
/// - 깜빡임 방지: 활동은 `dwell`만큼 유지하고, 그 사이 들어온 활동은 최신 것만 남겼다가 `tick`에서 반영합니다.
///   다만 더 "바쁜" 활동(대기 → 생각 → 작업)으로 바뀔 때는 바로 반영합니다.
/// - 자리 이동은 계속될 근거가 있을 때만 합니다 (읽기 연속, 오래 걸리는 셸 명령).
/// - 승인 대기는 무엇보다 우선합니다.
public struct Choreographer: Sendable {
    public var config: ChoreographyConfig
    public var privacy: PrivacyLevel
    private let book: DialogueBook
    private var rng: SeededRandom
    private var presences: [AgentID: Presence] = [:]
    private var lastChatter: Date?
    /// 탕비 코너에 들른 직원과 떠날 시각 (동시에 너무 많이 몰리지 않게)
    private var pantryVisits: [AgentID: Date] = [:]

    enum Shown: Equatable, Sendable {
        case idle, thinking
        case working(ToolCall)

        var rank: Int {
            switch self {
            case .idle: 0
            case .thinking: 1
            case .working: 2
            }
        }
    }

    /// 오래 걸리는지 지켜보는 셸 명령 (2초를 넘기면 책상에서 기다리는 자세로)
    struct ShellWatch: Sendable {
        var callID: String?
        var since: Date
    }

    struct Presence: Sendable {
        var agent: Agent
        var spot: Spot
        var seated = false
        var shown: Shown = .idle
        var shownAt: Date
        var pending: Shown?
        var pill: StatusPill?
        var emote: Emote?
        var shellWatch: ShellWatch?
        var returnAt: Date?
        var waiting = false
        var knocks = 0
        var nextKnockAt: Date?
        var idleSince: Date?
        var rest = Rest.none
        /// 책상에서 기다리는 중인 오래 걸리는 셸 명령 (⏳)
        var watching: String??
        /// 쉬러 간 횟수 (탕비 코너에 들를지 정하는 데 씀)
        var breaks = 0
        /// 승인 대기 중 띄운 외침 풍선 (화면에 다시 보일 때 그대로 띄웁니다)
        var shout: Bubble?
    }

    /// 쉼 단계 (설계서 §6.2): 소파 → 안마 의자 → 잠듦
    enum Rest: Int, Comparable, Sendable {
        case none, lounge, massage, nap
        static func < (lhs: Rest, rhs: Rest) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(privacy: PrivacyLevel = .detailed, config: ChoreographyConfig = .init(), book: DialogueBook = .korean, seed: UInt64) {
        self.privacy = privacy
        self.config = config
        self.book = book
        self.rng = SeededRandom(seed: seed)
    }

    /// 지금 화면에 있는 직원의 위치 (테스트와 인스펙터용)
    public func spot(of id: AgentID) -> Spot? { presences[id]?.spot }
    public func isPresent(_ id: AgentID) -> Bool { presences[id] != nil }

    // MARK: - 비트 처리

    public mutating func handle(_ beats: [Beat], at now: Date) -> [Directive] {
        var out: [Directive] = []
        for beat in beats {
            handle(beat, at: now, into: &out)
        }
        return out
    }

    private mutating func handle(_ beat: Beat, at now: Date, into out: inout [Directive]) {
        switch beat {
        case .teamOpened(let team):
            out.append(Directive(nil, .openTeam(team)))

        case .teamClosed(let team):
            out.append(Directive(nil, .closeTeam(team.id)))

        case .promoted(let agent):
            touch(agent)
            guard presences[agent.id] != nil else { return }
            out.append(Directive(agent.id, .refresh(agent)))
            reseat(agent, at: now, into: &out)
            if presences[agent.id]?.waiting == false {
                out.append(Directive(agent.id, .gesture(.cheer)))
                out.append(Directive(agent.id, .express(.proud)))
                setEmote(agent.id, .sparkle, into: &out)
                say(agent.id, "promote.lead", into: &out)
                out.append(Directive(agent.id, .wait(2)))
                setEmote(agent.id, nil, into: &out)
                out.append(Directive(agent.id, .express(.neutral)))
            }

        case .retitled(let agent), .reseated(let agent):
            touch(agent)
            guard presences[agent.id] != nil else { return }
            out.append(Directive(agent.id, .refresh(agent)))
            reseat(agent, at: now, into: &out)

        case .arrived(let agent):
            enter(agent, at: now, into: &out)
            if agent.role == .lead {
                out.append(Directive(agent.id, .gesture(.wave)))
                out.append(Directive(agent.id, .express(.happy)))
                say(agent.id, "arrive.lead", into: &out)
            }
            modify(agent.id) {
                $0.shown = .idle
                $0.shownAt = now
                $0.idleSince = now
            }

        case .settled(let agent):
            settle(agent, at: now, into: &out)

        case .promptArrived(let agent):
            touch(agent)
            resolveWaiting(agent.id, into: &out)
            wake(agent.id, into: &out)
            out.append(Directive(nil, .effect(.paperPlane(to: agent.id))))
            out.append(Directive(agent.id, .express(.surprised)))
            out.append(Directive(agent.id, .wait(0.6)))
            setEmote(agent.id, .bulb, into: &out)
            say(agent.id, "prompt.thinking", kind: .thought, into: &out)
            show(agent.id, .thinking, at: now, into: &out)
            modify(agent.id) { $0.idleSince = nil }

        case .working(let agent, let call):
            touch(agent)
            offer(agent.id, .working(call), at: now, into: &out)

        case .toolEnded(let agent, let call, let outcome):
            touch(agent)
            if let watch = presences[agent.id]?.shellWatch, watch.callID == call.id {
                modify(agent.id) { $0.shellWatch = nil }
            }
            // 책상에서 기다리던 긴 명령이 끝남: 성공이면 반가운 표정, 실패면 아래 오류 연출
            var watched = false
            if let watching = presences[agent.id]?.watching, watching == call.id {
                watched = true
                modify(agent.id) { $0.watching = nil }
                if presences[agent.id]?.emote == .hourglass { setEmote(agent.id, nil, into: &out) }
                if !outcome.isFailure {
                    out.append(Directive(agent.id, .express(.happy)))
                    out.append(Directive(agent.id, .gesture(.nod)))
                    out.append(Directive(agent.id, .wait(1.2)))
                }
            }
            if outcome.isFailure {
                if watched { out.append(Directive(agent.id, .pose(.thinking))) }
                resolveWaiting(agent.id, into: &out)
                let repeated = agent.consecutiveErrors >= 3
                out.append(Directive(agent.id, .express(repeated ? .sad : .troubled)))
                out.append(Directive(agent.id, .gesture(.scratchHead)))
                setEmote(agent.id, .sweat, into: &out)
                out.append(Directive(agent.id, .sound(.error)))
                say(agent.id, repeated ? "error.repeated" : "error.tool", into: &out)
                modify(agent.id) {
                    $0.shown = .thinking
                    $0.shownAt = now
                    $0.pending = agent.runningTools.last.map(Shown.working)
                }
            } else if let next = agent.runningTools.last {
                offer(agent.id, .working(next), at: now, into: &out)
            } else {
                offer(agent.id, .thinking, at: now, into: &out)
            }

        case .delegated(let lead, let member):
            touch(lead)
            resolveWaiting(lead.id, into: &out)
            wake(lead.id, into: &out)
            // 위임은 자기 책상에서 합니다 (서브에이전트가 책장 같은 공용 구역으로 찾아가지 않도록)
            move(lead.id, to: seatSpot(lead), into: &out)
            modify(lead.id) { $0.returnAt = nil }
            out.append(Directive(lead.id, .gesture(.beckon)))
            out.append(Directive(lead.id, .express(.happy)))
            var variables = ["member": member.displayName]
            if privacy == .detailed, let task = member.task {
                variables["task"] = ToolCatalog.truncate(task, 16)
            }
            say(lead.id, "delegate.lead", variables, into: &out)
            modify(lead.id) {
                $0.shown = .thinking
                $0.shownAt = now
            }

            enter(member, at: now, besideFirst: lead.id, into: &out)
            modify(member.id) {
                $0.shown = .thinking
                $0.shownAt = now
            }

        case .memberAppeared(let member):
            enter(member, at: now, into: &out)
            modify(member.id) {
                $0.shown = .thinking
                $0.shownAt = now
            }

        case .permissionAsked(let agent, let call):
            touch(agent)
            guard var presence = presences[agent.id] else { return }
            out.append(Directive(agent.id, .clearQueue))
            if presence.seated {
                out.append(Directive(agent.id, .stand))
                presence.seated = false
            }
            presence.waiting = true
            presence.knocks = 1
            presence.nextKnockAt = now.addingTimeInterval(config.knockInterval)
            presence.pending = nil
            presence.rest = .none
            presence.watching = nil
            presences[agent.id] = presence
            out.append(Directive(agent.id, .pose(.raisingHand)))
            out.append(Directive(agent.id, .express(.eager)))
            setEmote(agent.id, .exclamation, into: &out)
            out.append(Directive(nil, .sound(.knock)))
            let (key, variables) = permissionLine(for: call)
            say(agent.id, key, variables, kind: .shout, persistent: true, silent: true, into: &out)
            if case .say(let bubble)? = out.last?.action { modify(agent.id) { $0.shout = bubble } }
            // 대기열을 비우면 아직 실행하지 않은 이동(예: 부른 사람 옆에서 자기 자리로)도 사라지므로, 손을 든 채로 알고 있는 자리로 갑니다
            out.append(Directive(agent.id, .walk(to: presence.spot)))

        case .permissionDenied(let agent, _):
            touch(agent)
            resolveWaiting(agent.id, into: &out)
            out.append(Directive(agent.id, .express(.sad)))
            say(agent.id, "permission.denied", into: &out)
            modify(agent.id) {
                $0.shown = .thinking
                $0.shownAt = now
            }

        case .waitingForInput(let agent):
            touch(agent)
            out.append(Directive(nil, .sound(.inputWaiting)))
            if presences[agent.id]?.rest == Rest.none {
                out.append(Directive(agent.id, .gesture(.tilt)))
                setEmote(agent.id, .question, into: &out)
            }

        case .turnEnded(let agent, let failed):
            touch(agent)
            resolveWaiting(agent.id, into: &out)
            setPill(agent.id, nil, into: &out)
            out.append(Directive(agent.id, .prop(nil)))
            move(agent.id, to: seatSpot(agent), into: &out)
            out.append(Directive(agent.id, .pose(.sitting)))
            if failed {
                out.append(Directive(agent.id, .express(.sad)))
                setEmote(agent.id, .sweat, into: &out)
                out.append(Directive(nil, .sound(.error)))
                say(agent.id, "turn.failed", into: &out)
            } else {
                out.append(Directive(agent.id, .gesture(.stretch)))
                out.append(Directive(agent.id, .express(.proud)))
                setEmote(agent.id, .sparkle, into: &out)
                out.append(Directive(nil, .sound(.turnComplete)))
                say(agent.id, "turn.done", into: &out)
                out.append(Directive(agent.id, .wait(3)))
                setEmote(agent.id, nil, into: &out)
                out.append(Directive(agent.id, .express(.neutral)))
            }
            modify(agent.id) {
                $0.shown = .idle
                $0.shownAt = now
                $0.pending = nil
                $0.idleSince = now
                $0.rest = .none
                $0.returnAt = nil
            }

        case .compacting(let agent):
            touch(agent)
            out.append(Directive(agent.id, .pose(.sorting)))
            out.append(Directive(agent.id, .prop(.documents)))
            out.append(Directive(agent.id, .express(.focus)))
            say(agent.id, "compact", into: &out)
            modify(agent.id) {
                $0.shown = .thinking
                $0.shownAt = now
            }

        case .reported(let member, let lead):
            guard presences[member.id] != nil else { return }
            touch(member)
            out.append(Directive(member.id, .clearQueue))
            resolveWaiting(member.id, into: &out)
            setPill(member.id, nil, into: &out)
            out.append(Directive(member.id, .prop(nil)))
            if let lead, presences[lead.id] != nil {
                let cue = "report:\(member.id.raw)"
                move(member.id, to: .beside(lead.id), into: &out)
                out.append(Directive(member.id, .signal(cue)))
                out.append(Directive(member.id, .gesture(.highFive)))
                out.append(Directive(member.id, .express(.proud)))
                out.append(Directive(member.id, .sound(.memberReport)))
                say(member.id, "report.member", silent: true, into: &out)
                out.append(Directive(member.id, .wait(1.2)))
                out.append(Directive(member.id, .gesture(.wave)))

                out.append(Directive(lead.id, .await(cue, timeout: config.reportAwaitTimeout)))
                out.append(Directive(lead.id, .gesture(.highFive)))
                out.append(Directive(lead.id, .express(.proud)))
                setEmote(lead.id, .sparkle, into: &out)
                say(lead.id, "report.lead", into: &out)
                out.append(Directive(lead.id, .wait(1.3)))
                out.append(Directive(lead.id, .gesture(.thumbsUp)))
                out.append(Directive(lead.id, .wait(1.4)))
                setEmote(lead.id, nil, into: &out)
                out.append(Directive(lead.id, .express(.neutral)))
            }
            // 가끔 탕비 코너에서 물 한 잔 마시고 퇴근합니다 (출입문 옆이라 크게 돌아가지 않음)
            if chance(member.id, "leave", percent: config.pantryOnLeavePercent), reservePantry(member.id, at: now) {
                move(member.id, to: .pantry, into: &out)
                out.append(Directive(member.id, .prop(.cup)))
                out.append(Directive(member.id, .pose(.holdingCup)))
                out.append(Directive(member.id, .express(.happy)))
                out.append(Directive(member.id, .wait(2.4)))
                out.append(Directive(member.id, .prop(nil)))
                out.append(Directive(member.id, .pose(.standing)))
            }
            leave(member.id, into: &out)

        case .left(let agent):
            guard presences[agent.id] != nil else { return }
            touch(agent)
            out.append(Directive(agent.id, .clearQueue))
            resolveWaiting(agent.id, into: &out)
            setPill(agent.id, nil, into: &out)
            setEmote(agent.id, nil, into: &out)
            out.append(Directive(agent.id, .prop(nil)))
            if agent.role == .lead {
                say(agent.id, "leave.lead", into: &out)
            }
            out.append(Directive(agent.id, .gesture(.wave)))
            leave(agent.id, into: &out)
        }
    }

    // MARK: - 시간 경과

    public mutating func tick(at now: Date) -> [Directive] {
        var out: [Directive] = []
        for id in presences.keys.sorted() {
            tickPresence(id, at: now, into: &out)
        }
        tickChatter(at: now, into: &out)
        return out
    }

    private mutating func tickPresence(_ id: AgentID, at now: Date, into out: inout [Directive]) {
        guard let presence = presences[id] else { return }

        if let pending = presence.pending, !presence.waiting, now.timeIntervalSince(presence.shownAt) >= config.dwell {
            show(id, pending, at: now, into: &out)
        }

        if let watch = presences[id]?.shellWatch, now.timeIntervalSince(watch.since) >= config.shellWatchDelay {
            modify(id) { $0.shellWatch = nil }
            if case .working(let call) = presences[id]!.shown, call.category == .shell, call.id == watch.callID,
                !presences[id]!.waiting
            {
                // 실무처럼 자기 자리에서 원격으로 확인합니다: 모니터를 보며 기다리는 자세 + ⏳ (서버랙으로 가지 않음)
                let atDesk = presences[id]!.seated && isDesk(presences[id]!.spot)
                out.append(Directive(id, .pose(atDesk ? .watching : .thinking)))
                out.append(Directive(id, .express(.neutral)))
                setEmote(id, .hourglass, into: &out)
                modify(id) { $0.watching = .some(call.id) }
            }
        }

        if let returnAt = presences[id]?.returnAt, now >= returnAt {
            modify(id) { $0.returnAt = nil }
            let current = presences[id]!
            if !current.waiting, current.rest == .none {
                switch current.shown {
                case .idle, .thinking:
                    move(id, to: seatSpot(current.agent), into: &out)
                    out.append(Directive(id, .pose(current.shown == .idle ? .sitting : .thinking)))
                    out.append(Directive(id, .prop(nil)))
                case .working:
                    break
                }
            }
        }

        if let current = presences[id], current.waiting, let next = current.nextKnockAt, now >= next {
            if current.knocks < config.maxKnocks {
                out.append(Directive(nil, .sound(.knock)))
                let following = next.addingTimeInterval(config.knockInterval)
                modify(id) {
                    $0.knocks += 1
                    $0.nextKnockAt = following
                }
            } else {
                modify(id) { $0.nextKnockAt = nil }
            }
        }

        if let current = presences[id], current.agent.role == .lead, current.shown == .idle, !current.waiting,
            let since = current.idleSince
        {
            rest(id, current, elapsed: now.timeIntervalSince(since), at: now, into: &out)
        }
    }

    /// 쉼 단계: 60초 → 휴게 공간(소파), 3분 → 안마 의자(빈 의자가 있으면), 10분 → 잠듦.
    /// 안마 의자에 있으면 그 자리에서 잠들고, 아니면 자기 자리로 돌아가 꾸벅꾸벅 좁니다.
    private mutating func rest(_ id: AgentID, _ current: Presence, elapsed: Double, at now: Date, into out: inout [Directive]) {
        if elapsed >= config.napAfter, current.rest < .nap {
            if current.spot == .massageChair {
                out.append(Directive(id, .pose(.sleeping)))
                out.append(Directive(id, .express(.sleepy)))
                setEmote(id, .zzz, into: &out)
            } else {
                move(id, to: seatSpot(current.agent), into: &out)
                out.append(Directive(id, .prop(nil)))
                out.append(Directive(id, .pose(.sleeping)))
                out.append(Directive(id, .express(.sleepy)))
                setEmote(id, .zzz, into: &out)
            }
            modify(id) { $0.rest = .nap }
        } else if elapsed >= config.massageAfter, current.rest == .lounge,
            presences.values.filter({ $0.spot == .massageChair }).count < config.massageChairs
        {
            move(id, to: .massageChair, into: &out)
            out.append(Directive(id, .prop(nil)))
            out.append(Directive(id, .pose(.massage)))
            out.append(Directive(id, .express(.happy)))
            setEmote(id, .note, into: &out)
            modify(id) { $0.rest = .massage }
        } else if elapsed >= config.loungeAfter, current.rest == .none {
            var drink = Prop.cup
            // 가끔 탕비 코너 냉장고에서 음료를 꺼내 들고 갑니다
            if chance(id, "break\(current.breaks)", percent: config.pantryOnBreakPercent), reservePantry(id, at: now) {
                move(id, to: .pantry, into: &out)
                out.append(Directive(id, .pose(.standing)))
                out.append(Directive(id, .wait(1.2)))
                drink = .drink
            }
            move(id, to: .lounge, into: &out)
            out.append(Directive(id, .pose(.holdingCup)))
            out.append(Directive(id, .prop(drink)))
            out.append(Directive(id, .express(.happy)))
            setEmote(id, .note, into: &out)
            modify(id) {
                $0.rest = .lounge
                $0.breaks += 1
            }
        }
    }

    /// 직원과 상황마다 정해진 확률 (난수열을 쓰지 않아 대사 선택에 영향을 주지 않습니다)
    private func chance(_ id: AgentID, _ salt: String, percent: Int) -> Bool {
        Int(StableHash.fnv1a("\(id.raw)#\(salt)") % 100) < percent
    }

    /// 탕비 코너에 자리가 있으면 잠깐 머무를 자리를 잡습니다 (머무는 시간은 걸어가는 시간 포함 어림값)
    private mutating func reservePantry(_ id: AgentID, at now: Date) -> Bool {
        pantryVisits = pantryVisits.filter { $0.value > now }
        guard pantryVisits.count < config.pantryCapacity else { return false }
        pantryVisits[id] = now.addingTimeInterval(12)
        return true
    }

    private mutating func tickChatter(at now: Date, into out: inout [Directive]) {
        let resting = presences.values.filter { $0.spot == .lounge && $0.rest == .lounge }.map(\.agent.id).sorted()
        guard resting.count >= 2 else { return }
        if let last = lastChatter, now.timeIntervalSince(last) < config.chatterInterval { return }
        lastChatter = now
        if let speaker = resting.randomElement(using: &rng) {
            say(speaker, "idle.chat", kind: .whisper, into: &out)
        }
    }

    // MARK: - 활동 반영

    /// 깜빡임 방지 규칙을 거쳐 활동을 반영합니다.
    private mutating func offer(_ id: AgentID, _ target: Shown, at now: Date, into out: inout [Directive]) {
        guard let presence = presences[id] else { return }
        if presence.waiting {
            // 승인 대기 중 다른 활동이 왔다 = 승인됨. 고개를 끄덕이고, 손 든 자세를 풀도록 자세·소품·표정을 다시 정합니다.
            resolveWaiting(id, into: &out)
            out.append(Directive(id, .gesture(.nod)))
            show(id, target, at: now, into: &out)
            return
        }
        if target == presence.shown { return }
        let elapsed = now.timeIntervalSince(presence.shownAt)
        if target.rank > presence.shown.rank || elapsed >= config.dwell {
            show(id, target, at: now, into: &out)
        } else {
            modify(id) { $0.pending = target }
        }
    }

    private mutating func show(_ id: AgentID, _ target: Shown, at now: Date, into out: inout [Directive]) {
        guard let previous = presences[id] else { return }
        modify(id) {
            $0.pending = nil
            $0.shown = target
            $0.shownAt = now
        }
        // 기다리던 긴 명령이 아닌 다른 활동을 보여주면 ⏳를 내립니다
        if let watching = previous.watching {
            var same = false
            if case .working(let call) = target, call.id == watching { same = true }
            if !same {
                modify(id) { $0.watching = nil }
                if presences[id]?.emote == .hourglass { setEmote(id, nil, into: &out) }
            }
        }

        switch target {
        case .working(let call):
            wake(id, into: &out)
            // 프롬프트의 💡, 입력 대기의 ❓, 오류의 💦는 일을 다시 시작하면 내립니다
            if let emote = presences[id]?.emote, [.bulb, .question, .sweat].contains(emote) {
                setEmote(id, nil, into: &out)
            }
            var zone = seatSpot(previous.agent)
            var pose = Pose.typing
            var prop: Prop?
            switch call.category {
            case .read:
                // 파일 읽기는 자기 책상에서 책을 펴 읽습니다 (2026-11-08: 책장을 없앰)
                pose = .reading
                prop = .book
            case .web:
                // 웹 검색은 자기 책상에서 합니다 (M5(1): 리서치 데스크를 없앰)
                pose = .typing
            case .plan:
                zone = .whiteboard
                pose = .writingBoard
                prop = .marker
            case .shell:
                modify(id) { $0.shellWatch = ShellWatch(callID: call.id, since: now) }
            case .report:
                pose = .sorting
                prop = .documents
            case .write, .delegate, .mcp, .other:
                break
            }

            var sameCategory = false
            if case .working(let earlier) = previous.shown, earlier.category == call.category { sameCategory = true }
            let moved = previous.spot != zone
            move(id, to: zone, into: &out)
            if moved || !sameCategory {
                out.append(Directive(id, .pose(pose)))
                out.append(Directive(id, .prop(prop)))
                out.append(Directive(id, .express(.focus)))
            }
            setPill(id, pill(for: call), into: &out)
            modify(id) {
                $0.returnAt = nil
                $0.idleSince = nil
            }

        case .thinking:
            setPill(id, nil, into: &out)
            if previous.shown != .thinking {
                out.append(Directive(id, .pose(.thinking)))
                out.append(Directive(id, .prop(nil)))
                out.append(Directive(id, .express(.think)))
            }
            if !(presences[id]?.spot.isSeat ?? true) {
                let returnAt = now.addingTimeInterval(config.linger)
                modify(id) { $0.returnAt = returnAt }
            }

        case .idle:
            setPill(id, nil, into: &out)
            out.append(Directive(id, .prop(nil)))
            out.append(Directive(id, .pose(presences[id]?.seated == true ? .sitting : .standing)))
            let returnAt = now.addingTimeInterval(config.linger)
            modify(id) {
                $0.idleSince = now
                if !$0.spot.isSeat { $0.returnAt = returnAt }
            }
        }
    }

    // MARK: - 도우미

    private mutating func enter(_ agent: Agent, at now: Date, besideFirst companion: AgentID? = nil, into out: inout [Directive]) {
        presences[agent.id] = Presence(agent: agent, spot: .door, shownAt: now)
        out.append(Directive(agent.id, .spawn(agent, at: .door)))
        out.append(Directive(agent.id, .sound(.door)))
        if let companion, presences[companion] != nil {
            move(agent.id, to: .beside(companion), into: &out)
            out.append(Directive(agent.id, .gesture(.nod)))
            out.append(Directive(agent.id, .express(.eager)))
            say(agent.id, "delegate.member", into: &out)
        }
        move(agent.id, to: seatSpot(agent), into: &out)
        out.append(Directive(agent.id, .express(.neutral)))
    }

    /// 조용히 출근 (M5(5)): 출입문에서 걸어 들어오지 않고, 인사·효과음도 없이 지난 활동 시각에 맞는 쉼 단계의 자리에 바로 놓습니다.
    /// 10분 넘게 쉬었으면 자기 책상에서 잠든 채, 3분 넘게 쉬었으면 안마 의자(비었으면), 1분 넘게 쉬었으면 소파, 아니면 자기 책상.
    /// 그 뒤의 쉼 단계는 평소처럼 `tick`이 이어 갑니다.
    private mutating func settle(_ agent: Agent, at now: Date, into out: inout [Directive]) {
        let since = agent.activitySince
        let elapsed = max(0, now.timeIntervalSince(since))
        var presence = Presence(agent: agent, spot: seatSpot(agent), shownAt: now)
        presence.seated = true
        presence.idleSince = since
        if elapsed >= config.napAfter {
            presence.rest = .nap
            presence.emote = .zzz
        } else if elapsed >= config.massageAfter,
            presences.values.filter({ $0.spot == .massageChair }).count < config.massageChairs
        {
            presence.spot = .massageChair
            presence.seated = false
            presence.rest = .massage
            presence.emote = .note
        } else if elapsed >= config.loungeAfter {
            presence.spot = .lounge
            presence.seated = false
            presence.rest = .lounge
            presence.emote = .note
            presence.breaks = 1
        }
        presences[agent.id] = presence
        out += restoreDirectives(for: agent, entering: false)
    }

    /// 자리(책상·행)가 바뀐 직원을 새 자리로 옮깁니다. 자기 책상에 있으면 바로, 다른 곳에 있으면 돌아올 때 새 자리로 갑니다.
    private mutating func reseat(_ agent: Agent, at now: Date, into out: inout [Directive]) {
        guard let presence = presences[agent.id], case .seat = presence.spot else { return }
        let target = seatSpot(agent)
        guard target != presence.spot else { return }
        if presence.waiting || presence.rest > .none {
            // 손을 든 채이거나 자는 중이면 깨어나거나 승인이 끝난 뒤 옮깁니다
            let returnAt = now.addingTimeInterval(config.linger)
            modify(agent.id) { $0.returnAt = returnAt }
            return
        }
        move(agent.id, to: target, into: &out)
        out.append(Directive(agent.id, .pose(currentPose(presence, atDesk: isDesk(target)))))
    }

    /// 자리를 옮긴 뒤 이어 갈 자세
    private func currentPose(_ presence: Presence, atDesk: Bool) -> Pose {
        if presence.waiting { return .raisingHand }
        if presence.rest == .nap { return .sleeping }
        if presence.watching != nil, atDesk { return .watching }
        switch presence.shown {
        case .idle: return atDesk ? .sitting : .standing
        case .thinking: return .thinking
        case .working(let call):
            switch call.category {
            case .read, .web: return .reading
            case .report: return .sorting
            default: return .typing
            }
        }
    }

    private mutating func leave(_ id: AgentID, into out: inout [Directive]) {
        move(id, to: .door, into: &out)
        out.append(Directive(id, .sound(.door)))
        out.append(Directive(id, .despawn))
        presences[id] = nil
    }

    private mutating func move(_ id: AgentID, to spot: Spot, into out: inout [Directive]) {
        guard var presence = presences[id], presence.spot != spot else { return }
        if presence.seated {
            out.append(Directive(id, .stand))
            presence.seated = false
        }
        out.append(Directive(id, .walk(to: spot)))
        presence.spot = spot
        if spot.isSeat {
            out.append(Directive(id, .sit))
            presence.seated = true
        }
        presences[id] = presence
    }

    /// 휴게 공간·안마 의자·낮잠에서 깨워 자리로 돌려보냅니다.
    private mutating func wake(_ id: AgentID, into out: inout [Directive]) {
        guard let presence = presences[id], presence.rest > .none else { return }
        setEmote(id, nil, into: &out)
        out.append(Directive(id, .prop(nil)))
        out.append(Directive(id, .express(.surprised)))
        move(id, to: seatSpot(presence.agent), into: &out)
        modify(id) { $0.rest = .none }
    }

    private mutating func resolveWaiting(_ id: AgentID, into out: inout [Directive]) {
        guard let presence = presences[id], presence.waiting else { return }
        out.append(Directive(id, .dismissBubble))
        setEmote(id, nil, into: &out)
        // 손 든 자세를 풉니다. 이어지는 활동이 자세·소품·표정을 다시 정하도록 보이는 활동도 처음으로 돌립니다.
        out.append(Directive(id, .pose(presence.spot.isSeat ? .sitting : .standing)))
        if presence.spot.isSeat {
            out.append(Directive(id, .sit))
        }
        modify(id) {
            $0.shown = .idle
            $0.waiting = false
            $0.knocks = 0
            $0.nextKnockAt = nil
            $0.shout = nil
            $0.seated = $0.spot.isSeat
        }
    }

    private mutating func say(
        _ id: AgentID, _ key: String, _ variables: [String: String] = [:], kind: BubbleKind = .speech,
        persistent: Bool = false, silent: Bool = false, into out: inout [Directive]
    ) {
        guard let text = book.line(key, variables, using: &rng) else { return }
        if !silent {
            let voice = presences[id]?.agent.profile.appearance.voice ?? 0
            let cue: SoundCue = kind == .whisper ? .chatter : .bubble(voice: voice, syllables: min(4, max(2, text.count / 5)))
            out.append(Directive(id, .sound(cue)))
        }
        let bubble = persistent ? Bubble(kind: kind, text: text, duration: nil) : .timed(kind, text)
        out.append(Directive(id, .say(bubble)))
    }

    private mutating func setEmote(_ id: AgentID, _ emote: Emote?, into out: inout [Directive]) {
        guard presences[id]?.emote != emote else { return }
        out.append(Directive(id, .emote(emote)))
        modify(id) { $0.emote = emote }
    }

    private mutating func setPill(_ id: AgentID, _ pill: StatusPill?, into out: inout [Directive]) {
        guard presences[id] != nil, presences[id]?.pill != pill else { return }
        out.append(Directive(id, .status(pill)))
        modify(id) { $0.pill = pill }
    }

    private func pill(for call: ToolCall) -> StatusPill? {
        switch privacy {
        case .detailed:
            let text: String
            if call.category == .report {
                text = call.category.summaryLabel  // 넘기는 메시지 내용은 보여주지 않습니다
            } else if call.category == .mcp {
                text = "MCP · \(call.subject ?? call.name)"
            } else if let subject = call.subject {
                text = "\(call.name) · \(subject)"
            } else {
                text = call.name
            }
            return StatusPill(category: call.category, text: text)
        case .summary:
            return StatusPill(category: call.category, text: call.category.summaryLabel)
        case .hidden:
            return nil
        }
    }

    private func permissionLine(for call: ToolCall?) -> (String, [String: String]) {
        if call?.name == "AskUserQuestion" { return ("permission.question", [:]) }
        if call?.name == "ExitPlanMode" { return ("permission.plan", [:]) }
        guard privacy == .detailed, let call else { return ("permission.generic", [:]) }
        if call.category == .shell, let subject = call.subject {
            return ("permission.shell", ["subject": ToolCatalog.truncate(subject, 18)])
        }
        return ("permission.tool", ["tool": call.name])
    }

    // MARK: - 자리

    /// 일하고 쉬는 자리: 자기 행의 자기 책상. 책상은 사람마다 하나씩 있으므로 빌리지 않습니다 (M5(1)).
    private func seatSpot(_ agent: Agent) -> Spot {
        .seat(agent.teamID, agent.seat)
    }

    private func isDesk(_ spot: Spot) -> Bool {
        spot.isSeat
    }

    // MARK: - 다시 보이기

    /// 화면에 없던 직원을 지금 모습 그대로 무대에 다시 세우는 지시 (메인 선택이 바뀌거나 화면에 자리가 났을 때).
    /// `entering`이면 출입문에서 들어와 지금 있어야 할 곳으로 걸어가고, 아니면 그 자리에 바로 놓습니다.
    /// 말풍선은 승인 대기 외침 풍선만 다시 띄웁니다.
    public func restoreDirectives(for agent: Agent, entering: Bool) -> [Directive] {
        guard let presence = presences[agent.id] else { return [] }
        let id = agent.id
        var out: [Directive] = []
        if entering {
            out.append(Directive(id, .spawn(agent, at: .door)))
            out.append(Directive(id, .walk(to: presence.spot)))
        } else {
            out.append(Directive(id, .spawn(agent, at: presence.spot)))
        }
        if presence.seated { out.append(Directive(id, .sit)) }
        out.append(Directive(id, .pose(restoredPose(presence))))
        out.append(Directive(id, .prop(restoredProp(presence))))
        out.append(Directive(id, .express(restoredExpression(presence))))
        if let emote = presence.emote { out.append(Directive(id, .emote(emote))) }
        if let pill = presence.pill { out.append(Directive(id, .status(pill))) }
        if presence.waiting, let shout = presence.shout { out.append(Directive(id, .say(shout))) }
        return out
    }

    private func restoredPose(_ presence: Presence) -> Pose {
        switch presence.spot {
        case .massageChair: return presence.rest == .nap ? .sleeping : .massage
        case .lounge: return presence.waiting ? .raisingHand : .holdingCup
        case .pantry: return presence.waiting ? .raisingHand : .holdingCup
        case .whiteboard where !presence.waiting: return .writingBoard
        default:
            let pose = currentPose(presence, atDesk: presence.seated && isDesk(presence.spot))
            return presence.seated && pose == .standing ? .sitting : pose
        }
    }

    private func restoredProp(_ presence: Presence) -> Prop? {
        if presence.waiting { return nil }
        switch presence.spot {
        case .lounge, .pantry: return .cup
        case .whiteboard: return .marker
        default: break
        }
        if case .working(let call) = presence.shown {
            switch call.category {
            case .read: return .book
            case .plan: return .marker
            case .report: return .documents
            default: return nil
            }
        }
        return nil
    }

    private func restoredExpression(_ presence: Presence) -> FacialExpression {
        if presence.waiting { return .eager }
        if presence.rest == .nap { return .sleepy }
        if presence.rest > .none { return .happy }
        switch presence.shown {
        case .working: return .focus
        case .thinking: return .think
        case .idle: return .neutral
        }
    }

    private mutating func touch(_ agent: Agent) {
        if presences[agent.id] != nil {
            presences[agent.id]!.agent = agent
        }
    }

    private mutating func modify(_ id: AgentID, _ body: (inout Presence) -> Void) {
        guard presences[id] != nil else { return }
        body(&presences[id]!)
    }
}
