import Foundation
import Testing

@testable import OfficeCore

@Suite("메뉴바 목록 (로스터)")
struct RosterTests {
    let hook = Hook()

    func state(_ payloads: [JSONValue]) -> OfficeState {
        var state = OfficeState()
        for (index, payload) in payloads.enumerated() {
            _ = state.apply(HookParser.parse(payload, term: "iTerm.app", receivedAt: Fixture.epoch.addingTimeInterval(Double(index)))!)
        }
        return state
    }

    @Test("비어 있으면 empty, 쉬는 중이면 idle")
    func moods() {
        #expect(Roster.make(from: OfficeState(), privacy: .detailed).mood == .empty)
        let idle = state([hook.make("SessionStart"), hook.make("Stop")])
        #expect(Roster.make(from: idle, privacy: .detailed).mood == .idle)
    }

    @Test("개선 8: 일하는 사람 없이 답변 필요만 남으면 reply (작업 중이 아님). 승인 대기 > 작업 중 > 답변 필요 > 쉬는 중")
    func replyMood() {
        typealias A = AccessibilityTextTests
        #expect(A.roster([A.row("a", status: .awaitingReply, detail: nil)]).mood == .reply)
        #expect(A.roster([A.row("a", status: .awaitingReply, detail: nil), A.row("b", status: .idle), A.row("c", status: .unread)]).mood == .reply)
        #expect(A.roster([A.row("a", status: .awaitingReply, detail: nil), A.row("b", status: .editing)]).mood == .working)
        #expect(A.roster([A.row("a", status: .awaitingReply, detail: nil), A.row("b", status: .waitingForPermission)]).mood == .attention)
        #expect(A.roster([A.row("a", status: .unread), A.row("b", status: .idle)]).mood == .idle)
        // VoiceOver 문구도 "답변 필요"로 읽습니다 (메뉴바 점의 파랑과 같은 뜻)
        #expect(AccessibilityText.menuBar(A.roster([A.row("a", status: .awaitingReply, detail: nil)])) == "Claude Office, 답변 필요 1명")
    }

    @Test("메인이 먼저, 서브는 책상 순서. 상태와 대상이 보인다")
    func rows() throws {
        let s = state([
            hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]),
            hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/DeviceService.java"], agent: (id: "r1", type: "code-reviewer")),
        ])
        let roster = Roster.make(from: s, privacy: .detailed)
        #expect(roster.mood == .working)
        let team = try #require(roster.teams.first)
        #expect(team.name == "a-sdn-portal")
        #expect(team.rows.map(\.name) == ["메인", "서브"])
        #expect(team.label == "메인 · a-sdn-portal")
        #expect(team.rows[1].agentType == "code-reviewer")
        #expect(team.rows[1].kind == .fixed)
        #expect(team.rows[0].status == .delegating)
        #expect(team.rows[0].term == "iTerm.app")
        #expect(team.rows[1].status == .editing)
        #expect(team.rows[1].detail == "DeviceService.java")
        #expect(team.rows[1].status.label == "편집 중")
    }

    @Test("백그라운드로 맡기고 응답을 끝낸 세션: 세션은 쉬는 중이고, 맡긴 서브는 그 세션의 '맡긴 일'로 남아 일한다 (2026-11-19)")
    func delegatesOfIdleSession() throws {
        let architect = (id: "x1", type: "architect")
        let s = state([
            hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "2차 검토", "subagent_type": "architect", "run_in_background": true]),
            hook.tool("PostToolUse", "Agent", id: "a1", input: ["description": "2차 검토", "subagent_type": "architect", "run_in_background": true]),
            hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "git diff"], agent: architect),
            hook.tool("PostToolUse", "Bash", id: "b1", input: ["command": "git diff"], agent: architect),
            hook.make("Stop"),
        ])
        let team = try #require(Roster.make(from: s, privacy: .detailed).teams.first)
        let main = try #require(team.rows.first)
        // 응답을 끝냈고 아직 보지 않음 (쉬는 쪽 톤)
        #expect(main.status == .unread)
        #expect(main.status.tone == .calm)
        let delegates = team.subagents(calledBy: main)
        #expect(delegates.map(\.agentType) == ["architect"])
        #expect(delegates.first?.status == .thinking)
        // 서브에이전트는 맡긴 일이 없습니다
        #expect(team.subagents(calledBy: try #require(delegates.first)).isEmpty)
    }

    @Test("클릭한 직원의 행과 팀을 id로 찾는다")
    func lookup() throws {
        let s = state([
            hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]),
            hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/DeviceService.java"], agent: (id: "r1", type: "code-reviewer")),
        ])
        let roster = Roster.make(from: s, privacy: .detailed)
        let member = try #require(roster.teams.first?.rows.last)
        #expect(roster.row(for: member.id)?.name == "서브")
        #expect(roster.team(of: member.id)?.name == "a-sdn-portal")
        #expect(roster.row(for: AgentID("없는 직원")) == nil)
        #expect(roster.team(of: AgentID("없는 직원")) == nil)
    }

    @Test("승인 대기는 따로 모으고 mood는 attention")
    func waiting() throws {
        let s = state([hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"])])
        let roster = Roster.make(from: s, privacy: .detailed)
        #expect(roster.mood == .attention)
        let row = try #require(roster.waiting.first)
        #expect(row.detail == "Bash · npm test")
        #expect(row.status.tone == .attention)
    }

    @Test("표시 수준이 상세가 아니면 대상과 맡은 일을 숨긴다", arguments: [PrivacyLevel.summary, .hidden])
    func privacy(_ level: PrivacyLevel) {
        let s = state([
            hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "비밀 작업", "subagent_type": "code-reviewer"]),
            hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "deploy.sh"]),
        ])
        let rows = Roster.make(from: s, privacy: level).teams.flatMap(\.rows)
        #expect(rows.allSatisfy { $0.detail == nil })
    }

    @Test("모든 활동에 한국어 상태 이름이 있다")
    func labels() {
        for status in RosterStatus.allCases {
            #expect(!status.label.isEmpty)
        }
    }
}
