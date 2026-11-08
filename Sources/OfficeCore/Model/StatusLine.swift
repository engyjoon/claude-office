import Foundation

/// 사무실 아래 한 줄짜리 실시간 현황 (설계서 §10.2). 신원 카드가 "누구"라면 이 줄은 "무엇을 하고 있는지"의 흐름입니다.
///
/// - 캐릭터를 골랐으면 그 사람의 최근 도구 흐름 ("Read 3개 → Edit auth.ts → Bash npm test (12초째)").
///   새 동작은 오른쪽에 붙고 오래된 것은 왼쪽에서 잘립니다. 같은 도구가 이어지면 묶습니다.
/// - 아무도 안 골랐으면 고른 디렉토리(모두면 전체) 사람들의 최근 일 ("방금: 서브1이 auth.ts 편집 · 메인이 서브2에게 위임").
///   새 일이 왼쪽에 오고 오래된 것은 오른쪽에서 잘립니다.
/// - 표시 수준이 상세가 아니면 파일명·명령을 숨기고 도구 종류만 씁니다. 에이전트 종류는 쓰지 않고 직함만 씁니다.
/// - 디렉토리 드롭다운이 "모두"면 어느 디렉토리 일인지 폴더 이름을 붙입니다 (M5(7a), 서브 번호는 메인마다 따로라서):
///   고른 사람 줄은 맨 앞 "claude-office · 메인1 …", 사무실 줄은 디렉토리가 바뀌는 항목마다 "claude-office · 서브1이 …".
///   디렉토리를 하나 골랐으면 바로 위 드롭다운에 이미 보이므로 붙이지 않습니다.
/// 경과 시간은 화면이 `since`로 붙입니다 (이 값은 시간에 따라 바뀌지 않음).
public struct StatusLine: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// 고른 사람의 흐름 (새 것이 오른쪽)
        case agent
        /// 사무실(디렉토리)의 최근 일 (새 것이 왼쪽)
        case office
    }

    public enum Tone: Hashable, Sendable {
        case normal
        /// 안내 문구, 쉬는 중
        case muted
        /// 승인 대기 (노랑)
        case attention
        /// 오류·거부 (빨강)
        case error
    }

    public struct Segment: Hashable, Sendable {
        public var text: String
        public var tone: Tone
        /// 진행 중이면 시작 시각. 화면이 "(12초째)"를 붙입니다.
        public var since: Date?
        /// 이 항목 앞에 붙일 디렉토리 이름 (사무실 줄, "모두"일 때 디렉토리가 바뀌는 항목에만. 길면 줄인 것)
        public var folder: String?
        /// 그 디렉토리 행의 색 (화면의 점, 퇴근한 행이면 nil)
        public var colorIndex: Int?

        public init(text: String, tone: Tone = .normal, since: Date? = nil, folder: String? = nil, colorIndex: Int? = nil) {
            self.text = text
            self.tone = tone
            self.since = since
            self.folder = folder
            self.colorIndex = colorIndex
        }

        public func text(now: Date) -> String {
            let prefix = folder.map { "\($0) · " } ?? ""
            guard let since, let elapsed = StatusLine.elapsed(now.timeIntervalSince(since)) else { return prefix + text }
            return "\(prefix)\(text) (\(elapsed))"
        }
    }

    public var mode: Mode
    /// 줄 맨 앞 머리: 고른 사람의 직함("메인1") 또는 "방금". 안내 문구만 있으면 nil
    public var head: String?
    /// 고른 사람의 행 색 (화면의 점)
    public var colorIndex: Int?
    /// 고른 사람 줄 맨 앞 디렉토리 이름 ("모두"일 때만, 길면 줄인 것)
    public var folder: String?
    public var segments: [Segment]
    /// 다 못 보여 준 오래된 동작이 있는지 (에이전트: 앞쪽, 사무실: 뒤쪽)
    public var truncated: Bool

    public init(mode: Mode, head: String?, colorIndex: Int? = nil, folder: String? = nil, segments: [Segment], truncated: Bool = false) {
        self.mode = mode
        self.head = head
        self.colorIndex = colorIndex
        self.folder = folder
        self.segments = segments
        self.truncated = truncated
    }

    public var separator: String { mode == .agent ? " → " : " · " }

    /// 진행 중인 동작이 있는지 (화면이 1초마다 다시 그림)
    public var hasRunning: Bool { segments.contains { $0.since != nil } }

    /// 화면에 그릴 글자 그대로 (테스트·로그)
    public func text(now: Date) -> String {
        var body = segments.map { $0.text(now: now) }.joined(separator: separator)
        if truncated { body = mode == .agent ? "… " + body : body + " …" }
        return [folder.map { "\($0) ·" }, head.map { mode == .office ? "\($0):" : $0 }, body].compactMap { $0 }.joined(separator: " ")
    }

    /// 줄에 붙이는 디렉토리 이름의 최대 글자 수 (넘으면 앞쪽을 남기고 "…")
    public static let maxFolderLength = 16

    /// "claude-office" → 그대로, "very-long-directory-name" → "very-long-direc…"
    public static func shortFolder(_ name: String) -> String {
        name.count > maxFolderLength ? String(name.prefix(maxFolderLength - 1)) + "…" : name
    }

    public static let empty = StatusLine(mode: .office, head: nil, segments: [])

    /// 고른 사람의 줄에 보여 주는 묶음 수
    public static let maxAgentSegments = 6
    /// 사무실 줄에 보여 주는 일 수
    public static let maxOfficeSegments = 4

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
    ///   - selected: 고른 직원 (사무실에 없으면 사무실 줄)
    ///   - folder: 고른 디렉토리 (nil이면 모두)
    public static func make(
        state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, selected: AgentID?, folder: String?
    ) -> StatusLine {
        if let selected, let agent = state.agents[selected] {
            return agentLine(agent, state: state, journal: journal, privacy: privacy, showsFolder: folder == nil)
        }
        return officeLine(state: state, journal: journal, privacy: privacy, folder: folder)
    }

    // MARK: 고른 사람

    static func agentLine(
        _ agent: Agent, state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, showsFolder: Bool = true
    ) -> StatusLine {
        let words = Words(state: state, privacy: privacy)
        let groups = agentGroups(agent.id, journal: journal, words: words)
        var segments = groups.suffix(maxAgentSegments).map { words.agentSegment($0) }
        if segments.isEmpty {
            segments = [Segment(text: RosterStatus.from(agent.activity).label, tone: .muted)]
        }
        return StatusLine(
            mode: .agent, head: agent.displayName, colorIndex: state.teams[agent.teamID]?.colorIndex,
            folder: showsFolder ? state.teams[agent.teamID].map { shortFolder($0.name) } : nil,
            segments: segments, truncated: groups.count > maxAgentSegments)
    }

    /// 한 사람의 기록을 오래된 것부터, 이어진 같은 도구는 묶어서 (현황 줄과 인스펙터 타임라인이 같이 씀)
    static func agentGroups(_ agent: AgentID, journal: ActivityJournal, words: Words) -> [Group] {
        var groups: [Group] = []
        for entry in journal.entries(of: agent) {
            if let last = groups.last, last.canAbsorb(entry, key: words.toolLabel) {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(Group(entries: [entry]))
            }
        }
        return groups
    }

    // MARK: 사무실

    static func officeLine(state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, folder: String?) -> StatusLine {
        func folderOf(_ agent: Agent) -> String? { state.teams[agent.teamID]?.folder }
        let people = state.agents.values.filter { folder == nil || folderOf($0) == folder }
        if people.isEmpty {
            let text = folder != nil && !state.agents.isEmpty ? "고른 디렉토리에 출근한 직원이 없어요" : "아직 출근한 직원이 없어요"
            return StatusLine(mode: .office, head: nil, segments: [Segment(text: text, tone: .muted)])
        }
        if people.allSatisfy({ RosterStatus.from($0.activity).tone == .calm }) {
            return StatusLine(mode: .office, head: nil, segments: [Segment(text: "모두 쉬는 중이에요", tone: .muted)])
        }

        let words = Words(state: state, privacy: privacy)
        // 새 것부터, 같은 사람이 같은 종류의 일을 이어 하면 묶습니다
        let recent = journal.entries.reversed().filter { entry in
            guard let folder else { return true }
            return (state.agents[entry.agent].flatMap(folderOf) ?? entry.folder) == folder
        }
        var groups: [Group] = []
        for entry in recent {
            if let last = groups.last, last.canAbsorb(entry, key: { "\($0.category.rawValue)#\($0.category == .other ? $0.name : "")" }) {
                groups[groups.count - 1].entries.append(entry)
            } else {
                if groups.count == maxOfficeSegments + 1 { break }
                groups.append(Group(entries: [entry]))
            }
        }
        if !groups.isEmpty {
            let segments = groups.prefix(maxOfficeSegments).map { group in
                labeled(words.officeSegment(group), team: state.agents[group.first.agent].flatMap { state.teams[$0.teamID] },
                        folder: group.first.folder)
            }
            return StatusLine(
                mode: .office, head: "방금", segments: folderLabels(segments, show: folder == nil),
                truncated: groups.count > maxOfficeSegments)
        }
        // 기록이 없으면 (생각만 하는 중) 지금 상태로
        let busy = people.filter { RosterStatus.from($0.activity).tone != .calm }.sorted { ($0.teamID, $0.seat) < ($1.teamID, $1.seat) }
        let segments = busy.prefix(maxOfficeSegments).map { agent in
            let status = RosterStatus.from(agent.activity)
            return labeled(
                Segment(text: "\(agent.displayName) \(status.label)", tone: status == .waitingForPermission ? .attention : .normal),
                team: state.teams[agent.teamID], folder: nil)
        }
        return StatusLine(
            mode: .office, head: "지금", segments: folderLabels(Array(segments), show: folder == nil),
            truncated: busy.count > maxOfficeSegments)
    }

    /// 항목에 그 사람의 디렉토리 이름과 행 색을 달아 둡니다 (퇴근했으면 기록할 때 폴더의 이름, 색 없음)
    private static func labeled(_ segment: Segment, team: Team?, folder: String?) -> Segment {
        var segment = segment
        if let team {
            segment.folder = shortFolder(team.name)
            segment.colorIndex = team.colorIndex
        } else if let folder {
            segment.folder = shortFolder(URL(fileURLWithPath: folder).lastPathComponent)
        }
        return segment
    }

    /// "모두"면 앞 항목과 디렉토리가 같을 때 이름을 지우고(디렉토리가 바뀌는 항목에만), 디렉토리를 하나 골랐으면 모두 지웁니다
    private static func folderLabels(_ segments: [Segment], show: Bool) -> [Segment] {
        var previous: String?
        return segments.enumerated().map { index, segment in
            var segment = segment
            let current = segment.folder
            if !show || (index > 0 && current == previous) {
                segment.folder = nil
                segment.colorIndex = nil
            }
            previous = current
            return segment
        }
    }

    // MARK: - 묶음

    /// 이어진 같은 동작 (하나 또는 여럿)
    struct Group {
        var entries: [ActivityEntry]

        var first: ActivityEntry { entries[0] }
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

    /// 표시 수준에 맞춘 말 만들기
    struct Words {
        let state: OfficeState
        let privacy: PrivacyLevel

        var detailed: Bool { privacy == .detailed }

        /// 지금 직함 (퇴근했으면 기록할 때 직함)
        func name(_ id: AgentID?, fallback: String?) -> String? {
            id.flatMap { state.agents[$0]?.displayName } ?? fallback
        }

        /// 툴 종류 이름 (묶는 기준이기도 함)
        func toolLabel(_ call: ToolCall) -> String {
            switch call.category {
            case .mcp: "MCP"
            case .report: "보고 정리"
            default: call.name
            }
        }

        /// 상세면 "Edit auth.ts", 아니면 "Edit"
        func toolText(_ call: ToolCall) -> String {
            guard detailed, call.category != .report, let subject = call.subject, !subject.isEmpty else { return toolLabel(call) }
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

        // 고른 사람의 줄: "Read 3개", "Edit auth.ts", "Bash npm test 승인 대기", "서브2에게 위임"
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
            return Segment(text: text, tone: tone(entry.state), since: group.count > 1 ? nil : since(entry))
        }

        // 사무실 줄: "서브1이 auth.ts 편집", "서브1이 파일 3개 읽음", "메인이 서브2에게 위임"
        func officeSegment(_ group: Group) -> Segment {
            let entry = group.first
            let title = name(entry.agent, fallback: entry.title) ?? entry.title
            let who = Korean.subject(title)
            let text: String
            switch entry.kind {
            case .tool(let call):
                let target = detailed ? (call.subject.flatMap { $0.isEmpty ? nil : $0 } ?? toolLabel(call)) : toolLabel(call)
                switch entry.state {
                case .awaitingPermission: text = "\(who) \(target) 승인 기다림"
                case .failed: text = "\(title)의 \(target) 실패"
                case .denied: text = "\(title)의 \(target) 거부됨"
                default: text = "\(who) \(phrase(call, count: group.count))"
                }
            case .permission(let call):
                let target = call.map { detailed ? ($0.subject ?? toolLabel($0)) : toolLabel($0) }
                text = entry.state == .denied
                    ? "\(title)의 \(target ?? "요청") 거부됨"
                    : "\(who) \(target.map { "\($0) " } ?? "")승인 기다림"
            case .delegated(let member, let memberTitle):
                text = "\(who) \(name(member, fallback: memberTitle) ?? "서브")에게 위임"
            case .reported(let to, let toTitle):
                text = name(to, fallback: toTitle).map { "\(who) \($0)에게 보고" } ?? "\(who) 보고"
            }
            return Segment(text: text, tone: tone(entry.state), since: group.count > 1 ? nil : since(entry))
        }

        /// "auth.ts 편집", "파일 편집", "파일 3개 읽음", "웹 2번 검색"
        func phrase(_ call: ToolCall, count: Int) -> String {
            let (noun, unit, verb): (String, String, String) = switch call.category {
            case .read: ("파일", "개", "읽음")
            case .write: ("파일", "개", "편집")
            case .shell: ("명령", "개", "실행")
            case .web: ("웹", "번", "검색")
            case .plan: ("계획", "번", "정리")
            case .report: ("보고", "번", "정리")
            case .delegate: ("일", "번", "맡김")
            case .mcp, .other: (detailed && call.category == .other ? call.name : "도구", "번", "사용")
            }
            if count > 1 { return "\(noun) \(count)\(unit) \(verb)" }
            if detailed, call.category != .report, let subject = call.subject, !subject.isEmpty { return "\(subject) \(verb)" }
            return "\(noun) \(verb)"
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
