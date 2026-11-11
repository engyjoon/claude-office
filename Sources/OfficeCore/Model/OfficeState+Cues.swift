import Foundation

/// 머리 위 배지 판정: 답변 필요·확인 안 함 (M6(4), 설계서 §6.11)
extension OfficeState {
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
    mutating func refreshCues(beats: inout [Beat]) {
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
}
