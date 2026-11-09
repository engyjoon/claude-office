import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M6(7): 장면 키보드 이동·VoiceOver 읽는 순서
@Suite("장면 키보드 이동")
struct SceneNavigationTests {
    @Test("행(위에서부터) → 책상(왼쪽부터) 순서. 쉬러 가도 순서는 그대로")
    func order() {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m1"))
        h.hook(hook("SessionStart", session: "m2"), at: 0.5)
        h.hook(delegateHook("m1", "a1"), at: 1)
        h.hook(delegateHook("m1", "a2"), at: 1.2)
        h.run(until: 30)
        let names = SceneNavigation.order(h.stage).map { h.stage.actors[$0]!.agent.displayName }
        #expect(names == ["메인1", "서브1", "서브2", "메인2"])
        #expect(SceneNavigation.rows(h.stage).map(\.count) == [3, 1])
        // 메인2가 쉬러 가 휴게 공간에 있어도 자기 행 자리로 셈
        h.run(until: 120)
        #expect(SceneNavigation.order(h.stage).map { h.stage.actors[$0]!.agent.displayName } == names)
    }

    @Test("→·Tab은 다음, 끝을 넘으면 nil. ↑↓는 옆 행의 가장 가까운 책상")
    func moves() {
        let (a, b, c, d) = (AgentID("a"), AgentID("b"), AgentID("c"), AgentID("d"))
        let rows = [[a, b, c], [d]]
        #expect(SceneNavigation.target(from: nil, move: .next, rows: rows) == a)
        #expect(SceneNavigation.target(from: nil, move: .previous, rows: rows) == d)
        #expect(SceneNavigation.target(from: nil, move: .up, rows: rows) == d)
        #expect(SceneNavigation.target(from: a, move: .next, rows: rows) == b)
        #expect(SceneNavigation.target(from: c, move: .next, rows: rows) == d)
        #expect(SceneNavigation.target(from: d, move: .next, rows: rows) == nil)
        #expect(SceneNavigation.target(from: a, move: .previous, rows: rows) == nil)
        #expect(SceneNavigation.target(from: c, move: .down, rows: rows) == d)
        #expect(SceneNavigation.target(from: d, move: .up, rows: rows) == a)
        #expect(SceneNavigation.target(from: a, move: .up, rows: rows) == nil)
        #expect(SceneNavigation.target(from: d, move: .down, rows: rows) == nil)
        // 사라진 사람을 골라 두었으면 처음부터
        #expect(SceneNavigation.target(from: AgentID("x"), move: .next, rows: rows) == a)
        #expect(SceneNavigation.target(from: nil, move: .next, rows: []) == nil)
    }
}
