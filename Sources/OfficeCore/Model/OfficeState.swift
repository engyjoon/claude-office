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
    /// 끝 신호(Stop) 없이 끝난 응답을 닫음 (사용자가 Esc로 중단, 끝 신호를 놓침). 비트의 `Agent`는 닫은 뒤의 쉬는 상태입니다.
    /// 끝낸 것이 아니라서 축하 연출·응답 완료 알림은 없고, 남은 포그라운드 서브는 이 비트 앞의 `left`로 퇴근합니다.
    case turnAbandoned(Agent)
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
///
/// 암묵적 종료 (설계서 §5.3, 개선 4): 끝 이벤트(Stop·PostToolUse·SubagentStop·SessionEnd)는 오지 않을 수 있습니다
/// (Esc 중단에는 Stop이 없고, 실패한 도구는 PostToolUseFailure 훅이 없으면 끝 신호가 없음). 그래서 뒤따르는 신호로 끝을 미루어 압니다.
/// - 턴: 쉬지 않는 세션에 `idle_prompt`나 새 요청이 오면, 또는 세션 전체가 `silenceLimit` 동안 조용하면 앞 턴을 닫습니다 (`abandonTurn`).
/// - 도구: 앞 PreToolUse로부터 `toolBatchWindow`가 지나서 온 PreToolUse는 새 묶음이라, 남아 있던 도구를 버립니다 (`beginTool`).
/// - 서브: 닫힌 턴의 포그라운드 서브는 퇴근하고, `silenceLimit` 동안 조용한 서브도 퇴근합니다 (`expireSilence`).
/// - 세션: SessionEnd 뒤 `endedSessionMemory` 안에 늦게 온 훅은 버립니다. 세션의 시간 기반 퇴근은 두지 않습니다 (§5.2).
public struct OfficeState: Sendable {
    /// 행 (예전 이름 그대로 팀)
    public internal(set) var teams: [TeamID: Team] = [:]
    public internal(set) var agents: [AgentID: Agent] = [:]
    /// 세션 → 세션 기록
    public internal(set) var parts: [SessionID: Part] = [:]

    var teamOrder = 0
    var partOrder = 0
    var memberBySubagent: [String: AgentID] = [:]
    var memberByDelegation: [String: AgentID] = [:]
    var serial = 0
    /// 최근에 끝난 tool_use_id. 훅마다 따로 뜬 스크립트(curl)가 보내서 도착 순서가 뒤바뀔 수 있어, Post가 Pre보다 먼저 올 수 있습니다.
    var finishedToolIDs: [String] = []
    var finishedToolIDSet: Set<String> = []
    /// 데스크톱 앱이 앞에 있을 때 지금 보고 있는 데스크톱 세션 (`syncResidents`가 맞춤, M6(4)).
    /// 이 세션의 응답이 끝나면 사용자가 보고 있었으므로 바로 "본" 것으로 칩니다.
    var focusedHost: String?
    /// 최근에 끝난(SessionEnd) 세션과 그 시각. 늦게 온 훅이 끝난 세션을 다시 출근시키지 않게 잠깐 기억합니다.
    var endedSessions: [SessionID: Date] = [:]
    var endedSessionOrder: [SessionID] = []

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

    /// 이 직원의 세션이 응답을 끝낸 때 (끝낸 적이 없으면 지금 상태가 된 때). 답변 필요·확인 안 한 응답이 "언제부터"인지 셀 때 씁니다.
    public func completedAt(of agent: Agent) -> Date {
        parts[agent.session]?.completedAt ?? agent.activitySince
    }

    /// 행 안 세션들이 가장 최근에 요청을 받은 때
    public func lastPromptAt(in people: [Agent]) -> Date? {
        Set(people.map(\.session)).compactMap { parts[$0]?.lastPromptAt }.max()
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
            rememberEnded(event.session, at: event.at)
            refreshCues(beats: &beats)
            return beats
        }
        if isLateAfterEnd(event) { return [] }

        let leadID = ensureLead(for: event, beats: &beats)
        let actorID = resolveActor(for: event, leadID: leadID, beats: &beats)
        let now = event.at
        update(leadID) { $0.lastHeardAt = now }
        update(actorID) { $0.lastHeardAt = now }

        switch event.kind {
        case .sessionStarted(source: "compact"?), .compactFinished:
            finishCompaction(leadID, at: now, timedOut: false, beats: &beats)

        case .sessionStarted, .sessionEnded:
            break

        case .promptSubmitted where event.subagent != nil:
            // 서브에이전트 안에서 난 요청 훅은 사용자가 세션에 보낸 새 요청이 아닙니다 (그 서브가 살아 있다는 것만 압니다)
            break

        case .promptSubmitted:
            // 앞 턴이 Stop 없이 끝났으면(중단) 먼저 닫습니다
            abandonTurn(event.session, restingAs: .idle, at: now, beats: &beats)
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
            beginTool(actorID, at: now)
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
                } else if agent.activity == .arriving {
                    // 앱을 턴 도중에 켜서 첫 훅이 도구의 끝: 응답 중입니다 ("출근 중"으로 남지 않게)
                    agent.setActivity(.thinking, at: now)
                }
            }
            beats.append(.toolEnded(agents[actorID]!, call, outcome))

        case .delegationStarted(let call, let subagentType):
            if let id = call.id, finishedToolIDSet.contains(id) { break }
            beginTool(actorID, at: now)
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

        case .permissionRequested(let requested):
            var askerID = actorID
            var call = requested
            if requested == nil, event.subagent == nil {
                // Notification(permission_prompt)에는 agent_id도 도구도 없어서, 서브가 낸 요청도 메인 스레드의 알림으로 옵니다.
                // 이미 누가 기다리는 중이면(PermissionRequest가 먼저 옴, 알림은 6초쯤 뒤) 같은 요청이라 넘기고,
                // 아니면 그 세션에서 가장 최근에 도구를 시작해 아직 끝내지 않은 사람의 요청으로 봅니다.
                let people = agents.values.filter { $0.session == event.session }
                if people.contains(where: \.isWaitingForPermission) { break }
                if let asker = people.filter({ !$0.runningTools.isEmpty }).max(by: {
                    ($0.lastToolStartAt ?? .distantPast, $0.serial) < ($1.lastToolStartAt ?? .distantPast, $1.serial)
                }) {
                    askerID = asker.id
                    call = asker.runningTools.last
                }
            }
            let agent = agents[askerID]!
            if case .waitingForPermission(let existing) = agent.activity {
                // Notification과 PermissionRequest가 둘 다 오는 경우: 툴 정보만 보강하고 비트는 한 번만
                if existing == nil, let call {
                    update(askerID) { $0.activity = .waitingForPermission(call) }
                }
            } else {
                update(askerID) { $0.setActivity(.waitingForPermission(call), at: now) }
                beats.append(.permissionAsked(agents[askerID]!, call))
            }

        case .permissionDenied(let call):
            update(actorID) {
                if let call { $0.removeRunning(call) }
                $0.setActivity(.thinking, at: now)
            }
            beats.append(.permissionDenied(agents[actorID]!, call))

        case .waitingForInput:
            // 방금 온 요청보다 늦게 도착한 지난 턴의 알림은 버립니다 (idle_prompt는 응답이 끝나고 60초쯤 뒤에 옴)
            if isResponding(event.session), let prompt = parts[event.session]?.lastPromptAt,
                now.timeIntervalSince(prompt) < Self.staleIdlePromptWindow
            {
                break
            }
            // 쉬지 않는 세션에 왔으면 앞 턴이 Stop 없이 끝난 것입니다 (중단)
            let abandoned = abandonTurn(event.session, restingAs: .waitingForInput, at: now, beats: &beats)
            if abandoned || agents[leadID]!.activity != .waitingForInput {
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
    mutating func finishCompaction(_ id: AgentID, at now: Date, timedOut: Bool, beats: inout [Beat]) {
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

    // MARK: - 공통

    mutating func makeAgent(
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
        agents[id]!.lastHeardAt = now
        return id
    }

    mutating func update(_ id: AgentID, _ body: (inout Agent) -> Void) {
        guard var agent = agents[id] else { return }
        body(&agent)
        agents[id] = agent
    }

    mutating func removeAgent(_ id: AgentID) {
        guard let agent = agents.removeValue(forKey: id) else { return }
        if let subagentID = agent.subagentID {
            memberBySubagent[Self.subagentKey(agent.session, subagentID)] = nil
        }
        if let toolUseID = agent.delegationToolUseID {
            memberByDelegation[toolUseID] = nil
        }
    }

    mutating func rememberFinished(_ id: String?) {
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

    var isWaitingForPermission: Bool {
        if case .waitingForPermission = activity { return true }
        return false
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
