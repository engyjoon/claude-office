import Foundation

/// 리듀서가 내보내는 "무슨 일이 일어났는지". 연출 엔진(Choreographer)이 이것을 화면 지시로 바꿉니다.
/// 각 비트에는 그 순간의 `Agent` 스냅숏이 들어 있어서, 퇴근한 직원도 마지막 연출을 할 수 있습니다.
public enum Beat: Hashable, Sendable {
    case teamOpened(Team)
    /// 사람이 모두 떠난 방. 섬은 다음 방이 다시 씁니다.
    case teamClosed(Team)
    case arrived(Agent)
    /// 파트장이 팀장이 됨 (팀장이 퇴근했거나, 늦게 온 메인 세션에게서 넘겨받음). 좌석도 팀장석으로 바뀝니다.
    case promoted(Agent)
    /// 직함·좌석이 바뀜 ("파트장" → "파트장1", 팀장 → 파트장)
    case retitled(Agent)
    /// 파트원의 자리가 바뀜 (파트장이 팀장으로 승진해 그 파트가 팀장 직속 파트(0번 칸)가 되는 경우 등)
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
    case reported(member: Agent, to: Agent?)
    case left(Agent)
}

/// 사무실의 의미 상태 (누가 어느 방·파트에서 무엇을 하는지). 순수 값 타입이며 시간은 이벤트에서만 받습니다.
///
/// 방 규칙 (설계서 §5.1):
/// - 방 = 메인 세션 단위. 방의 첫 세션(또는 데스크톱 앱이 알려 준 최상위 세션)이 팀장, 나머지 세션은 파트장.
/// - 힌트에 부모가 있으면 부모의 방, 없으면 최상위 세션 폴더(없으면 자기 폴더)의 방. 워크트리는 원래 폴더로 합칩니다.
/// - 팀장이 퇴근하면 가장 먼저 온 파트장이 팀장으로 승진합니다. 사람이 모두 떠난 방은 닫힙니다.
public struct OfficeState: Sendable {
    /// 방 (예전 이름 그대로 팀)
    public private(set) var teams: [TeamID: Team] = [:]
    public private(set) var agents: [AgentID: Agent] = [:]
    /// 세션 → 파트
    public private(set) var parts: [SessionID: Part] = [:]

    private var partOrder = 0
    private var memberBySubagent: [String: AgentID] = [:]
    private var memberByDelegation: [String: AgentID] = [:]
    private var serial = 0
    /// 최근에 끝난 tool_use_id. 훅 스크립트가 curl을 백그라운드로 보내므로 Post가 Pre보다 먼저 도착할 수 있습니다.
    private var finishedToolIDs: [String] = []
    private var finishedToolIDSet: Set<String> = []

    public init() {}

    // MARK: - 조회

    /// 세션 직원 (팀장 또는 파트장)
    public func lead(of session: SessionID) -> Agent? {
        parts[session].flatMap { agents[$0.lead] }
    }

    /// 방의 파트들. 팀장 파트(0번)가 먼저, 그다음 파트장 번호 순서.
    public func parts(in team: TeamID) -> [Part] {
        parts.values.filter { $0.teamID == team }.sorted { ($0.number, $0.order) < ($1.number, $1.order) }
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
            if let id = call.id, finishedToolIDSet.contains(id) { break }  // 이미 끝난 툴의 늦은 시작
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
                if let last = agent.runningTools.last {
                    agent.setActivity(.working(last), at: now)
                } else if case .working = agent.activity {
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
            update(actorID) { $0.setActivity(.delegating, at: now) }
            beats.append(.delegated(by: agents[actorID]!, member: agents[memberID]!))

        case .delegationFinished(let call, _):
            rememberFinished(call.id)
            // SubagentStart를 받은 팀원과 백그라운드 실행은 SubagentStop을 기다립니다.
            // 시작·종료 신호를 보내지 않는 서브에이전트(web-fetch 등)와 구버전은 여기서 보고 처리합니다.
            if let id = call.id, let memberID = memberByDelegation[id], let member = agents[memberID],
                !member.announcedByHook, !member.runsInBackground
            {
                finishMember(memberID, at: now, beats: &beats)
            }

        case .subagentStarted(let ref):
            // 종류가 빈 서브에이전트는 Claude Code 내부 작업입니다 (M0: 신호 하나만 오고 툴 이벤트가 없음)
            guard let type = ref.type, !type.isEmpty else { break }
            let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: now)
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

        case .turnEnded(let failed):
            // 안전장치: 팀장 응답이 끝났는데 남은 (백그라운드가 아닌) 팀원은 이때 보고하고 퇴근합니다
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
            beats.append(.turnEnded(agents[leadID]!, failed: failed))

        case .compacting:
            update(leadID) { $0.setActivity(.compacting, at: now) }
            beats.append(.compacting(agents[leadID]!))
        }
        return beats
    }

    // MARK: - 방과 세션 직원

    private mutating func ensureLead(for event: OfficeEvent, beats: inout [Beat]) -> AgentID {
        if let part = parts[event.session], agents[part.lead] != nil {
            if let hint = event.hint { absorb(hint, for: event.session, beats: &beats) }
            return part.lead
        }
        let teamID = room(for: event, beats: &beats)
        let ancestors = event.hint?.ancestors ?? []

        // 방의 지금 팀장이 이 세션이 띄운 세션이면 (메인 세션이 늦게 나타남) 팀장 자리를 넘겨받습니다
        var number = 0
        var demoted: AgentID?
        var moved: [AgentID] = []
        if let current = leadPart(in: teamID) {
            if current.ancestors.contains(event.session) {
                moved = demote(current.session)
                demoted = current.lead
            } else {
                number = freePartNumber(in: teamID)
            }
        }

        let roomName = teams[teamID]!.name
        var profile = AgentProfile.lead(roomName: roomName, number: number)
        if agents.values.contains(where: { $0.profile.key == profile.key }) {
            // 같은 얼굴이 둘 생기지 않도록 출근 순번으로 바꿉니다 (승진한 사람은 얼굴이 그대로라서)
            let key = "part@\(roomName)#o\(partOrder + 1)"
            profile = AgentProfile(key: key, displayName: profile.displayName, kind: .lead, agentType: nil, appearance: .make(key: key, kind: .lead))
        }
        let partLeads = parts.values.filter { $0.teamID == teamID && $0.number > 0 }.count + (number > 0 ? 1 : 0)
        let id = makeAgent(
            role: .lead, profile: profile, teamID: teamID, session: event.session, part: number,
            title: .lead(number: number, partLeadCount: partLeads),
            delegatedBy: nil, task: nil, toolUseID: nil, background: false, term: event.term, at: event.at)
        partOrder += 1
        parts[event.session] = Part(
            session: event.session, teamID: teamID, number: number, order: partOrder, lead: id,
            ancestors: ancestors, title: event.hint?.title)
        relabel(teamID, force: demoted.map { [$0] } ?? [], beats: &beats)
        reseated(moved, beats: &beats)
        beats.append(.arrived(agents[id]!))
        return id
    }

    /// 새 세션이 들어갈 방: 힌트의 조상이 있는 방 → 최상위 세션 폴더의 방 → 자기 폴더의 방
    private mutating func room(for event: OfficeEvent, beats: inout [Beat]) -> TeamID {
        if let hint = event.hint {
            for ancestor in hint.ancestors {
                if let part = parts[ancestor], teams[part.teamID] != nil { return part.teamID }
            }
            if let root = hint.rootCwd, !root.isEmpty { return ensureTeam(cwd: root, beats: &beats) }
        }
        return ensureTeam(cwd: event.cwd, beats: &beats)
    }

    private mutating func ensureTeam(cwd: String?, beats: inout [Beat]) -> TeamID {
        let normalized = Team.folder(for: cwd)
        let id = TeamID(normalized)
        if teams[id] == nil {
            // 닫힌 방의 섬을 다시 씁니다
            let used = Set(teams.values.map(\.island))
            var island = 0
            while used.contains(island) { island += 1 }
            let name = normalized.split(separator: "/").last.map(String.init) ?? normalized
            let team = Team(id: id, name: name, island: island, colorIndex: island % Team.colorCount, reservedSeats: [:])
            teams[id] = team
            beats.append(.teamOpened(team))
        }
        return id
    }

    private func leadPart(in team: TeamID) -> Part? {
        parts.values.first { $0.teamID == team && $0.number == 0 }
    }

    /// 비어 있는 가장 작은 파트장 번호 (1부터)
    private func freePartNumber(in team: TeamID) -> Int {
        let used = Set(parts.values.filter { $0.teamID == team }.map(\.number))
        var number = 1
        while used.contains(number) { number += 1 }
        return number
    }

    /// 이미 있는 세션에 늦게 온 힌트 (데스크톱 정보 파일이 나중에 생긴 경우, 제목이 바뀐 경우)
    private mutating func absorb(_ hint: SessionHint, for session: SessionID, beats: inout [Beat]) {
        guard var part = parts[session] else { return }
        if let title = hint.title { part.title = title }
        let ancestorsChanged = !hint.ancestors.isEmpty && hint.ancestors != part.ancestors
        if ancestorsChanged { part.ancestors = hint.ancestors }
        parts[session] = part
        if ancestorsChanged { reconcileLead(in: part.teamID, beats: &beats) }
    }

    /// 팀장이 같은 방에 있는 다른 세션이 띄운 세션이면, 가장 위 조상에게 팀장 자리를 넘깁니다.
    private mutating func reconcileLead(in team: TeamID, beats: inout [Beat]) {
        guard let current = leadPart(in: team) else { return }
        var candidate = current
        for _ in 0..<8 {
            guard let top = candidate.ancestors.last(where: { parts[$0]?.teamID == team }), top != candidate.session else { break }
            candidate = parts[top]!
        }
        guard candidate.session != current.session else { return }
        let number = candidate.number
        // 자리를 맞바꿉니다: 파트 칸도 번호를 따라가므로 두 파트의 파트원도 서로의 칸으로 옮깁니다
        let moved = setPartNumber(candidate.session, 0) + setPartNumber(current.session, number)
        relabel(team, promoted: candidate.lead, force: [current.lead, candidate.lead], beats: &beats)
        reseated(moved, beats: &beats)
    }

    /// 팀장을 파트장으로 내립니다 (늦게 온 메인 세션에게 자리를 넘길 때). 직함 비트는 호출한 쪽이 relabel로 냅니다.
    /// 돌려주는 값은 자리가 바뀐 파트원입니다.
    private mutating func demote(_ session: SessionID) -> [AgentID] {
        guard let part = parts[session] else { return [] }
        return setPartNumber(session, freePartNumber(in: part.teamID))
    }

    /// 파트 번호를 바꿉니다. 파트 칸은 파트 번호와 같은 번호이므로 세션 직원의 자리도 따라갑니다:
    /// 세션 직원은 팀장실(0번) 또는 새 칸의 ★ 자리, 파트원은 새 칸의 같은 번호 책상.
    /// 돌려주는 값은 자리가 바뀐 파트원입니다 (세션 직원은 직함 비트로 알립니다).
    @discardableResult
    private mutating func setPartNumber(_ session: SessionID, _ number: Int) -> [AgentID] {
        guard let old = parts[session] else { return [] }
        parts[session]!.number = number
        var moved: [AgentID] = []
        for agent in agents.values.filter({ $0.session == session }).sorted(by: { $0.serial < $1.serial }) {
            let seat: Seat
            if agent.role == .lead {
                seat = number == 0 ? .office : Seat(part: number, desk: 0)
            } else {
                seat = Seat(part: number, desk: agent.seat.desk)
                if seat != agent.seat { moved.append(agent.id) }
                // 고정 직원의 지정석도 새 칸으로 옮깁니다
                if teams[old.teamID]?.reservedSeats[agent.profile.key] == agent.seat {
                    teams[old.teamID]?.reservedSeats[agent.profile.key] = seat
                }
            }
            update(agent.id) {
                $0.part = number
                $0.seat = seat
            }
        }
        return moved
    }

    private mutating func reseated(_ members: [AgentID], beats: inout [Beat]) {
        for id in members {
            if let agent = agents[id] { beats.append(.reseated(agent)) }
        }
    }

    /// 방의 세션 직원 직함을 다시 정하고, 바뀐 사람마다 비트를 냅니다.
    private mutating func relabel(_ team: TeamID, promoted: AgentID? = nil, force: Set<AgentID> = [], beats: inout [Beat]) {
        let roomParts = parts.values.filter { $0.teamID == team }.sorted { $0.order < $1.order }
        let partLeads = roomParts.filter { $0.number > 0 }.count
        for part in roomParts {
            guard let agent = agents[part.lead] else { continue }
            let title = JobTitle.lead(number: part.number, partLeadCount: partLeads)
            guard agent.title != title || force.contains(agent.id) else { continue }
            update(part.lead) { $0.title = title }
            beats.append(part.lead == promoted ? .promoted(agents[part.lead]!) : .retitled(agents[part.lead]!))
        }
    }

    private mutating func endSession(_ session: SessionID, beats: inout [Beat]) {
        guard let part = parts[session] else { return }
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
        var moved: [AgentID] = []
        if part.number == 0, let next = parts.values.filter({ $0.teamID == team }).min(by: { $0.order < $1.order }) {
            // 가장 먼저 온 파트장이 팀장실로, 그 파트원은 팀장 직속 파트(0번 칸)로
            moved = setPartNumber(next.session, 0)
            promoted = next.lead
        }
        relabel(team, promoted: promoted, force: promoted.map { [$0] } ?? [], beats: &beats)
        reseated(moved, beats: &beats)

        if !agents.values.contains(where: { $0.teamID == team }), let closed = teams.removeValue(forKey: team) {
            beats.append(.teamClosed(closed))
        }
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
    ///
    /// 실제 수집(M0)에서 종류가 빈 SubagentStop이 많았습니다 (Claude Code 내부 작업, 다른 이벤트 없음).
    /// 엉뚱한 팀원과 짝짓지 않도록 종류가 정확히 같을 때만 묶고, 종류를 모르면 묶지 않습니다.
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
            role: .member, profile: profile, teamID: teamID, session: session, part: parts[session]?.number ?? 0,
            title: .member, delegatedBy: delegatedBy,
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
        role: Role, profile: AgentProfile, teamID: TeamID, session: SessionID, part: Int, title: JobTitle,
        delegatedBy: AgentID?, task: String?, toolUseID: String?, background: Bool, term: String?, at now: Date
    ) -> AgentID {
        serial += 1
        let id = AgentID(role == .lead ? "lead-\(serial)" : "member-\(serial)")
        let seat = assignSeat(teamID: teamID, profile: profile, part: part, isLead: role == .lead)
        agents[id] = Agent(
            id: id, role: role, profile: profile, teamID: teamID, session: session, part: part, title: title, seat: seat,
            subagentID: nil, delegatedBy: delegatedBy, task: task, delegationToolUseID: toolUseID,
            runsInBackground: background, activity: .arriving, activitySince: now, runningTools: [],
            consecutiveErrors: 0, term: term, serial: serial)
        return id
    }

    /// 자리 규칙 (설계서 §8.1): 팀장은 팀장실, 파트장은 자기 칸의 ★ 자리(0번 책상), 파트원은 자기 파트 칸의 1번 책상부터.
    /// 고정 직원은 지정석, 임시 직원은 지정석이 아닌 빈자리. 책상이 모자라면 칸 앞에 서는 자리(4번~)를 받습니다.
    private mutating func assignSeat(teamID: TeamID, profile: AgentProfile, part: Int, isLead: Bool) -> Seat {
        if isLead { return part == 0 ? .office : Seat(part: part, desk: 0) }
        guard var team = teams[teamID] else { return Seat(part: part, desk: 1) }
        let occupied = Set(agents.values.filter { $0.teamID == teamID }.map(\.seat))
        let reserved = Set(team.reservedSeats.values)
        defer { teams[teamID] = team }

        func firstFree() -> Seat {
            var desk = 1
            while occupied.contains(Seat(part: part, desk: desk)) || reserved.contains(Seat(part: part, desk: desk)) { desk += 1 }
            return Seat(part: part, desk: desk)
        }

        if profile.kind == .fixed {
            if let seat = team.reservedSeats[profile.key], seat.part == part {
                // 같은 직원이 동시에 둘 → 두 번째는 빈자리로
                return occupied.contains(seat) ? firstFree() : seat
            }
            let seat = firstFree()
            team.reservedSeats[profile.key] = seat
            return seat
        }
        return firstFree()
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
