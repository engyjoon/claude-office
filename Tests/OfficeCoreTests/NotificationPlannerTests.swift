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
}
