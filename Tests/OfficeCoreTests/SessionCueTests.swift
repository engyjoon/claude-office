import Foundation
import Testing

@testable import OfficeCore

/// M6(4): 응답을 끝낸 세션의 "답변 필요"(?)와 "확인 안 함"(✉) 표시.
/// 답변 필요는 쉬러 가지 않고 자기 책상에서 기다리고, 확인 안 함은 쉼 단계를 그대로 밟으며 배지만 답니다.
@Suite("답변 필요·확인 안 함 (M6(4))")
struct SessionCueTests {
    static let folder = "/Users/demo/work/claude-office"
    let hook = Hook(session: "s1", cwd: Self.folder)
    let lead = AgentID("lead-1")
    var seat: Spot { .seat(TeamID("\(Self.folder)#1"), .main) }

    func stop(_ message: String? = nil) -> JSONValue {
        hook.make("Stop", message.map { JSONObject([("last_assistant_message", .string($0))]) } ?? JSONObject())
    }

    var prompt: JSONValue { hook.make("UserPromptSubmit", JSONObject([("prompt", .string("다음"))])) }

    func cue(_ h: EngineHarness) -> SessionCue? { h.engine.state.agents[lead]?.cue }

    /// 지시 목록에서 마지막 배지
    func lastBadge(_ actions: [Directive.Action]) -> SessionCue?? {
        var badge: SessionCue??
        for case .badge(let value) in actions { badge = .some(value) }
        return badge
    }

    func roll(_ residents: [ResidentSession], at seconds: Double) -> ResidentRoll {
        ResidentRoll(
            residents: residents, openHostSessions: Set(residents.map(\.hostSession)), isReliable: true,
            readAt: Fixture.epoch.addingTimeInterval(seconds))
    }

    func resident(
        lastFocused: Double? = nil, focused: Bool = false, edge: Double? = nil, reply: Bool? = nil, session: String = "s1"
    ) -> ResidentSession {
        ResidentSession(
            session: SessionID(session), hostSession: "local_\(session)", rootCwd: Self.folder, title: "제목",
            lastActivity: edge.map { Fixture.epoch.addingTimeInterval($0) },
            lastFocused: lastFocused.map { Fixture.epoch.addingTimeInterval($0) }, isFocused: focused,
            lastTurnEdge: edge.map { Fixture.epoch.addingTimeInterval($0) }, replyRequest: reply)
    }

    // MARK: - 질문으로 끝났는지

    @Test("마지막 문장이 물음표거나 결정을 바라는 말이면 답변 필요", arguments: [
        ("A안과 B안 중 어느 쪽으로 할까요?", true),
        ("정리했어요.\n\n어느 안으로 구현할지 **골라 주세요**.", true),
        ("목업 4개를 만들었습니다. 추천은 D안입니다. 정해 주시면 구현할게요", false),
        ("커밋까지 마쳤어요.\n\n화면에서 배지가 보이는지 확인해 주세요.", false),
        ("Done. Should I push the branch too", true),
        ("Which one do you prefer?)", true),
        ("고쳤어요.\n\n```swift\nlet x = 1 // 왜?\n```", false),
        ("테스트 314개가 통과했어요.", false),
    ])
    func asksUser(message: String, expected: Bool) {
        #expect(ReplyRequest.asksUser(message) == expected)
    }

    @Test("Stop의 마지막 응답이 질문이면 turnEnded에 asksUser, 본문 없으면 아님")
    func parsesStop() throws {
        let asked = try #require(HookParser.parse(stop("이대로 갈까요?"), term: nil, receivedAt: Fixture.epoch))
        #expect(asked.kind == .turnEnded(failed: false, asksUser: true))
        let plain = try #require(HookParser.parse(stop(), term: nil, receivedAt: Fixture.epoch))
        #expect(plain.kind == .turnEnded(failed: false))
    }

    // MARK: - 상태

    @Test("질문으로 끝나면 답변 필요, 새 요청을 보내면 풀린다. 캐릭터를 눌러도 답변 필요는 그대로")
    func replyCue() {
        var h = EngineHarness()
        h.send(prompt, at: 0)
        #expect(cue(h) == nil)  // 응답 중
        h.send(stop("어느 쪽으로 할까요?"), at: 5)
        #expect(cue(h) == .reply)
        let rows = Roster.make(from: h.engine.state, privacy: .detailed).teams[0].rows
        #expect(rows[0].status == .awaitingReply && rows[0].status.tone == .reply)
        #expect(rows[0].since == Fixture.epoch.addingTimeInterval(5))

        _ = h.engine.acknowledge(SessionID("s1"), at: Fixture.epoch.addingTimeInterval(6))
        #expect(cue(h) == .reply)

        let directives = h.send(prompt, at: 10)
        #expect(cue(h) == nil)
        #expect(lastBadge(directives.filter { $0.agent == lead }.map(\.action)) == .some(nil))
    }

    @Test("그냥 끝나면 확인 안 함, 캐릭터를 누르면(확인) 풀린다")
    func unreadCue() {
        var h = EngineHarness()
        h.send(prompt, at: 0)
        let ended = h.send(stop("다 했어요."), at: 5)
        #expect(cue(h) == .unread)
        #expect(lastBadge(ended.filter { $0.agent == lead }.map(\.action)) == .some(.unread))
        #expect(RosterStatus.from(h.engine.state.agents[lead]!) == .unread)

        let seen = h.engine.acknowledge(SessionID("s1"), at: Fixture.epoch.addingTimeInterval(8))
        #expect(cue(h) == nil)
        #expect(lastBadge(seen.filter { $0.agent == lead }.map(\.action)) == .some(nil))
        // 이미 본 응답을 다시 확인해도 아무 일 없음
        #expect(h.engine.acknowledge(SessionID("s1"), at: Fixture.epoch.addingTimeInterval(9)).isEmpty)
    }

    @Test("서브에이전트와 승인 대기에는 배지가 붙지 않는다")
    func noCueWhileBusy() {
        var h = EngineHarness()
        h.send(prompt, at: 0)
        h.send(hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "general-purpose"]), at: 1)
        h.send(hook.make("SubagentStart", JSONObject([("agent_id", .string("g1")), ("agent_type", .string("general-purpose"))])), at: 1.2)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "rm -rf x"], agent: (id: "g1", type: "general-purpose")), at: 2)
        h.send(hook.tool("PermissionRequest", "Bash", id: nil, input: ["command": "rm -rf x"], agent: (id: "g1", type: "general-purpose")), at: 2.1)
        #expect(h.engine.state.agents.values.allSatisfy { $0.cue == nil })
    }

    // MARK: - 연출

    @Test("답변 필요는 1분·3분·10분이 지나도 쉬러 가지 않고 자기 책상에서 깨어 기다린다")
    func replyStaysAtDesk() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(prompt, at: 1)
        h.send(stop("이렇게 할까요?"), at: 2)
        let count = h.actions(of: lead).count
        h.advance(to: 700)
        let later = Array(h.actions(of: lead).dropFirst(count))
        #expect(h.engine.choreographer.spot(of: lead) == seat)
        #expect(!later.contains { if case .walk = $0 { true } else { false } })
        #expect(!later.contains(.pose(.sleeping)))
        #expect(lastBadge(h.actions(of: lead)) == .some(.reply))
        #expect(h.actions(of: lead).contains(.gesture(.tilt)))
        // 다시 그려도 배지가 그대로
        let agent = h.engine.state.agents[lead]!
        #expect(h.engine.choreographer.restoreDirectives(for: agent, entering: false).contains { $0.action == .badge(.reply) })
    }

    @Test("확인 안 함은 쉼 단계를 그대로 밟고 배지를 단다")
    func unreadRests() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(prompt, at: 1)
        h.send(stop(), at: 2)
        h.advance(to: 70)
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
        #expect(lastBadge(h.actions(of: lead)) == .some(.unread))
    }

    @Test("쉬러 간 뒤에 답변 필요가 되면(데스크톱 앱 요약이 늦게 옴) 자기 책상으로 돌아온다")
    func lateReplyReturnsToDesk() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        _ = h.engine.syncResidents(roll([resident()], at: 0), at: Fixture.epoch)
        h.send(prompt, at: 1)
        h.send(stop(), at: 2)
        h.advance(to: 70)
        #expect(h.engine.choreographer.spot(of: lead) == .lounge)
        let directives = h.engine.syncResidents(roll([resident(lastFocused: 0, reply: true)], at: 70), at: Fixture.epoch.addingTimeInterval(70))
        #expect(cue(h) == .reply)
        #expect(h.engine.choreographer.spot(of: lead) == seat)
        #expect(directives.contains { $0.agent == lead && $0.action == .badge(.reply) })
    }

    @Test("정리 중에는 배지를 내렸다가 압축이 끝나면 다시 단다")
    func compactionHidesCue() {
        var h = EngineHarness()
        h.send(prompt, at: 0)
        h.send(stop(), at: 1)
        #expect(cue(h) == .unread)
        h.send(hook.make("PreCompact", JSONObject([("trigger", .string("manual"))])), at: 100)
        #expect(cue(h) == nil)
        h.send(hook.make("SessionStart", JSONObject([("source", .string("compact"))])), at: 130)
        #expect(cue(h) == .unread)
    }

    // MARK: - 데스크톱 앱 정보

    @Test("데스크톱 앱에서 그 세션을 보고 있었으면 응답이 끝나도 확인 안 함이 아니다")
    func focusedSessionIsSeen() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        _ = h.engine.syncResidents(roll([resident(lastFocused: 0, focused: true)], at: 0), at: Fixture.epoch)
        h.send(prompt, at: 1)
        h.send(stop(), at: 5)
        #expect(cue(h) == nil)
    }

    @Test("다른 세션을 보는 동안 끝나면 확인 안 함, 그 세션을 열면(lastFocusedAt) 풀린다")
    func openingSessionClearsUnread() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        _ = h.engine.syncResidents(roll([resident(lastFocused: 0)], at: 0), at: Fixture.epoch)
        h.send(prompt, at: 1)
        h.send(stop(), at: 5)
        #expect(cue(h) == .unread)
        _ = h.engine.syncResidents(roll([resident(lastFocused: 4)], at: 6), at: Fixture.epoch.addingTimeInterval(6))
        #expect(cue(h) == .unread)  // 끝나기 전에 연 것
        _ = h.engine.syncResidents(roll([resident(lastFocused: 8)], at: 9), at: Fixture.epoch.addingTimeInterval(9))
        #expect(cue(h) == nil)
    }

    @Test("데스크톱 앱의 응답 요약이 오면 마지막 문장 판정보다 그것을 따른다 (응답 중에는 무시)")
    func desktopVerdictWins() {
        var h = EngineHarness()
        h.send(hook.make("SessionStart"), at: 0)
        h.send(prompt, at: 1)
        h.send(stop("이건 어떨까요?"), at: 5)
        #expect(cue(h) == .reply)
        _ = h.engine.syncResidents(roll([resident(reply: false)], at: 8), at: Fixture.epoch.addingTimeInterval(8))
        #expect(cue(h) == .unread)
        _ = h.engine.syncResidents(roll([resident(reply: true)], at: 9), at: Fixture.epoch.addingTimeInterval(9))
        #expect(cue(h) == .reply)
        // 다음 요청을 보낸 뒤(응답 중)에는 지난 응답의 요약을 따르지 않음
        h.send(prompt, at: 10)
        _ = h.engine.syncResidents(roll([resident(reply: true)], at: 11), at: Fixture.epoch.addingTimeInterval(11))
        #expect(cue(h) == nil)
        #expect(h.engine.state.parts[SessionID("s1")]?.replyRequested == false)
    }

    @Test("사무실에 오기 전에 끝난 데스크톱 세션도 조용히 앉으며 확인 안 함·답변 필요를 보여 준다")
    func settledResidents() throws {
        var h = EngineHarness()
        let directives = h.engine.syncResidents(roll([
            resident(lastFocused: 10, edge: 20, session: "a"),  // 연 뒤에 끝남 → 확인 안 함
            resident(lastFocused: 30, edge: 20, session: "b"),  // 끝난 뒤에 열어 봄
            resident(lastFocused: 10, edge: 20, reply: true, session: "c"),  // 답변 필요
        ], at: 100), at: Fixture.epoch.addingTimeInterval(100))
        let state = h.engine.state
        #expect(state.lead(of: SessionID("a"))?.cue == .unread)
        #expect(state.lead(of: SessionID("b"))?.cue == nil)
        let asker = try #require(state.lead(of: SessionID("c")))
        #expect(asker.cue == .reply)
        #expect(directives.contains { $0.agent == asker.id && $0.action == .badge(.reply) })
    }

    // MARK: - 현황 줄

    @Test("행 줄: 승인 대기 > 답변 필요 > 일하는 중 > 새 응답 > 쉬는 중")
    func statusLinePriority() {
        var h = EngineHarness()
        let side = Hook(session: "s2", cwd: Self.folder)
        h.send(prompt, at: 0)
        h.send(stop("다 했어요."), at: 2)
        func text(_ at: Double) -> [String] {
            StatusLine.make(state: h.engine.state, journal: h.engine.journal, privacy: .detailed, selected: nil, folder: nil)
                .texts(now: Fixture.epoch.addingTimeInterval(at))
        }
        #expect(text(3) == ["claude-office · 메인 · 새 응답 (방금)"])
        // 다른 행(CLI 세션은 각자 메인)이 일해도 이 행은 답변 필요
        h.send(side.make("UserPromptSubmit", JSONObject([("prompt", .string("x"))])), at: 4)
        h.send(prompt, at: 4.5)
        h.send(stop("어느 쪽이 좋을까요?"), at: 5)
        let line = StatusLine.make(state: h.engine.state, journal: h.engine.journal, privacy: .detailed, selected: nil, folder: nil)
        #expect(line.lines[0].segment.text == "답변 필요" && line.lines[0].segment.tone == .reply)
    }
}
