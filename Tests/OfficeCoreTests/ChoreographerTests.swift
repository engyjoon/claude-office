import Foundation
import Testing

@testable import OfficeCore

@Suite("연출 엔진")
struct ChoreographerTests {
    let hook = Hook()
    let lead = AgentID("lead-1")

    func started(_ h: inout EngineHarness) {
        h.send(hook.make("SessionStart"))
    }

    @Test("출근: 문에서 등장해 자리로 걸어가 앉고 인사한다")
    func arrival() {
        var h = EngineHarness()
        started(&h)
        let actions = h.actions(of: lead)
        guard case .spawn(_, .door) = actions.first else { Issue.record("\(actions)"); return }
        #expect(actions.walks == [.seat(TeamID("/Users/demo/work/a-sdn-portal#1"), .main)])
        #expect(actions.contains(.sit))
        #expect(actions.contains(.gesture(.wave)))
        #expect(h.all.sounds.contains(.door))
        #expect(h.all.contains { if case .openTeam(let team) = $0.action { team.name == "a-sdn-portal" } else { false } })
    }

    @Test("짧은 툴 호출이 연달아 와도 최소 유지 시간 동안은 바뀌지 않고, 최신 활동만 반영된다")
    func dwell() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/x/A.swift"]), at: 1)
        h.send(hook.tool("PostToolUse", "Edit", id: "e1", input: [:]), at: 1.1)
        h.send(hook.tool("PreToolUse", "Edit", id: "e2", input: ["file_path": "/x/B.swift"]), at: 1.2)
        h.send(hook.tool("PostToolUse", "Edit", id: "e2", input: [:]), at: 1.3)
        h.send(hook.tool("PreToolUse", "Edit", id: "e3", input: ["file_path": "/x/C.swift"]), at: 1.4)
        // 1.0초에 A가 보이고, 유지 시간(2.5초)이 지난 3.5초에 최신인 C가 반영됩니다
        let before = h.actions(of: lead).statusTexts
        #expect(before == ["Edit · A.swift"])
        h.advance(to: 3.6)
        #expect(h.actions(of: lead).statusTexts == ["Edit · A.swift", "Edit · C.swift"])
    }

    @Test("생각 중에서 작업으로 바뀔 때는 기다리지 않는다")
    func upgradeIsImmediate() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.make("UserPromptSubmit"), at: 1)
        let directives = h.send(hook.tool("PreToolUse", "Bash", id: "b", input: ["command": "ls"]), at: 1.2)
        #expect(directives.contains(Directive(lead, .status(StatusPill(category: .shell, text: "Bash · ls")))))
    }

    @Test("읽기가 10초 안에 5번 이어지면 책장으로 간다")
    func readBurst() {
        var h = EngineHarness()
        started(&h)
        for index in 0..<6 {
            let t = 1 + Double(index) * 1.5
            h.send(hook.tool("PreToolUse", "Read", id: "r\(index)", input: ["file_path": .string("/x/F\(index).swift")]), at: t)
            h.send(hook.tool("PostToolUse", "Read", id: "r\(index)", input: [:]), at: t + 0.1)
        }
        h.advance(to: 12)
        #expect(h.actions(of: lead).walks.contains(.bookshelf))
    }

    @Test("셸 명령이 2초를 넘기면 자기 책상에서 모니터를 보며 기다리고(⏳), 성공하면 반가운 표정을 짓는다")
    func longShellAtDesk() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "npm run build"]), at: 1)
        h.advance(to: 2.9)
        #expect(!h.actions(of: lead).contains(.pose(.watching)))
        h.advance(to: 3.1)
        let waiting = h.actions(of: lead)
        #expect(waiting.contains(.pose(.watching)))
        #expect(waiting.contains(.emote(.hourglass)))
        // 서버랙(사라짐)이나 다른 구역으로 가지 않고 자기 자리에 그대로
        #expect(waiting.walks == [.seat(TeamID("/Users/demo/work/a-sdn-portal#1"), .main)])
        #expect(h.engine.choreographer.spot(of: lead) == .seat(TeamID("/Users/demo/work/a-sdn-portal#1"), .main))
        let done = h.send(hook.tool("PostToolUse", "Bash", id: "b1", input: [:]), at: 8)
        #expect(done.contains(Directive(lead, .emote(nil))))
        #expect(done.contains(Directive(lead, .express(.happy))))
    }

    @Test("책상에서 기다리던 긴 명령이 실패하면 ⏳를 내리고 곤란한 표정")
    func longShellFails() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "swift test"]), at: 1)
        h.advance(to: 4)
        let failed = h.send(hook.tool("PostToolUseFailure", "Bash", id: "b1", input: [:], extra: [("error", "x")]), at: 9)
        #expect(failed.contains(Directive(lead, .emote(.sweat))))
        #expect(failed.contains(Directive(lead, .express(.troubled))))
        #expect(!failed.contains(Directive(lead, .express(.happy))))
    }

    @Test("빨리 끝난 셸 명령은 자리에서 처리한다")
    func quickShellStays() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "git status"]), at: 1)
        h.send(hook.tool("PostToolUse", "Bash", id: "b1", input: [:]), at: 1.3)
        h.advance(to: 6)
        #expect(!h.actions(of: lead).contains(.pose(.watching)))
        #expect(!h.actions(of: lead).contains(.emote(.hourglass)))
    }

    @Test("승인 대기: 대기열을 비우고 일어나 손을 들고, 노크는 30초마다 최대 3번")
    func permission() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Bash", id: "b", input: ["command": "npm test"]), at: 1)
        let asked = h.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "npm test"]), at: 1.2)
        #expect(asked.first == Directive(lead, .clearQueue))
        #expect(asked.contains(Directive(lead, .pose(.raisingHand))))
        #expect(asked.contains(Directive(lead, .emote(.exclamation))))
        let shout = asked.bubbles.first
        #expect(shout?.kind == .shout)
        #expect(shout?.duration == nil)
        #expect(shout?.text.contains("npm test") == true)
        h.advance(to: 200)
        #expect(h.all.sounds.filter { $0 == .knock }.count == 3)

        // 승인되어 명령이 끝나면 외침 풍선을 닫고 앉습니다
        let resolved = h.send(hook.tool("PostToolUse", "Bash", id: "b", input: [:]), at: 201)
        #expect(resolved.contains(Directive(lead, .dismissBubble)))
        #expect(resolved.contains(Directive(lead, .sit)))
    }

    @Test("위임: 팀장이 부탁하고, 팀원이 옆에 왔다가 자리로 간다. 보고는 신호로 맞춘다")
    func delegationDialogue() throws {
        var h = EngineHarness()
        started(&h)
        h.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["description": "RouterConfig 리뷰", "subagent_type": "code-reviewer"]), at: 1)
        let member = AgentID("member-2")
        let leadLine = try #require(h.actions(of: lead).bubbles.last)
        #expect(leadLine.text.contains("RouterConfig") || leadLine.text.contains("code-reviewer") || leadLine.text.contains("부탁") || leadLine.text.contains("맡아"))
        let memberActions = h.actions(of: member)
        #expect(memberActions.walks.first == .beside(lead))
        #expect(memberActions.walks.last == .seat(TeamID("/Users/demo/work/a-sdn-portal#1"), Seat(desk: 1)))
        #expect(memberActions.contains(.gesture(.nod)))

        h.send(hook.make("SubagentStart", ["agent_id": "x1", "agent_type": "code-reviewer"]), at: 1.2)
        h.send(hook.make("SubagentStop", ["agent_id": "x1", "agent_type": "code-reviewer"]), at: 10)
        let report = h.actions(of: member)
        let signal = "report:member-2"
        #expect(report.contains(.signal(signal)))
        #expect(report.contains(.gesture(.highFive)))
        #expect(report.last == .despawn)
        #expect(h.actions(of: lead).contains(.await(signal, timeout: 8)))
        #expect(h.all.sounds.contains(.memberReport))
        #expect(!h.engine.choreographer.isPresent(member))
    }

    @Test("쉼 단계: 1분 → 휴게 공간, 3분 → 안마 의자, 10분 → 안마 의자에서 잠듦. 새 프롬프트가 오면 깬다")
    func restStages() {
        var h = EngineHarness()
        started(&h)
        h.send(hook.make("Stop"), at: 1)
        h.advance(to: 62)
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
        h.advance(to: 182)
        #expect(h.engine.choreographer.spot(of: lead) == .massageChair)
        #expect(h.actions(of: lead).contains(.pose(.massage)))
        h.advance(to: 602)
        #expect(h.actions(of: lead).contains(.pose(.sleeping)))
        #expect(h.engine.choreographer.spot(of: lead) == .massageChair)
        let woke = h.send(hook.make("UserPromptSubmit"), at: 610)
        #expect(woke.contains(Directive(lead, .emote(nil))))
        #expect(woke.contains(Directive(nil, .effect(.paperPlane(to: lead)))))
    }

    @Test("휴게실에 두 명 이상 있으면 가끔 속삭인다")
    func chatter() {
        var h = EngineHarness()
        h.send(Hook(session: "s1").make("Stop"), at: 0)
        h.send(Hook(session: "s2", cwd: "/w/other").make("Stop"), at: 0)
        h.advance(to: 130)
        #expect(h.all.bubbles.contains { $0.kind == .whisper })
    }

    @Test("오류: 곤란한 표정, 머리 긁적, 땀방울. 세 번째부터는 슬픈 표정")
    func errors() {
        var h = EngineHarness()
        started(&h)
        let first = h.send(hook.tool("PostToolUseFailure", "Read", id: "r1", input: [:], extra: [("error", "x")]), at: 1)
        #expect(first.contains(Directive(lead, .express(.troubled))))
        #expect(first.contains(Directive(lead, .gesture(.scratchHead))))
        #expect(first.sounds.contains(.error))
        h.send(hook.tool("PostToolUseFailure", "Read", id: "r2", input: [:], extra: [("error", "x")]), at: 2)
        let third = h.send(hook.tool("PostToolUseFailure", "Read", id: "r3", input: [:], extra: [("error", "x")]), at: 3)
        #expect(third.contains(Directive(lead, .express(.sad))))
    }

    @Test("표시 수준: 상세는 파일명, 요약은 툴 종류, 비공개는 상태 칩 없음", arguments: [
        (PrivacyLevel.detailed, "Edit · Secret.swift" as String?), (.summary, "파일 편집 중"), (.hidden, nil),
    ])
    func privacy(_ level: PrivacyLevel, _ expected: String?) {
        var h = EngineHarness(privacy: level)
        started(&h)
        let directives = h.send(hook.tool("PreToolUse", "Edit", id: "e", input: ["file_path": "/x/Secret.swift"]), at: 1)
        let pill = directives.compactMap { if case .status(let pill) = $0.action { pill } else { nil } }.first
        #expect(pill?.text == expected)
        if level != .detailed {
            let asked = h.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "deploy-prod.sh"]), at: 2)
            #expect(asked.bubbles.allSatisfy { !$0.text.contains("deploy") })
        }
    }

    @Test("세션 종료: 인사하고 문으로 나가 사라진다")
    func leaving() {
        var h = EngineHarness()
        started(&h)
        let directives = h.send(hook.make("SessionEnd"), at: 5)
        #expect(directives.first == Directive(lead, .clearQueue))
        #expect(directives.dropLast().last == Directive(lead, .despawn))
        #expect(directives.last?.action == .closeTeam(TeamID("/Users/demo/work/a-sdn-portal#1")))
        #expect(directives.contains(Directive(lead, .walk(to: .door))))
        #expect(!h.engine.choreographer.isPresent(lead))
    }

    @Test("같은 시드면 같은 연출이 나온다")
    func deterministic() {
        func run() -> [Directive] {
            var h = EngineHarness(seed: 42)
            h.send(Hook().make("SessionStart"))
            h.send(Hook().make("UserPromptSubmit"), at: 1)
            h.send(Hook().tool("PreToolUse", "Agent", id: "a", input: ["subagent_type": "general-purpose"]), at: 2)
            h.advance(to: 10)
            return h.all
        }
        #expect(run() == run())
    }
}

@Suite("연출 엔진 세부 규칙")
struct ChoreographerDetailTests {
    let hook = Hook()
    let lead = AgentID("lead-1")

    @Test("책장에 있다가 위임하면 팀장이 먼저 자리로 돌아오고, 팀원은 팀장 자리로 찾아온다")
    func delegateFromDesk() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        for index in 0..<5 {
            h.send(hook.tool("PreToolUse", "Read", id: "r\(index)", input: [:]), at: 1 + Double(index))
        }
        h.advance(to: 7)
        #expect(h.engine.choreographer.spot(of: lead) == .bookshelf)
        h.send(hook.tool("PreToolUse", "Agent", id: "a", input: ["description": "리뷰", "subagent_type": "code-reviewer"]), at: 8)
        #expect(h.engine.choreographer.spot(of: lead) == .seat(TeamID("/Users/demo/work/a-sdn-portal#1"), .main))
        #expect(h.actions(of: lead).bubbles.last?.text.contains("리뷰") == true)
    }

    @Test("응답이 끝나면 앉은 자세로 돌아가고, 퇴근할 때는 소품과 아이콘을 내려놓는다")
    func cleanUp() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"))
        h.send(hook.tool("PreToolUse", "Read", id: "r", input: [:]), at: 1)
        let ended = h.send(hook.make("Stop"), at: 2)
        #expect(ended.contains(Directive(lead, .pose(.sitting))))
        h.advance(to: 70)
        let left = h.send(hook.make("SessionEnd"), at: 71)
        #expect(left.contains(Directive(lead, .emote(nil))))
        #expect(left.contains(Directive(lead, .prop(nil))))
    }
}
