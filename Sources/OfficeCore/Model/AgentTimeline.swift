import Foundation

/// 인스펙터의 "최근 일" 타임라인 (설계서 §10, M5(7)). 고른 한 사람이 최근에 한 일을 시간 순서대로 한 줄씩.
///
/// 현황 줄(`StatusLine`)의 고른 사람 흐름과 같은 기록·같은 묶기(이어진 같은 도구는 "Read 3개")·같은 말(표시 수준이
/// 상세가 아니면 파일명·명령을 숨김)을 쓰고, 줄마다 언제 했는지를 붙입니다: "12초 전 · Edit auth.ts".
/// 진행 중인 일은 "지금 · Bash npm test (12초째)". 승인 대기는 노랑, 실패·거부는 빨강(`StatusLine.Tone`).
public struct AgentTimeline: Hashable, Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        /// 묶음 첫 기록의 일련번호 (같은 줄이면 같은 값)
        public let id: Int
        public let text: String
        public let tone: StatusLine.Tone
        /// 한 때 (묶음이면 마지막 것)
        public let at: Date
        /// 진행 중이면 지금 상태가 된 시각 (화면이 "(12초째)"를 붙임)
        public let since: Date?
        /// 묶은 기록 수
        public let count: Int

        public init(id: Int, text: String, tone: StatusLine.Tone = .normal, at: Date, since: Date? = nil, count: Int = 1) {
            self.id = id
            self.text = text
            self.tone = tone
            self.at = at
            self.since = since
            self.count = count
        }

        /// 줄 앞머리: 진행 중이면 "지금", 아니면 "12초 전"
        public func when(now: Date) -> String {
            since != nil ? "지금" : AgentTimeline.ago(now.timeIntervalSince(at))
        }

        /// 화면에 그릴 글자 그대로 (테스트·도움말): "12초 전 · Edit auth.ts", "지금 · Bash npm test (12초째)"
        public func text(now: Date) -> String {
            var body = text
            if let since, let elapsed = StatusLine.elapsed(now.timeIntervalSince(since)) { body += " (\(elapsed))" }
            return "\(when(now: now)) · \(body)"
        }
    }

    /// 오래된 것부터
    public var items: [Item]
    /// 보여 주지 못한 더 오래된 일이 있는지
    public var truncated: Bool

    public init(items: [Item], truncated: Bool = false) {
        self.items = items
        self.truncated = truncated
    }

    public static let empty = AgentTimeline(items: [])

    /// 타임라인에 남기는 줄 수 (묶은 뒤)
    public static let maxItems = 15

    /// 진행 중인 줄이 있는지 (화면이 1초마다 다시 그림)
    public var hasRunning: Bool { items.contains { $0.since != nil } }

    /// - Parameters:
    ///   - agent: 고른 사람 (퇴근했어도 기록이 남아 있으면 그 기록)
    ///   - limit: 보여 줄 줄 수 (묶은 뒤, 최근 것부터 셈)
    public static func make(
        agent: AgentID, state: OfficeState, journal: ActivityJournal, privacy: PrivacyLevel, limit: Int = maxItems
    ) -> AgentTimeline {
        let words = StatusLine.Words(state: state, privacy: privacy)
        let groups = StatusLine.agentGroups(agent, journal: journal, words: words)
        let items = groups.suffix(max(0, limit)).map { group in
            let segment = words.agentSegment(group)
            return Item(
                id: group.first.serial, text: segment.text, tone: segment.tone,
                at: group.entries.last?.at ?? group.first.at, since: segment.since, count: group.count)
        }
        return AgentTimeline(items: Array(items), truncated: groups.count > items.count)
    }

    /// "방금", "12초 전", "3분 전", "2시간 전", "3일 전"
    public static func ago(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 5 { return "방금" }
        if total < 60 { return "\(total)초 전" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 전" }
        return "\(hours / 24)일 전"
    }
}
