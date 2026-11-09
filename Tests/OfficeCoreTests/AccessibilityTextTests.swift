import Foundation
import Testing

@testable import OfficeCore

@Suite("VoiceOver 문구 (M6(7))")
struct AccessibilityTextTests {
    static func row(
        _ id: String, name: String = "메인1", title: JobTitle = .main(1), folder: String = "claude-office",
        status: RosterStatus = .editing, detail: String? = "Stage.swift", sessionTitle: String? = nil, calledBy: String? = nil,
        since: Date = Fixture.epoch
    ) -> RosterRow {
        RosterRow(
            id: AgentID(id), name: name, role: title.isMain ? .lead : .member, title: title, seat: .main, sessionTitle: sessionTitle,
            calledBy: calledBy, mainName: "메인1", agentType: nil, kind: title.isMain ? .lead : .temporary, status: status, detail: detail,
            since: since, appearance: .make(key: id, kind: .lead), teamName: folder, session: SessionID("s-\(id)"), term: nil,
            hostSession: nil)
    }

    static func roster(_ rows: [RosterRow]) -> Roster {
        let team = RosterTeam(id: TeamID("t"), name: "claude-office", folder: "/w/claude-office", colorIndex: 0, mainName: "메인1", mainTitle: nil, rows: rows)
        return Roster(teams: [team], waiting: rows.filter { $0.status == .waitingForPermission })
    }

    @Test("캐릭터는 이름, 디렉토리, 상태, 상세 순서로 읽는다")
    func agent() {
        #expect(AccessibilityText.agent(Self.row("a")) == "메인1, claude-office, 편집 중, Stage.swift")
        // 상세가 없으면(요약·비공개 표시 수준) 상태까지만
        #expect(AccessibilityText.agent(Self.row("a", status: .idle, detail: nil)) == "메인1, claude-office, 쉬는 중")
        // 서브는 부른 세션을 끝에
        let sub = Self.row("b", name: "서브2", title: .sub(2), status: .reading, detail: "Roster.swift", calledBy: "메인1")
        #expect(AccessibilityText.agent(sub) == "서브2, claude-office, 읽는 중, Roster.swift, 메인1 호출")
    }

    @Test("답변 필요, 새 응답, 승인 대기, 정리 중도 말로 읽힌다")
    func cues() {
        #expect(AccessibilityText.agent(Self.row("a", status: .awaitingReply, detail: nil)) == "메인1, claude-office, 답변 필요")
        #expect(AccessibilityText.agent(Self.row("a", status: .unread, detail: nil)) == "메인1, claude-office, 새 응답")
        #expect(AccessibilityText.agent(Self.row("a", status: .waitingForPermission, detail: "Bash · npm test"))
            == "메인1, claude-office, 승인 대기, Bash · npm test")
        #expect(AccessibilityText.agent(Self.row("a", status: .compacting, detail: nil)) == "메인1, claude-office, 정리 중")
        // 빈 상세는 읽지 않음
        #expect(AccessibilityText.agent(Self.row("a", status: .thinking, detail: "  ")) == "메인1, claude-office, 생각 중")
    }

    @Test("패널 줄은 상세가 없을 때 세션 제목을 붙인다")
    func panelRow() {
        #expect(AccessibilityText.row(Self.row("a", status: .idle, detail: nil, sessionTitle: "접근성 작업")) == "메인1, claude-office, 쉬는 중, 접근성 작업")
        #expect(AccessibilityText.row(Self.row("a", sessionTitle: "접근성 작업")) == "메인1, claude-office, 편집 중, Stage.swift")
    }

    @Test("숨긴 사람·행, 장면 요약, 힌트")
    func hiddenAndScene() {
        #expect(AccessibilityText.hidden(count: 2, folder: "claude-office") == "claude-office 행, 화면에 못 보여 준 2명 더 있음")
        #expect(AccessibilityText.hiddenRows([]) == nil)
        #expect(AccessibilityText.hiddenRows([("docs", "메인3", 2)]) == "화면에 못 보여 준 행 1개: docs 메인3 2명")
        #expect(AccessibilityText.scene(rows: 2, people: 5) == "사무실, 2행 5명")
        #expect(AccessibilityText.scene(rows: 0, people: 0) == "사무실, 출근한 직원 없음")
        #expect(AccessibilityText.scene(rows: 1, people: 3, mini: true) == "미니 사무실, 3명")
        #expect(AccessibilityText.agentHint(focusLabel: nil) == "누르면 골라서 인스펙터를 보여 줘요.")
        #expect(AccessibilityText.agentHint(focusLabel: "앱으로").contains("앱으로 이동"))
        #expect(AccessibilityText.agentValue(selected: true) == "선택됨")
        #expect(AccessibilityText.agentValue(selected: false) == nil)
    }

    @Test("메뉴바 아이콘은 상태 점의 색 대신 묶음별 사람 수를 읽는다")
    func menuBar() {
        #expect(AccessibilityText.menuBar(.empty) == "Claude Office, 출근한 직원 없음")
        let roster = Self.roster([
            Self.row("a", status: .waitingForPermission), Self.row("b", status: .editing), Self.row("c", status: .thinking),
            Self.row("d", status: .idle), Self.row("e", status: .awaitingReply), Self.row("f", status: .unread),
        ])
        #expect(AccessibilityText.menuBar(roster) == "Claude Office, 승인 대기 1명, 답변 필요 1명, 일하는 중 2명, 새 응답 1명, 쉬는 중 1명")
    }

    @Test("현황 줄은 화면 밖 표시를 말로 바꾸고 줄을 마침표로 잇는다")
    func statusLine() {
        let now = Fixture.epoch.addingTimeInterval(12)
        let first = StatusLine.Line(colorIndex: 0, folder: "docs", head: "메인2", segment: .init(text: "승인 대기", tone: .attention, since: Fixture.epoch), offscreen: true)
        let second = StatusLine.Line(colorIndex: 1, head: "메인1", segment: .init(text: "쉬는 중", tone: .muted))
        #expect(AccessibilityText.statusLine(first, now: now) == "화면 밖, docs · 메인2 · 승인 대기 (12초째)")
        #expect(AccessibilityText.statusLines(StatusLine(mode: .office, lines: [first, second]), now: now)
            == "화면 밖, docs · 메인2 · 승인 대기 (12초째). 메인1 · 쉬는 중")
        #expect(AccessibilityText.statusLines(.empty, now: now) == "내용 없음")
    }

    @Test("미니 머리줄은 화면 문구와 다른 메인 칩을 값으로 읽는다 (M6(7b))")
    func miniHeader() {
        let chips = [
            AccessibilityText.miniChip(main: "메인2", tier: "답변 기다림"), AccessibilityText.miniChip(main: "메인3", tier: nil),
        ]
        #expect(AccessibilityText.miniHeader(status: "서브3: 생각 중 · 방금", chips: chips, more: 1)
            == "서브3: 생각 중 · 방금. 다른 메인: 메인2, 답변 기다림 · 메인3 · 외 1개")
        #expect(AccessibilityText.miniHeader(status: "메인: 쉬는 중 · 3분 전", chips: []) == "메인: 쉬는 중 · 3분 전")
        #expect(AccessibilityText.miniHeader(status: "", chips: ["메인2"]) == "다른 메인: 메인2")
        #expect(AccessibilityText.miniHeader(status: nil, chips: []) == "내용 없음")
    }

    @Test("승인 대기·답변 필요는 처음 생길 때 한 번만 알린다")
    func announcer() {
        var announcer = AccessibilityAnnouncer()
        // 앱을 켤 때 이미 기다리던 사람은 알리지 않음
        #expect(announcer.announcements(for: Self.roster([Self.row("a", status: .waitingForPermission)])).isEmpty)
        // 새로 생긴 승인 대기
        let waiting = Self.roster([
            Self.row("a", status: .waitingForPermission),
            Self.row("b", name: "서브", title: .sub(nil), status: .waitingForPermission, since: Fixture.epoch.addingTimeInterval(5)),
        ])
        #expect(announcer.announcements(for: waiting).map(\.text) == ["서브 승인 대기, claude-office"])
        #expect(announcer.announcements(for: waiting).isEmpty)
        // 답변 필요가 잠깐 새 응답으로 바뀌었다 돌아와도(같은 응답) 다시 알리지 않음
        let reply = Self.roster([Self.row("a", status: .awaitingReply, since: Fixture.epoch.addingTimeInterval(20))])
        #expect(announcer.announcements(for: reply).map(\.kind) == [.reply])
        #expect(announcer.announcements(for: Self.roster([Self.row("a", status: .unread, since: Fixture.epoch.addingTimeInterval(20))])).isEmpty)
        #expect(announcer.announcements(for: reply).isEmpty)
        // 다음 응답의 답변 필요는 다시 알림
        let next = Self.roster([Self.row("a", status: .awaitingReply, since: Fixture.epoch.addingTimeInterval(90))])
        #expect(announcer.announcements(for: next).map(\.text) == ["메인1 답변 필요, claude-office"])
    }

    @Test("거른 종류는 알리지 않지만 알린 것으로 친다")
    func announcerKinds() {
        var announcer = AccessibilityAnnouncer()
        _ = announcer.announcements(for: .empty)
        let waiting = Self.roster([Self.row("a", status: .waitingForPermission)])
        #expect(announcer.announcements(for: waiting, kinds: [.reply]).isEmpty)
        #expect(announcer.announcements(for: waiting).isEmpty)
        let two = [
            AccessibilityAnnouncer.Announcement(kind: .permission, text: "메인1 승인 대기, a"),
            AccessibilityAnnouncer.Announcement(kind: .reply, text: "메인2 답변 필요, b"),
        ]
        #expect(AccessibilityAnnouncer.sentence(two) == "메인1 승인 대기, a. 메인2 답변 필요, b")
        #expect(AccessibilityAnnouncer.sentence([]) == nil)
    }
}
