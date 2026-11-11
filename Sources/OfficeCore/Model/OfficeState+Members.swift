import Foundation

/// 서브에이전트: 위임과 짝짓기, 만들기, 끝내기
extension OfficeState {
    // MARK: - 서브에이전트

    mutating func resolveActor(for event: OfficeEvent, leadID: AgentID, beats: inout [Beat]) -> AgentID {
        guard let ref = event.subagent else { return leadID }
        let (memberID, created) = bindOrCreateMember(ref, session: event.session, leadID: leadID, term: event.term, at: event.at, beats: &beats)
        if created { beats.append(.memberAppeared(agents[memberID]!)) }
        return memberID
    }

    /// agent_id로 서브에이전트를 찾고, 없으면 아직 agent_id가 없는 위임 서브에이전트에 묶고, 그래도 없으면 새로 만듭니다.
    mutating func bindOrCreateMember(
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
    func pendingMember(for ref: SubagentRef, in session: SessionID) -> AgentID? {
        guard let type = ref.type, !type.isEmpty else { return nil }
        return agents.values
            .filter { $0.session == session && $0.role == .member && $0.subagentID == nil && $0.profile.agentType == type }
            .min { $0.serial < $1.serial }?
            .id
    }

    mutating func createMember(
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

    mutating func finishMember(_ memberID: AgentID, at now: Date, beats: inout [Beat]) {
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
}
