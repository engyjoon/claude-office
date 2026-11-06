import Foundation

/// 리듀서가 내보내는 "무슨 일이 일어났는지". 연출 엔진(Choreographer)이 이것을 화면 지시로 바꿉니다.
/// 각 비트에는 그 순간의 `Agent` 스냅숏이 들어 있어서, 퇴근한 직원도 마지막 연출을 할 수 있습니다.
public enum Beat: Hashable, Sendable {
    case teamOpened(Team)
    case arrived(Agent)
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
    case reported(member: Agent, to: Agent?)
    case left(Agent)
}

/// 사무실의 의미 상태 (누가 어느 팀에서 무엇을 하는지). 순수 값 타입이며 시간은 이벤트에서만 받습니다.
public struct OfficeState: Sendable {
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var agents: [AgentID: Agent] = [:]

    private var leadBySession: [SessionID: AgentID] = [:]
    private var memberBySubagent: [String: AgentID] = [:]
    private var memberByDelegation: [String: AgentID] = [:]
    private var serial = 0

    public init() {}

    // MARK: - 조회

    public func lead(of session: SessionID) -> Agent? {
        leadBySession[session].flatMap { agents[$0] }
    }

    public func agents(in team: TeamID) -> [Agent] {
        agents.values.filter { $0.teamID == team }.sorted { $0.serial < $1.serial }
    }

    public var sortedTeams: [Team] {
        teams.values.sorted { $0.island < $1.island }
    }

    public func member(subagentID: String, in session: SessionID) -> Agent? {
        memberBySubagent[Self.subagentKey(session, subagentID)].flatMap { agents[$0] }
    }

    // MARK: - 리듀서

    public mutating func apply(_ event: OfficeEvent) -> [Beat] {
        var beats: [Beat] = []

        if case .sessionEnded = event.kind {
            endSession(event.session, beats: &beats)
            return beats
        }

        let leadID = ensureLead(for: event, beats: &beats)
        let actorID = resolveActor(for: event, leadID: leadID, beats: &beats)
        let now = event.at

        switch event.kind {
        case .sessionStarted, .sessionEnded:
            break

        case .promptSubmitted:
            update(leadID) {
                $0.consecutiveErrors = 0
                $0.runningTools = []
                $0.setActivity(.thinking, at: now)
            }
            beats.append(.promptArrived(agents[leadID]!))

        case .toolStarted(let call):
            update(actorID) {
                $0.runningTools.append(call)
                $0.setActivity(.working(call), at: now)
            }
            beats.append(.working(agents[actorID]!, call))

        case .toolFinished(let call, let outcome):
            update(actorID) { agent in
                agent.removeRunning(call)
                switch outcome {
                case .failure: agent.consecutiveErrors += 1
                case .success: agent.consecutiveErrors = 0
                case .interrupted: break
                }
                if let last = agent.runningTools.last {
                    agent.setActivity(.working(last), at: now)
                } else if case .working = agent.activity {
                    agent.setActivity(.thinking, at: now)
                }
            }
            beats.append(.toolEnded(agents[actorID]!, call, outcome))

        case .delegationStarted(let call, let subagentType):
            let memberID = createMember(
                session: event.session, teamID: agents[leadID]!.teamID, agentType: subagentType,
                delegatedBy: actorID, task: call.subject, toolUseID: call.id, background: call.runsInBackground,
                term: event.term, at: now)
            update(actorID) { $0.setActivity(.delegating, at: now) }
            beats.append(.delegated(by: agents[actorID]!, member: agents[memberID]!))

        case .delegationFinished(let call, _):
            // SubagentStart로 agent_id가 묶인 경우와 백그라운드 실행은 SubagentStop을 기다립니다.
            // 구버전처럼 agent_id를 끝내 모르면 여기서 보고 처리합니다.
            if let id = call.id, let memberID = memberByDelegation[id], let member = agents[memberID],
                member.subagentID == nil, !member.runsInBackground
            {
                finishMember(memberID, at: now, beats: &beats)
            }

        case .subagentStarted(let ref):
            let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: now)
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

        case .turnEnded(let failed):
            update(leadID) {
                $0.runningTools = []
                $0.setActivity(.idle, at: now)
            }
            beats.append(.turnEnded(agents[leadID]!, failed: failed))

        case .compacting:
            update(leadID) { $0.setActivity(.compacting, at: now) }
            beats.append(.compacting(agents[leadID]!))
        }
        return beats
    }

    // MARK: - 팀장과 팀

    private mutating func ensureLead(for event: OfficeEvent, beats: inout [Beat]) -> AgentID {
        if let id = leadBySession[event.session], agents[id] != nil { return id }
        let teamID = ensureTeam(cwd: event.cwd, beats: &beats)
        let leadIndex = agents.values.filter { $0.teamID == teamID && $0.role == .lead }.count
        let profile = AgentProfile.lead(teamName: teams[teamID]!.name, index: leadIndex)
        let id = makeAgent(
            role: .lead, profile: profile, teamID: teamID, session: event.session,
            delegatedBy: nil, task: nil, toolUseID: nil, background: false, term: event.term, at: event.at)
        leadBySession[event.session] = id
        beats.append(.arrived(agents[id]!))
        return id
    }

    private mutating func ensureTeam(cwd: String?, beats: inout [Beat]) -> TeamID {
        let path = (cwd?.isEmpty == false ? cwd! : "(알 수 없는 프로젝트)")
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let id = TeamID(normalized)
        if teams[id] == nil {
            let island = teams.count
            let name = normalized.split(separator: "/").last.map(String.init) ?? normalized
            let team = Team(
                id: id, name: name, island: island, colorIndex: island % Team.colorCount,
                seatCount: Team.minimumSeats, reservedSeats: [:])
            teams[id] = team
            beats.append(.teamOpened(team))
        }
        return id
    }

    private mutating func endSession(_ session: SessionID, beats: inout [Beat]) {
        guard let leadID = leadBySession[session], let lead = agents[leadID] else { return }
        for member in agents.values.filter({ $0.session == session && $0.role == .member }).sorted(by: { $0.serial < $1.serial }) {
            beats.append(.left(member))
            removeAgent(member.id)
        }
        beats.append(.left(lead))
        removeAgent(leadID)
        leadBySession[session] = nil
    }

    // MARK: - 팀원

    private mutating func resolveActor(for event: OfficeEvent, leadID: AgentID, beats: inout [Beat]) -> AgentID {
        guard let ref = event.subagent else { return leadID }
        let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: event.at)
        if created { beats.append(.memberAppeared(agents[memberID]!)) }
        return memberID
    }

    /// agent_id로 팀원을 찾고, 없으면 아직 agent_id가 없는 위임 팀원에 묶고, 그래도 없으면 새로 만듭니다.
    private mutating func bindOrCreateMember(
        _ ref: SubagentRef, session: SessionID, leadID: AgentID, term: String?, at now: Date
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
        return (id, true)
    }

    /// 위임으로 만들어졌지만 아직 agent_id가 없는 팀원 중 종류가 맞는 가장 오래된 팀원
    private func pendingMember(for ref: SubagentRef, in session: SessionID) -> AgentID? {
        agents.values
            .filter { $0.session == session && $0.role == .member && $0.subagentID == nil }
            .filter { ref.type == nil || $0.profile.agentType == ref.type }
            .min { $0.serial < $1.serial }?
            .id
    }

    private mutating func createMember(
        session: SessionID, teamID: TeamID, agentType: String?, delegatedBy: AgentID?, task: String?,
        toolUseID: String?, background: Bool, term: String?, at now: Date
    ) -> AgentID {
        let duplicates = agents.values.filter { $0.teamID == teamID && $0.profile.agentType == agentType && $0.role == .member }.count
        let profile = AgentProfile.member(agentType: agentType, serial: serial + 1, duplicateIndex: duplicates)
        let id = makeAgent(
            role: .member, profile: profile, teamID: teamID, session: session, delegatedBy: delegatedBy,
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

        if let delegatorID = delegator?.id, agents[delegatorID]?.activity == .delegating,
            !agents.values.contains(where: { $0.delegatedBy == delegatorID })
        {
            update(delegatorID) { $0.setActivity(.thinking, at: now) }
        }
    }

    // MARK: - 공통

    private mutating func makeAgent(
        role: Role, profile: AgentProfile, teamID: TeamID, session: SessionID, delegatedBy: AgentID?,
        task: String?, toolUseID: String?, background: Bool, term: String?, at now: Date
    ) -> AgentID {
        serial += 1
        let id = AgentID(role == .lead ? "lead-\(serial)" : "member-\(serial)")
        let seat = assignSeat(teamID: teamID, profile: profile)
        agents[id] = Agent(
            id: id, role: role, profile: profile, teamID: teamID, session: session, seat: seat,
            subagentID: nil, delegatedBy: delegatedBy, task: task, delegationToolUseID: toolUseID,
            runsInBackground: background, activity: .arriving, activitySince: now, runningTools: [],
            consecutiveErrors: 0, term: term, serial: serial)
        return id
    }

    /// 좌석 규칙: 0번은 팀장석, 고정 직원은 지정석, 임시 직원은 지정석이 아닌 빈자리. 자리가 없으면 늘립니다.
    private mutating func assignSeat(teamID: TeamID, profile: AgentProfile) -> Int {
        guard var team = teams[teamID] else { return 0 }
        let occupied = Set(agents.values.filter { $0.teamID == teamID }.map(\.seat))
        let reserved = Set(team.reservedSeats.values)
        defer { teams[teamID] = team }

        func firstFree(excludingReserved: Bool) -> Int {
            var seat = 1
            while occupied.contains(seat) || (excludingReserved && reserved.contains(seat)) { seat += 1 }
            team.seatCount = max(team.seatCount, seat + 1)
            return seat
        }

        switch profile.kind {
        case .lead:
            return occupied.contains(0) ? firstFree(excludingReserved: true) : 0
        case .fixed:
            if let seat = team.reservedSeats[profile.key] {
                if !occupied.contains(seat) { return seat }
                return firstFree(excludingReserved: true)  // 같은 직원이 동시에 둘 → 두 번째는 빈자리로
            }
            let seat = firstFree(excludingReserved: true)
            team.reservedSeats[profile.key] = seat
            return seat
        case .temporary:
            return firstFree(excludingReserved: true)
        }
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

    static func subagentKey(_ session: SessionID, _ agentID: String) -> String {
        "\(session.raw)#\(agentID)"
    }
}

extension Agent {
    mutating func setActivity(_ activity: Activity, at now: Date) {
        self.activity = activity
        activitySince = now
    }

    mutating func removeRunning(_ call: ToolCall) {
        if let id = call.id, let index = runningTools.firstIndex(where: { $0.id == id }) {
            runningTools.remove(at: index)
        } else if let index = runningTools.firstIndex(where: { $0.name == call.name }) {
            runningTools.remove(at: index)
        }
    }
}
