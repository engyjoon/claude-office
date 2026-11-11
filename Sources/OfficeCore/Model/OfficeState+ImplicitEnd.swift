import Foundation

/// 끝 이벤트 없이 끝난 턴·도구·서브·세션을 닫는 규칙 (개선 4, 설계서 §5.3)
extension OfficeState {
    // MARK: - 암묵적 종료 (끝 이벤트 없는 턴·도구·서브·세션, 개선 4)

    /// 같은 묶음(한 응답이 한꺼번에 부른 병렬 도구)의 PreToolUse는 이 시간 안에 이어서 옵니다.
    /// 이보다 늦게 온 PreToolUse는 다음 응답의 도구라, 그때까지 끝 신호 없이 남은 도구는 버립니다.
    public static let toolBatchWindow: TimeInterval = 2
    /// 요청을 받고 이 시간 안에 온 `idle_prompt`는 지난 턴의 알림이 늦게 도착한 것으로 봅니다.
    public static let staleIdlePromptWindow: TimeInterval = 3
    /// 끝난 세션을 기억하는 시간과 수 (SessionEnd 뒤 늦게 온 훅을 버림)
    public static let endedSessionMemory: TimeInterval = 30
    public static let endedSessionCapacity = 64
    /// "출근 중"으로 보여 주는 시간. 지나면 세션은 쉬는 중, 서브는 생각 중으로 넘어갑니다.
    public static let arrivalGrace: TimeInterval = 10
    /// 이만큼 훅이 하나도 없으면 끝 이벤트를 놓친 것으로 봅니다: 바쁜 세션은 턴이 끝난 것으로, 서브는 퇴근한 것으로.
    /// 승인·질문 답을 기다리는 세션은 사용자를 기다리는 것이라 건드리지 않습니다. 세션은 퇴근시키지 않습니다 (설계서 §5.2).
    public static let silenceLimit: TimeInterval = 60 * 60

    /// Stop 없이 끝난 턴을 닫습니다: 쉬지 않는 세션 직원이면 남은 도구를 비우고, 포그라운드 서브를 퇴근시키고, 쉬는 상태로 돌립니다.
    /// 사용자가 직접 멈춘 턴으로 보아 "확인 안 함"·"답변 필요"는 붙이지 않습니다. 이미 쉬고 있으면 아무것도 하지 않습니다.
    /// 정리 중이면 끝 신호를 놓친 압축부터 풉니다: 쉬던 중의 압축이었으면 쉬던 상태(배지·쉼 단계 그대로)로 돌아가는 것으로 끝이고,
    /// 응답 중의 압축이었으면 하던 일로 되돌린 뒤 그 턴을 닫습니다.
    @discardableResult
    mutating func abandonTurn(_ session: SessionID, restingAs rest: Activity, at now: Date, beats: inout [Beat]) -> Bool {
        guard let part = parts[session] else { return false }
        finishCompaction(part.lead, at: now, timedOut: false, beats: &beats)
        guard let lead = agents[part.lead], !lead.isResting else { return false }
        let leftovers = agents.values
            .filter { $0.session == session && $0.role == .member && !$0.runsInBackground }
            .sorted { $0.serial < $1.serial }
        for member in leftovers {
            dismissMember(member.id, beats: &beats)
        }
        update(part.lead) {
            $0.runningTools = []
            $0.setActivity(rest, at: now)
        }
        parts[session]?.completedAt = now
        parts[session]?.seenAt = max(part.seenAt ?? .distantPast, now)
        parts[session]?.replyRequested = false
        beats.append(.turnAbandoned(agents[part.lead]!))
        return true
    }

    /// 보고 없이 퇴근시킵니다 (닫힌 턴에 남은 서브, 아주 오래 조용한 서브).
    mutating func dismissMember(_ memberID: AgentID, beats: inout [Beat]) {
        guard let member = agents[memberID] else { return }
        beats.append(.left(member))
        removeAgent(memberID)
        relabel(reseated: compactDesks(in: member.teamID), beats: &beats)
    }

    /// 도구(위임 포함)를 시작하기 전에: 앞 PreToolUse로부터 `toolBatchWindow`가 지났으면 새 묶음이라 남은 도구를 버립니다.
    /// 같은 묶음의 병렬 도구는 이어서 오므로 남습니다. 서브에이전트(백그라운드 포함)는 도구 목록에 없어 영향이 없습니다.
    mutating func beginTool(_ id: AgentID, at now: Date) {
        update(id) {
            if let last = $0.lastToolStartAt, now.timeIntervalSince(last) >= Self.toolBatchWindow {
                $0.runningTools = []
            }
            $0.lastToolStartAt = now
        }
    }

    /// 기억하고 있는 끝난 세션 수 (테스트용)
    var endedSessionCount: Int { endedSessions.count }

    mutating func rememberEnded(_ session: SessionID, at now: Date) {
        if endedSessions.updateValue(now, forKey: session) != nil {
            endedSessionOrder.removeAll { $0 == session }
        }
        endedSessionOrder.append(session)
        while endedSessionOrder.count > Self.endedSessionCapacity {
            endedSessions[endedSessionOrder.removeFirst()] = nil
        }
    }

    /// 방금 끝난 세션의 늦게 온 훅인지. 다시 시작한 것(SessionStart·새 요청)이면 기억을 지우고 받아들입니다.
    /// 데스크톱 목록에서 다시 앉힌 세션(`syncResidents`)처럼 이미 사무실에 있으면 따지지 않습니다.
    mutating func isLateAfterEnd(_ event: OfficeEvent) -> Bool {
        guard let ended = endedSessions[event.session] else { return false }
        var restarted = event.at.timeIntervalSince(ended) >= Self.endedSessionMemory || parts[event.session] != nil
        switch event.kind {
        case .sessionStarted, .promptSubmitted: restarted = true
        default: break
        }
        guard restarted else { return true }
        endedSessions[event.session] = nil
        endedSessionOrder.removeAll { $0 == event.session }
        return false
    }

    /// `arrivalGrace`가 지난 "출근 중"을 쉬는 중(세션)·생각 중(서브)으로 넘깁니다 (앱이 화면 주기마다 부름).
    /// 연출은 출근할 때 이미 그 모습이라 비트는 없고, 쉰 시간은 출근한 때부터 셉니다. 넘긴 사람이 있으면 true.
    @discardableResult
    public mutating func settleArrivals(at now: Date, after grace: TimeInterval = arrivalGrace) -> Bool {
        var settled = false
        for (id, agent) in agents where agent.activity == .arriving && now.timeIntervalSince(agent.activitySince) >= grace {
            agents[id]!.activity = agent.role == .lead ? .idle : .thinking
            settled = true
        }
        return settled
    }

    /// `silenceLimit` 동안 훅이 없는 바쁜 세션의 턴을 닫고, 그만큼 조용한 서브를 퇴근시킵니다 (앱이 화면 주기마다 부름).
    /// 누군가 승인·질문 답을 기다리는 세션과 정리 중인 세션(따로 시간 제한이 있음)은 그대로 둡니다.
    public mutating func expireSilence(at now: Date, after limit: TimeInterval = silenceLimit) -> [Beat] {
        var beats: [Beat] = []
        // 화면 주기마다 불리므로 조용한 사람이 없으면 바로 돌아갑니다
        guard agents.values.contains(where: {
            now.timeIntervalSince($0.lastHeardAt) >= limit && ($0.role == .member || !$0.isResting)
        }) else { return beats }
        for part in parts.values.sorted(by: { $0.order < $1.order }) {
            guard let lead = agents[part.lead] else { continue }
            let people = agents.values.filter { $0.session == part.session }
            if people.contains(where: \.isWaitingForPermission) { continue }
            if lead.activity != .compacting, now.timeIntervalSince(lead.lastHeardAt) >= limit {
                abandonTurn(part.session, restingAs: .idle, at: now, beats: &beats)
            }
            let silent = agents.values
                .filter { $0.session == part.session && $0.role == .member && now.timeIntervalSince($0.lastHeardAt) >= limit }
                .sorted { $0.serial < $1.serial }
            for member in silent {
                dismissMember(member.id, beats: &beats)
                if let delegator = member.delegatedBy, agents[delegator]?.activity == .delegating,
                    !agents.values.contains(where: { $0.delegatedBy == delegator })
                {
                    update(delegator) { $0.setActivity(.thinking, at: now) }
                }
            }
        }
        if !beats.isEmpty { refreshCues(beats: &beats) }
        return beats
    }
}
