import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

@Suite("죽은 터미널 세션 퇴근 (개선 7, PID 확인)")
struct SessionProcessTests {
    let alive = ProcessIdentity(pid: 4242, startedAt: 100)
    let dead = ProcessIdentity(pid: 4343, startedAt: 200)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func payload(_ session: String, _ event: String, extra: String = "") -> Data {
        Data(#"{"session_id":"\#(session)","cwd":"/w/proj","hook_event_name":"\#(event)"\#(extra)}"#.utf8)
    }

    @Test("X-Office-Pid는 1보다 큰 10진수만, X-Office-App은 번들 id 꼴만 받는다")
    func headers() {
        #expect(HookRequestPolicy.hookParentPID(["x-office-pid": "40984"]) == 40984)
        for bad in ["", "1", "0", "-5", "12a", "4 2", "99999999999", "+3", "٣٤"] {
            #expect(HookRequestPolicy.hookParentPID(["x-office-pid": bad]) == nil)
        }
        #expect(HookRequestPolicy.hookParentPID([:]) == nil)
        #expect(HookRequestPolicy.appBundleID(["x-office-app": "com.todesktop.230313mzl4w4u92"]) == "com.todesktop.230313mzl4w4u92")
        for bad in ["", "com/evil", "a b", "../x", String(repeating: "a", count: 200)] {
            #expect(HookRequestPolicy.appBundleID(["x-office-app": bad]) == nil)
        }
    }

    @Test("죽은 PID의 세션은 sessionEnded로 퇴근하고, 산 PID·PID 없음·데스크톱 세션은 그대로")
    func sweep() throws {
        var engine = OfficeEngine(seed: 1)
        var tracker = SessionProcessTracker()
        func receive(_ session: String, process: ProcessIdentity?, desktop: Bool = false) throws {
            let event = try #require(try HookParser.parse(payload(session, "UserPromptSubmit", extra: #","prompt":"hi""#), receivedAt: t0))
            tracker.note(session: event.session, process: process, app: nil, desktop: desktop, ended: false)
            _ = engine.handle(event)
        }
        try receive("alive", process: alive)
        try receive("dead", process: dead)
        try receive("old-script", process: nil)
        try receive("desktop", process: dead, desktop: true)
        #expect(engine.state.parts.count == 4)

        let isAlive: (ProcessIdentity) -> Bool = { $0 == alive }
        let events = tracker.sweep(at: t0.addingTimeInterval(5), isAlive: isAlive)
        #expect(events.map(\.session) == [SessionID("dead")])
        #expect(events.first?.kind == .sessionEnded(reason: SessionProcessTracker.endReason))
        for event in events { _ = engine.handle(event) }
        #expect(engine.state.parts[SessionID("dead")] == nil)
        #expect(Set(engine.state.parts.keys) == [SessionID("alive"), SessionID("old-script"), SessionID("desktop")])
        // 한 번 퇴근시킨 세션은 잊음 (다시 넣지 않음)
        #expect(tracker.sweep(at: t0.addingTimeInterval(10), isAlive: isAlive).isEmpty)

        // 4번 규칙: 30초 안에 온 그 세션의 늦은 훅은 버리고, 새 요청이면 다시 출근
        _ = try engine.handle(hookPayload: payload("dead", "PostToolUse", extra: #","tool_name":"Bash","tool_use_id":"t""#), at: t0.addingTimeInterval(8))
        #expect(engine.state.parts[SessionID("dead")] == nil)
        _ = try engine.handle(hookPayload: payload("dead", "UserPromptSubmit", extra: #","prompt":"again""#), at: t0.addingTimeInterval(9))
        #expect(engine.state.parts[SessionID("dead")] != nil)
    }

    @Test("SessionEnd를 받으면 잊고, 데스크톱 세션이 되면 잊고, 새 프로세스가 이어받으면 바꾼다")
    func noteRules() {
        var tracker = SessionProcessTracker()
        let session = SessionID("s")
        tracker.note(session: session, process: dead, app: "com.apple.Terminal", desktop: false, ended: false)
        #expect(tracker.app(for: session) == "com.apple.Terminal")
        tracker.note(session: session, process: nil, app: nil, desktop: false, ended: false)  // PID 없는 훅은 기억을 지우지 않음
        #expect(tracker.processes[session] == dead)
        tracker.note(session: session, process: alive, app: nil, desktop: false, ended: false)  // claude --resume
        #expect(tracker.processes[session] == alive)
        tracker.note(session: session, process: nil, app: nil, desktop: false, ended: true)
        #expect(tracker.processes[session] == nil && tracker.app(for: session) == nil)
        tracker.note(session: session, process: dead, app: nil, desktop: false, ended: false)
        tracker.note(session: session, process: dead, app: nil, desktop: true, ended: false)
        #expect(tracker.processes[session] == nil)
    }

    @Test("프로세스 찾기: 자기 자신은 살아 있고, 셸이면 부모로 올라가며, 시작 시각이 다르면(번호 재사용) 죽은 것")
    func inspector() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let identity = try #require(ProcessInspector.claudeProcess(fromHookParent: me))
        #expect(identity.pid == me)  // 테스트 실행기는 셸이 아님
        #expect(ProcessInspector.isAlive(identity))
        #expect(!ProcessInspector.isAlive(ProcessIdentity(pid: me, startedAt: identity.startedAt &+ 1)))
        #expect(ProcessInspector.claudeProcess(fromHookParent: 1) == nil)
        #expect(ProcessInspector.claudeProcess(fromHookParent: Int32.max) == nil)

        // 셸(sh) 아래에서: 셸의 PID를 주면 그 부모(이 테스트 실행기)를 찾음
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 2; :"]
        try shell.run()
        defer { shell.terminate() }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(ProcessInspector.claudeProcess(fromHookParent: shell.processIdentifier)?.pid == me)
    }

    @Test("실제 훅 스크립트가 보낸 PID·앱을 서버가 프로세스로 바꿔 넘긴다")
    func endToEnd() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = Inbox()
        let token = HookRequestPolicy.makeToken()
        let server = HookServer(token: token) { inbox.append($0) }
        let port = try server.start(preferredPort: 0)
        defer { server.stop() }
        let endpoint = directory.appendingPathComponent("endpoint")
        try EndpointFile.write(port: port, token: token, to: endpoint)
        let script = directory.appendingPathComponent("claude-office.sh")
        try HookInstaller.bundledScript.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_OFFICE_ENDPOINT"] = endpoint.path
        environment["CLAUDE_CODE_HOST_SESSION_ID"] = nil
        environment["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        // 이 테스트 실행기가 Claude Code 자리 (스크립트의 $PPID)
        let result = try run("/bin/sh", [script.path], stdin: #"{"session_id":"p","hook_event_name":"Stop"}"#, environment: environment)
        #expect(result.status == 0 && result.output.isEmpty)
        let delivered = try #require(await inbox.wait(for: 1).first)
        #expect(delivered.process?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(delivered.app == "com.todesktop.230313mzl4w4u92")

        // 데스크톱 앱 세션이면 프로세스를 보지 않음
        environment["CLAUDE_CODE_HOST_SESSION_ID"] = "local_abc-1"
        _ = try run("/bin/sh", [script.path], stdin: #"{"session_id":"q","hook_event_name":"Stop"}"#, environment: environment)
        let second = await inbox.wait(for: 2)
        #expect(second.count == 2 && second[1].process == nil)
    }
}
