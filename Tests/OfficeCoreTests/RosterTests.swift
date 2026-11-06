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

    @Test("팀장이 먼저, 팀원은 자리 순서. 상태와 대상이 보인다")
    func rows() throws {
        let s = state([
            hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]),
            hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/DeviceService.java"], agent: (id: "r1", type: "code-reviewer")),
        ])
        let roster = Roster.make(from: s, privacy: .detailed)
        #expect(roster.mood == .working)
        let team = try #require(roster.teams.first)
        #expect(team.name == "a-sdn-portal")
        #expect(team.rows.map(\.name) == ["팀장", "code-reviewer"])
        #expect(team.rows[0].status == .delegating)
        #expect(team.rows[0].term == "iTerm.app")
        #expect(team.rows[1].status == .editing)
        #expect(team.rows[1].detail == "DeviceService.java")
        #expect(team.rows[1].status.label == "편집 중")
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
