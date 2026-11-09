import Foundation
import Testing

@testable import OfficeCore

@Suite("알림 판단 (M5(3))")
struct NotificationPlannerTests {
    let hook = Hook()
    let reviewer = (id: "r1", type: "code-reviewer")

    /// 훅을 엔진에 넣고 그때 나온 알림 동작을 돌려줍니다
    struct Office {
        var engine: OfficeEngine
        var clock = 0.0

        init(privacy: PrivacyLevel = .detailed, settings: NotificationSettings = .init()) {
            engine = OfficeEngine(privacy: privacy, seed: 7)
            engine.notificationSettings = settings
        }

        @discardableResult
        mutating func send(_ payload: JSONValue, hint: SessionHint? = nil) -> [NoticeAction] {
            clock += 1
            var event = HookParser.parse(payload, term: "iTerm.app", receivedAt: Fixture.epoch.addingTimeInterval(clock))!
            event.hint = hint
            _ = engine.handle(event)
            return engine.drainNotices()
        }
    }

    func posts(_ actions: [NoticeAction]) -> [OfficeNotice] {
        actions.compactMap { if case .post(let notice) = $0 { notice } else { nil } }
    }

    func removed(_ actions: [NoticeAction]) -> [String] {
        actions.flatMap { action -> [String] in
            if case .remove(let ids) = action { return ids }
            return []
        }
    }

    func npmTest(_ hookName: String, id: String? = nil, agent: (id: String, type: String)? = nil) -> JSONValue {
        hook.tool(hookName, "Bash", id: id, input: ["command": "npm test"], agent: agent)
    }

    // MARK: - 승인 대기

    @Test("대기가 시작되면 알림 한 번: 직함 · 디렉토리 · 도구와 명령")
    func permissionOnce() throws {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "테스트 돌려 줘"]))
        office.send(npmTest("PreToolUse", id: "b1"))
        let asked = posts(office.send(npmTest("PermissionRequest")))
        let notice = try #require(asked.first)
        #expect(asked.count == 1)
        #expect(notice.kind == .permission)
        #expect(notice.title == "메인 승인 대기")
        #expect(notice.subtitle == "a-sdn-portal")
        #expect(notice.body == "Bash npm test · 승인이 필요해요")
        #expect(notice.term == "iTerm.app")
        #expect(notice.hostSession == nil)
        #expect(!notice.isUpdate)
        #expect(office.engine.notices.openPermissionCount == 1)
    }

    @Test("같은 대기에 다시 오는 훅(Notification)에는 알림을 또 띄우지 않음")
    func noDuplicate() {
        var office = Office()
        office.send(npmTest("PreToolUse", id: "b1"))
        #expect(posts(office.send(npmTest("PermissionRequest"))).count == 1)
        let again = office.send(hook.make("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"]))
        #expect(again.isEmpty)
        #expect(office.send(npmTest("PermissionRequest")).isEmpty)
    }

    @Test("Notification이 먼저 와서 도구를 몰랐으면, PermissionRequest가 오면 같은 알림의 내용만 조용히 보강")
    func upgradeLater() throws {
        var office = Office()
        let first = try #require(posts(office.send(hook.make("Notification", ["notification_type": "permission_prompt", "message": "x"]))).first)
        #expect(first.body == "승인이 필요해요")
        let second = try #require(posts(office.send(npmTest("PermissionRequest"))).first)
        #expect(second.id == first.id)
        #expect(second.isUpdate)
        #expect(second.body == "Bash npm test · 승인이 필요해요")
    }

    @Test("승인 뒤 도구가 끝나면 대기가 풀리고 알림을 지움")
    func clearedOnFinish() throws {
        var office = Office()
        office.send(npmTest("PreToolUse", id: "b1"))
        let id = try #require(posts(office.send(npmTest("PermissionRequest"))).first?.id)
        let done = office.send(hook.tool("PostToolUse", "Bash", id: "b1", input: ["command": "npm test"], extra: [("tool_response", [:])]))
        #expect(removed(done) == [id])
        #expect(office.engine.notices.openPermissionCount == 0)
        #expect(Roster.make(from: office.engine.state, privacy: .detailed).waiting.isEmpty)
        // 다음 대기는 새 알림 (새 식별자)
        office.send(npmTest("PreToolUse", id: "b2"))
        let next = try #require(posts(office.send(npmTest("PermissionRequest"))).first)
        #expect(next.id != id)
    }

    @Test("병렬로 돌던 다른 도구가 끝나도 기다리는 승인은 그대로")
    func otherToolDoesNotClear() {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Read", id: "r1", input: ["file_path": "/w/a.ts"]))
        office.send(npmTest("PreToolUse", id: "b1"))
        office.send(npmTest("PermissionRequest"))
        let other = office.send(hook.tool("PostToolUse", "Read", id: "r1", input: ["file_path": "/w/a.ts"], extra: [("tool_response", [:])]))
        #expect(removed(other).isEmpty)
        #expect(office.engine.notices.openPermissionCount == 1)
    }

    @Test("거부·새 요청·응답 끝·퇴근하면 알림을 지움")
    func clearedOtherwise() throws {
        let releases: [JSONValue] = [
            hook.tool("PermissionDenied", "Bash", id: "b1", input: ["command": "npm test"]),
            hook.make("UserPromptSubmit", ["prompt": "다른 걸 해 줘"]),
            hook.make("Stop"),
            hook.make("SessionEnd", ["reason": "exit"]),
        ]
        for release in releases {
            var office = Office()
            office.send(npmTest("PreToolUse", id: "b1"))
            let id = try #require(posts(office.send(npmTest("PermissionRequest"))).first?.id)
            #expect(removed(office.send(release)) == [id])
        }
    }

    @Test("서브에이전트의 승인 대기도 그 사람의 직함으로")
    func subagent() throws {
        var office = Office()
        office.send(hook.tool("PreToolUse", "Agent", id: "t1", input: ["subagent_type": "code-reviewer", "description": "리뷰"]))
        office.send(hook.make("SubagentStart", agent: reviewer))
        office.send(npmTest("PreToolUse", id: "b1", agent: reviewer))
        let notice = try #require(posts(office.send(npmTest("PermissionRequest", agent: reviewer))).first)
        #expect(notice.title == "서브 승인 대기")
        #expect(office.engine.state.agents[notice.agent]?.role == .member)
    }

    @Test("메인이 여럿이면 번호 붙은 직함")
    func numberedTitle() throws {
        var office = Office()
        office.send(hook.make("SessionStart", ["source": "startup"]))
        var other = hook
        other.session = "s2"
        other.cwd = "/Users/demo/work/claude-office"
        office.send(other.tool("PreToolUse", "Bash", id: "x", input: ["command": "make test"]))
        let notice = try #require(posts(office.send(other.tool("PermissionRequest", "Bash", id: nil, input: ["command": "make test"]))).first)
        #expect(notice.title == "메인2 승인 대기")
        #expect(notice.subtitle == "claude-office")
    }

    @Test("표시 수준: 요약·비공개면 명령을 숨기고 도구 종류만")
    func privacy() throws {
        for level in [PrivacyLevel.summary, .hidden] {
            var office = Office(privacy: level)
            office.send(hook.tool("PreToolUse", "Edit", id: "e1", input: ["file_path": "/w/secret/auth.ts"]))
            let notice = try #require(posts(office.send(hook.tool("PermissionRequest", "Edit", id: nil, input: ["file_path": "/w/secret/auth.ts"]))).first)
            #expect(notice.body == "Edit · 승인이 필요해요")
            #expect(!notice.body.contains("auth.ts"))
            #expect(notice.subtitle == "a-sdn-portal")
        }
        var detailed = Office()
        let shown = try #require(posts(detailed.send(hook.tool("PermissionRequest", "Edit", id: nil, input: ["file_path": "/w/secret/auth.ts"]))).first)
        #expect(shown.body == "Edit auth.ts · 승인이 필요해요")
    }

    @Test("승인 대기 알림을 끄면 띄우지 않음")
    func permissionOff() {
        var office = Office(settings: NotificationSettings(permission: false))
        office.send(npmTest("PreToolUse", id: "b1"))
        #expect(office.send(npmTest("PermissionRequest")).isEmpty)
        #expect(office.engine.notices.openPermissionCount == 0)
    }

    @Test("데스크톱 앱 세션이면 알림에 데스크톱 세션 id")
    func hostSession() throws {
        var office = Office()
        let hint = SessionHint(hostSession: "local_abc", title: "알림 만들기")
        office.send(npmTest("PreToolUse", id: "b1"), hint: hint)
        let notice = try #require(posts(office.send(npmTest("PermissionRequest"), hint: hint)).first)
        #expect(notice.hostSession == "local_abc")
    }

    // MARK: - 응답 완료

    @Test("응답 완료(Stop) 알림은 기본으로 꺼져 있음")
    func completionOffByDefault() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        #expect(office.send(hook.make("Stop")).isEmpty)
    }

    @Test("응답 완료 알림을 켜면 세션마다 하나, 새 요청이 오면 지움")
    func completionOn() throws {
        var office = Office(settings: NotificationSettings(permission: true, completion: true))
        let hint = SessionHint(hostSession: "local_abc", title: "알림 만들기")
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]), hint: hint)
        let done = try #require(posts(office.send(hook.make("Stop"))).first)
        #expect(done.kind == .completion)
        #expect(done.title == "메인 응답 완료")
        #expect(done.subtitle == "a-sdn-portal")
        #expect(done.body == "알림 만들기 · 응답을 마쳤어요")
        // 같은 세션의 다음 완료는 같은 식별자로 바꿔 끼움
        #expect(removed(office.send(hook.make("UserPromptSubmit", ["prompt": "y"]))) == [done.id])
        #expect(posts(office.send(hook.make("Stop"))).first?.id == done.id)
        // 요약이면 세션 제목을 숨김
        office.engine.privacy = .summary
        office.send(hook.make("UserPromptSubmit", ["prompt": "z"]))
        #expect(posts(office.send(hook.make("Stop"))).first?.body == "응답을 마쳤어요")
    }

    @Test("서브에이전트의 보고는 응답 완료 알림이 아님")
    func subagentStopIsNotCompletion() {
        var office = Office(settings: NotificationSettings(permission: true, completion: true))
        office.send(hook.tool("PreToolUse", "Agent", id: "t1", input: ["subagent_type": "code-reviewer", "description": "리뷰"]))
        office.send(hook.make("SubagentStart", agent: reviewer))
        #expect(posts(office.send(hook.make("SubagentStop", agent: reviewer))).isEmpty)
    }

    // MARK: - 직함이 바뀌면 알림 제목도 (M6(14))

    /// 서브에이전트 넷을 부르고 각자 출근시킴 (서브1~4)
    func fourSubs(_ office: inout Office) -> [(id: String, type: String)] {
        let subs = (1...4).map { (id: "g\($0)", type: "worker-\($0)") }
        for (index, sub) in subs.enumerated() {
            office.send(hook.tool("PreToolUse", "Agent", id: "t\(index + 1)", input: ["subagent_type": .string(sub.type), "description": "일"]))
            office.send(hook.make("SubagentStart", agent: sub))
        }
        return subs
    }

    @Test("승인 대기 중인 서브가 빈 책상으로 옮겨 앉아 번호가 바뀌면, 같은 알림의 제목만 조용히 바꾼다")
    func retitledWhenRenumbered() throws {
        var office = Office()
        let subs = fourSubs(&office)
        office.send(npmTest("PreToolUse", id: "b1", agent: subs[3]))
        let asked = try #require(posts(office.send(npmTest("PermissionRequest", agent: subs[3]))).first)
        #expect(asked.title == "서브4 승인 대기")

        // 서브1이 퇴근 → 서브4가 1번 책상으로 옮겨 서브1
        let actions = office.send(hook.make("SubagentStop", agent: subs[0]))
        let renamed = try #require(posts(actions).first)
        #expect(posts(actions).count == 1)
        #expect(renamed.id == asked.id)
        #expect(renamed.title == "서브1 승인 대기")
        #expect(renamed.body == asked.body)
        #expect(renamed.isUpdate && renamed.onlyIfDelivered)
        #expect(removed(actions).isEmpty)
        #expect(office.engine.state.agents[renamed.agent]?.displayName == "서브1")

        // 끝 책상(서브3)이 퇴근하면 아무도 바뀌지 않음 → 알림도 그대로
        #expect(posts(office.send(hook.make("SubagentStop", agent: subs[2]))).isEmpty)
        // 둘만 남았다가 하나가 퇴근해 "서브1" → "서브"가 되어도 따라감
        let alone = try #require(posts(office.send(hook.make("SubagentStop", agent: subs[1]))).first)
        #expect(alone.title == "서브 승인 대기")
        // 대기가 풀려 지운 알림은 다시 바꾸지 않음
        office.send(hook.tool("PostToolUse", "Bash", id: "b1", input: ["command": "npm test"], agent: subs[3], extra: [("tool_response", [:])]))
        office.send(hook.tool("PreToolUse", "Agent", id: "t9", input: ["subagent_type": "worker-9", "description": "일"]))
        #expect(!posts(office.send(hook.make("SubagentStart", agent: (id: "g9", type: "worker-9")))).contains { $0.id == asked.id })
    }

    @Test("데스크톱 서브 세션의 답변 대기·응답 완료 알림도 번호가 바뀌면 따라간다")
    func sessionNoticesRetitled() throws {
        var office = Office(settings: NotificationSettings(permission: true, completion: true, reply: true))
        let main = Hook(session: "m")
        office.send(main.make("SessionStart", ["source": "startup"]))
        let children = (1...3).map { Hook(session: "c\($0)") }
        for child in children {
            office.send(child.make("SessionStart", ["source": "startup"]), hint: SessionHint(hostSession: "local_\(child.session)", ancestors: [SessionID("m")]))
        }
        office.send(children[2].make("UserPromptSubmit", ["prompt": "x"]))
        let done = try #require(posts(office.send(children[2].make("Stop"))).first)
        #expect(done.title == "서브3 응답 완료")
        // 서브1 세션이 끝남 → 서브3이 1번 책상으로 옮겨 서브1
        let renamed = try #require(posts(office.send(children[0].make("SessionEnd", ["reason": "other"]))).first { $0.id == done.id })
        #expect(renamed.title == "서브1 응답 완료")
        #expect(renamed.isUpdate && renamed.onlyIfDelivered)
    }

    @Test("제목의 맨 앞 직함만 바꾼다")
    func retitledHelper() throws {
        let notice = OfficeNotice(
            id: "n", kind: .permission, title: "서브4 질문 답 대기", subtitle: "w", body: "b", agent: AgentID("m-1"),
            session: SessionID("s"), term: nil, hostSession: nil, isUpdate: false)
        #expect(NotificationPlanner.retitled(notice, as: "서브4") == nil)
        let renamed = try #require(NotificationPlanner.retitled(notice, as: "서브1"))
        #expect(renamed.title == "서브1 질문 답 대기")
        #expect(renamed.isUpdate && renamed.onlyIfDelivered)
    }

    // MARK: - 답변 필요 (M6(4c))

    func ask(_ text: String = "A안과 B안 중 어느 쪽으로 할까요?") -> JSONValue {
        hook.make("Stop", ["last_assistant_message": .string(text)])
    }

    /// 데스크톱 앱 세션 정보 (응답 요약 판정, 지금 보고 있는지)
    func desktop(_ office: inout Office, reply: Bool? = nil, viewing: Bool = false) -> [NoticeAction] {
        let resident = ResidentSession(
            session: SessionID("s1"), hostSession: "local_s1", rootCwd: hook.cwd, isFocused: viewing, replyRequest: reply)
        let at = Fixture.epoch.addingTimeInterval(office.clock + 0.5)
        _ = office.engine.syncResidents(
            ResidentRoll(residents: [resident], openHostSessions: ["local_s1"], isReliable: true, readAt: at), at: at)
        return office.engine.drainNotices()
    }

    @Test("답변 필요 알림은 기본으로 켜져 있고 응답마다 한 번, 답하면 지움")
    func replyOnce() throws {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        let asked = posts(office.send(ask()))
        let notice = try #require(asked.first)
        #expect(asked.count == 1)
        #expect(notice.kind == .reply)
        #expect(notice.title == "메인 답변 대기")
        #expect(notice.subtitle == "a-sdn-portal")
        #expect(notice.body == "응답을 마치고 답을 기다려요")
        #expect(notice.term == "iTerm.app")
        // 그냥 끝난 응답은 알리지 않음
        #expect(removed(office.send(hook.make("UserPromptSubmit", ["prompt": "y"]))) == [notice.id])
        #expect(posts(office.send(hook.make("Stop", ["last_assistant_message": "다 했어요."]))).isEmpty)
        // 다음 응답이 또 질문이면 다시 한 번
        office.send(hook.make("UserPromptSubmit", ["prompt": "z"]))
        #expect(posts(office.send(ask())).map(\.id) == [notice.id])
    }

    @Test("같은 응답이면 데스크톱 앱 요약으로 판정이 바뀌었다 돌아와도 다시 띄우지 않음")
    func replySameTurnOnce() {
        var office = Office()
        _ = desktop(&office)
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        let first = posts(office.send(ask()))
        #expect(first.count == 1)
        #expect(first.first?.hostSession == "local_s1")
        // 요약이 "완료"라고 하면 답변 필요가 풀려 알림을 지움
        #expect(removed(desktop(&office, reply: false)) == [first[0].id])
        // 요약이 다시 "막힘"이어도 같은 응답이라 띄우지 않음
        #expect(posts(desktop(&office, reply: true)).isEmpty)
        #expect(office.engine.state.lead(of: SessionID("s1"))?.cue == .reply)
    }

    @Test("마지막 문장은 질문이 아니어도 요약이 막힘이면 한 번 띄움")
    func replyFromSummary() {
        var office = Office()
        _ = desktop(&office)
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        #expect(posts(office.send(hook.make("Stop", ["last_assistant_message": "정리했어요."]))).isEmpty)
        let late = posts(desktop(&office, reply: true))
        #expect(late.map(\.kind) == [.reply])
    }

    @Test("데스크톱 앱에서 그 세션을 보고 있으면 띄우지 않음 (그 응답은 다시 띄우지 않음)")
    func replySkippedWhileViewing() {
        var office = Office()
        _ = desktop(&office, viewing: true)
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        #expect(posts(office.send(ask())).isEmpty)
        #expect(office.engine.state.lead(of: SessionID("s1"))?.cue == .reply)
        // 다른 세션으로 옮겨 가도 이미 본 응답이라 띄우지 않음
        #expect(posts(desktop(&office, reply: true)).isEmpty)
    }

    @Test("질문 도구의 승인 대기 알림과 겹치지 않음")
    func replyDoesNotOverlapQuestionTool() {
        var office = Office()
        office.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        let question = hook.tool("PreToolUse", "AskUserQuestion", id: "q1", input: ["questions": []])
        let asked = posts(office.send(question))
        #expect(asked.map(\.kind) == [.permission])
        // 질문에 답하지 않은 채 응답이 질문으로 끝나도 답변 필요 알림을 또 띄우지 않고, 질문 알림만 지움
        let ended = office.send(ask())
        #expect(posts(ended).isEmpty)
        #expect(removed(ended) == [asked[0].id])
    }

    @Test("답변 필요 알림을 끄면 띄우지 않고, 응답 완료 알림을 켜 두면 질문으로 끝난 응답은 답변 필요 하나만")
    func replySettings() {
        var off = Office(settings: NotificationSettings(permission: true, completion: false, reply: false))
        off.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        #expect(posts(off.send(ask())).isEmpty)

        var both = Office(settings: NotificationSettings(permission: true, completion: true, reply: true))
        both.send(hook.make("UserPromptSubmit", ["prompt": "x"]))
        #expect(posts(both.send(ask())).map(\.kind) == [.reply])
        both.send(hook.make("UserPromptSubmit", ["prompt": "y"]))
        #expect(posts(both.send(hook.make("Stop"))).map(\.kind) == [.completion])
    }
}
