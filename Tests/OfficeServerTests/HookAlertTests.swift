import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

@Suite("연동 경고 (개선 6)")
struct HookAlertTests {
    let events = ["SessionStart", "Stop"]

    func evaluate(_ status: HookInstaller.Status, _ script: HookScriptState = .current, port: UInt16? = 50_000,
               error: String? = nil, version: ClaudeVersion? = nil, blocker: HookBlocker? = nil) -> HookAlert? {
        HookAlert.evaluate(.init(status: status, script: script, port: port, serverError: error, lastEventAt: nil,
                                 eventCount: 0, version: version, blocker: blocker))
    }

    @Test("엔드포인트 파일을 다른 프로세스가 가로채거나 없어지면 빨간 경고 (개선 7)")
    func endpointLost() throws {
        func check(_ endpoint: EndpointFile.State?) -> HookAlert? {
            HookAlert.evaluate(.init(status: .installed(events: events), script: .current, port: 50_000, lastEventAt: nil,
                                     eventCount: 0, endpoint: endpoint))
        }
        #expect(check(.ours) == nil)
        #expect(check(nil) == nil)
        let taken = try #require(check(.other(port: 47821)))
        #expect(taken.kind == .endpointLost && taken.isError && taken.action == .openSettings)
        #expect(taken.detail.contains("office-sim serve"))
        #expect(check(.missing)?.kind == .endpointLost)

        let health = HookHealth.evaluate(.init(status: .installed(events: events), script: .current, port: 50_000, lastEventAt: nil,
                                               eventCount: 0, endpoint: .other(port: 47821)), now: Date())
        #expect(health.level == .error)
        #expect(health.items.contains { $0.label == "엔드포인트 파일" && $0.level == .error })
        #expect(health.headline.contains("서버 다시 시작"))
    }

    @Test("정상이면(아직 이벤트가 없어도) 경고가 없다")
    func healthy() {
        #expect(evaluate(.installed(events: events)) == nil)
    }

    @Test("서버가 멈추면 다른 무엇보다 먼저 빨간 경고, 설정으로 보낸다")
    func serverFailed() throws {
        let alert = try #require(evaluate(.notInstalled, .missing, port: nil, error: "주소 사용 중"))
        #expect(alert.kind == .serverFailed)
        #expect(alert.isError)
        #expect(alert.action == .openSettings)
        #expect(alert.actionLabel == "연동 설정…")
        #expect(alert.detail == "훅 서버를 시작하지 못했어요. 주소 사용 중")
    }

    @Test("설치되지 않았으면 주황 경고와 설치 버튼")
    func notInstalled() throws {
        let alert = try #require(evaluate(.notInstalled, .missing))
        #expect(alert.kind == .notInstalled)
        #expect(!alert.isError)
        #expect(alert.action == .install)
        #expect(alert.actionLabel == "훅 설치")
    }

    @Test("스크립트가 낡았거나 없으면 다시 설치")
    func scriptStale() {
        #expect(evaluate(.scriptMissingOrOutdated(events: events), .outdated)?.kind == .scriptNeedsFix)
        #expect(evaluate(.installed(events: events), .notExecutable)?.action == .reinstall)
        #expect(evaluate(.installed(events: events), .missing)?.kind == .scriptNeedsFix)
    }

    @Test("막는 설정이 있으면 빨간 경고, 문구는 막는 까닭")
    func blocked() throws {
        let alert = try #require(evaluate(.installed(events: events), blocker: .managedHooksOnly))
        #expect(alert.kind == .blocked)
        #expect(alert.isError)
        #expect(alert.detail == HookBlocker.managedHooksOnly.message)
    }

    @Test("settings.json을 읽을 수 없으면 빨간 경고")
    func unreadable() {
        #expect(evaluate(.settingsUnreadable("JSON 오류"))?.kind == .settingsUnreadable)
    }

    @Test("버전을 알고 이벤트가 빠졌으면 다시 설치, 버전을 모르면 따지지 않는다")
    func missingEvents() throws {
        let version = ClaudeVersion(2, 1, 321)
        let alert = try #require(evaluate(.installed(events: events), version: version))
        #expect(alert.kind == .missingEvents)
        #expect(alert.action == .reinstall)
        #expect(evaluate(.installed(events: events)) == nil)
    }
}
