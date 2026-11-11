import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

@Suite("훅 상태 판정 (M5(8))")
struct HookHealthTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let events = ["SessionStart", "Stop"]

    func evaluate(_ status: HookInstaller.Status, _ script: HookScriptState, port: UInt16? = 50_000,
                  last: TimeInterval? = 12, count: Int = 3) -> HookHealth {
        HookHealth.evaluate(
            .init(status: status, script: script, port: port, lastEventAt: last.map { now.addingTimeInterval(-$0) }, eventCount: count),
            now: now)
    }

    @Test("모두 정상이면 마지막 이벤트 시각을 보여 준다")
    func healthy() {
        let health = evaluate(.installed(events: events), .current)
        #expect(health.level == .ok)
        #expect(health.headline == "정상 작동 중 · 마지막 이벤트 12초 전")
        #expect(!health.suggestsReinstall)
        #expect(health.items.map(\.label) == ["settings.json 등록", "훅 스크립트", "서버", "마지막 이벤트", "받은 이벤트", "Claude Code"])
        #expect(health.items[5].value == "버전을 확인하지 못함")
        #expect(health.items[0].value == "됨 · 이벤트 2개")
        #expect(health.items[2].value == "실행 중 · 127.0.0.1:50000")
        #expect(health.items[4].value == "3개 (앱을 켠 뒤)")
    }

    @Test("설치는 됐지만 아직 이벤트가 없으면 세션을 다시 시작하라고 알려 준다")
    func noEventsYet() {
        let health = evaluate(.installed(events: events), .current, last: nil, count: 0)
        #expect(health.level == .ok)
        #expect(health.headline.contains("다시 시작"))
        #expect(health.items[3].value == "아직 없음")
    }

    @Test("스크립트가 없거나 옛 버전이거나 실행 권한이 없으면 다시 설치를 권한다")
    func reinstall() {
        for script in [HookScriptState.missing, .outdated, .notExecutable] {
            let health = evaluate(.scriptMissingOrOutdated(events: events), script)
            #expect(health.level == .warning)
            #expect(health.suggestsReinstall)
            #expect(health.headline.contains("다시 설치"))
        }
    }

    @Test("거절한 요청이 있으면 상태 코드별로 보여 준다 (개선 7)")
    func rejectedRequests() {
        let input = HookHealth.Input(status: .installed(events: HookSettingsEditor.baseEvents), script: .current, port: 1,
                                     lastEventAt: nil, eventCount: 0, rejected: [413: 1, 401: 2])
        let item = HookHealth.evaluate(input, now: Date()).items.first { $0.label == "거절한 요청" }
        #expect(item?.value == "3개 (401 토큰 틀림 2개, 413 본문 너무 큼 1개)")
        #expect(item?.level == .warning)
        let clean = HookHealth.Input(status: .installed(events: HookSettingsEditor.baseEvents), script: .current, port: 1,
                                     lastEventAt: nil, eventCount: 0)
        #expect(!HookHealth.evaluate(clean, now: Date()).items.contains { $0.label == "거절한 요청" })
    }

    @Test("설치 안 됨은 경고가 아니라 안내")
    func notInstalled() {
        let health = evaluate(.notInstalled, .missing, last: nil, count: 0)
        #expect(health.level == .idle)
        #expect(!health.suggestsReinstall)
        #expect(health.headline.contains("훅 설치"))
        #expect(health.items[1].level == .idle)
    }

    @Test("서버가 멈췄거나 settings.json을 읽을 수 없으면 오류")
    func errors() {
        #expect(evaluate(.installed(events: events), .current, port: nil).level == .error)
        let unreadable = evaluate(.settingsUnreadable("깨진 JSON"), .current)
        #expect(unreadable.level == .error)
        #expect(unreadable.items[0].value == "읽을 수 없음 · 깨진 JSON")
        let failed = HookHealth.evaluate(
            .init(status: .installed(events: events), script: .current, port: nil, serverError: "포트 사용 중", lastEventAt: nil, eventCount: 0),
            now: now)
        #expect(failed.items[2].value == "시작하지 못함 · 포트 사용 중")
    }

    @Test("기본 9종만 등록됐는데 Claude Code가 확장 이벤트를 지원하면 다시 설치를 권한다")
    func missingExtendedEvents() {
        let base = HookSettingsEditor.baseEvents
        let input = HookHealth.Input(status: .installed(events: base), script: .current, port: 50_000,
                                     lastEventAt: now.addingTimeInterval(-12), eventCount: 3, version: ClaudeVersion(2, 1, 321))
        let health = HookHealth.evaluate(input, now: now)
        #expect(health.level == .warning)
        #expect(health.suggestsReinstall)
        #expect(health.missingEvents == HookSettingsEditor.extendedEvents)
        #expect(health.headline.contains("다시 설치"))
        #expect(health.headline.contains("2.1.321"))
        #expect(health.items[0].level == .warning)
        #expect(health.items[0].value.contains("5개 빠짐"))

        // 버전을 모르면 경고하지 않습니다
        var unknown = input
        unknown.version = nil
        let quiet = HookHealth.evaluate(unknown, now: now)
        #expect(quiet.level == .ok)
        #expect(!quiet.suggestsReinstall)
        #expect(quiet.missingEvents.isEmpty)

        // 다 등록돼 있으면 정상
        var full = input
        full.status = .installed(events: base + HookSettingsEditor.extendedEvents)
        #expect(HookHealth.evaluate(full, now: now).level == .ok)
    }

    @Test("disableAllHooks·관리 설정으로 막혀 있으면 구체적인 까닭을 보여 준다")
    func blocked() {
        for blocker in [HookBlocker.disableAllHooks(managed: false), .disableAllHooks(managed: true), .managedHooksOnly] {
            let health = HookHealth.evaluate(
                .init(status: .installed(events: events), script: .current, port: 50_000, lastEventAt: nil, eventCount: 0, blocker: blocker),
                now: now)
            #expect(health.level == .error)
            #expect(health.headline == blocker.message)
            #expect(health.items.contains { $0.label == "훅 실행" && $0.value == blocker.shortValue })
        }
    }

    @Test("설치기가 settings.json과 관리 설정에서 막는 설정을 읽는다")
    func installerBlocker() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-block-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent("managed")
        let installer = HookInstaller(home: home, managedDirectory: managed)
        #expect(installer.blocker() == nil)  // 파일이 없으면 확인하지 않음

        try FileManager.default.createDirectory(at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"disableAllHooks": true}"#.utf8).write(to: installer.settingsURL)
        #expect(installer.blocker() == .disableAllHooks(managed: false))

        try Data(#"{"disableAllHooks": false}"#.utf8).write(to: installer.settingsURL)
        try FileManager.default.createDirectory(at: managed.appendingPathComponent("managed-settings.d"), withIntermediateDirectories: true)
        try Data(#"{"allowManagedHooksOnly": true}"#.utf8).write(to: managed.appendingPathComponent("managed-settings.d/10-hooks.json"))
        #expect(installer.blocker() == .managedHooksOnly)
        try Data(#"{"disableAllHooks": true}"#.utf8).write(to: managed.appendingPathComponent("managed-settings.json"))
        #expect(installer.blocker() == .disableAllHooks(managed: true))
    }

    @Test("GUI 앱 환경(PATH가 /usr/bin:/bin:/usr/sbin:/sbin)에서도 ~/.local/bin/claude의 버전을 찾는다")
    func detectsVersionWithoutShellPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\necho '2.1.321 (Claude Code)'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let gui = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #expect(ClaudeVersionDetector.candidates(home: home, environment: gui).first == fake.path)
        // 셸을 쓰지 않아도(shells: []) 알려진 위치에서 찾습니다
        #expect(ClaudeVersionDetector.detect(home: home, environment: gui, shells: []) == ClaudeVersion(2, 1, 321))

        // 어디에도 없으면 nil (셸도 쓰지 않음)
        try FileManager.default.removeItem(at: fake)
        let empty = ["HOME": home.path, "PATH": home.appendingPathComponent("nowhere").path]
        let others = ClaudeVersionDetector.candidates(home: home, environment: empty)
            .filter { !$0.hasPrefix(home.path) && FileManager.default.isExecutableFile(atPath: $0) }
        if others.isEmpty {  // 이 맥에 Homebrew·/usr/local의 claude가 있으면 그 버전이 나오므로 건너뜀
            #expect(ClaudeVersionDetector.detect(home: home, environment: empty, shells: []) == nil)
        }
    }

    @Test("스크립트 파일 상태: 없음 → 설치 후 정상 → 권한 없음 → 다른 내용")
    func scriptState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hook-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HookInstaller(home: home)
        #expect(installer.scriptState() == .missing)
        try installer.install(version: nil)
        #expect(installer.scriptState() == .current)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installer.scriptURL.path)
        #expect(installer.scriptState() == .notExecutable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installer.scriptURL)
        #expect(installer.scriptState() == .outdated)
    }
}
