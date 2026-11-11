import Foundation
import Testing

@testable import OfficeCore

@Suite("세션으로 이동할 곳 (개선 6, 설계서 §10.3)")
struct SessionDestinationTests {
    static func row(term: String?, hostSession: String?) -> RosterRow {
        RosterRow(
            id: AgentID("a"), name: "메인1", role: .lead, title: .main(1), seat: .main, sessionTitle: nil, calledBy: nil,
            mainName: "메인1", agentType: nil, kind: .lead, status: .idle, detail: nil, since: Fixture.epoch,
            appearance: .make(key: "a", kind: .lead), teamName: "claude-office", session: SessionID("s"), term: term,
            hostSession: hostSession)
    }

    @Test("데스크톱 앱 세션이면 터미널 값이 있어도 앱으로 간다")
    func desktopFirst() throws {
        let destination = try #require(SessionDestination.resolve(hostSession: "local_abc", term: "vscode"))
        #expect(destination.kind == .desktopApp(session: "local_abc"))
        #expect(destination.bundleIDs == [SessionDestination.desktopBundleID])
        #expect(destination.label == "앱으로")
        #expect(destination.displayName == "Claude 데스크톱 앱")
        #expect(destination.buttonHelp == "Claude 데스크톱 앱에서 이 세션을 열어요")
        #expect(destination.doubleClickHelp == "더블클릭하면 앱으로 이동")
    }

    @Test("아는 터미널이면 터미널로, 이름은 사람이 읽는 이름")
    func knownTerminal() throws {
        let iterm = try #require(SessionDestination.resolve(hostSession: nil, term: "iTerm.app"))
        #expect(iterm.kind == .terminal(term: "iTerm.app"))
        #expect(iterm.label == "터미널로")
        #expect(iterm.displayName == "iTerm2")
        #expect(iterm.buttonHelp == "iTerm2 창을 앞으로 가져와요")
        let wez = try #require(SessionDestination.resolve(hostSession: nil, term: "WezTerm"))
        #expect(wez.displayName == "WezTerm")
    }

    @Test("VS Code 계열은 구별할 수 없어 VS Code → Insiders → Cursor 순서의 후보를 모두 둔다")
    func vscodeFamily() throws {
        let code = try #require(SessionDestination.resolve(hostSession: nil, term: "vscode"))
        #expect(code.bundleIDs == ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"])
        #expect(code.displayName == "VS Code")
    }

    @Test("모르는 터미널(tmux·zed)이나 빈 값이면 갈 곳이 없다")
    func unknown() {
        #expect(SessionDestination.resolve(hostSession: nil, term: "tmux") == nil)
        #expect(SessionDestination.resolve(hostSession: nil, term: "zed") == nil)
        #expect(SessionDestination.resolve(hostSession: nil, term: nil) == nil)
        #expect(SessionDestination.resolve(hostSession: "", term: nil) == nil)
        // 보여 주기용 이름은 모르는 값도 그대로 (어디서 연 세션인지는 알려 줌)
        #expect(SessionDestination.displayName(term: "tmux") == "tmux")
        #expect(SessionDestination.displayName(term: "") == nil)
    }

    @Test("명단 줄의 이동 가능 여부와 문구는 갈 곳을 따른다")
    func rosterRow() {
        let tmux = Self.row(term: "tmux", hostSession: nil)
        #expect(!tmux.canFocus)
        #expect(tmux.focusLabel == nil)
        #expect(tmux.destination == nil)
        let terminal = Self.row(term: "Apple_Terminal", hostSession: nil)
        #expect(terminal.canFocus)
        #expect(terminal.focusLabel == "터미널로")
        #expect(terminal.destination?.displayName == "터미널")
        let desktop = Self.row(term: nil, hostSession: "local_1")
        #expect(desktop.focusLabel == "앱으로")
    }
}
