import Foundation
import Testing

@testable import OfficeCore

/// 응답 중에 앱을 켠 세션 (2026-11-19): 켠 뒤 그 세션의 훅이 오기 전까지 "쉬는 중"으로 앉아 있었습니다.
/// 데스크톱 기록의 마지막 활동이 응답 경계보다 뒤이고 최근이면 "생각 중"으로 앉힙니다 (`ResidentSession.isResponding`).
@Suite("응답 중에 앱을 켠 세션")
struct RespondingResidentTests {
    static let folder = "/Users/demo/work/claude-office"
    let hook = Hook(session: "s1", cwd: Self.folder)
    let session = SessionID("s1")

    /// `edge`초에 응답 경계, `activity`초에 마지막 활동이 찍힌 데스크톱 세션
    func resident(edge: Double, activity: Double) -> ResidentSession {
        ResidentSession(
            session: session, hostSession: "local_s1", rootCwd: Self.folder, title: "제목",
            lastActivity: Fixture.epoch.addingTimeInterval(activity), lastTurnEdge: Fixture.epoch.addingTimeInterval(edge))
    }

    /// `seconds`초에 앱을 켜서 그 세션을 앉힙니다
    func seated(_ resident: ResidentSession, at seconds: Double) -> EngineHarness {
        var h = EngineHarness()
        h.advance(to: seconds)
        let roll = ResidentRoll(residents: [resident], openHostSessions: [resident.hostSession], isReliable: true, readAt: h.date)
        h.log += h.engine.syncResidents(roll, at: h.date).map { (seconds, $0) }
        return h
    }

    func lead(_ h: EngineHarness) -> Agent? { h.engine.state.lead(of: session) }

    @Test("판정: 마지막 활동이 응답 경계보다 1초 넘게 뒤이고 5분 안일 때만 응답 중")
    func verdict() {
        let now = Fixture.epoch.addingTimeInterval(600)
        #expect(resident(edge: 100, activity: 598).isResponding(at: now))
        #expect(resident(edge: 595.5, activity: 598).isResponding(at: now))
        // 끝난 응답: 경계와 활동이 거의 같은 때 (실측 0.013~0.06초)
        #expect(!resident(edge: 598, activity: 598.06).isResponding(at: now))
        // 끝 표시 없이 멈춘 응답: 차이는 크지만 마지막 활동이 오래됨
        #expect(!resident(edge: 100, activity: 290).isResponding(at: now))
        // 필드가 없으면 지금까지처럼 쉬는 중
        #expect(!ResidentSession(session: session, hostSession: "local_s1").isResponding(at: now))
    }

    @Test("응답 중이면 생각 중으로 앉는다: 응답 시작부터 세고, 배지 없이, 쉬러 가지 않는다")
    func seatsThinking() throws {
        var h = seated(resident(edge: 100, activity: 598), at: 600)
        let agent = try #require(lead(h))
        #expect(agent.activity == .thinking)
        #expect(agent.activitySince == Fixture.epoch.addingTimeInterval(100))
        #expect(agent.cue == nil)
        #expect(Roster.make(from: h.engine.state, privacy: .detailed).mood == .working)
        #expect(h.actions(of: agent.id).contains(.pose(.thinking)))
        // 응답을 시작한 지 8분이 넘었어도 안마 의자·소파·잠으로 가지 않습니다
        let spot = h.engine.choreographer.spot(of: agent.id)
        h.advance(to: 1300)
        #expect(h.engine.choreographer.spot(of: agent.id) == spot)
        #expect(!h.actions(of: agent.id).contains(.pose(.sleeping)))
    }

    @Test("그 뒤 Stop이 오면 평소처럼 응답을 끝내고, 도구 훅이 오면 일하는 모습으로")
    func hooksTakeOver() throws {
        var h = seated(resident(edge: 100, activity: 598), at: 600)
        h.send(hook.tool("PreToolUse", "Bash", id: "b1", input: ["command": "make test"]), at: 610)
        #expect(Roster.make(from: h.engine.state, privacy: .detailed).teams.first?.rows.first?.status == .running)
        h.send(hook.tool("PostToolUse", "Bash", id: "b1", input: ["command": "make test"]), at: 611)
        h.send(hook.make("Stop"), at: 620)
        #expect(try #require(lead(h)).activity == .idle)
        #expect(try #require(lead(h)).cue == .unread)
    }

    @Test("훅이 끝내 오지 않으면 마지막 활동부터 1시간 뒤에 쉬는 상태로 풀린다 (그 전에는 그대로)")
    func expires() throws {
        var h = seated(resident(edge: 100, activity: 598), at: 600)
        h.advance(to: 598 + OfficeState.silenceLimit - 30)
        #expect(try #require(lead(h)).activity == .thinking)
        h.advance(to: 598 + OfficeState.silenceLimit + 30)
        #expect(try #require(lead(h)).isResting)
    }

    @Test("응답을 끝낸 세션과 오래 멈춘 세션은 지금까지처럼 쉬는 중으로 앉는다")
    func restingAsBefore() throws {
        let done = seated(resident(edge: 598, activity: 598.06), at: 600)
        #expect(try #require(lead(done)).activity == .idle)
        #expect(done.engine.state.parts[session]?.completedAt == Fixture.epoch.addingTimeInterval(598))
        let stale = seated(resident(edge: 100, activity: 200), at: 600)
        #expect(try #require(lead(stale)).activity == .idle)
    }
}
