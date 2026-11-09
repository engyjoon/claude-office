import Foundation

/// VoiceOver가 읽을 문구 (M6(7)). 화면(SwiftUI·SpriteKit 접근성 요소)은 이 문구를 그대로 붙이기만 합니다.
///
/// - 캐릭터 한 명은 "이름, 디렉토리, 상태, 상세" 순서로 읽습니다 ("메인1, claude-office, 편집 중, Stage.swift").
///   상세는 표시 수준이 "상세"일 때만 `RosterRow.detail`에 있으므로, 화면에 보이는 것보다 더 말하지 않습니다.
/// - 색(행 점, 칩 색, 형광펜)만으로 보이던 것은 말로 바꿉니다: 상태 이름, 행 이름, "화면 밖".
public enum AccessibilityText {
    // MARK: - 사무실 장면

    /// 캐릭터 하나: "메인1, claude-office, 편집 중, Stage.swift". 서브면 끝에 부른 세션("메인1 호출")을 붙입니다.
    public static func agent(_ row: RosterRow) -> String {
        var parts = [row.name, row.teamName, row.status.label]
        if let detail = clean(row.detail) { parts.append(detail) }
        if let caller = row.calledBy { parts.append("\(caller) 호출") }
        return parts.joined(separator: ", ")
    }

    /// 캐릭터의 값: 골랐으면 "선택됨"
    public static func agentValue(selected: Bool) -> String? {
        selected ? "선택됨" : nil
    }

    /// 캐릭터 힌트. `focusLabel`은 "앱으로"·"터미널로"(갈 곳을 모르면 nil).
    public static func agentHint(focusLabel: String?) -> String {
        guard let focusLabel else { return "누르면 골라서 인스펙터를 보여 줘요." }
        return "누르면 골라서 인스펙터를 보여 줘요. Return 키나 동작 메뉴의 \(moveActionName(focusLabel: focusLabel))으로 그 세션을 열어요."
    }

    /// 동작 메뉴 이름: "앱으로 이동", "터미널로 이동"
    public static func moveActionName(focusLabel: String) -> String {
        "\(focusLabel) 이동"
    }

    /// 행 끝 "+N": "claude-office 행, 화면에 못 보여 준 2명 더 있음"
    public static func hidden(count: Int, folder: String) -> String {
        "\(folder) 행, 화면에 못 보여 준 \(count)명 더 있음"
    }

    /// 행이 모자라 통째로 숨긴 행: "화면에 못 보여 준 행 2개: a-sdn-portal 메인2, docs 메인3" (없으면 nil)
    public static func hiddenRows(_ teams: [(folder: String, main: String, people: Int)]) -> String? {
        guard !teams.isEmpty else { return nil }
        let names = teams.map { "\($0.folder) \($0.main) \($0.people)명" }.joined(separator: ", ")
        return "화면에 못 보여 준 행 \(teams.count)개: \(names)"
    }

    /// 사무실 장면 전체의 이름과 요약 ("사무실, 3행 7명" / "사무실, 출근한 직원 없음")
    public static func scene(rows: Int, people: Int, mini: Bool = false) -> String {
        let name = mini ? "미니 사무실" : "사무실"
        guard people > 0 else { return "\(name), 출근한 직원 없음" }
        return mini ? "\(name), \(people)명" : "\(name), \(rows)행 \(people)명"
    }

    /// 사무실 장면 힌트 (키보드)
    public static let sceneHint = "화살표나 Tab으로 직원을 고르고, Return으로 그 세션을 열고, Esc로 고르기를 풀어요."

    // MARK: - 패널·메뉴

    /// 직원 패널·메뉴 줄: 캐릭터와 같은 문구에 세션 제목을 붙입니다 ("메인1, claude-office, 쉬는 중, 접근성 작업")
    public static func row(_ row: RosterRow) -> String {
        var text = agent(row)
        if row.detail == nil, let title = clean(row.sessionTitle) { text += ", \(title)" }
        return text
    }

    /// 상태 칩: "상태: 승인 대기"
    public static func status(_ status: RosterStatus) -> String {
        "상태: \(status.label)"
    }

    /// 현황 줄 한 줄: "[화면 밖] a · b"를 "화면 밖, a · b"로
    public static func statusLine(_ line: StatusLine.Line, now: Date) -> String {
        let body = [line.heading, line.segment.text(now: now)].compactMap { $0 }.joined(separator: " · ")
        return line.note.map { "\($0), \(body)" } ?? body
    }

    /// 현황 줄 전체 (빈 줄은 뺌). 줄 사이는 마침표로 끊어 읽습니다.
    public static func statusLines(_ line: StatusLine, now: Date) -> String {
        let texts = line.lines.map { statusLine($0, now: now) }.filter { !$0.isEmpty }
        return texts.isEmpty ? "내용 없음" : texts.joined(separator: ". ")
    }

    /// 메뉴바 아이콘: "Claude Office, 승인 대기 1명, 일하는 중 2명, 쉬는 중 3명" (상태 점의 색을 말로)
    public static func menuBar(_ roster: Roster) -> String {
        let rows = roster.teams.flatMap(\.rows)
        guard !rows.isEmpty else { return "Claude Office, 출근한 직원 없음" }
        let counts = statusCounts(rows)
        return (["Claude Office"] + counts.map { "\($0.label) \($0.count)명" }).joined(separator: ", ")
    }

    /// 상태 묶음별 사람 수 (현황 줄의 행 순서와 같음: 승인 대기 > 답변 필요 > 일하는 중 > 새 응답 > 쉬는 중). 0명인 묶음은 뺍니다.
    public static func statusCounts(_ rows: [RosterRow]) -> [(label: String, count: Int)] {
        var attention = 0, reply = 0, working = 0, unread = 0, resting = 0
        for row in rows {
            switch row.status {
            case .waitingForPermission: attention += 1
            case .awaitingReply: reply += 1
            case .unread: unread += 1
            default: if row.status.tone == .calm { resting += 1 } else { working += 1 }
            }
        }
        return [("승인 대기", attention), ("답변 필요", reply), ("일하는 중", working), ("새 응답", unread), ("쉬는 중", resting)]
            .filter { $0.1 > 0 }
            .map { (label: $0.0, count: $0.1) }
    }

    /// 미니 사무실 다른 메인 칩: "메인2, 승인 대기" / "메인3, 새 응답" / "메인1"
    public static func miniChip(main: String, tier: String?) -> String {
        tier.map { "\(main), \($0)" } ?? main
    }

    /// 미니 사무실 머리줄 값 (M6(7b)): 화면 문구 + 다른 메인 칩.
    /// "서브3: 생각 중 · 방금. 다른 메인: 메인2, 답변 기다림 · 메인3 · 외 1개"
    public static func miniHeader(status: String?, chips: [String], more: Int = 0) -> String {
        var parts: [String] = []
        if let status = clean(status) { parts.append(status) }
        let others = chips.compactMap(clean) + (more > 0 ? ["외 \(more)개"] : [])
        if !others.isEmpty { parts.append("다른 메인: " + others.joined(separator: " · ")) }
        return parts.isEmpty ? "내용 없음" : parts.joined(separator: ". ")
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// 중요한 상태 변화를 VoiceOver로 한 번씩 알립니다 (M6(7)): 승인 대기, 답변 필요.
///
/// - 같은 대기(같은 사람·같은 상태·같은 시작 시각)는 한 번만 알립니다. 데스크톱 앱 요약이 늦게 와서 답변 필요 판정이
///   잠깐 바뀌었다 돌아와도 다시 알리지 않습니다.
/// - 처음 본 목록(앱을 켤 때 이미 기다리던 사람)은 알리지 않고 알린 것으로 칩니다.
/// - 알림 설정과 겹치지 않게 할지는 화면 쪽이 정합니다 (`kinds`로 거를 종류를 넘김).
public struct AccessibilityAnnouncer: Sendable {
    public enum Kind: String, Hashable, Sendable {
        case permission, reply
    }

    public struct Announcement: Hashable, Sendable {
        public let kind: Kind
        /// "메인1 승인 대기, claude-office"
        public let text: String
    }

    /// 사람마다 이미 알린 대기 ("permission|1800000000")
    private var announced: [AgentID: Set<String>] = [:]
    private var primed = false

    public init() {}

    /// 새로 생긴 대기. `kinds`에 없는 종류는 알리지 않지만 알린 것으로 칩니다 (설정을 켠 순간 지난 대기를 몰아 알리지 않게).
    public mutating func announcements(for roster: Roster, kinds: Set<Kind> = [.permission, .reply]) -> [Announcement] {
        let rows = roster.teams.flatMap(\.rows)
        var fresh: [(Date, Announcement)] = []
        var present = Set<AgentID>()
        for row in rows {
            present.insert(row.id)
            let kind: Kind
            switch row.status {
            case .waitingForPermission: kind = .permission
            case .awaitingReply: kind = .reply
            default: continue
            }
            let key = "\(kind.rawValue)|\(Int(row.since.timeIntervalSince1970.rounded()))"
            guard announced[row.id, default: []].insert(key).inserted, primed, kinds.contains(kind) else { continue }
            fresh.append((row.since, Announcement(kind: kind, text: "\(row.name) \(row.status.label), \(row.teamName)")))
        }
        // 퇴근한 사람의 기록은 지웁니다
        announced = announced.filter { present.contains($0.key) }
        primed = true
        return fresh.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 여러 개면 한 문장으로 ("메인1 승인 대기, claude-office. 서브2 답변 필요, docs")
    public static func sentence(_ announcements: [Announcement]) -> String? {
        announcements.isEmpty ? nil : announcements.map(\.text).joined(separator: ". ")
    }
}
