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
        /// 소파에서 손에 든 것: 보통 컵, 탕비 코너 냉장고에 들렀으면 음료
        var drink = Prop.cup
        /// 승인 대기 중 띄운 외침 풍선 (화면에 다시 보일 때 그대로 띄웁니다)
        var shout: Bubble?
        /// 대화를 압축하는 중 (서류 정리 자세). 쉼 단계(`rest`)와 쉬기 시작한 때(`idleSince`)는 그대로 두었다가 끝나면 되돌립니다 (M6(2)).
        var compacting = false
        /// 머리 위 배지 (M6(4)). "답변 필요"면 쉬러 가지 않고 자기 책상에서 기다립니다.
        var badge: SessionCue?
    }

    /// 쉼 단계 (설계서 §6.2): 소파 → 안마 의자 → 잠듦
    enum Rest: Int, Comparable, Sendable {
        case none, lounge, massage, nap
        static func < (lhs: Rest, rhs: Rest) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 직원의 모습: 자세·손에 든 것·표정, 그리고 그 모습에 늘 따라붙는 머리 위 아이콘.
    struct Look: Equatable, Sendable {
        var pose: Pose
        var prop: Prop?
        var expression: FacialExpression
        /// 승인 대기 "!", 쉼 ♪·Zz, 긴 명령 ⏳. 잠깐 띄우는 아이콘(💡·❓·💦·✨)은 비트가 따로 띄우고 `Presence.emote`가 기억합니다.
        var emote: Emote?
    }

    /// 상태 → 모습 (개선 11). 모습을 정하는 규칙은 여기 한 곳뿐이고, 일을 시작할 때(`show`)·쉼 단계에 들어갈 때(`rest`)·
    /// 조용히 앉힐 때(`settle`)·자리를 옮긴 뒤(`returnToOwnDesk`)·화면에 다시 세울 때(`restoreDirectives`) 모두 이 값을 씁니다.
    /// 앞선 것이 이깁니다: 승인 대기 → 대화 정리 → 보이는 활동(일하는 중·생각 중) → 쉼 단계 → 자리에서 쉼.
    /// 인사·축하·놀람 같은 잠깐의 표정과 제스처는 상태가 아니라서 각 비트가 따로 냅니다.
    static func look(for presence: Presence) -> Look {
        if presence.waiting { return Look(pose: .raisingHand, prop: nil, expression: .eager, emote: .exclamation) }
        if presence.compacting { return Look(pose: .sorting, prop: .documents, expression: .focus, emote: nil) }
        let atDesk = presence.seated && presence.spot.isSeat
        switch presence.shown {
        case .working(let call):
            // 오래 걸리는 셸 명령은 자기 책상에서 모니터를 보며 기다립니다 (⏳)
            if presence.watching != nil { return Look(pose: atDesk ? .watching : .thinking, prop: nil, expression: .neutral, emote: .hourglass) }
            switch call.category {
            case .read: return Look(pose: .reading, prop: .book, expression: .focus, emote: nil)
            case .plan: return Look(pose: .writingBoard, prop: .marker, expression: .focus, emote: nil)
            case .report: return Look(pose: .sorting, prop: .documents, expression: .focus, emote: nil)
            // 웹 검색은 자기 책상에서 타이핑 (M5(1): 리서치 데스크를 없앰)
            case .web, .write, .shell, .delegate, .mcp, .other: return Look(pose: .typing, prop: nil, expression: .focus, emote: nil)
            }
        case .thinking:
            return Look(pose: .thinking, prop: nil, expression: .think, emote: nil)
        case .idle:
            switch presence.rest {
            case .nap: return Look(pose: .sleeping, prop: nil, expression: .sleepy, emote: .zzz)
            case .massage: return Look(pose: .massage, prop: nil, expression: .happy, emote: .note)
            case .lounge: return Look(pose: .holdingCup, prop: presence.drink, expression: .happy, emote: .note)
            case .none: return Look(pose: atDesk ? .sitting : .standing, prop: nil, expression: .neutral, emote: nil)
            }
        }
    }

    /// 모습을 지시로 냅니다. 순서는 자리마다 예전 그대로 둡니다 (`propFirst`: 손에 든 것을 먼저 내려놓는 곳).
    private mutating func wear(_ id: AgentID, propFirst: Bool = false, emote: Bool = false, into out: inout [Directive]) {
        guard let presence = presences[id] else { return }
        let look = Self.look(for: presence)
        if propFirst { out.append(Directive(id, .prop(look.prop))) }
        out.append(Directive(id, .pose(look.pose)))
        if !propFirst { out.append(Directive(id, .prop(look.prop))) }
        out.append(Directive(id, .express(look.expression)))
        if emote { setEmote(id, look.emote, into: &out) }
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
        for beat in Self.latestSeatBeats(beats) {
            handle(beat, at: now, into: &out)
        }
        return out
    }

    /// 한 번에 여러 사람이 퇴근하면 같은 사람이 빈 책상을 차례로 메우며(4 → 3 → 2 → 1) 자리 비트를 여러 번 받습니다.
    /// 책상마다 들르지 않고 마지막 책상으로 바로 가도록, 같은 사람의 앞선 `retitled`·`reseated`는 버립니다 (뒤 비트가 최신 직함·자리를 담음).
    static func latestSeatBeats(_ beats: [Beat]) -> [Beat] {
        func seatChange(_ beat: Beat) -> AgentID? {
            switch beat {
            case .retitled(let agent), .reseated(let agent): agent.id
            default: nil
            }
        }
        var seen: Set<AgentID> = []
        var kept: [Beat] = []
        for beat in beats.reversed() {
            if let id = seatChange(beat), !seen.insert(id).inserted { continue }
            kept.append(beat)
        }
        return kept.reversed()
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
                // 쉬는 사람에게 늦게 온 끝 신호(응답이 끝난 뒤 도착한 PostToolUse)는 모습을 일하는 중으로 바꾸지 않습니다 (개선 4)
                if !agent.isResting {
                    modify(agent.id) {
                        $0.shown = .thinking
                        $0.shownAt = now
                        $0.pending = agent.runningTools.last.map(Shown.working)
                    }
                }
            } else if let next = agent.runningTools.last {
                offer(agent.id, .working(next), at: now, into: &out)
            } else if !agent.isResting {
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
            // 손에 든 것은 그대로 둡니다 (손 든 모습의 자세·표정·"!"만)
            let look = Self.look(for: presence)
            out.append(Directive(agent.id, .pose(look.pose)))
            out.append(Directive(agent.id, .express(look.expression)))
            setEmote(agent.id, look.emote, into: &out)
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
            // 배지(답변 필요·확인 안 함)를 단 사람은 "?" 아이콘을 따로 띄우지 않습니다 (M6(4))
            if presences[agent.id]?.rest == Rest.none, presences[agent.id]?.badge == nil {
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
                $0.compacting = false
            }

        case .turnAbandoned(let agent):
            // 끝 신호 없이 닫힌 턴 (중단 등): 축하 없이 하던 일의 표시(칩·⏳·💡·외침 풍선·소품)를 거두고 자기 책상에 앉아 쉽니다.
            // 쉼 단계는 지금부터 다시 셉니다. 뒤따르는 비트(입력 대기 "?", 새 요청)가 그다음 모습을 정합니다.
            touch(agent)
            guard presences[agent.id] != nil else { return }
            resolveWaiting(agent.id, into: &out)
            wake(agent.id, into: &out)
            setPill(agent.id, nil, into: &out)
            setEmote(agent.id, nil, into: &out)
            out.append(Directive(agent.id, .prop(nil)))
            move(agent.id, to: seatSpot(agent), into: &out)
            out.append(Directive(agent.id, .pose(.sitting)))
            out.append(Directive(agent.id, .express(.neutral)))
            modify(agent.id) {
                $0.shown = .idle
                $0.shownAt = now
                $0.pending = nil
                $0.idleSince = now
                $0.rest = .none
                $0.returnAt = nil
                $0.compacting = false
                $0.watching = nil
                $0.shellWatch = nil
            }

        case .compacting(let agent):
            touch(agent)
            guard presences[agent.id] != nil else { return }
            resolveWaiting(agent.id, into: &out)
            // 정리는 잠깐 하는 뒷정리라 걸어가지 않고 그 자리에서 합니다: 자기 책상이면 책상에서, 소파·안마 의자에서 쉬던 중이면
            // 그 자리에 앉은 채 잠에서 깨어 서류를 훑어봅니다. Zz·음표·⏳ 같은 이전 표시와 들고 있던 컵은 내립니다.
            setEmote(agent.id, nil, into: &out)
            setPill(agent.id, nil, into: &out)
            modify(agent.id) {
                $0.shown = .thinking
                $0.shownAt = now
                $0.pending = nil
                $0.returnAt = nil
                $0.watching = nil
                $0.shellWatch = nil
                $0.compacting = true
            }
            wear(agent.id, into: &out)
            say(agent.id, "compact", into: &out)

        case .compactionEnded(let agent):
            touch(agent)
            guard let presence = presences[agent.id], presence.compacting else { return }
            modify(agent.id) { $0.compacting = false }
            if agent.isResting {
                // 쉬던 중 압축: 원래 쉼 단계의 모습으로 돌아가고, 쉼 단계는 쉬기 시작한 때부터 이어서 셉니다
                modify(agent.id) {
                    $0.shown = .idle
                    $0.shownAt = now
                    $0.idleSince = $0.idleSince ?? agent.activitySince
                }
                restoreRest(agent.id, into: &out)
            } else {
                // 응답 중 압축: 하던 일로 돌아갑니다
                wake(agent.id, into: &out)
                modify(agent.id) { $0.shown = .idle }
                if case .working(let call) = agent.activity {
                    show(agent.id, .working(call), at: now, into: &out)
                } else {
                    show(agent.id, .thinking, at: now, into: &out)
                }
            }

        case .reported(let member, let lead):
            guard presences[member.id] != nil else { return }
            touch(member)
            out.append(Directive(member.id, .clearQueue))
            resolveWaiting(member.id, into: &out)
            setPill(member.id, nil, into: &out)
            out.append(Directive(member.id, .prop(nil)))
            // 메인이 승인을 기다리거나(외침·"!"), 쉬거나(소파·안마 의자·잠, Zz·♪), 대화를 정리하는 중이면 메인 쪽 연출(하이파이브·"고마워요"·
            // 반짝이)을 하지 않습니다 (개선 8: 그 연출이 메인의 아이콘·표정을 덮어 "!"·Zz가 사라졌음). 그때는 서브도 메인에게 가지 않고
            // 신호·`await`~`awaitEnd` 짝도 만들지 않아 메인의 대기열이 막히지 않습니다. 서브는 제자리에서 뿌듯해하고 퇴근합니다.
            if let lead, let leadPresence = presences[lead.id], !leadPresence.waiting, leadPresence.rest == .none, !leadPresence.compacting {
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
                // 서브가 화면 밖(+N, 미니의 칸 밖)이면 무대가 여기까지 건너뜁니다 (개선 5). 아이콘·표정은 그때도 되돌립니다.
                out.append(Directive(lead.id, .awaitEnd(cue)))
                setEmote(lead.id, nil, into: &out)
                out.append(Directive(lead.id, .express(.neutral)))
            } else if let lead, presences[lead.id] != nil {
                out.append(Directive(member.id, .express(.proud)))
                out.append(Directive(member.id, .sound(.memberReport)))
                out.append(Directive(member.id, .wait(1.2)))
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

        case .cueChanged(let agent):
            touch(agent)
            guard let presence = presences[agent.id], presence.badge != agent.cue else { return }
            modify(agent.id) { $0.badge = agent.cue }
            out.append(Directive(agent.id, .badge(agent.cue)))
            // 답변 필요: 쉬러 가 있었으면(데스크톱 앱의 응답 요약이 늦게 옴) 자기 책상으로 돌아와 깨어 기다립니다.
            // 쉼 단계는 멈추고(`tickPresence`), 답하면(새 요청) 평소처럼 일합니다.
            if agent.cue == .reply, !presence.waiting, !presence.compacting {
                if presence.rest > .none || !isDesk(presence.spot) {
                    setEmote(agent.id, nil, into: &out)
                    out.append(Directive(agent.id, .prop(nil)))
                    move(agent.id, to: seatSpot(agent), into: &out)
                    out.append(Directive(agent.id, .pose(.sitting)))
                    out.append(Directive(agent.id, .express(.neutral)))
                    modify(agent.id) { $0.rest = .none }
                }
                out.append(Directive(agent.id, .gesture(.tilt)))
            }

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
                modify(id) { $0.watching = .some(call.id) }
                let look = Self.look(for: presences[id]!)
                out.append(Directive(id, .pose(look.pose)))
                out.append(Directive(id, .express(look.expression)))
                setEmote(id, look.emote, into: &out)
            }
        }

        if let returnAt = presences[id]?.returnAt, now >= returnAt {
            modify(id) { $0.returnAt = nil }
            let current = presences[id]!
            if !current.waiting, current.rest == .none {
                switch current.shown {
                case .idle, .thinking:
                    move(id, to: seatSpot(current.agent), into: &out)
                    let look = Self.look(for: presences[id]!)
                    out.append(Directive(id, .pose(look.pose)))
                    out.append(Directive(id, .prop(look.prop)))
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

        // 답변 필요(M6(4))는 쉬러 가지 않고 자기 책상에서 기다립니다
        if let current = presences[id], current.agent.role == .lead, current.shown == .idle, !current.waiting,
            current.badge != .reply, let since = current.idleSince
        {
            rest(id, current, elapsed: now.timeIntervalSince(since), at: now, into: &out)
        }
    }

    /// 쉼 단계: 60초 → 휴게 공간(소파), 3분 → 안마 의자(빈 의자가 있으면), 10분 → 잠듦.
    /// 안마 의자에 있으면 그 자리에서 잠들고, 아니면 자기 자리로 돌아가 꾸벅꾸벅 좁니다.
    private mutating func rest(_ id: AgentID, _ current: Presence, elapsed: Double, at now: Date, into out: inout [Directive]) {
        if elapsed >= config.napAfter, current.rest < .nap {
            modify(id) { $0.rest = .nap }
            if current.spot == .massageChair {
                // 안마 의자에서는 그 자리에서 잠듭니다 (손에 든 것이 없음)
                let look = Self.look(for: presences[id]!)
                out.append(Directive(id, .pose(look.pose)))
                out.append(Directive(id, .express(look.expression)))
                setEmote(id, look.emote, into: &out)
            } else {
                move(id, to: seatSpot(current.agent), into: &out)
                wear(id, propFirst: true, emote: true, into: &out)
            }
        } else if elapsed >= config.massageAfter, current.rest == .lounge,
            presences.values.filter({ $0.spot == .massageChair }).count < config.massageChairs
        {
            move(id, to: .massageChair, into: &out)
            modify(id) { $0.rest = .massage }
            wear(id, propFirst: true, emote: true, into: &out)
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
            modify(id) {
                $0.rest = .lounge
                $0.breaks += 1
                $0.drink = drink
            }
            wear(id, emote: true, into: &out)
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
            $0.compacting = false
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
            // 파일 읽기·웹 검색도 자기 책상에서 합니다 (책장·리서치 데스크를 없앰). 계획만 화이트보드 앞에서.
            let zone: Spot = call.category == .plan ? .whiteboard : seatSpot(previous.agent)
            if call.category == .shell {
                modify(id) { $0.shellWatch = ShellWatch(callID: call.id, since: now) }
            }

            var sameCategory = false
            if case .working(let earlier) = previous.shown, earlier.category == call.category, !previous.compacting { sameCategory = true }
            let moved = previous.spot != zone
            move(id, to: zone, into: &out)
            if moved || !sameCategory {
                wear(id, into: &out)
            }
            setPill(id, pill(for: call), into: &out)
            modify(id) {
                $0.returnAt = nil
                $0.idleSince = nil
            }

        case .thinking:
            setPill(id, nil, into: &out)
            if previous.shown != .thinking || previous.compacting {
                wear(id, into: &out)
            }
            if !(presences[id]?.spot.isSeat ?? true) {
                let returnAt = now.addingTimeInterval(config.linger)
                modify(id) { $0.returnAt = returnAt }
            }

        case .idle:
            setPill(id, nil, into: &out)
            if let presence = presences[id] {
                let look = Self.look(for: presence)
                out.append(Directive(id, .prop(look.prop)))
                out.append(Directive(id, .pose(look.pose)))
            }
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
        if !agent.isResting {
            // 응답 중에 앱을 켠 세션 (`ResidentSession.isResponding`): 쉼 단계 없이 자기 책상에서 생각하는 모습으로
            presence.shown = .thinking
            presences[agent.id] = presence
            out += restoreDirectives(for: agent, entering: false)
            return
        }
        presence.idleSince = since
        if elapsed >= config.napAfter {
            presence.rest = .nap
        } else if elapsed >= config.massageAfter,
            presences.values.filter({ $0.spot == .massageChair }).count < config.massageChairs
        {
            presence.spot = .massageChair
            presence.seated = false
            presence.rest = .massage
        } else if elapsed >= config.loungeAfter {
            presence.spot = .lounge
            presence.seated = false
            presence.rest = .lounge
            presence.breaks = 1
        }
        presence.emote = Self.look(for: presence).emote
        presences[agent.id] = presence
        out += restoreDirectives(for: agent, entering: false)
    }

    /// 자리(책상·행)가 바뀐 직원을 새 자리로 옮깁니다. 자기 책상에 있으면 바로, 다른 곳에 있으면 돌아올 때 새 자리로 갑니다.
    /// 손을 든 채(승인·질문 대기)면 답을 받은 뒤 옮깁니다(`resolveWaiting`).
    /// 자는 중이면 바로 옮겨 새 책상에서 이어 잡니다: 쉬는 세션은 며칠씩 깨지 않아, 깨어날 때까지 미루면 옛 책상에 남아
    /// 그 사이 책상이 모두 빈 채로 행이 늘어나 있었습니다 (2026-11-10, btw 세션들이 퇴근한 뒤 서브가 7번째 책상에서 잠).
    private mutating func reseat(_ agent: Agent, at now: Date, into out: inout [Directive]) {
        guard let presence = presences[agent.id], case .seat = presence.spot, !presence.waiting else { return }
        returnToOwnDesk(agent.id, into: &out)
    }

    /// 책상에 앉아 있는데 자기 책상이 아니면(자리가 바뀜) 자기 책상으로 옮기고 하던 자세를 이어 갑니다.
    private mutating func returnToOwnDesk(_ id: AgentID, into out: inout [Directive]) {
        guard let presence = presences[id], presence.spot.isSeat, !presence.waiting else { return }
        let target = seatSpot(presence.agent)
        guard target != presence.spot else { return }
        move(id, to: target, into: &out)
        out.append(Directive(id, .pose(Self.look(for: presences[id]!).pose)))
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

    /// 지금 쉼 단계의 모습 (자세·소품·표정·머리 위 표시)을 다시 정합니다. `rest(_:)`가 각 단계에 들어갈 때와 같은 모습입니다.
    private mutating func restoreRest(_ id: AgentID, into out: inout [Directive]) {
        guard let presence = presences[id] else { return }
        if presence.rest == .none { move(id, to: seatSpot(presence.agent), into: &out) }
        // 소파에서는 자세부터, 나머지는 손에 든 것부터 (예전 순서 그대로)
        wear(id, propFirst: presence.rest != .lounge, emote: true, into: &out)
    }

    private mutating func resolveWaiting(_ id: AgentID, into out: inout [Directive]) {
        guard let presence = presences[id], presence.waiting else { return }
        out.append(Directive(id, .dismissBubble))
        setEmote(id, nil, into: &out)
        // 손 든 자세를 풉니다. 이어지는 활동이 자세·소품·표정을 다시 정하도록 보이는 활동도 처음으로 돌립니다.
        modify(id) {
            $0.shown = .idle
            $0.waiting = false
            $0.knocks = 0
            $0.nextKnockAt = nil
            $0.shout = nil
            $0.seated = $0.spot.isSeat
        }
        out.append(Directive(id, .pose(Self.look(for: presences[id]!).pose)))
        if presence.spot.isSeat {
            out.append(Directive(id, .sit))
        }
        // 손을 든 동안 자리가 바뀌었으면 이제 옮깁니다
        returnToOwnDesk(id, into: &out)
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
        // MCP는 사전의 말 (M6(5)): 상세 "브라우저 페이지 이동", 요약 "브라우저 사용 중"
        let summary = call.category == .mcp ? MCPNames.summary(call.name) ?? call.category.summaryLabel : call.category.summaryLabel
        switch privacy {
        case .detailed:
            let text: String
            if call.category == .report {
                text = call.category.summaryLabel  // 넘기는 메시지 내용은 보여주지 않습니다
            } else if call.category == .mcp {
                text = MCPNames.short(call.name, detailed: true)
            } else if let subject = call.subject {
                text = "\(call.name) · \(subject)"
            } else {
                text = call.name
            }
            return StatusPill(category: call.category, text: text, summary: summary)
        case .summary:
            return StatusPill(category: call.category, text: summary, summary: summary)
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
        if call.category == .mcp {
            // "할 일 목록 정리 해도 될까요?" / "브라우저 써도 될까요?" (M6(5))
            if MCPNames.isAction(call.name) { return ("permission.action", ["action": MCPNames.label(call.name, detailed: true)]) }
            return ("permission.mcp", ["tool": MCPNames.label(call.name, detailed: true)])
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
        let look = Self.look(for: presence)
        out.append(Directive(id, .pose(look.pose)))
        out.append(Directive(id, .prop(look.prop)))
        out.append(Directive(id, .express(look.expression)))
        // 머리 위 아이콘은 기억해 둔 것 그대로 (💡·❓처럼 잠깐 띄운 것도 아직 떠 있으면 다시 띄움)
        if let emote = presence.emote { out.append(Directive(id, .emote(emote))) }
        if let badge = presence.badge { out.append(Directive(id, .badge(badge))) }
        if let pill = presence.pill { out.append(Directive(id, .status(pill))) }
        if presence.waiting, let shout = presence.shout { out.append(Directive(id, .say(shout))) }
        return out
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
