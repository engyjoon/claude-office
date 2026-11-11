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
        // (셸은 입력이 닫힐 때까지 살아 있음: 시간에 기대지 않음. posix_spawn이 돌아오면 이미 셸로 바뀌어 있음)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "read line; :"]
        let input = Pipe()
        shell.standardInput = input
        try shell.run()
        defer {
            try? input.fileHandleForWriting.close()
            shell.waitUntilExit()
        }
        #expect(ProcessInspector.claudeProcess(fromHookParent: shell.processIdentifier)?.pid == me)
    }

    @Test("실제 훅 스크립트는 $PPID와 __CFBundleIdentifier를 헤더로 보낸다 (curl 대신 인자를 적는 가짜 curl)")
    func scriptHeaders() throws {
        // 진짜 curl은 부하가 크면 뜨는 데만 수 초가 걸려(실측) -m 1에 걸릴 수 있습니다. 헤더만 보면 되니 가짜로 바꿉니다.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("args")
        let fake = bin.appendingPathComponent("curl")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '\(record.path)'; done\ncat >/dev/null\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let endpoint = directory.appendingPathComponent("endpoint")
        try EndpointFile.write(port: 1234, token: "tok", to: endpoint)
        let script = directory.appendingPathComponent("claude-office.sh")
        try HookInstaller.bundledScript.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["CLAUDE_OFFICE_ENDPOINT"] = endpoint.path
        environment["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        // 이 테스트 실행기가 Claude Code 자리 (스크립트의 $PPID)
        let result = try run("/bin/sh", [script.path], stdin: #"{"session_id":"p","hook_event_name":"Stop"}"#, environment: environment)
        #expect(result.status == 0 && result.output.isEmpty)
        let args = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.contains("X-Office-Pid: \(ProcessInfo.processInfo.processIdentifier)"))
        #expect(args.contains("X-Office-App: com.todesktop.230313mzl4w4u92"))
        #expect(args.contains("http://127.0.0.1:1234/v1/hook"))
    }

    @Test("서버는 X-Office-Pid를 Claude Code 프로세스로 바꿔 넘기고, 데스크톱 세션이면 보지 않는다")
    func serverResolvesProcess() async throws {
        let inbox = Inbox()
        let server = HookServer(token: "tkn") { inbox.append($0) }
        let port = try server.start(preferredPort: 0)
        defer { server.stop() }
        let me = ProcessInfo.processInfo.processIdentifier
        func post(_ session: String, host: String) throws -> String {
            let body = #"{"session_id":"\#(session)","hook_event_name":"Stop"}"#
            return try rawRequest(port: port, "POST /v1/hook HTTP/1.1\r\nX-Office-Token: tkn\r\nContent-Type: application/json\r\n"
                + "X-Office-Pid: \(me)\r\nX-Office-App: com.apple.Terminal\r\nX-Office-Host-Session: \(host)\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
        #expect(try post("p", host: "").hasPrefix("HTTP/1.1 202"))
        #expect(try post("q", host: "local_abc-1").hasPrefix("HTTP/1.1 202"))
        let delivered = await inbox.wait(for: 2, timeout: 30)
        #expect(delivered.count == 2)
        #expect(delivered.first?.process?.pid == me)
        #expect(delivered.first?.app == "com.apple.Terminal")
        #expect(delivered.last?.process == nil)
    }
}
