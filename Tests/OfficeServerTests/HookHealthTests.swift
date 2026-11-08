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
        #expect(health.items.map(\.label) == ["settings.json 등록", "훅 스크립트", "서버", "마지막 이벤트", "받은 이벤트"])
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
