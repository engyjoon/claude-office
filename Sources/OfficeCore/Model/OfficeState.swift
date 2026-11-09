import Foundation

/// 리듀서가 내보내는 "무슨 일이 일어났는지". 연출 엔진(Choreographer)이 이것을 화면 지시로 바꿉니다.
/// 각 비트에는 그 순간의 `Agent` 스냅숏이 들어 있어서, 퇴근한 직원도 마지막 연출을 할 수 있습니다.
public enum Beat: Hashable, Sendable {
    case teamOpened(Team)
    /// 사람이 모두 떠난 행 (또는 다른 메인의 행으로 합쳐진 행). 메인 번호는 다음 행이 다시 씁니다.
    case teamClosed(Team)
    case arrived(Agent)
    /// 조용히 출근 (M5(5)): 데스크톱 앱에 열려 있던 세션을 출입문·인사·효과음 없이 "쉬는 중"으로 바로 앉힘.
    /// `activitySince`가 데스크톱 앱의 마지막 활동 시각이라 연출은 그때부터 쉼 단계를 셉니다.
    case settled(Agent)
    /// 서브 세션이 메인이 됨 (메인이 퇴근했거나, 늦게 밝혀진 부모 관계로 자리를 맞바꿈). 자리도 메인 책상으로 바뀝니다.
    case promoted(Agent)
    /// 직함이 바뀜 ("서브" → "서브1", "메인" → "메인1", 메인 → 서브). 자리·행이 함께 바뀔 수 있습니다.
    case retitled(Agent)
    /// 자리만 바뀜 (가운데 책상이 비어 오른쪽 끝 사람이 옮겨 앉음)
    case reseated(Agent)
    case promptArrived(Agent)
    case working(Agent, ToolCall)
    case toolEnded(Agent, ToolCall, ToolOutcome)
    case delegated(by: Agent, member: Agent)
    /// 위임 없이 서브에이전트가 나타남 (위임 이벤트를 놓쳤거나 구버전)
    case memberAppeared(Agent)
    case permissionAsked(Agent, ToolCall?)
    case permissionDenied(Agent, ToolCall?)
    case waitingForInput(Agent)
    case turnEnded(Agent, failed: Bool)
    case compacting(Agent)
    /// 압축이 끝남 (`SessionStart` source `compact`, `PostCompact`, 또는 오래 풀리지 않아 시간 초과).
    /// 비트의 `Agent.activity`가 되돌린 활동입니다: 쉬는 중이면 원래 쉼 단계로, 응답 중이면 하던 일로 (M6(2)).
    case compactionEnded(Agent)
    case reported(member: Agent, to: Agent?)
    case left(Agent)
    /// 응답을 끝낸 세션의 표시(`Agent.cue`: 답변 필요·확인 안 함)가 바뀜 (M6(4)). 다른 비트 뒤에 옵니다.
    case cueChanged(Agent)
}

/// 사무실의 의미 상태 (누가 어느 행·책상에서 무엇을 하는지). 순수 값 타입이며 시간은 이벤트에서만 받습니다.
///
/// 메인·서브 규칙 (설계서 §5.1, 2026-11-08 M5(1)):
/// - 메인 = 사용자가 직접 연 세션. 데스크톱 정보에 부모(`spawnedFrom`)가 없거나 부모가 사무실에 없으면 새 행을 열고 메인이 됩니다.
///   같은 폴더에서 직접 연 두 번째 세션, 터미널 CLI 세션도 각자 메인입니다.
/// - 서브 = 그 메인이 띄운 세션(조상이 그 행에 있는 세션)과, 그 행의 세션들이 부른 모든 서브에이전트.
/// - 행 = 메인 하나 + 서브들. 책상은 0번(메인)부터 사람 수만큼, 빈 책상 없이 (`Seat`). 서브 번호 = 책상 번호 (M6(14)).
/// - 메인이 퇴근하면 그 행에서 가장 먼저 온 서브 세션이 메인으로 승진합니다. 사람이 모두 떠난 행은 닫힙니다.
/// - 부모가 늦게 나타나면(하위 세션이 먼저 이벤트를 보냄, 정보 파일이 늦게 생김) 부모가 메인 자리를 넘겨받거나,
///   따로 열렸던 행을 부모의 행에 합칩니다.
public struct OfficeState: Sendable {
    /// 행 (예전 이름 그대로 팀)
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var agents: [AgentID: Agent] = [:]
    /// 세션 → 세션 기록
    public private(set) var parts: [SessionID: Part] = [:]

    private var teamOrder = 0
    private var partOrder = 0
    private var memberBySubagent: [String: AgentID] = [:]
    private var memberByDelegation: [String: AgentID] = [:]
    private var serial = 0
    /// 최근에 끝난 tool_use_id. 훅 스크립트가 curl을 백그라운드로 보내므로 Post가 Pre보다 먼저 도착할 수 있습니다.
    private var finishedToolIDs: [String] = []
    private var finishedToolIDSet: Set<String> = []
    /// 데스크톱 앱이 앞에 있을 때 지금 보고 있는 데스크톱 세션 (`syncResidents`가 맞춤, M6(4)).
    /// 이 세션의 응답이 끝나면 사용자가 보고 있었으므로 바로 "본" 것으로 칩니다.
    private var focusedHost: String?

    public init() {}

    // MARK: - 조회

    /// 세션 직원 (메인 또는 서브 세션)
    public func lead(of session: SessionID) -> Agent? {
        parts[session].flatMap { agents[$0.lead] }
    }

    /// 행의 메인
    public func main(of team: TeamID) -> Agent? {
        agents.values.first { $0.teamID == team && $0.number == 0 }
    }

    /// 행의 세션들 (들어온 순서)
    public func parts(in team: TeamID) -> [Part] {
        parts.values.filter { $0.teamID == team }.sorted { $0.order < $1.order }
    }

    /// 행의 직원 (책상 순서: 메인부터 오른쪽으로)
    public func agents(in team: TeamID) -> [Agent] {
        agents.values.filter { $0.teamID == team }.sorted { ($0.seat, $0.serial) < ($1.seat, $1.serial) }
    }

    /// 행 순서 (열린 순서 = 위에서 아래로)
    public var sortedTeams: [Team] {
        teams.values.sorted { $0.order < $1.order }
    }

    public func member(subagentID: String, in session: SessionID) -> Agent? {
        memberBySubagent[Self.subagentKey(session, subagentID)].flatMap { agents[$0] }
    }

    // MARK: - 리듀서

    public mutating func apply(_ event: OfficeEvent) -> [Beat] {
        var beats: [Beat] = []

        if case .sessionEnded = event.kind {
            endSession(event.session, beats: &beats)
            refreshCues(beats: &beats)
            return beats
        }

        let leadID = ensureLead(for: event, beats: &beats)
        let actorID = resolveActor(for: event, leadID: leadID, beats: &beats)
        let now = event.at

        switch event.kind {
        case .sessionStarted(source: "compact"?), .compactFinished:
            finishCompaction(leadID, at: now, timedOut: false, beats: &beats)

        case .sessionStarted, .sessionEnded:
            break

        case .promptSubmitted:
            parts[event.session]?.lastPromptAt = now
            parts[event.session]?.completedAt = nil
            parts[event.session]?.seenAt = now
            parts[event.session]?.replyRequested = false
            update(leadID) {
                $0.consecutiveErrors = 0
                $0.runningTools = []
                $0.setActivity(.thinking, at: now)
            }
            beats.append(.promptArrived(agents[leadID]!))

        case .toolStarted(let call):
            if let id = call.id, finishedToolIDSet.contains(id) { break }  // 이미 끝난 툴의 늦은 시작
            if call.asksUser {
                // 질문·계획 승인: 내가 답할 때까지(PostToolUse) 승인 대기와 같은 "답변 필요" (M5(4))
                update(actorID) {
                    $0.runningTools.append(call)
                    $0.setActivity(.waitingForPermission(call), at: now)
                }
                beats.append(.permissionAsked(agents[actorID]!, call))
                break
            }
            update(actorID) {
                $0.runningTools.append(call)
                $0.setActivity(.working(call), at: now)
            }
            beats.append(.working(agents[actorID]!, call))

        case .toolFinished(let call, let outcome):
            rememberFinished(call.id)
            update(actorID) { agent in
                agent.removeRunning(call)
                switch outcome {
                case .failure: agent.consecutiveErrors += 1
                case .success: agent.consecutiveErrors = 0
                case .interrupted: break
                }
                if case .waitingForPermission(let waited) = agent.activity,
                    !Self.permissionResolved(waited, by: call, stillRunning: agent.runningTools)
                {
                    // 다른 도구가 끝났을 뿐 승인 대기는 그대로 (병렬 도구)
                } else if let last = agent.runningTools.last {
                    agent.setActivity(.working(last), at: now)
                } else if case .working = agent.activity {
                    agent.setActivity(.thinking, at: now)
                } else if case .waitingForPermission = agent.activity {
                    // 승인받은 도구가 끝남: 승인 대기를 풉니다 (승인 자체를 알리는 훅은 없음, M5(3))
                    agent.setActivity(.thinking, at: now)
                }
            }
            beats.append(.toolEnded(agents[actorID]!, call, outcome))

        case .delegationStarted(let call, let subagentType):
            if let id = call.id, finishedToolIDSet.contains(id) { break }
            let memberID = createMember(
                session: event.session, teamID: agents[leadID]!.teamID, agentType: subagentType,
                delegatedBy: actorID, task: call.subject, toolUseID: call.id, background: call.runsInBackground,
                term: event.term, at: now)
            relabel(beats: &beats)
            update(actorID) { $0.setActivity(.delegating, at: now) }
            beats.append(.delegated(by: agents[actorID]!, member: agents[memberID]!))

        case .delegationFinished(let call, _):
            rememberFinished(call.id)
            // SubagentStart를 받은 서브에이전트와 백그라운드 실행은 SubagentStop을 기다립니다.
            // 시작·종료 신호를 보내지 않는 서브에이전트(web-fetch 등)와 구버전은 여기서 보고 처리합니다.
            if let id = call.id, let memberID = memberByDelegation[id], let member = agents[memberID],
                !member.announcedByHook, !member.runsInBackground
            {
                finishMember(memberID, at: now, beats: &beats)
            }

        case .subagentStarted(let ref):
            // 종류가 빈 서브에이전트는 Claude Code 내부 작업입니다 (M0: 신호 하나만 오고 툴 이벤트가 없음)
            guard let type = ref.type, !type.isEmpty else { break }
            let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: now, beats: &beats)
            update(memberID) { $0.announcedByHook = true }
            if created { beats.append(.memberAppeared(agents[memberID]!)) }

        case .subagentStopped(let ref):
            if let memberID = memberBySubagent[Self.subagentKey(event.session, ref.id)] ?? pendingMember(for: ref, in: event.session) {
                finishMember(memberID, at: now, beats: &beats)
            }

        case .permissionRequested(let call):
            let agent = agents[actorID]!
            if case .waitingForPermission(let existing) = agent.activity {
                // Notification과 PermissionRequest가 둘 다 오는 경우: 툴 정보만 보강하고 비트는 한 번만
                if existing == nil, let call {
                    update(actorID) { $0.activity = .waitingForPermission(call) }
                }
            } else {
                update(actorID) { $0.setActivity(.waitingForPermission(call), at: now) }
                beats.append(.permissionAsked(agents[actorID]!, call))
            }

        case .permissionDenied(let call):
            update(actorID) {
                if let call { $0.removeRunning(call) }
                $0.setActivity(.thinking, at: now)
            }
            beats.append(.permissionDenied(agents[actorID]!, call))

        case .waitingForInput:
            if agents[leadID]!.activity != .waitingForInput {
                update(leadID) { $0.setActivity(.waitingForInput, at: now) }
                beats.append(.waitingForInput(agents[leadID]!))
            }

        case .turnEnded(let failed, let asksUser):
            // 안전장치: 세션 응답이 끝났는데 남은 (백그라운드가 아닌) 서브에이전트는 이때 보고하고 퇴근합니다
            let leftovers = agents.values
                .filter { $0.session == event.session && $0.role == .member && !$0.runsInBackground }
                .sorted { $0.serial < $1.serial }
            for member in leftovers {
                finishMember(member.id, at: now, beats: &beats)
            }
            update(leadID) {
                $0.runningTools = []
                $0.setActivity(.idle, at: now)
            }
            parts[event.session]?.completedAt = now
            parts[event.session]?.replyRequested = asksUser && !failed
            if let host = parts[event.session]?.hostSession, host == focusedHost { parts[event.session]?.seenAt = now }
            beats.append(.turnEnded(agents[leadID]!, failed: failed))

        case .compacting:
            update(leadID) {
                if $0.activity != .compacting {
                    $0.beforeCompacting = CompactionOrigin(activity: $0.activity, since: $0.activitySince)
                }
                $0.setActivity(.compacting, at: now)
            }
            beats.append(.compacting(agents[leadID]!))
        }
        refreshCues(beats: &beats)
        return beats
    }

    // MARK: - 답변 필요·확인 안 함 (M6(4))

    /// 응답을 끝낸 세션 직원의 표시. 응답 중이거나 쉬는 중이 아니면(정리 중 등) 없음.
    func cue(for agent: Agent) -> SessionCue? {
        guard agent.role == .lead, agent.isResting, let part = parts[agent.session], let done = part.completedAt,
            !isResponding(agent.session)
        else { return nil }
        if part.replyRequested { return .reply }
        if (part.seenAt ?? .distantPast) < done { return .unread }
        return nil
    }

    /// 모든 세션 직원의 표시를 다시 정하고, 바뀐 사람마다 `cueChanged` 비트를 냅니다.
    private mutating func refreshCues(beats: inout [Beat]) {
        for id in agents.keys.sorted() {
            let next = cue(for: agents[id]!)
            guard agents[id]!.cue != next else { continue }
            agents[id]!.cue = next
            beats.append(.cueChanged(agents[id]!))
        }
    }

    /// 사용자가 데스크톱 앱에서 지금 그 세션을 보고 있음 (데스크톱 앱이 맨 앞이고 가장 최근에 연 세션, M6(4c) 알림 생략)
    public func isViewing(_ session: SessionID) -> Bool {
        guard let host = parts[session]?.hostSession else { return false }
        return host == focusedHost
    }

    /// 사용자가 그 세션의 응답을 봤음 (사무실·미니에서 캐릭터를 누름). "확인 안 함"이 풀립니다. "답변 필요"는 답할 때까지 그대로.
    public mutating func acknowledge(_ session: SessionID, at now: Date) -> [Beat] {
        guard parts[session] != nil else { return [] }
        parts[session]!.seenAt = max(parts[session]!.seenAt ?? .distantPast, now)
        var beats: [Beat] = []
        refreshCues(beats: &beats)
        return beats
    }

    // MARK: - 압축 (정리 중, M6(2))

    /// 이보다 오래 "정리 중"이면 끝 신호를 놓친 것으로 보고 쉬는 상태로 풉니다.
    public static let compactionTimeout: TimeInterval = 5 * 60

    /// 응답 중인지: 요청을 받은 뒤 아직 Stop이 오지 않음
    func isResponding(_ session: SessionID) -> Bool {
        guard let part = parts[session], let prompt = part.lastPromptAt else { return false }
        return part.completedAt.map { $0 < prompt } ?? true
    }

    /// 압축을 끝냅니다. 응답 중이 아니면(쉬던 중 수동 `/compact`, 데스크톱 앱의 압축) 압축 전의 쉬는 상태와 그 시각으로 되돌려
    /// 쉼 단계가 이어지게 하고, 응답 중이면(자동 압축) 압축 전 활동으로 되돌립니다. 시간 초과면 언제나 쉬는 상태로 풉니다.
    private mutating func finishCompaction(_ id: AgentID, at now: Date, timedOut: Bool, beats: inout [Beat]) {
        guard let agent = agents[id], agent.activity == .compacting else { return }
        let origin = agent.beforeCompacting
        let responding = !timedOut && isResponding(agent.session)
        update(id) {
            $0.beforeCompacting = nil
            if responding {
                switch origin?.activity {
                case .working?, .delegating?, .thinking?, .waitingForPermission?:
                    $0.activity = origin!.activity
                default:
                    $0.activity = .thinking
                }
                $0.activitySince = now
            } else if let origin, $0.isResting(origin.activity) {
                $0.activity = origin.activity == .arriving ? .idle : origin.activity
                $0.activitySince = origin.since
            } else {
                $0.runningTools = []
                $0.setActivity(.idle, at: now)
            }
        }
        beats.append(.compactionEnded(agents[id]!))
    }

    /// `compactionTimeout`보다 오래 "정리 중"인 세션을 쉬는 상태로 풉니다 (앱이 화면 주기마다 부름).
    public mutating func expireCompaction(at now: Date, after limit: TimeInterval = compactionTimeout) -> [Beat] {
        let stuck = agents.values
            .filter { $0.activity == .compacting && now.timeIntervalSince($0.activitySince) >= limit }
            .sorted { $0.serial < $1.serial }
        var beats: [Beat] = []
        for agent in stuck {
            finishCompaction(agent.id, at: now, timedOut: true, beats: &beats)
        }
        if !beats.isEmpty { refreshCues(beats: &beats) }
        return beats
    }

    // MARK: - 행과 세션 직원

    private mutating func ensureLead(for event: OfficeEvent, beats: inout [Beat]) -> AgentID {
        continueHostSession(for: event)
        summonRoot(for: event, beats: &beats)
        if let part = parts[event.session], agents[part.lead] != nil {
            if let hint = event.hint { absorb(hint, for: event.session, beats: &beats) }
            return part.lead
        }
        let ancestors = event.hint?.ancestors ?? []
        let teamID: TeamID
        var asMain = true
        var demoted: AgentID?
        if let parent = ancestors.first(where: { parts[$0] != nil }) {
            // 부모가 사무실에 있으면 그 행의 서브
            teamID = parts[parent]!.teamID
            asMain = false
        } else if let child = sortedTeams.compactMap({ main(of: $0.id) }).first(where: { parts[$0.session]?.ancestors.contains(event.session) == true }) {
            // 이 세션이 띄운 세션이 먼저 와서 메인 자리에 있음 → 메인 자리를 넘겨받고, 먼저 온 세션은 서브가 됩니다
            teamID = child.teamID
            let desk = nextDesk(in: teamID)
            update(child.id) {
                $0.number = desk
                $0.seat = Seat(desk: desk)
            }
            demoted = child.id
        } else {
            teamID = openTeam(folder: Team.folder(for: event.hint?.rootCwd ?? event.cwd), beats: &beats)
        }

        let profile = AgentProfile.session(event.session)
        let id = makeAgent(
            role: .lead, profile: profile, teamID: teamID, session: event.session, asMain: asMain,
            delegatedBy: nil, task: nil, toolUseID: nil, background: false, term: event.term, at: event.at)
        partOrder += 1
        parts[event.session] = Part(
            session: event.session, teamID: teamID, order: partOrder, lead: id, ancestors: ancestors, title: event.hint?.title,
            hostSession: event.hint?.hostSession)
        relabel(force: demoted.map { [$0] } ?? [], beats: &beats)
        beats.append(.arrived(agents[id]!))
        // 이 세션이 띄운 세션이 다른 행의 메인으로 와 있었으면 그 행을 합칩니다
        reconcileTeams(beats: &beats)
        return id
    }

    /// 서브 세션이 왔는데 그 최상위 세션(메인)이 데스크톱 앱에 열려 있으면서 사무실에 아직 없으면(쉬고 있어 훅을 보내지 않음),
    /// 메인을 먼저 입력 대기로 앉힙니다. 서브가 먼저 메인 자리에 와 있었으면 "늦게 온 부모"처럼 메인 자리를 넘겨받습니다.
    private mutating func summonRoot(for event: OfficeEvent, beats: inout [Beat]) {
        guard let hint = event.hint, hint.rootIsOpen, let root = hint.ancestors.last, root != event.session,
            parts[root] == nil || agents[parts[root]!.lead] == nil
        else { return }
        let arrival = OfficeEvent(
            session: root, cwd: hint.rootCwd ?? event.cwd, term: event.term, at: event.at, kind: .sessionStarted(source: nil),
            hint: SessionHint(hostSession: hint.rootHostSession, rootCwd: hint.rootCwd, title: hint.rootTitle))
        let id = ensureLead(for: arrival, beats: &beats)
        update(id) { $0.setActivity(.waitingForInput, at: event.at) }
        beats.append(.waitingForInput(agents[id]!))
    }

    /// 데스크톱 앱이 같은 데스크톱 세션의 CLI 세션 id를 바꿨으면(정보 파일의 `cliSessionId`가 이 훅의 `session_id`),
    /// 그 데스크톱 세션으로 앉아 있던 사람을 새 id로 이어 갑니다 (캐릭터가 둘이 되지 않게, M5(5)).
    /// 정보 파일이 확인해 줄 때만 이어 갑니다: 세션 안에서 띄운 `claude` 명령도 같은 데스크톱 세션 id를 물려받기 때문입니다.
    private mutating func continueHostSession(for event: OfficeEvent) {
        guard parts[event.session] == nil, let hint = event.hint, let host = hint.hostSession, hint.hostCliSession == event.session,
            let old = parts.values.filter({ $0.hostSession == host && agents[$0.lead] != nil }).min(by: { $0.order < $1.order })
        else { return }
        rekey(old.session, to: event.session)
    }

    /// 세션 id만 바꿉니다 (사람·자리·행·직함은 그대로).
    private mutating func rekey(_ old: SessionID, to new: SessionID) {
        guard old != new, parts[new] == nil, var part = parts.removeValue(forKey: old) else { return }
        part.session = new
        parts[new] = part
        for (id, agent) in agents where agent.session == old {
            agents[id]!.session = new
            if let subagentID = agent.subagentID {
                memberBySubagent[Self.subagentKey(old, subagentID)] = nil
                memberBySubagent[Self.subagentKey(new, subagentID)] = id
            }
        }
        for key in parts.keys where parts[key]!.ancestors.contains(old) {
            parts[key]!.ancestors = parts[key]!.ancestors.map { $0 == old ? new : $0 }
        }
    }

    // MARK: - 데스크톱 앱에 열려 있는 세션 (M5(5))

    /// 데스크톱 앱 세션 정보를 사무실에 맞춥니다 (앱이 몇 초마다 부름).
    ///
    /// - 열려 있지만 사무실에 없는 세션은 "쉬는 중"으로 조용히 앉힙니다(`settled`). 부모가 사무실에 있으면 그 행의 서브.
    /// - 이미 있는 세션은 제목·데스크톱 id·부모만 맞춥니다. 같은 데스크톱 세션이 CLI 세션 id만 바뀌었으면 같은 사람으로 이어 갑니다.
    /// - 보관했거나 목록에서 사라진 데스크톱 세션은 퇴근시킵니다. 다만 파일을 읽기 시작한 뒤에 훅이 왔거나,
    ///   지금 일하는 중(마지막 활동이 `busyGrace` 안)이면 그대로 둡니다. 터미널 CLI 세션과 `office-sim`의 가짜 세션은
    ///   데스크톱 id가 없어서 건드리지 않습니다.
    public mutating func syncResidents(_ roll: ResidentRoll, at now: Date, busyGrace: TimeInterval = 10 * 60) -> [Beat] {
        var beats: [Beat] = []
        focusedHost = roll.residents.first(where: \.isFocused)?.hostSession
        if roll.isReliable {
            let gone = parts.values
                .filter { part in
                    guard let host = part.hostSession, !roll.openHostSessions.contains(host), let lead = agents[part.lead] else { return false }
                    guard lead.activitySince < roll.readAt else { return false }
                    return lead.isResting || now.timeIntervalSince(lead.activitySince) >= busyGrace
                }
                .sorted { $0.order > $1.order }  // 서브 세션부터 (메인이 먼저 나가 서브가 승진했다가 바로 나가지 않게)
            for part in gone where parts[part.session] != nil {
                endSession(part.session, beats: &beats)
            }
        }
        for resident in roll.residents {
            let hint = SessionHint(
                hostSession: resident.hostSession, ancestors: resident.ancestors, rootCwd: resident.rootCwd, title: resident.title)
            if parts[resident.session] == nil,
                let old = parts.values.filter({ $0.hostSession == resident.hostSession && agents[$0.lead]?.isResting == true })
                    .min(by: { $0.order < $1.order })
            {
                rekey(old.session, to: resident.session)
            }
            if let part = parts[resident.session], agents[part.lead] != nil {
                absorb(hint, for: resident.session, beats: &beats)
                observe(resident, at: now)
                continue
            }
            let arrival = OfficeEvent(
                session: resident.session, cwd: resident.rootCwd, term: nil, at: now, kind: .sessionStarted(source: nil), hint: hint)
            var local: [Beat] = []
            let id = ensureLead(for: arrival, beats: &local)
            update(id) { $0.setActivity(.idle, at: min(resident.lastActivity ?? now, now)) }
            // 사무실에 오기 전에 끝난 응답도 확인 안 함·답변 필요를 보여 주도록 응답 끝을 데스크톱 기록에서 가져옵니다
            parts[resident.session]?.completedAt = resident.lastTurnEdge.map { min($0, now) }
            parts[resident.session]?.replyRequested = resident.replyRequest ?? false
            observe(resident, at: now)
            let settled = agents[id]!
            beats += local.map { beat in
                if case .arrived(let agent) = beat, agent.id == id { return .settled(settled) }
                return beat
            }
        }
        refreshCues(beats: &beats)
        return beats
    }

    /// 데스크톱 앱이 알려 준 "본 때"와 응답 요약을 세션 기록에 반영합니다 (M6(4)).
    private mutating func observe(_ resident: ResidentSession, at now: Date) {
        guard var part = parts[resident.session] else { return }
        let seen = [part.seenAt, resident.lastFocused.map { min($0, now) }, resident.isFocused ? now : nil].compactMap { $0 }.max()
        part.seenAt = seen
        // 응답 요약은 끝난 응답에 대한 것만 따릅니다 (응답 중이면 지난 응답의 요약일 수 있음)
        if let verdict = resident.replyRequest, part.completedAt != nil, !isResponding(resident.session) {
            part.replyRequested = verdict
        }
        parts[resident.session] = part
    }

    private mutating func openTeam(folder: String, beats: inout [Beat]) -> TeamID {
        // 닫힌 행의 메인 번호를 다시 씁니다
        let used = Set(teams.values.map(\.island))
        var island = 0
        while used.contains(island) { island += 1 }
        teamOrder += 1
        let id = TeamID("\(folder)#\(teamOrder)")
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        let team = Team(id: id, name: name, folder: folder, island: island, order: teamOrder, colorIndex: island % Team.colorCount)
        teams[id] = team
        beats.append(.teamOpened(team))
        return id
    }

    /// 오른쪽 끝에 붙일 책상 번호 (책상은 빈자리 없이 0번부터 이어지므로 사람 수와 같음).
    /// 서브 번호는 언제나 책상 번호와 같으므로 새 서브의 번호이기도 합니다 (M6(14)).
    private func nextDesk(in team: TeamID) -> Int {
        (agents.values.filter { $0.teamID == team }.map(\.seat.desk).max() ?? -1) + 1
    }

    /// 이미 있는 세션에 늦게 온 힌트 (데스크톱 정보 파일이 나중에 생긴 경우, 제목이 바뀐 경우)
    private mutating func absorb(_ hint: SessionHint, for session: SessionID, beats: inout [Beat]) {
        guard var part = parts[session] else { return }
        if let title = hint.title { part.title = title }
        if let host = hint.hostSession { part.hostSession = host }
        let ancestorsChanged = !hint.ancestors.isEmpty && hint.ancestors != part.ancestors
        if ancestorsChanged { part.ancestors = hint.ancestors }
        parts[session] = part
        if ancestorsChanged { reconcileTeams(beats: &beats) }
    }

    /// 메인이 다른 행 사람의 후손이면 그 행에 합칩니다 (부모가 늦게 나타났거나 정보 파일이 늦게 생김).
    private mutating func reconcileTeams(beats: inout [Beat]) {
        for _ in 0..<8 {
            var merged = false
            for team in sortedTeams {
                guard let main = main(of: team.id), let part = parts[main.session],
                    let target = part.ancestors.compactMap({ parts[$0]?.teamID }).first(where: { $0 != team.id && teams[$0] != nil })
                else { continue }
                merge(team.id, into: target, beats: &beats)
                merged = true
                break
            }
            if !merged { return }
        }
    }

    /// 행 하나를 다른 행에 합칩니다: 사람들은 책상 순서대로 그 행의 오른쪽 끝에 서브로 붙고, 원래 행은 닫힙니다.
    private mutating func merge(_ source: TeamID, into target: TeamID, beats: inout [Beat]) {
        let movers = agents(in: source)
        for agent in movers {
            let desk = nextDesk(in: target)
            update(agent.id) {
                $0.teamID = target
                $0.number = desk
                $0.seat = Seat(desk: desk)
            }
        }
        for (session, part) in parts where part.teamID == source { parts[session]!.teamID = target }
        relabel(force: Set(movers.map(\.id)), beats: &beats)
        if let closed = teams.removeValue(forKey: source) {
            beats.append(.teamClosed(closed))
            relabel(beats: &beats)
        }
    }

    /// 직함을 다시 정하고, 바뀐 사람마다 비트를 냅니다.
    /// 메인은 사무실 전체에서 1명이면 "메인", 여럿이면 "메인N". 서브는 행마다 1명이면 "서브", 여럿이면 "서브N".
    /// `reseated`(옮겨 앉은 사람)는 직함이 그대로여도 `reseated` 비트를 냅니다 (자리와 직함을 한 비트로).
    private mutating func relabel(
        promoted: AgentID? = nil, force: Set<AgentID> = [], reseated: Set<AgentID> = [], beats: inout [Beat]
    ) {
        let people = agents.values.sorted { $0.serial < $1.serial }
        var subCounts: [TeamID: Int] = [:]
        for agent in people where agent.number > 0 { subCounts[agent.teamID, default: 0] += 1 }
        let several = teams.count > 1
        for agent in people {
            let title: JobTitle = agent.number == 0
                ? .main(several ? teams[agent.teamID].map(\.mainNumber) : nil)
                : .sub((subCounts[agent.teamID] ?? 0) > 1 ? agent.number : nil)
            guard agent.title != title || force.contains(agent.id) || reseated.contains(agent.id) else { continue }
            update(agent.id) { $0.title = title }
            let changed = agents[agent.id]!
            beats.append(agent.id == promoted ? .promoted(changed) : reseated.contains(agent.id) ? .reseated(changed) : .retitled(changed))
        }
    }

    /// 가운데 빈 책상을 오른쪽 끝 사람으로 메웁니다 (빈 책상 없음). 옮긴 사람은 그 책상 번호를 서브 번호로 받습니다
    /// (M6(14): 서브 번호 = 책상 번호, 서브3·서브4 중 서브3이 빠지면 서브4가 3번 책상으로 옮겨 서브3).
    /// 옮긴 사람을 돌려주며, 비트는 뒤따르는 `relabel(reseated:)`가 새 직함과 함께 냅니다.
    private mutating func compactDesks(in team: TeamID) -> Set<AgentID> {
        var moved: Set<AgentID> = []
        for _ in 0..<64 {
            let people = agents(in: team)
            let used = Set(people.map(\.seat.desk))
            guard let last = people.last, let hole = (1..<max(last.seat.desk, 1)).first(where: { !used.contains($0) }) else { break }
            update(last.id) {
                $0.seat = Seat(desk: hole)
                $0.number = hole
            }
            moved.insert(last.id)
        }
        return moved
    }

    private mutating func endSession(_ session: SessionID, beats: inout [Beat]) {
        guard let part = parts[session] else { return }
        let wasMain = agents[part.lead]?.number == 0
        for member in agents.values.filter({ $0.session == session && $0.role == .member }).sorted(by: { $0.serial < $1.serial }) {
            beats.append(.left(member))
            removeAgent(member.id)
        }
        if let lead = agents[part.lead] {
            beats.append(.left(lead))
            removeAgent(part.lead)
        }
        parts[session] = nil

        let team = part.teamID
        var promoted: AgentID?
        if wasMain, let next = parts.values.filter({ $0.teamID == team }).min(by: { $0.order < $1.order }), agents[next.lead] != nil {
            // 가장 먼저 온 서브 세션이 메인 책상으로
            update(next.lead) {
                $0.number = 0
                $0.seat = .main
            }
            promoted = next.lead
        }
        if !agents.values.contains(where: { $0.teamID == team }), let closed = teams.removeValue(forKey: team) {
            beats.append(.teamClosed(closed))
        }
        let moved = compactDesks(in: team)
        relabel(promoted: promoted, force: promoted.map { [$0] } ?? [], reseated: moved, beats: &beats)
    }

    // MARK: - 서브에이전트

    private mutating func resolveActor(for event: OfficeEvent, leadID: AgentID, beats: inout [Beat]) -> AgentID {
        guard let ref = event.subagent else { return leadID }
        let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: event.at, beats: &beats)
        if created { beats.append(.memberAppeared(agents[memberID]!)) }
        return memberID
    }

    /// agent_id로 서브에이전트를 찾고, 없으면 아직 agent_id가 없는 위임 서브에이전트에 묶고, 그래도 없으면 새로 만듭니다.
    private mutating func bindOrCreateMember(
        _ ref: SubagentRef, session: SessionID, leadID: AgentID, term: String?, at now: Date, beats: inout [Beat]
    ) -> (AgentID, created: Bool) {
        let key = Self.subagentKey(session, ref.id)
        if let id = memberBySubagent[key], agents[id] != nil { return (id, false) }
        if let id = pendingMember(for: ref, in: session) {
            update(id) { $0.subagentID = ref.id }
            memberBySubagent[key] = id
            return (id, false)
        }
        let id = createMember(
            session: session, teamID: agents[leadID]!.teamID, agentType: ref.type, delegatedBy: leadID,
            task: nil, toolUseID: nil, background: false, term: term, at: now)
        update(id) { $0.subagentID = ref.id }
        memberBySubagent[key] = id
        relabel(beats: &beats)
        return (id, true)
    }

    /// 위임으로 만들어졌지만 아직 agent_id가 없는 서브에이전트 중 종류가 맞는 가장 오래된 팀원
    ///
    /// 실제 수집(M0)에서 종류가 빈 SubagentStop이 많았습니다 (Claude Code 내부 작업, 다른 이벤트 없음).
    /// 엉뚱한 서브에이전트와 짝짓지 않도록 종류가 정확히 같을 때만 묶고, 종류를 모르면 묶지 않습니다.
    private func pendingMember(for ref: SubagentRef, in session: SessionID) -> AgentID? {
        guard let type = ref.type, !type.isEmpty else { return nil }
        return agents.values
            .filter { $0.session == session && $0.role == .member && $0.subagentID == nil && $0.profile.agentType == type }
            .min { $0.serial < $1.serial }?
            .id
    }

    private mutating func createMember(
        session: SessionID, teamID: TeamID, agentType: String?, delegatedBy: AgentID?, task: String?,
        toolUseID: String?, background: Bool, term: String?, at now: Date
    ) -> AgentID {
        // 같은 종류가 이미 있으면 비어 있는 가장 작은 번호를 붙입니다 (먼저 온 사람이 퇴근해도 이름이 겹치지 않게)
        let usedNames = Set(agents.values.filter { $0.teamID == teamID && $0.role == .member }.map(\.profile.displayName))
        var duplicates = 0
        var profile = AgentProfile.member(agentType: agentType, serial: serial + 1, duplicateIndex: 0)
        while profile.kind == .fixed, usedNames.contains(profile.displayName) {
            duplicates += 1
            profile = AgentProfile.member(agentType: agentType, serial: serial + 1, duplicateIndex: duplicates)
        }
        let id = makeAgent(
            role: .member, profile: profile, teamID: teamID, session: session, asMain: false,
            delegatedBy: delegatedBy,
            task: task, toolUseID: toolUseID, background: background, term: term, at: now)
        if let toolUseID { memberByDelegation[toolUseID] = id }
        return id
    }

    private mutating func finishMember(_ memberID: AgentID, at now: Date, beats: inout [Beat]) {
        guard var member = agents[memberID] else { return }
        member.setActivity(.reporting, at: now)
        let delegator = member.delegatedBy.flatMap { agents[$0] }
        beats.append(.reported(member: member, to: delegator))
        removeAgent(memberID)
        relabel(reseated: compactDesks(in: member.teamID), beats: &beats)

        if let delegatorID = delegator?.id, agents[delegatorID]?.activity == .delegating,
            !agents.values.contains(where: { $0.delegatedBy == delegatorID })
        {
            update(delegatorID) { $0.setActivity(.thinking, at: now) }
        }
    }

    // MARK: - 공통

    private mutating func makeAgent(
        role: Role, profile: AgentProfile, teamID: TeamID, session: SessionID, asMain: Bool,
        delegatedBy: AgentID?, task: String?, toolUseID: String?, background: Bool, term: String?, at now: Date
    ) -> AgentID {
        // 메인은 0번(메인 책상), 서브는 오른쪽 끝 책상과 그 책상 번호를 서브 번호로 받습니다 (M6(14))
        let number = asMain ? 0 : nextDesk(in: teamID)
        let seat = Seat(desk: number)
        // 다른 사람의 표시("서브" → "서브1" 등)는 뒤따르는 relabel이 바꿉니다
        let title: JobTitle
        if asMain {
            title = .main(teams.count > 1 ? teams[teamID].map(\.mainNumber) : nil)
        } else {
            let subs = agents.values.filter { $0.teamID == teamID && $0.number > 0 }.count + 1
            title = .sub(subs > 1 ? number : nil)
        }
        // 외형: 지금 사무실에 있는 모든 사람(모든 디렉토리, 쉬는 사람 포함)과 겹치지 않게 (M5(6))
        var profile = profile
        profile.appearance = AppearanceAllocator.allocate(
            key: profile.key, kind: profile.kind,
            among: agents.values.sorted { $0.serial < $1.serial }.map {
                AppearanceAllocator.Occupant(appearance: $0.profile.appearance, sameRow: $0.teamID == teamID)
            })
        serial += 1
        let id = AgentID(role == .lead ? "lead-\(serial)" : "member-\(serial)")
        agents[id] = Agent(
            id: id, role: role, profile: profile, teamID: teamID, session: session, number: number, title: title, seat: seat,
            subagentID: nil, delegatedBy: delegatedBy, task: task, delegationToolUseID: toolUseID,
            runsInBackground: background, activity: .arriving, activitySince: now, runningTools: [],
            consecutiveErrors: 0, term: term, serial: serial)
        return id
    }

    private mutating func update(_ id: AgentID, _ body: (inout Agent) -> Void) {
        guard var agent = agents[id] else { return }
        body(&agent)
        agents[id] = agent
    }

    private mutating func removeAgent(_ id: AgentID) {
        guard let agent = agents.removeValue(forKey: id) else { return }
        if let subagentID = agent.subagentID {
            memberBySubagent[Self.subagentKey(agent.session, subagentID)] = nil
        }
        if let toolUseID = agent.delegationToolUseID {
            memberByDelegation[toolUseID] = nil
        }
    }

    private mutating func rememberFinished(_ id: String?) {
        guard let id, finishedToolIDSet.insert(id).inserted else { return }
        finishedToolIDs.append(id)
        if finishedToolIDs.count > 512 {
            finishedToolIDSet.remove(finishedToolIDs.removeFirst())
        }
    }

    /// 끝난 도구가 기다리던 승인을 풀었는지: 기다리던 도구와 같거나(이름·대상), 무엇을 기다렸는지 모르거나, 남은 도구가 없으면
    static func permissionResolved(_ waited: ToolCall?, by finished: ToolCall, stillRunning: [ToolCall]) -> Bool {
        guard let waited else { return true }
        if let a = waited.id, let b = finished.id { return a == b }
        if waited.name == finished.name && (waited.subject == nil || waited.subject == finished.subject) { return true }
        return stillRunning.isEmpty
    }

    static func subagentKey(_ session: SessionID, _ agentID: String) -> String {
        "\(session.raw)#\(agentID)"
    }
}

extension Agent {
    /// 쉬는 중 (응답을 끝냈거나 입력을 기다림, 막 들어옴)
    var isResting: Bool { isResting(activity) }

    func isResting(_ activity: Activity) -> Bool {
        switch activity {
        case .idle, .waitingForInput, .arriving: true
        default: false
        }
    }

    mutating func setActivity(_ activity: Activity, at now: Date) {
        self.activity = activity
        activitySince = now
        if activity != .compacting { beforeCompacting = nil }
    }

    mutating func removeRunning(_ call: ToolCall) {
        if let id = call.id, let index = runningTools.firstIndex(where: { $0.id == id }) {
            runningTools.remove(at: index)
        } else if let index = runningTools.firstIndex(where: { $0.name == call.name }) {
            runningTools.remove(at: index)
        }
    }
}
