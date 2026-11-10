import Testing

@testable import OfficeServer

@Suite("디렉토리 고르기 항목 (드롭다운·미니 메뉴, M6(18))")
struct DirectoryChoiceTests {
    let open = [DesktopFolder(path: "/w/a-sdn", sessions: 2), DesktopFolder(path: "/w/claude-office", sessions: 3)]
    let counts: [String: (mains: Int, people: Int)] = ["/w/a-sdn": (1, 3), "/w/claude-office": (2, 7)]

    func list(selected: String?, open: [DesktopFolder]? = nil, total: Int = 10) -> [DirectoryChoice] {
        DirectoryChoice.list(open: open ?? self.open, selected: selected, total: total) { counts[$0] ?? (0, 0) }
    }

    @Test("모두를 맨 앞에, 열린 디렉토리는 받은 순서대로, 인원을 붙인다")
    func labels() {
        let choices = list(selected: nil)
        #expect(choices.map(\.title) == ["모두 · 10명", "a-sdn · 3명", "claude-office · 메인 2 · 7명"])
        #expect(choices.map(\.path) == [nil, "/w/a-sdn", "/w/claude-office"])
        #expect(choices.map(\.isSelected) == [true, false, false])
    }

    @Test("고른 디렉토리에 체크, 사람이 없으면 인원을 붙이지 않는다")
    func selection() {
        let choices = list(selected: "/w/a-sdn", total: 0)
        #expect(choices.map(\.isSelected) == [false, true, false])
        #expect(choices[0].title == "모두")
    }

    @Test("데스크톱 앱에서 닫힌 디렉토리를 골라 두었으면 맨 끝에 (닫힘)으로 남긴다")
    func closed() {
        let choices = list(selected: "/w/old")
        #expect(choices.count == 4)
        #expect(choices.last == DirectoryChoice(title: "old (닫힘)", path: "/w/old", isSelected: true, isClosed: true))
        #expect(!choices.dropLast().contains { $0.isClosed })
    }

    @Test("열린 디렉토리가 없으면 모두만")
    func empty() {
        let choices = list(selected: nil, open: [], total: 0)
        #expect(choices == [DirectoryChoice(title: "모두", path: nil, isSelected: true)])
    }
}
