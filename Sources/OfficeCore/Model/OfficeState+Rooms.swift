import Foundation

/// 행(방)과 책상 배정: 세션 직원 세우기, 행 열기·합치기, 책상 당기기, 세션 끝
extension OfficeState {
    // MARK: - 행과 세션 직원

    mutating func ensureLead(for event: OfficeEvent, beats: inout [Beat]) -> AgentID {
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
    mutating func summonRoot(for event: OfficeEvent, beats: inout [Beat]) {
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
    mutating func continueHostSession(for event: OfficeEvent) {
        guard parts[event.session] == nil, let hint = event.hint, let host = hint.hostSession, hint.hostCliSession == event.session,
            let old = parts.values.filter({ $0.hostSession == host && agents[$0.lead] != nil }).min(by: { $0.order < $1.order })
        else { return }
        rekey(old.session, to: event.session)
    }

    /// 세션 id만 바꿉니다 (사람·자리·행·직함은 그대로).
    mutating func rekey(_ old: SessionID, to new: SessionID) {
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

    mutating func openTeam(folder: String, beats: inout [Beat]) -> TeamID {
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
    func nextDesk(in team: TeamID) -> Int {
        (agents.values.filter { $0.teamID == team }.map(\.seat.desk).max() ?? -1) + 1
    }

    /// 이미 있는 세션에 늦게 온 힌트 (데스크톱 정보 파일이 나중에 생긴 경우, 제목이 바뀐 경우)
    mutating func absorb(_ hint: SessionHint, for session: SessionID, beats: inout [Beat]) {
        guard var part = parts[session] else { return }
        if let title = hint.title { part.title = title }
        if let host = hint.hostSession { part.hostSession = host }
        let ancestorsChanged = !hint.ancestors.isEmpty && hint.ancestors != part.ancestors
        if ancestorsChanged { part.ancestors = hint.ancestors }
        parts[session] = part
        if ancestorsChanged { reconcileTeams(beats: &beats) }
    }

    /// 메인이 다른 행 사람의 후손이면 그 행에 합칩니다 (부모가 늦게 나타났거나 정보 파일이 늦게 생김).
    mutating func reconcileTeams(beats: inout [Beat]) {
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
    mutating func merge(_ source: TeamID, into target: TeamID, beats: inout [Beat]) {
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
    mutating func relabel(
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
    mutating func compactDesks(in team: TeamID) -> Set<AgentID> {
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

    mutating func endSession(_ session: SessionID, beats: inout [Beat]) {
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
}
