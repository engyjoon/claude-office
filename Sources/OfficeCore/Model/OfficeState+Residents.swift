import Foundation

/// 데스크톱 앱에 열려 있는 세션을 사무실에 맞추기 (M5(5), 설계서 §5.2)
extension OfficeState {
    // MARK: - 데스크톱 앱에 열려 있는 세션 (M5(5))

    /// 데스크톱 앱 세션 정보를 사무실에 맞춥니다 (앱이 몇 초마다 부름).
    ///
    /// - 열려 있지만 사무실에 없는 세션은 "쉬는 중"으로 조용히 앉힙니다(`settled`). 부모가 사무실에 있으면 그 행의 서브.
    /// - 이미 있는 세션은 제목·데스크톱 id·부모만 맞춥니다. 같은 데스크톱 세션이 CLI 세션 id만 바뀌었으면 같은 사람으로 이어 갑니다.
    ///   옛 id와 새 id가 둘 다 앉아 있으면 옛 id 쪽을 정리합니다 (`priorSessions`, 2026-11-19 work-stats 행이 둘로 보인 증상).
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
            // 같은 데스크톱 세션이 전에 쓰던 CLI 세션 id로 앉아 있는 사람은 같은 사람입니다: 새 id가 아직 없으면 이어 가고,
            // 새 id가 이미 다른 사람으로 와 있으면(새 id의 훅이 정보 파일보다 먼저 옴) 옛 사람을 정리하고 그 행을 합칩니다.
            for prior in resident.priorSessions where prior != resident.session && parts[prior]?.hostSession == resident.hostSession {
                if parts[resident.session] == nil {
                    rekey(prior, to: resident.session)
                } else {
                    retire(prior, into: resident.session, beats: &beats)
                }
            }
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
            if resident.isResponding(at: now), let edge = resident.lastTurnEdge, let activity = resident.lastActivity {
                // 응답 중에 앱을 켰음: "생각 중"으로 앉히고, 이때의 응답 경계는 끝이 아니라 시작입니다.
                // 다음 훅(도구·Stop)이 실제 상태로 바꾸고, 훅이 끝내 없으면 마지막 활동부터 `silenceLimit` 뒤에 쉬는 상태로 풉니다.
                let started = min(edge, now)
                update(id) {
                    $0.setActivity(.thinking, at: started)
                    $0.lastHeardAt = min(activity, now)
                }
                parts[resident.session]?.lastPromptAt = started
                parts[resident.session]?.completedAt = nil
                parts[resident.session]?.replyRequested = false
            } else {
                update(id) { $0.setActivity(.idle, at: min(resident.lastActivity ?? now, now)) }
                // 사무실에 오기 전에 끝난 응답도 확인 안 함·답변 필요를 보여 주도록 응답 끝을 데스크톱 기록에서 가져옵니다
                parts[resident.session]?.completedAt = resident.lastTurnEdge.map { min($0, now) }
                parts[resident.session]?.replyRequested = resident.replyRequest ?? false
            }
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
    mutating func observe(_ resident: ResidentSession, at now: Date) {
        guard var part = parts[resident.session] else { return }
        let seen = [part.seenAt, resident.lastFocused.map { min($0, now) }, resident.isFocused ? now : nil].compactMap { $0 }.max()
        part.seenAt = seen
        // 응답 요약은 끝난 응답에 대한 것만 따릅니다 (응답 중이면 지난 응답의 요약일 수 있음)
        if let verdict = resident.replyRequest, part.completedAt != nil, !isResponding(resident.session) {
            part.replyRequested = verdict
        }
        parts[resident.session] = part
    }
}
