import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

private func request(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

@Suite("HTTP 요청 파서")
struct HTTPParserTests {
    @Test("완전한 요청을 읽는다")
    func complete() {
        let data = request("POST /v1/hook HTTP/1.1\nHost: 127.0.0.1\nContent-Type: application/json\nContent-Length: 2\n\n{}")
        guard case .complete(let parsed) = HTTPRequestParser.parse(data, maxBodyBytes: 100) else { Issue.record("완료 아님"); return }
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/v1/hook")
        #expect(parsed.headers["content-type"] == "application/json")
        #expect(parsed.body == Data("{}".utf8))
    }

    @Test("본문이 덜 왔으면 더 기다린다")
    func incomplete() {
        #expect(HTTPRequestParser.parse(request("POST / HTTP/1.1\nContent-Length: 10\n\n{}"), maxBodyBytes: 100) == .incomplete)
        #expect(HTTPRequestParser.parse(request("POST / HTTP/1.1\nContent-Le"), maxBodyBytes: 100) == .incomplete)
    }

    @Test("너무 크거나 형식이 이상하면 거절한다")
    func rejects() {
        #expect(HTTPRequestParser.parse(request("POST / HTTP/1.1\nContent-Length: 5000\n\n"), maxBodyBytes: 100) == .tooLarge)
        guard case .invalid = HTTPRequestParser.parse(request("NONSENSE\n\n"), maxBodyBytes: 100) else { Issue.record("invalid 아님"); return }
        guard case .invalid = HTTPRequestParser.parse(request("POST / HTTP/1.1\nTransfer-Encoding: chunked\n\n"), maxBodyBytes: 100) else { Issue.record("invalid 아님"); return }
        guard case .invalid = HTTPRequestParser.parse(Data(repeating: 65, count: 20_000), maxBodyBytes: 100) else { Issue.record("invalid 아님"); return }
    }
}

@Suite("요청 검증 규칙")
struct HookRequestPolicyTests {
    let policy = HookRequestPolicy(token: "secret-token")

    func make(method: String = "POST", path: String = "/v1/hook", headers: [String: String] = [:], body: String = "{}") -> HTTPRequest {
        var base = ["x-office-token": "secret-token", "content-type": "application/json", "x-office-term": "iTerm.app"]
        for (key, value) in headers { base[key] = value }
        return HTTPRequest(method: method, path: path, headers: base.filter { !$0.value.isEmpty }, body: Data(body.utf8))
    }

    @Test("정상 요청은 받고 TERM_PROGRAM을 넘긴다")
    func accept() {
        #expect(policy.evaluate(make()) == .accept(body: Data("{}".utf8), term: "iTerm.app", hostSession: nil))
        #expect(policy.evaluate(make(headers: ["x-office-term": "unknown"])) == .accept(body: Data("{}".utf8), term: nil, hostSession: nil))
    }

    @Test("데스크톱 세션 id 헤더는 형식이 맞을 때만 넘긴다 (파일 경로에 쓰므로)")
    func hostSessionHeader() {
        let id = "local_46e4d935-07fb-4ab0-a5e7-b1fbf04c1416"
        #expect(policy.evaluate(make(headers: ["x-office-host-session": id])) == .accept(body: Data("{}".utf8), term: "iTerm.app", hostSession: id))
        for bad in ["local_../../etc/passwd", "local_", "abc", "local_a/b", "local_가나", String(repeating: "local_a", count: 20)] {
            #expect(policy.evaluate(make(headers: ["x-office-host-session": bad])) == .accept(body: Data("{}".utf8), term: "iTerm.app", hostSession: nil))
        }
    }

    @Test(
        "규칙에 어긋나면 상태 코드로 거절한다",
        arguments: [
            (["origin": "https://evil.example"], "POST", "/v1/hook", 403),
            ([:], "POST", "/other", 404),
            ([:], "GET", "/v1/hook", 405),
            (["x-office-token": "wrong"], "POST", "/v1/hook", 401),
            (["x-office-token": ""], "POST", "/v1/hook", 401),
            (["content-type": "text/plain"], "POST", "/v1/hook", 415),
        ] as [([String: String], String, String, Int)])
    func reject(_ headers: [String: String], _ method: String, _ path: String, _ status: Int) {
        guard case .reject(let actual, _) = policy.evaluate(make(method: method, path: path, headers: headers)) else {
            Issue.record("거절되지 않음"); return
        }
        #expect(actual == status)
    }

    @Test("토큰은 64자 16진수이고 매번 다르다")
    func tokens() {
        let a = HookRequestPolicy.makeToken()
        let b = HookRequestPolicy.makeToken()
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit })
        #expect(a != b)
    }
}

/// 훅을 받으면 모아 두는 수신함
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HookDelivery] = []

    func append(_ delivery: HookDelivery) {
        lock.lock()
        items.append(delivery)
        lock.unlock()
    }

    var deliveries: [HookDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func wait(for count: Int, timeout: TimeInterval = 5) async -> [HookDelivery] {
        let deadline = Date().addingTimeInterval(timeout)
        while deliveries.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return deliveries
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-office-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func run(_ executable: String, _ arguments: [String], stdin: String? = nil, environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let input = Pipe()
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@Suite("로컬 훅 서버", .serialized)
struct HookServerTests {
    @Test("127.0.0.1에서 받고, 토큰이 틀리거나 Origin이 있으면 거절한다")
    func endToEndWithCurl() async throws {
        let inbox = Inbox()
        let server = HookServer(token: "tkn") { inbox.append($0) }
        let port = try server.start(preferredPort: 0)
        defer { server.stop() }
        #expect(port > 0)
        let url = "http://127.0.0.1:\(port)/v1/hook"
        func curl(_ extra: [String]) throws -> String {
            try run("/usr/bin/env", ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "3", "-X", "POST",
                                     "-H", "Content-Type: application/json", "--data-binary", #"{"session_id":"s","hook_event_name":"Stop"}"#, url] + extra).output
        }
        #expect(try curl(["-H", "X-Office-Token: tkn", "-H", "X-Office-Term: vscode"]) == "202")
        #expect(try curl(["-H", "X-Office-Token: nope"]) == "401")
        #expect(try curl(["-H", "X-Office-Token: tkn", "-H", "Origin: http://localhost:3000"]) == "403")
        let received = await inbox.wait(for: 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(inbox.deliveries.count == 1)
        #expect(received.first?.term == "vscode")
        #expect(received.first.flatMap { try? JSONValue.parse($0.body)["hook_event_name"]?.stringValue } == "Stop")
    }

    @Test("선호 포트가 사용 중이면 다음 포트를 쓴다")
    func portFallback() throws {
        let first = HookServer(token: "a") { _ in }
        let port = try first.start(preferredPort: 0)
        defer { first.stop() }
        let second = HookServer(token: "b") { _ in }
        let other = try second.start(preferredPort: port, attempts: 3)
        defer { second.stop() }
        #expect(other != port)
    }

    @Test("멈추면 더 이상 받지 않고, 다시 시작할 수 있다")
    func stopAndRestart() throws {
        let server = HookServer(token: "a") { _ in }
        let port = try server.start(preferredPort: 0)
        server.stop()
        #expect(!server.isRunning)
        let code = try run("/usr/bin/env", ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "2", "http://127.0.0.1:\(port)/v1/hook"]).output
        #expect(code == "000")
        #expect(try server.start(preferredPort: 0) > 0)
        server.stop()
    }

    @Test("실제 훅 스크립트 → 서버 → 엔진: 아무것도 출력하지 않고 바로 끝나며, 훅이 도착한다")
    func hookScriptEndToEnd() async throws {
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
        environment["TERM_PROGRAM"] = "iTerm.app"
        environment["CLAUDE_CODE_HOST_SESSION_ID"] = "local_1234abcd-0000"
        let payload = #"{"session_id":"s1","cwd":"/w/a-sdn-portal","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_use_id":"t1"}"#
        let started = Date()
        let result = try run("/bin/sh", [script.path], stdin: payload, environment: environment)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)

        let delivered = try #require(await inbox.wait(for: 1).first)
        #expect(delivered.term == "iTerm.app")
        #expect(delivered.hostSession == "local_1234abcd-0000")

        // 데스크톱 앱 밖(터미널)에서는 헤더가 비어 있습니다
        environment["CLAUDE_CODE_HOST_SESSION_ID"] = nil
        _ = try run("/bin/sh", [script.path], stdin: payload, environment: environment)
        let second = await inbox.wait(for: 2)
        #expect(second.count == 2 && second[1].hostSession == nil)
        var engine = OfficeEngine(seed: 1)
        let directives = try engine.handle(hookPayload: delivered.body, term: delivered.term, at: delivered.receivedAt)
        #expect(directives.contains { if case .status(let pill) = $0.action { pill?.text == "Bash · npm test" } else { false } })
    }

    /// Claude Code는 훅을 별도 프로세스 그룹에서 실행하고, 끝나면 그룹 전체를 종료합니다.
    /// 백그라운드로 보내던 첫 버전은 이 경우 훅이 도착하지 않았습니다 (M2 첫 실행에서 발견).
    @Test(
        "훅이 끝나자마자 프로세스 그룹이 종료되어도 훅이 도착한다",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/setsid"), "setsid가 있는 Linux에서만 실행")
    )
    func survivesProcessGroupKill() async throws {
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
        let payloadFile = directory.appendingPathComponent("payload.json")
        try #"{"session_id":"g","hook_event_name":"SessionStart","source":"startup"}"#.write(to: payloadFile, atomically: true, encoding: .utf8)

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_OFFICE_ENDPOINT"] = endpoint.path
        let result = try run("/usr/bin/setsid", ["/bin/sh", "-c", "sh '\(script.path)' < '\(payloadFile.path)'; kill -TERM 0"], environment: environment)
        #expect(result.output.isEmpty)
        let delivered = await inbox.wait(for: 1, timeout: 3)
        #expect(delivered.count == 1)
    }

    @Test("앱이 꺼져 있어도(엔드포인트 없음, 서버 없음) 훅 스크립트는 조용히 성공한다")
    func hookScriptWithoutApp() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("claude-office.sh")
        try HookInstaller.bundledScript.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_OFFICE_ENDPOINT"] = directory.appendingPathComponent("missing").path
        let missing = try run("/bin/sh", [script.path], stdin: "{}", environment: environment)
        #expect(missing.status == 0 && missing.output.isEmpty)

        // 엔드포인트 파일은 있지만 서버가 꺼진 경우
        let endpoint = directory.appendingPathComponent("endpoint")
        try EndpointFile.write(port: 9, token: "x", to: endpoint)
        environment["CLAUDE_OFFICE_ENDPOINT"] = endpoint.path
        let started = Date()
        let stale = try run("/bin/sh", [script.path], stdin: "{}", environment: environment)
        #expect(stale.status == 0 && stale.output.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

@Suite("엔드포인트 파일과 설치기")
struct InstallerTests {
    @Test("엔드포인트 파일은 600 권한으로 쓰고 다시 읽는다")
    func endpointFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sub/endpoint")
        try EndpointFile.write(port: 47821, token: "abc", to: url)
        let read = try EndpointFile.read(from: url)
        #expect(read.port == 47821 && read.token == "abc")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try EndpointFile.write(port: 1, token: "new", to: url)
        #expect(try EndpointFile.read(from: url).token == "new")
        #expect(EndpointFile.defaultURL(home: URL(fileURLWithPath: "/Users/demo")).path == "/Users/demo/Library/Application Support/ClaudeOffice/endpoint")
    }

    @Test("설치: 스크립트를 쓰고, settings.json을 백업한 뒤 기존 훅을 지키며 병합한다")
    func installAndUninstall() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(home: home)
        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"say done\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        try original.write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        #expect(installer.status() == .notInstalled)

        let report = try installer.install(version: ClaudeVersion(2, 1, 318))
        #expect(report.events.contains("SubagentStart"))
        let backup = try #require(report.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        guard case .installed(let installed) = installer.status() else { Issue.record("설치 상태가 아님"); return }
        #expect(Set(installed) == Set(report.events))
        let permissions = try FileManager.default.attributesOfItem(atPath: installer.scriptURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
        let settings = try JSONValue.parse(Data(contentsOf: installer.settingsURL))
        #expect(settings["hooks"]?["Stop"]?.arrayValue?.count == 2)

        // 스크립트가 바뀌면 상태가 알려줍니다 (M4.5a: 데스크톱 세션 헤더가 없는 예전 스크립트도)
        #expect(HookInstaller.bundledScript.contains("X-Office-Host-Session: ${CLAUDE_CODE_HOST_SESSION_ID:-}"))
        let previous = HookInstaller.bundledScript.replacingOccurrences(
            of: "  -H \"X-Office-Host-Session: ${CLAUDE_CODE_HOST_SESSION_ID:-}\" \\\n", with: "")
        #expect(previous != HookInstaller.bundledScript)
        try previous.write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        guard case .scriptMissingOrOutdated = installer.status() else { Issue.record("예전 스크립트를 감지하지 못함"); return }
        try "#!/bin/sh\n".write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        guard case .scriptMissingOrOutdated = installer.status() else { Issue.record("오래된 스크립트를 감지하지 못함"); return }

        #expect(try installer.uninstall() == report.events.count)
        #expect(installer.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: installer.scriptURL.path))
        #expect(try String(contentsOf: installer.settingsURL, encoding: .utf8) == original)
    }

    @Test("settings.json이 없으면 새로 만들고, 깨져 있으면 건드리지 않는다")
    func missingOrBrokenSettings() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(home: home)
        let report = try installer.install(version: nil)
        #expect(report.backup == nil)
        #expect(report.events == HookSettingsEditor.baseEvents)

        try "{ broken".write(to: installer.settingsURL, atomically: true, encoding: .utf8)
        guard case .settingsUnreadable = installer.status() else { Issue.record("깨진 설정을 감지하지 못함"); return }
        #expect(throws: (any Error).self) { try installer.install(version: nil) }
        #expect(try String(contentsOf: installer.settingsURL, encoding: .utf8) == "{ broken")
    }

    @Test("홈 경로에 공백이 있으면 명령을 따옴표로 감싼다")
    func quotedCommand() {
        #expect(HookInstaller(home: URL(fileURLWithPath: "/Users/a b")).command == "\"/Users/a b/.claude/hooks/claude-office.sh\"")
        #expect(HookInstaller(home: URL(fileURLWithPath: "/Users/ab")).command == "/Users/ab/.claude/hooks/claude-office.sh")
    }
}
