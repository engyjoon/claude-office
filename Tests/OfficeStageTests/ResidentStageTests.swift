import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 데스크톱 세션 미리 출근이 무대·미니 사무실에서 어떻게 보이는지 (M5(5))
@Suite("데스크톱 세션 미리 출근 (무대)")
struct ResidentStageTests {
    func roll(_ h: FloorHarness, _ items: [(cli: String, folder: String, idle: Double)]) -> ResidentRoll {
        let now = h.epoch.addingTimeInterval(h.now)
        let residents = items.map {
            ResidentSession(
                session: SessionID($0.cli), hostSession: "local_\($0.cli)", rootCwd: $0.folder, lastActivity: now.addingTimeInterval(-$0.idle))
        }
        return ResidentRoll(residents: residents, openHostSessions: Set(residents.map(\.hostSession)), isReliable: true, readAt: now)
    }

    func settle(_ h: inout FloorHarness, _ roll: ResidentRoll) {
        let directives = h.engine.syncResidents(roll, at: h.epoch.addingTimeInterval(h.now))
        h.floor.apply(directives, engine: h.engine)
    }

    @Test("앱을 켤 때 우르르 걸어 들어오지 않는다: 제자리에 바로 놓이고 효과음이 없다")
    func noCrowdOnLaunch() throws {
        var h = FloorHarness()
        settle(&h, roll(h, [("a", "/w/office", 7200), ("b", "/w/blog", 86400 * 3), ("c", "/w/site", 90)]))
        h.run(until: 0.5)
        #expect(h.stage.sortedActors.count == 3)
        #expect(h.stage.sortedActors.allSatisfy { !$0.isWalking })
        #expect(!h.events.contains { if case .sound = $0 { true } else { false } })
        let a = try #require(h.engine.state.lead(of: SessionID("a")))
        let actor = try #require(h.stage.sortedActors.first { $0.id == a.id })
        #expect(actor.pose == .sleeping && actor.seated && actor.emote == .zzz)
        let c = try #require(h.engine.state.lead(of: SessionID("c")))
        #expect(h.stage.sortedActors.first { $0.id == c.id }?.loungeSeat == .sofa)
    }

    @Test("미니 사무실: 미리 앉힌 사람은 최근 요청한 행을 밀어내지 않는다")
    func miniFocusUnchanged() throws {
        var h = FloorHarness(band: true)
        h.hook(hook("SessionStart", session: "m1", cwd: "/w/m1"), at: 0)
        h.hook(hook("UserPromptSubmit", #""prompt":"x""#, session: "m1", cwd: "/w/m1"), at: 1)
        let m1 = try #require(h.engine.state.lead(of: SessionID("m1"))?.teamID)
        let before = MiniFocus.next(previous: .empty, state: h.engine.state, pinned: nil, autoSwitch: true, now: h.epoch.addingTimeInterval(h.now))
        #expect(before.team == m1 && before.reason == .requested)

        settle(&h, roll(h, [("a", "/w/office", 30), ("b", "/w/blog", 5)]))
        let after = MiniFocus.next(previous: before, state: h.engine.state, pinned: nil, autoSwitch: true, now: h.epoch.addingTimeInterval(h.now))
        #expect(after.team == m1 && after.reason == .requested)
        #expect(after.tiers.values.filter { $0 == .none }.count == 2)

        // 훅을 보낸 행이 없으면 먼저 앉힌 행(최근에 활동한 행이 먼저)을 보여 줌
        var fresh = FloorHarness(band: true)
        settle(&fresh, roll(fresh, [("a", "/w/office", 30), ("b", "/w/blog", 5)]))
        let first = MiniFocus.next(previous: .empty, state: fresh.engine.state, pinned: nil, autoSwitch: true, now: fresh.epoch)
        #expect(first.team == fresh.engine.state.lead(of: SessionID("a"))?.teamID && first.reason == .none)
    }
}

@Suite("화면에 보일 행: 최근 활동 순 (M5(5) 화면 확인)")
struct RecentRowsTests {
    @Test("앱을 켠 뒤 새로 연 세션이 일하면, 오래 쉰 데스크톱 세션 대신 보인다")
    func newSessionReplacesOldResident() throws {
        var h = FloorHarness()  // 기본 창 = 3행
        let now = h.epoch
        let residents = [("a", 60.0), ("b", 86400 * 3), ("c", 86400 * 11), ("d", 86400 * 12)].map {
            ResidentSession(session: SessionID($0.0), hostSession: "local_\($0.0)", rootCwd: "/w/\($0.0)", lastActivity: now.addingTimeInterval(-$0.1))
        }
        let roll = ResidentRoll(residents: residents, openHostSessions: Set(residents.map(\.hostSession)), isReliable: true, readAt: now)
        h.floor.apply(h.engine.syncResidents(roll, at: now), engine: h.engine)
        func team(_ s: String) -> TeamID { h.engine.state.lead(of: SessionID(s))!.teamID }
        #expect(h.floor.plan.rows.map(\.team) == [team("a"), team("b"), team("c")])
        #expect(h.floor.plan.hiddenTeams == [team("d")])

        // 새 세션 e가 와서 요청 → 메인5, 맨 아래 행으로 보이고 11일째 쉬는 c가 숨음
        h.hook(hook("SessionStart", session: "e", cwd: "/w/e"), at: 1)
        h.hook(hook("UserPromptSubmit", #""prompt":"x""#, session: "e", cwd: "/w/e"), at: 2)
        h.run(until: 3)
        #expect(h.engine.state.lead(of: SessionID("e"))?.displayName == "메인5")
        #expect(h.floor.plan.rows.map(\.team) == [team("a"), team("b"), team("e")])
        #expect(Set(h.floor.plan.hiddenTeams) == [team("c"), team("d")])
        #expect(h.stage.sortedActors.contains { $0.agent.session == SessionID("e") })
        #expect(!h.stage.sortedActors.contains { $0.agent.session == SessionID("c") })
    }
}
