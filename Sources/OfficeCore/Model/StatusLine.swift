import Foundation

/// 사무실 아래 세 줄짜리 실시간 현황 (설계서 §10.2, M5(9)). 신원 카드가 "누구"라면 이 줄은 "무엇을 하고 있는지"입니다.
///
/// - 아무도 안 골랐으면 **사무실에 보이는 행과 같은 순서로 행마다 한 줄**: 행 색 점, 디렉토리, 메인 직함, 그 행(메인 + 서브)의
///   가장 최근 일 하나와 상대 시간 ("● claude-office · 메인1 · 서브2가 Edit StaffPanel.swift (방금)").
///   진행 중이면 경과 시간("12초째"), 조용한 행은 "쉬는 중"(10분이 지나면 "잠든 중"). 승인 대기가 있으면 그 행의 줄은 승인 대기.
///   화면에 못 보여 준 행(+N)에서 승인 대기가 생기면 빈 줄(없으면 셋째 줄)을 "화면 밖" 알림으로 씁니다.
/// - 캐릭터를 골랐으면 그 사람의 최근 일 세 개를 한 줄에 하나씩 (최신이 아래). 첫 줄 맨 앞에 "디렉토리 · 직함".
///   같은 도구가 이어지면 묶습니다 ("Read 3개").
/// - 표시 수준이 상세가 아니면 파일명·명령을 숨기고 도구 종류만 씁니다. 에이전트 종류는 쓰지 않고 직함만 씁니다.
/// - 디렉토리 드롭다운이 "모두"면 디렉토리 이름을 붙이고, 하나를 골랐으면 바로 위 드롭다운에 보이므로 생략합니다 (M5(7a)).
/// 경과·상대 시간은 화면이 그릴 때 붙입니다 (이 값은 시간에 따라 바뀌지 않음).
public struct StatusLine: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// 고른 사람의 최근 일 (최신이 아래)
        case agent
        /// 행마다 한 줄 (사무실의 행 순서)
        case office
    }

    public enum Tone: Hashable, Sendable {
        case normal
        /// 안내 문구, 쉬는 중
        case muted
        /// 승인 대기 (노랑)
        case attention
        /// 답변 필요 (파랑, M6(4))
        case reply
        /// 오류·거부 (빨강)
        case error
    }

    /// 한 줄의 내용 (일 하나)
    public struct Segment: Hashable, Sendable {
        public var text: String
        public var tone: Tone
        /// 진행 중이면 시작 시각. 화면이 "(12초째)"를 붙입니다.
        public var since: Date?
        /// 끝난 일이면 그 일을 한 때. 화면이 "(3초 전)"을 붙입니다.
        public var at: Date?
        /// 쉬는 중이면 쉬기 시작한 때. `napAfter`가 지나면 "잠든 중"으로 그립니다.
        public var restingSince: Date?

        public init(text: String, tone: Tone = .normal, since: Date? = nil, at: Date? = nil, restingSince: Date? = nil) {
            self.text = text
            self.tone = tone
            self.since = since
            self.at = at
            self.restingSince = restingSince
        }

        /// 시간을 뺀 본문 ("쉬는 중"은 오래되면 "잠든 중")
        public func body(now: Date) -> String {
            if let restingSince, now.timeIntervalSince(restingSince) >= StatusLine.napAfter { return "잠든 중" }
            return text
        }

        /// 괄호 안 시간: 진행 중이면 "12초째"(1초 미만은 없음), 끝났으면 "방금"·"3초 전"
        public func time(now: Date) -> String? {
            if let since { return StatusLine.elapsed(now.timeIntervalSince(since)) }
            return at.map { AgentTimeline.ago(now.timeIntervalSince($0)) }
        }

        public func text(now: Date) -> String {
            time(now: now).map { "\(body(now: now)) (\($0))" } ?? body(now: now)
        }
    }

    /// 화면의 한 줄
    public struct Line: Hashable, Sendable {
        /// 행 색 (화면의 점, 퇴근했거나 안내 줄이면 nil)
        public var colorIndex: Int?
        /// 디렉토리 이름 ("모두"일 때만, 길면 줄인 것)
        public var folder: String?
        /// 직함 (행 줄은 메인, 고른 사람 줄은 그 사람. 고른 사람의 둘째·셋째 줄과 안내 줄은 nil)
        public var head: String?
        public var segment: Segment
        /// 화면에 못 보여 준 행의 알림 (승인 대기)
        public var offscreen: Bool
        /// 알림 줄: 같은 처지의 다른 행 수 ("외 2행")
        public var more: Int

        public init(colorIndex: Int? = nil, folder: String? = nil, head: String? = nil, segment: Segment, offscreen: Bool = false, more: Int = 0) {
            self.colorIndex = colorIndex
            self.folder = folder
            self.head = head
            self.segment = segment
            self.offscreen = offscreen
            self.more = more
        }

        /// 머리 ("claude-office · 메인1", 없으면 nil)
        public var heading: String? {
            let parts = [folder, head].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// 알림 줄 맨 앞 표시 ("화면 밖", "화면 밖 외 2행")
        public var note: String? {
            guard offscreen else { return nil }
            return more > 0 ? "화면 밖 외 \(more)행" : "화면 밖"
        }

        /// 화면에 그릴 글자 그대로 (테스트·도움말): "[화면 밖] claude-office · 메인1 · 서브2가 Edit auth.ts (방금)"
        public func text(now: Date) -> String {
            let body = [heading, segment.text(now: now)].compactMap { $0 }.joined(separator: " · ")
            return note.map { "[\($0)] \(body)" } ?? body
        }
    }

    public var mode: Mode
    /// 위에서부터 최대 `lineCount`줄. 모자라면 아래 줄은 비어 있습니다 (줄 위치는 고정).
    public var lines: [Line]

    public init(mode: Mode, lines: [Line]) {
        self.mode = mode
        self.lines = Array(lines.prefix(Self.lineCount))
    }

    /// 화면의 줄 수
    public static let lineCount = 3
    /// "쉬는 중"이 "잠든 중"이 되는 시간 (연출의 잠듦과 같음, `ChoreographyConfig.napAfter`)
    public static let napAfter = ChoreographyConfig().napAfter

    public static let empty = StatusLine(mode: .office, lines: [])

    /// 시간이 지나면 바뀌는 글자가 있는지 (화면이 1초마다 다시 그림)
    public var ticks: Bool {
        lines.contains { $0.segment.since != nil || $0.segment.at != nil || $0.segment.restingSince != nil }
    }

    /// 시간 때문에 화면 글자가 다음에 바뀌는 때 (바뀔 일이 없으면 nil). 화면은 이때만 다시 그립니다 (M6(1), 설계서 §8.3).
    ///
    /// "12초째"·"3초 전"처럼 1분 안쪽은 1초마다, "3분째"·"5분 전"·"1시간 2분째"는 1분마다 바뀌고(시작 시각 기준으로 맞춤),
    /// 쉬는 중은 `napAfter`가 지나는 순간 "잠든 중"으로 바뀝니다. 1초마다 창 전체를 다시 배치하던 것을 줄입니다.
    public func nextChange(after now: Date) -> Date? {
        var next: Date?
        func consider(_ date: Date) {
            if date > now, next.map({ date < $0 }) ?? true { next = date }
        }
        for line in lines {
            let segment = line.segment
            if let start = segment.since ?? segment.at {
                let elapsed = max(now.timeIntervalSince(start), 0)
                let step: TimeInterval = elapsed < 60 ? 1 : 60
                consider(start.addingTimeInterval(((elapsed / step).rounded(.down) + 1) * step))
            }
            if let resting = segment.restingSince { consider(resting.addingTimeInterval(Self.napAfter)) }
        }
        return next
    }

    /// 화면에 그릴 글자 그대로, 줄마다 (테스트·로그)
    public func texts(now: Date) -> [String] { lines.map { $0.text(now: now) } }

    /// 줄에 붙이는 디렉토리 이름의 최대 글자 수 (넘으면 앞쪽을 남기고 "…")
    public static let maxFolderLength = 16

    /// "claude-office" → 그대로, "very-long-directory-name" → "very-long-direc…"
    public static func shortFolder(_ name: String) -> String {
        name.count > maxFolderLength ? String(name.prefix(maxFolderLength - 1)) + "…" : name
    }

    /// "12초째", "3분째", "1시간 5분째". 1초 미만은 nil
    public static func elapsed(_ seconds: TimeInterval) -> String? {
        let total = Int(seconds)
        if total < 1 { return nil }
        if total < 60 { return "\(total)초째" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분째" }
        return "\(minutes / 60)시간 \(minutes % 60)분째"
    }

    // MARK: - 만들기

    /// - Parameters:
    ///   - selected: 고른 직원 (사무실에 없으면 행 줄)
    ///   - folder: 고른 디렉토리 (nil이면 모두)
    ///   - rows: 사무실에 보이는 행 (위에서부터, 사무실 화면과 같은 출처 `FloorPlan.rows`). nil이면 고른 디렉토리의 행을 온 순서대로.
    ///   - hiddenRows: 화면에 못 보여 준 행 (`FloorPlan.hiddenTeams`). `rows`가 nil이면 넘친 행.
    public static func make(
        state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, selected: AgentID?, folder: String?,
        rows: [TeamID]? = nil, hiddenRows: [TeamID] = []
    ) -> StatusLine {
        if let selected, let agent = state.agents[selected] {
            return agentLines(agent, state: state, journal: journal, privacy: privacy, showsFolder: folder == nil)
        }
        let teams = state.sortedTeams.filter { (folder == nil || $0.folder == folder) && !state.agents(in: $0.id).isEmpty }.map(\.id)
        let shown = rows ?? Array(teams.prefix(lineCount))
        let hidden = rows == nil ? Array(teams.dropFirst(lineCount)) : hiddenRows
        return officeLines(state: state, journal: journal, privacy: privacy, folder: folder, rows: shown, hiddenRows: hidden)
    }

    // MARK: 고른 사람

    static func agentLines(
        _ agent: Agent, state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, showsFolder: Bool = true
    ) -> StatusLine {
        let words = Words(state: state, privacy: privacy)
        let groups = agentGroups(agent.id, journal: journal, words: words)
        var lines = groups.suffix(lineCount).map { Line(segment: words.agentSegment($0)) }
        if lines.isEmpty {
            lines = [Line(segment: Segment(text: RosterStatus.from(agent).label, tone: .muted))]
        }
        let team = state.teams[agent.teamID]
        lines[0].colorIndex = team?.colorIndex
        lines[0].folder = showsFolder ? team.map { shortFolder($0.name) } : nil
        lines[0].head = agent.displayName
        return StatusLine(mode: .agent, lines: lines)
    }

    /// 한 사람의 기록을 오래된 것부터, 이어진 같은 도구는 묶어서 (현황 줄과 인스펙터 타임라인이 같이 씀)
    static func agentGroups(_ agent: AgentID, journal: ActivityJournal, words: Words) -> [Group] {
        groups(journal.entries(of: agent), words: words)
    }

    /// 기록을 오래된 것부터, 같은 사람이 이어서 쓴 같은 도구는 묶어서
    static func groups(_ entries: [ActivityEntry], words: Words) -> [Group] {
        var groups: [Group] = []
        for entry in entries {
            if let last = groups.last, last.canAbsorb(entry, key: words.toolLabel) {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(Group(entries: [entry]))
            }
        }
        return groups
    }

    // MARK: 행 줄

    static func officeLines(
        state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, folder: String?, rows: [TeamID], hiddenRows: [TeamID]
    ) -> StatusLine {
        let words = Words(state: state, privacy: privacy)
        let shown = rows.compactMap { state.teams[$0] }.filter { !state.agents(in: $0.id).isEmpty }
        var lines = shown.prefix(lineCount).map { rowLine($0, state: state, journal: journal, words: words, showsFolder: folder == nil) }

        // 화면에 못 보여 준 행의 승인 대기: 가장 오래 기다린 행 하나를 빈 줄(없으면 셋째 줄)에
        let waiting = hiddenRows.compactMap { state.teams[$0] }
            .compactMap { team in waitingSince(team.id, state: state, journal: journal).map { (team, $0) } }
            .sorted { $0.1 < $1.1 }
        if let (team, _) = waiting.first {
            var alert = rowLine(team, state: state, journal: journal, words: words, showsFolder: folder == nil)
            alert.offscreen = true
            alert.more = waiting.count - 1
            if lines.count < lineCount { lines.append(alert) } else { lines[lineCount - 1] = alert }
        }

        if lines.isEmpty {
            let text = folder != nil && !state.agents.isEmpty ? "고른 디렉토리에 출근한 직원이 없어요" : "아직 출근한 직원이 없어요"
            lines = [Line(segment: Segment(text: text, tone: .muted))]
        }
        return StatusLine(mode: .office, lines: lines)
    }

    /// 행 하나의 줄: 승인 대기 → 답변 필요 → 일하는 중이면 그 행의 가장 최근 일 → 새 응답 → 조용하면 쉬는 중
    static func rowLine(_ team: Team, state: OfficeState, journal: ActivityJournal, words: Words, showsFolder: Bool) -> Line {
        let people = state.agents(in: team.id)
        let main = people.first(where: \.isMain) ?? people.first
        var line = Line(
            colorIndex: team.colorIndex, folder: showsFolder ? shortFolder(team.name) : nil, head: main?.displayName,
            segment: Segment(text: "", tone: .muted))
        let entries = journal.entries.filter { $0.team == team.id }
        func completed(_ agent: Agent) -> Date { state.parts[agent.session]?.completedAt ?? agent.activitySince }
        /// 메인이 한 일은 그냥, 서브가 한 일은 "서브2가 …"
        func spoken(_ segment: Segment, by agent: AgentID, title: String) -> Segment {
            guard agent != main?.id else { return segment }
            var segment = segment
            segment.text = "\(Korean.subject(words.name(agent, fallback: title) ?? title)) \(segment.text)"
            return segment
        }

        if let entry = entries.last(where: { $0.state == .awaitingPermission }) {
            line.segment = spoken(words.agentSegment(Group(entries: [entry])), by: entry.agent, title: entry.title)
        } else if let waiter = people.first(where: { RosterStatus.from($0.activity) == .waitingForPermission }) {
            line.segment = spoken(
                Segment(text: RosterStatus.waitingForPermission.label, tone: .attention, since: waiter.activitySince),
                by: waiter.id, title: waiter.displayName)
        } else if let asker = people.filter({ $0.cue == .reply }).min(by: { completed($0) < completed($1) }) {
            // 응답을 끝내고 내 답을 기다림 (M6(4))
            line.segment = spoken(
                Segment(text: RosterStatus.awaitingReply.label, tone: .reply, at: completed(asker)), by: asker.id, title: asker.displayName)
        } else if let busy = people.first(where: { RosterStatus.from($0.activity).tone != .calm }) {
            if let group = groups(entries, words: words).last {
                line.segment = spoken(words.agentSegment(group), by: group.first.agent, title: group.first.title)
            } else {
                // 기록 없이 생각만 하는 중
                line.segment = spoken(
                    Segment(text: RosterStatus.from(busy.activity).label, since: busy.activitySince), by: busy.id, title: busy.displayName)
            }
        } else if let reader = people.filter({ $0.cue == .unread }).max(by: { completed($0) < completed($1) }) {
            // 아직 확인하지 않은 응답 (M6(4))
            line.segment = spoken(Segment(text: RosterStatus.unread.label, at: completed(reader)), by: reader.id, title: reader.displayName)
        } else if let main {
            let status = RosterStatus.from(main.activity)
            line.segment = status == .arriving
                ? Segment(text: status.label, tone: .muted)
                : Segment(text: RosterStatus.idle.label, tone: .muted, restingSince: main.activitySince)
        }
        return line
    }

    /// 행에서 승인을 기다리기 시작한 가장 이른 때 (기다리는 사람이 없으면 nil)
    static func waitingSince(_ team: TeamID, state: OfficeState, journal: ActivityJournal) -> Date? {
        let people = state.agents(in: team).filter { RosterStatus.from($0.activity) == .waitingForPermission }
        let fromJournal = journal.entries.filter { $0.team == team && $0.state == .awaitingPermission }.map(\.since)
        return (people.map(\.activitySince) + fromJournal).min()
    }

    // MARK: - 묶음

    /// 이어진 같은 동작 (하나 또는 여럿)
    struct Group {
        var entries: [ActivityEntry]

        var first: ActivityEntry { entries[0] }
        var last: ActivityEntry { entries[entries.count - 1] }
        var count: Int { entries.count }

        /// 묶을 수 있는 것: 끝난(정상) 툴끼리, 같은 사람, 같은 키
        func canAbsorb(_ entry: ActivityEntry, key: (ToolCall) -> String) -> Bool {
            guard entry.agent == first.agent, let call = entry.toolCall, let mine = first.toolCall,
                Self.groupable(entry.state), Self.groupable(first.state)
            else { return false }
            return key(call) == key(mine)
        }

        static func groupable(_ state: ActivityEntry.State) -> Bool {
            state == .succeeded || state == .closed || state == .interrupted
        }
    }

    /// 표시 수준에 맞춘 말 만들기 (현황 줄·인스펙터 타임라인·알림이 같이 씀)
    struct Words {
        let state: OfficeState
        let privacy: PrivacyLevel

        var detailed: Bool { privacy == .detailed }

        /// 지금 직함 (퇴근했으면 기록할 때 직함)
        func name(_ id: AgentID?, fallback: String?) -> String? {
            id.flatMap { state.agents[$0]?.displayName } ?? fallback
        }

        /// 툴 종류 이름 (묶는 기준이기도 함). MCP는 사람이 읽는 말 (`MCPNames`)
        func toolLabel(_ call: ToolCall) -> String {
            switch call.category {
            case .mcp: MCPNames.label(call.name, detailed: detailed)
            case .report: "보고 정리"
            default: call.name
            }
        }

        /// 상세면 "Edit auth.ts", "브라우저 페이지 이동", 아니면 "Edit", "브라우저"
        func toolText(_ call: ToolCall) -> String {
            if call.category == .mcp { return MCPNames.text(call.name, detailed: detailed) }
            guard detailed, call.category != .report else { return toolLabel(call) }
            guard let subject = call.subject, !subject.isEmpty else { return toolLabel(call) }
            return "\(toolLabel(call)) \(subject)"
        }

        func tone(_ state: ActivityEntry.State) -> Tone {
            switch state {
            case .awaitingPermission: .attention
            case .failed, .denied: .error
            default: .normal
            }
        }

        func since(_ entry: ActivityEntry) -> Date? { entry.state.isOpen ? entry.since : nil }

        static func suffix(_ state: ActivityEntry.State) -> String {
            switch state {
            case .awaitingPermission: " 승인 대기"
            case .failed: " 실패"
            case .denied: " 거부됨"
            default: ""
            }
        }

        /// 일 하나(또는 묶음): "Read 3개", "Edit auth.ts", "Bash npm test 승인 대기", "서브2에게 위임".
        /// 진행 중이면 `since`, 끝났으면 마지막 기록의 때 `at`.
        func agentSegment(_ group: Group) -> Segment {
            let entry = group.first
            let text: String
            switch entry.kind {
            case .tool(let call):
                text = group.count > 1 ? "\(toolLabel(call)) \(group.count)개" : toolText(call) + Self.suffix(entry.state)
            case .permission(let call):
                if let call, call.asksUser {
                    text = entry.state == .denied ? "\(call.name) 거부됨" : call.waitLabel
                } else {
                    text = (call.map(toolText).map { $0 + " " } ?? "") + (entry.state == .denied ? "거부됨" : "승인 대기")
                }
            case .delegated(let member, let title):
                text = "\(name(member, fallback: title) ?? "서브")에게 위임"
            case .reported(let to, let title):
                text = name(to, fallback: title).map { "\($0)에게 보고" } ?? "보고"
            }
            let running = group.count > 1 ? nil : since(entry)
            return Segment(text: text, tone: tone(entry.state), since: running, at: running == nil ? group.last.at : nil)
        }
    }
}

/// 한국어 조사
public enum Korean {
    /// 받침이 있으면 "이", 없으면 "가"를 붙입니다 ("메인이", "서브가", "서브1이", "서브2가")
    public static func subject(_ word: String) -> String {
        word + (hasFinalConsonant(word) ? "이" : "가")
    }

    static func hasFinalConsonant(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        if (0xAC00...0xD7A3).contains(last.value) { return (last.value - 0xAC00) % 28 != 0 }
        // 숫자는 읽는 소리로: 영 일 이 삼 사 오 육 칠 팔 구
        if let digit = Int(String(last)) { return [true, true, false, true, false, false, true, true, true, false][digit] }
        return false
    }
}
