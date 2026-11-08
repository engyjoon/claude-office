import Foundation
import Testing

@testable import OfficeCore

/// 테스트용 설정 저장소
final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

@Suite("설정 이전과 동작 줄이기 (M5(8))")
struct SettingsTests {
    @Test("옛 표시 수준 키를 새 키로 옮기고 옛 키는 지운다")
    func migratesPrivacy() {
        let store = MemoryStore(["privacy": "summary", "sound.volume": 0.4, "office.widenedTo1400": true])
        let moved = SettingsMigration.migrate(store)
        #expect(moved == ["privacy → display.privacy"])
        #expect(store.values["display.privacy"] as? String == "summary")
        #expect(store.values["privacy"] == nil)
        #expect(store.values["sound.volume"] as? Double == 0.4)
        #expect(store.values["office.widenedTo1400"] == nil)
        #expect(store.values[SettingsMigration.versionKey] as? Int == SettingsMigration.currentVersion)
        #expect(PrivacyLevel(store: store) == .summary)
    }

    @Test("M5(9): 1단계를 마친 맥에서 예전 창 보정 표시만 지운다")
    func removesWindowFlags() {
        let store = MemoryStore([
            SettingsMigration.versionKey: 1, "office.widenedTo1440": true, "office.tallerForStatusLine": true, "display.privacy": "summary",
        ])
        #expect(SettingsMigration.migrate(store).isEmpty)
        #expect(store.values["office.widenedTo1440"] == nil)
        #expect(store.values["office.tallerForStatusLine"] == nil)
        #expect(store.values["display.privacy"] as? String == "summary")
        #expect(store.values[SettingsMigration.versionKey] as? Int == 2)
    }

    @Test("새 키에 이미 값이 있으면 새 값을 지킨다")
    func keepsNewValue() {
        let store = MemoryStore(["privacy": "hidden", "display.privacy": "summary"])
        SettingsMigration.migrate(store)
        #expect(store.values["display.privacy"] as? String == "summary")
        #expect(store.values["privacy"] == nil)
    }

    @Test("이전은 한 번만 돈다: 끝낸 뒤 생긴 옛 키는 건드리지 않는다")
    func runsOnce() {
        let store = MemoryStore(["privacy": "hidden"])
        SettingsMigration.migrate(store)
        store.values["privacy"] = "detailed"
        #expect(SettingsMigration.migrate(store).isEmpty)
        #expect(store.values["display.privacy"] as? String == "hidden")
    }

    @Test("처음 켠 앱: 옮길 것이 없고 기본값을 쓴다")
    func freshInstall() {
        let store = MemoryStore()
        #expect(SettingsMigration.migrate(store).isEmpty)
        #expect(store.values[SettingsMigration.versionKey] as? Int == SettingsMigration.currentVersion)
        #expect(PrivacyLevel(store: store) == .detailed)
        #expect(MotionSettings(store: store) == MotionSettings(followSystem: true, alwaysReduce: false))
    }

    @Test("동작 줄이기: 항상 켬이 우선, 아니면 시스템을 따를 때만 시스템 값")
    func reduceMotionDecision() {
        let follow = MotionSettings(followSystem: true, alwaysReduce: false)
        #expect(follow.reducesMotion(systemReduceMotion: true))
        #expect(!follow.reducesMotion(systemReduceMotion: false))
        let ignore = MotionSettings(followSystem: false, alwaysReduce: false)
        #expect(!ignore.reducesMotion(systemReduceMotion: true))
        let always = MotionSettings(followSystem: false, alwaysReduce: true)
        #expect(always.reducesMotion(systemReduceMotion: false))
        #expect(MotionSettings(followSystem: true, alwaysReduce: true).reducesMotion(systemReduceMotion: false))
        #expect(ignore.summary(systemReduceMotion: true).contains("따르지 않음"))
        #expect(follow.summary(systemReduceMotion: true).contains("시스템 설정을 따름"))
        #expect(always.summary(systemReduceMotion: false).contains("항상"))
    }

    @Test("동작 줄이기 설정을 저장하고 다시 읽는다")
    func motionRoundTrip() {
        let store = MemoryStore()
        MotionSettings(followSystem: false, alwaysReduce: true).save(to: store)
        #expect(MotionSettings(store: store) == MotionSettings(followSystem: false, alwaysReduce: true))
    }
}

@Suite("테스트 이벤트 시나리오 (M5(8))")
struct HookTestScenarioTests {
    @Test("가짜 세션이 출근했다가 퇴근하고, 알림은 걸러진다")
    func scenario() throws {
        var engine = OfficeEngine(seed: 5)
        engine.notificationSettings = NotificationSettings(permission: true, completion: true)
        let session = HookTestScenario.sessionID(at: Fixture.epoch)
        #expect(HookTestScenario.isTestSession(session))
        var clock = Fixture.epoch
        var spawned = false
        var notices: [NoticeAction] = []
        for step in HookTestScenario.steps(session: session) {
            clock = clock.addingTimeInterval(step.delay)
            let directives = try engine.handle(hookPayload: Data(step.payload.utf8), at: clock)
            if directives.contains(where: { if case .spawn = $0.action { true } else { false } }) { spawned = true }
            notices += engine.drainNotices()
        }
        #expect(spawned)
        // 응답 완료 알림을 켜 두었으니 엔진은 알림을 내지만, 테스트 세션 것은 걸러집니다
        #expect(notices.contains { if case .post = $0 { true } else { false } })
        #expect(!HookTestScenario.withoutTestNotices(notices).contains { if case .post = $0 { true } else { false } })
        // 퇴근 지시를 다 흘리면 사무실이 빕니다
        for second in 1...60 { _ = engine.tick(at: clock.addingTimeInterval(Double(second))) }
        #expect(!engine.state.agents.values.contains { $0.session.raw == session })
        #expect(HookTestScenario.duration > 5 && HookTestScenario.duration < 15)
    }

    @Test("다른 세션의 알림은 그대로 둔다")
    func keepsRealNotices() {
        let notice = OfficeNotice(
            id: "n", kind: .permission, title: "메인 승인 대기", subtitle: "w", body: "b", agent: AgentID("lead-1"),
            session: SessionID("real"), term: nil, hostSession: nil, isUpdate: false)
        let actions: [NoticeAction] = [.post(notice), .remove(["x"])]
        #expect(HookTestScenario.withoutTestNotices(actions) == actions)
    }
}
