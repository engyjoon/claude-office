import Foundation
import Testing

@testable import OfficeCore

/// 데스크톱 앱에 열려 있는 세션을 쉬는 중으로 미리 앉히기 (설계서 §5.2, M5(5))
@Suite("데스크톱 세션 미리 출근")
struct ResidentTests {
    static let office = "/Users/demo/work/claude-office"
    static let blog = "/Users/demo/work/blog"

    func at(_ seconds: Double) -> Date { Fixture.epoch.addingTimeInterval(seconds) }

    func resident(_ cli: String, _ host: String, folder: String = office, ancestors: [String] = [], title: String? = nil, idle: Double) -> ResidentSession {
        ResidentSession(
            session: SessionID(cli), hostSession: host, ancestors: ancestors.map(SessionID.init), rootCwd: folder, title: title,
            lastActivity: at(-idle))
    }

    func roll(_ residents: [ResidentSession], open: Set<String>? = nil, readAt: Double = 0, reliable: Bool = true) -> ResidentRoll {
        ResidentRoll(
            residents: residents, openHostSessions: open ?? Set(residents.map(\.hostSession)), isReliable: reliable, readAt: at(readAt))
    }

    /// 메인 A(2시간 전), A가 띄운 서브 C(30초 전), 다른 폴더의 메인 B(5분 전)
    var standard: [ResidentSession] {
        [
            resident("A", "local_a", title: "사무실 작업", idle: 7200),
            resident("C", "local_c", ancestors: ["A"], title: "곁가지", idle: 30),
            resident("B", "local_b", folder: Self.blog, idle: 300),
        ]
    }

    func hook(_ session: String, _ name: String, hint: SessionHint?, at seconds: Double, cwd: String = office) throws -> OfficeEvent {
        var event = try #require(HookParser.parse(Hook(session: session, cwd: cwd).make(name), term: nil, receivedAt: at(seconds)))
        event.hint = hint
        return event
    }

    @Test("열린 세션을 쉬는 중으로 앉힌다: 메인은 각자 행, 띄운 세션은 그 메인의 서브")
    func seatsResidents() throws {
        var engine = OfficeEngine(seed: 1)
        let directives = engine.syncResidents(roll(standard), at: at(0))
        let state = engine.state

        let a = try #require(state.lead(of: SessionID("A")))
        let b = try #require(state.lead(of: SessionID("B")))
        let c = try #require(state.lead(of: SessionID("C")))
        #expect(a.isMain && b.isMain && !c.isMain)
        #expect(c.teamID == a.teamID && b.teamID != a.teamID)
        #expect(a.displayName == "메인1" && b.displayName == "메인2" && c.displayName == "서브")
        #expect(state.sortedTeams.map(\.folder) == [Self.office, Self.blog])
        #expect(state.parts[SessionID("A")]?.title == "사무실 작업")
        #expect(state.parts[SessionID("C")]?.hostSession == "local_c")
        // 쉬는 중, 쉰 시간은 데스크톱 앱의 마지막 활동부터
        for agent in [a, b, c] { #expect(agent.activity == .idle) }
        #expect(a.activitySince == at(-7200))
        let roster = Roster.make(from: state, privacy: .detailed)
        #expect(roster.teams.flatMap(\.rows).allSatisfy { $0.status == .idle && $0.status.label == "쉬는 중" })

        // 조용히: 효과음·말풍선·출입문·걷기 없음, 알림 없음
        #expect(directives.sounds.isEmpty)
        #expect(directives.bubbles.isEmpty)
        #expect(directives.map(\.action).walks.isEmpty)
        let spawns = directives.compactMap { if case .spawn(let agent, let spot) = $0.action { (agent.id, spot) } else { nil } }
        #expect(spawns.count == 3 && !spawns.contains { $0.1 == .door })
        #expect(engine.drainNotices().isEmpty)
        #expect(engine.journal.entries(of: a.id).isEmpty)
    }

    @Test("지난 활동 시각에 맞는 쉼 단계에서 시작한다 (10분 넘으면 자기 책상에서 잠듦)")
    func startsAtRestStage() throws {
        var engine = OfficeEngine(seed: 1)
        let directives = engine.syncResidents(roll([
            resident("nap", "local_1", folder: "/w/1", idle: 3600),
            resident("massage", "local_2", folder: "/w/2", idle: 240),
            resident("lounge", "local_3", folder: "/w/3", idle: 90),
            resident("desk", "local_4", folder: "/w/4", idle: 20),
        ]), at: at(0))
        func lead(_ session: String) throws -> Agent { try #require(engine.state.lead(of: SessionID(session))) }
        func actions(_ session: String) throws -> [Directive.Action] {
            let id = try lead(session).id
            return directives.filter { $0.agent == id }.map(\.action)
        }
        let nap = try lead("nap")
        #expect(engine.choreographer.spot(of: nap.id) == .seat(nap.teamID, .main))
        #expect(try actions("nap").contains(.pose(.sleeping)))
        #expect(try actions("nap").contains(.emote(.zzz)))
        #expect(engine.choreographer.spot(of: try lead("massage").id) == .massageChair)
        #expect(try actions("massage").contains(.pose(.massage)))
        #expect(engine.choreographer.spot(of: try lead("lounge").id) == .lounge)
        #expect(try actions("lounge").contains(.pose(.holdingCup)))
        let desk = try lead("desk")
        #expect(engine.choreographer.spot(of: desk.id) == .seat(desk.teamID, .main))
        #expect(try actions("desk").contains(.sit))

        // 그 뒤는 평소 쉼 흐름: 책상에 있던 사람은 쉰 지 60초가 되면 휴게 공간으로
        var later: [Directive] = []
        for step in 1...200 { later += engine.tick(at: at(Double(step) * 0.25)) }
        #expect(engine.choreographer.spot(of: desk.id) == .lounge)
        #expect(later.filter { $0.agent == nap.id }.isEmpty)  // 이미 잠든 사람은 그대로
    }

    @Test("자는 서브가 빈 책상을 메우면 바로 새 책상으로 옮겨 이어 잔다 (옛 책상에 남아 빈 책상이 늘어나지 않게)")
    func sleepingSubFillsHole() throws {
        // 2026-11-10 실제 증상: btw 세션들이 퇴근한 뒤 서브 명패는 1번 책상에 있는데, 서브는 6번 책상에서 계속 자고 있었음
        var engine = OfficeEngine(seed: 1)
        let subs = (1...4).map { resident("C\($0)", "local_c\($0)", ancestors: ["A"], idle: 3600) }
        let everyone = [resident("A", "local_a", idle: 3600)] + subs
        _ = engine.syncResidents(roll(everyone), at: at(0))
        let last = try #require(engine.state.lead(of: SessionID("C4")))
        #expect(last.seat == Seat(desk: 4))
        #expect(engine.choreographer.spot(of: last.id) == .seat(last.teamID, Seat(desk: 4)))

        // 앞 서브 셋이 퇴근 → 끝 서브가 1번 책상으로
        let left = Array(everyone.prefix(1)) + [subs[3]]
        var directives = engine.syncResidents(roll(left), at: at(1))
        for step in 1...40 { directives += engine.tick(at: at(1 + Double(step) * 0.25)) }
        let moved = try #require(engine.state.lead(of: SessionID("C4")))
        #expect(moved.seat == Seat(desk: 1))
        #expect(engine.choreographer.spot(of: moved.id) == .seat(moved.teamID, Seat(desk: 1)))
        // 자던 그대로 새 책상에서 이어 잠
        let actions = directives.filter { $0.agent == moved.id }.map(\.action)
        #expect(actions.walks == [.seat(moved.teamID, Seat(desk: 1))])
        #expect(actions.last(where: { if case .pose = $0 { true } else { false } }) == .pose(.sleeping))
    }

    @Test("다시 맞춰도 같은 사람: 중복 없음, 지시 없음")
    func idempotent() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let ids = Set(engine.state.agents.keys)
        let again = engine.syncResidents(roll(standard), at: at(5))
        #expect(again.isEmpty)
        #expect(Set(engine.state.agents.keys) == ids)
    }

    @Test("미리 앉힌 세션이 훅을 보내면 같은 캐릭터가 일을 시작한다 (번호·행 그대로)")
    func hookContinuesSamePerson() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let before = try #require(engine.state.lead(of: SessionID("B")))
        let teams = engine.state.sortedTeams.map(\.id)

        let hint = SessionHint(hostSession: "local_b", rootCwd: Self.blog, title: "블로그", hostCliSession: SessionID("B"))
        let directives = engine.handle(try hook("B", "UserPromptSubmit", hint: hint, at: 10, cwd: Self.blog))
        let after = try #require(engine.state.lead(of: SessionID("B")))
        #expect(after.id == before.id && after.displayName == "메인2" && after.activity == .thinking)
        #expect(engine.state.agents.count == 3)
        #expect(engine.state.sortedTeams.map(\.id) == teams)
        #expect(engine.state.parts[SessionID("B")]?.title == "블로그")
        // 출근 연출 없이 깨어나 생각하기 (출입문 등장 없음)
        #expect(!directives.contains { if case .spawn = $0.action { true } else { false } })
        #expect(directives.contains { $0.agent == after.id && $0.action == .pose(.thinking) })
    }

    @Test("데스크톱 앱이 CLI 세션 id를 바꾸면 같은 데스크톱 세션의 사람으로 이어 간다")
    func rekeysByHostSession() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let a = try #require(engine.state.lead(of: SessionID("A")))

        // 세션 안에서 띄운 `claude` 명령: 같은 데스크톱 id를 물려받지만 정보 파일의 CLI id는 A → 다른 사람
        let nested = SessionHint(hostSession: "local_a", hostCliSession: SessionID("A"))
        _ = engine.handle(try hook("N", "SessionStart", hint: nested, at: 5))
        #expect(engine.state.lead(of: SessionID("N"))?.id != a.id)
        #expect(engine.state.lead(of: SessionID("A"))?.id == a.id)

        // 정보 파일이 새 CLI id(A2)를 적음 → 훅이 오면 A가 A2로 이어짐, 서브 C의 조상도 따라 바뀜
        let renewed = SessionHint(hostSession: "local_a", hostCliSession: SessionID("A2"))
        _ = engine.handle(try hook("A2", "UserPromptSubmit", hint: renewed, at: 10))
        #expect(engine.state.lead(of: SessionID("A2"))?.id == a.id)
        #expect(engine.state.parts[SessionID("A")] == nil)
        #expect(engine.state.parts[SessionID("C")]?.ancestors == [SessionID("A2")])

        // 정보 파일을 다시 읽어 A2가 열려 있으면 새로 앉히지 않음
        var residents = standard
        residents[0].session = SessionID("A2")
        residents[1].ancestors = [SessionID("A2")]
        let count = engine.state.agents.count
        _ = engine.syncResidents(roll(residents), at: at(15))
        #expect(engine.state.agents.count == count)
    }

    @Test("정보 파일을 다시 읽었을 때 CLI id가 바뀌어 있으면 쉬고 있던 사람을 그 id로 이어 간다")
    func rekeysOnSync() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let b = try #require(engine.state.lead(of: SessionID("B")))
        var residents = standard
        residents[2].session = SessionID("B2")
        let directives = engine.syncResidents(roll(residents), at: at(5))
        #expect(directives.isEmpty)
        #expect(engine.state.lead(of: SessionID("B2"))?.id == b.id)
        #expect(engine.state.agents.count == 3)
    }

    @Test("보관했거나 목록에서 사라진 세션은 퇴근, 메인이 나가면 서브가 승진")
    func archivedLeave() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let c = try #require(engine.state.lead(of: SessionID("C")))
        // A 보관(목록에는 있지만 열려 있지 않음), B 정보 파일 사라짐
        let directives = engine.syncResidents(roll([standard[1]], open: ["local_c"], readAt: 5), at: at(6))
        #expect(engine.state.lead(of: SessionID("A")) == nil)
        #expect(engine.state.lead(of: SessionID("B")) == nil)
        let promoted = try #require(engine.state.lead(of: SessionID("C")))
        #expect(promoted.id == c.id && promoted.isMain && promoted.displayName == "메인")
        #expect(engine.state.teams.count == 1)
        #expect(directives.contains { if case .despawn = $0.action { true } else { false } })
    }

    @Test("훅으로 일하는 중이면 닫혀도 바로 퇴근시키지 않는다 (10분 넘게 조용하면 퇴근)")
    func busyStays() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.syncResidents(roll(standard), at: at(0))
        let hint = SessionHint(hostSession: "local_b", rootCwd: Self.blog, hostCliSession: SessionID("B"))
        _ = engine.handle(try hook("B", "UserPromptSubmit", hint: hint, at: 10, cwd: Self.blog))
        let closed = roll(Array(standard.prefix(2)), readAt: 20)

        // 파일을 읽은 뒤에 훅이 옴 → 이번 결과로는 퇴근하지 않음
        var stale = closed
        stale.readAt = at(5)
        _ = engine.syncResidents(stale, at: at(21))
        #expect(engine.state.lead(of: SessionID("B")) != nil)
        // 일하는 중 (생각 중, 10초 전) → 그대로
        _ = engine.syncResidents(closed, at: at(25))
        #expect(engine.state.lead(of: SessionID("B")) != nil)
        // 10분 넘게 소식이 없음 → 퇴근
        _ = engine.syncResidents(closed, at: at(10 + 601))
        #expect(engine.state.lead(of: SessionID("B")) == nil)
    }

    @Test("데스크톱 정보가 없는 세션(터미널, office-sim)은 건드리지 않고, 파일을 못 읽으면 아무도 퇴근시키지 않는다")
    func leavesOthersAlone() throws {
        var engine = OfficeEngine(seed: 1)
        _ = engine.handle(try hook("term", "SessionStart", hint: nil, at: 0))
        _ = engine.syncResidents(roll(standard), at: at(1))
        #expect(engine.state.lead(of: SessionID("term")) != nil)
        // 터미널 세션이 먼저 와서 첫 행 → 메인 번호·행 순서 그대로
        #expect(engine.state.sortedTeams.first.flatMap { engine.state.main(of: $0.id) }?.session == SessionID("term"))

        _ = engine.syncResidents(roll([], open: [], readAt: 2, reliable: false), at: at(3))
        #expect(engine.state.agents.count == 4)
        _ = engine.syncResidents(roll([], open: [], readAt: 2), at: at(3))
        #expect(engine.state.agents.count == 1)
        #expect(engine.state.lead(of: SessionID("term")) != nil)
    }

    @Test("훅으로 먼저 온 데스크톱 세션은 다시 앉히지 않고 제목만 맞춘다")
    func hookFirstThenSync() throws {
        var engine = OfficeEngine(seed: 1)
        let hint = SessionHint(hostSession: "local_a", rootCwd: Self.office, hostCliSession: SessionID("A"))
        _ = engine.handle(try hook("A", "UserPromptSubmit", hint: hint, at: 0))
        let a = try #require(engine.state.lead(of: SessionID("A")))
        let directives = engine.syncResidents(roll(standard, readAt: 1), at: at(2))
        #expect(engine.state.lead(of: SessionID("A"))?.id == a.id)
        #expect(engine.state.lead(of: SessionID("A"))?.activity == .thinking)
        #expect(engine.state.parts[SessionID("A")]?.title == "사무실 작업")
        #expect(engine.state.lead(of: SessionID("C"))?.teamID == a.teamID)
        #expect(directives.sounds.isEmpty)
    }
}
