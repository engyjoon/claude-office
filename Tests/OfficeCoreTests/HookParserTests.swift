import Foundation
import Testing

@testable import OfficeCore

@Suite("훅 파서")
struct HookParserTests {
    @Test("합성 픽스처를 모두 파싱한다 (무시 대상 제외)")
    func allSyntheticFixtures() throws {
        let files = Fixture.files(in: "synthetic")
        #expect(files.count >= 20)
        for file in files {
            let record = try JSONValue.parse(Data(contentsOf: file))
            let payload = try #require(record["payload"])
            let event = HookParser.parse(payload, term: record["term_program"]?.stringValue, receivedAt: Fixture.epoch)
            let ignored = ["CwdChanged-ignored.json", "Notification-auth.json"].contains(file.lastPathComponent)
            #expect((event == nil) == ignored, "\(file.lastPathComponent)")
        }
    }

    @Test("공통 필드")
    func common() throws {
        let event = try Fixture.event("SessionStart")
        #expect(event.session == SessionID("s-demo"))
        #expect(event.cwd == "/Users/demo/work/a-sdn-portal")
        #expect(event.term == "iTerm.app")
        #expect(event.subagent == nil)
        #expect(event.kind == .sessionStarted(source: "startup"))
    }

    @Test("툴 시작과 종료")
    func tools() throws {
        guard case .toolStarted(let call) = try Fixture.event("PreToolUse-Bash").kind else { Issue.record("toolStarted 아님"); return }
        #expect(call.name == "Bash")
        #expect(call.id == "tu-bash-1")
        #expect(call.category == .shell)
        #expect(call.subject == "npm test -- --watch=false")
        #expect(try Fixture.event("PostToolUse-Bash").kind == .toolFinished(call, .success))
    }

    @Test("PostToolUseFailure는 오류 결과가 된다")
    func failure() throws {
        guard case .toolFinished(let call, let outcome) = try Fixture.event("PostToolUseFailure-Read").kind else {
            Issue.record("toolFinished 아님"); return
        }
        #expect(call.subject == "missing.txt")
        #expect(outcome == .failure("File does not exist."))
    }

    @Test("Agent와 구버전 Task 툴은 위임이 된다")
    func delegation() throws {
        guard case .delegationStarted(let call, let type) = try Fixture.event("PreToolUse-Agent").kind else { Issue.record("위임 아님"); return }
        #expect(type == "code-reviewer")
        #expect(call.subject == "RouterConfig 리뷰")
        guard case .delegationStarted(_, let legacyType) = try Fixture.event("PreToolUse-Task-legacy").kind else { Issue.record("구버전 위임 아님"); return }
        #expect(legacyType == "general-purpose")
        guard case .delegationFinished(_, .success) = try Fixture.event("PostToolUse-Agent").kind else { Issue.record("위임 종료 아님"); return }
    }

    @Test("서브에이전트 안의 훅은 agent_id 문맥을 가진다")
    func subagentContext() throws {
        let event = try Fixture.event("PreToolUse-Grep-subagent")
        #expect(event.subagent == SubagentRef(id: "a-rev-1", type: "code-reviewer"))
        // SubagentStart/Stop의 agent_id는 문맥이 아니라 대상
        let start = try Fixture.event("SubagentStart")
        #expect(start.subagent == nil)
        #expect(start.kind == .subagentStarted(SubagentRef(id: "a-rev-1", type: "code-reviewer")))
        #expect(try Fixture.event("SubagentStop").kind == .subagentStopped(SubagentRef(id: "a-rev-1", type: "code-reviewer")))
    }

    @Test("권한 요청은 툴 정보를 담고, 명령의 비밀번호는 가린다")
    func permission() throws {
        let event = try Fixture.event("PermissionRequest-Bash-subagent")
        guard case .permissionRequested(let call?) = event.kind else { Issue.record("권한 요청 아님"); return }
        #expect(call.subject == "./gradlew test --password=<가림>")
        #expect(event.subagent?.id == "a-rev-1")
        #expect(try Fixture.event("Notification-permission").kind == .permissionRequested(nil))
        #expect(try Fixture.event("Notification-legacy-permission").kind == .permissionRequested(nil))
        guard case .permissionDenied(let denied?) = try Fixture.event("PermissionDenied-Bash").kind else { Issue.record("거부 아님"); return }
        #expect(denied.subject == "rm -rf build")
    }

    @Test("나머지 이벤트")
    func others() throws {
        #expect(try Fixture.event("Notification-idle").kind == .waitingForInput)
        #expect(try Fixture.event("Stop").kind == .turnEnded(failed: false))
        #expect(try Fixture.event("StopFailure").kind == .turnEnded(failed: true))
        #expect(try Fixture.event("PreCompact").kind == .compacting)
        #expect(try Fixture.event("UserPromptSubmit").kind == .promptSubmitted)
        #expect(try Fixture.event("SessionEnd").kind == .sessionEnded(reason: "prompt_input_exit"))
    }

    @Test("필수 필드가 없거나 JSON이 깨지면 무시하거나 오류를 낸다")
    func robustness() throws {
        #expect(HookParser.parse(["hook_event_name": "Stop"], receivedAt: Fixture.epoch) == nil)
        #expect(HookParser.parse(["session_id": "s"], receivedAt: Fixture.epoch) == nil)
        #expect(HookParser.parse(["session_id": "s", "hook_event_name": "PreToolUse"], receivedAt: Fixture.epoch) == nil)
        #expect(throws: JSONParseError.self) { try HookParser.parse(Data("{".utf8), receivedAt: Fixture.epoch) }
        // 알 수 없는 필드가 더 있어도 괜찮습니다
        let extra: JSONValue = ["session_id": "s", "hook_event_name": "Stop", "future_field": ["x": 1]]
        #expect(HookParser.parse(extra, receivedAt: Fixture.epoch)?.kind == .turnEnded(failed: false))
    }

    @Test("TERM_PROGRAM이 unknown이거나 비어 있으면 nil")
    func term() {
        let payload: JSONValue = ["session_id": "s", "hook_event_name": "Stop"]
        #expect(HookParser.parse(payload, term: "unknown", receivedAt: Fixture.epoch)?.term == nil)
        #expect(HookParser.parse(payload, term: " ", receivedAt: Fixture.epoch)?.term == nil)
        #expect(HookParser.parse(payload, term: "vscode", receivedAt: Fixture.epoch)?.term == "vscode")
    }
}

@Suite("실제 수집 픽스처")
struct CapturedFixtureTests {
    @Test("captured/ 폴더의 실제 페이로드를 모두 이벤트로 읽고 오류 없이 처리한다")
    func capturedFixtures() throws {
        for file in Fixture.files(in: "captured") {
            let record = try JSONValue.parse(Data(contentsOf: file))
            let payload = try #require(record["payload"], "\(file.lastPathComponent)")
            // 실제 수집본은 모두 사무실이 다루는 이벤트입니다 (무시되는 것이 없어야 합니다)
            let parsed = HookParser.parse(payload, term: record["term_program"]?.stringValue, receivedAt: Fixture.epoch)
            #expect(parsed != nil, "\(file.lastPathComponent)")
            var engine = OfficeEngine(seed: 1)
            if let event = HookParser.parse(payload, receivedAt: Fixture.epoch) {
                _ = engine.handle(event)
            }
        }
    }
}
