import Foundation
import Testing

@testable import OfficeCore

/// 사무실 안에서 겹치지 않는 외형 (설계서 §9.4, M5(6))
@Suite("외형 배정")
struct AppearanceAllocatorTests {
    let hook = Hook()

    func apply(_ state: inout OfficeState, _ payload: JSONValue, at seconds: Double = 0) -> [Beat] {
        guard let event = HookParser.parse(payload, receivedAt: Fixture.epoch.addingTimeInterval(seconds)) else { return [] }
        return state.apply(event)
    }

    /// 어떤 두 사람이든 눈에 띄는 부위가 몇 군데 이상 다른지
    func minimumDifference(_ appearances: [Appearance]) -> Int {
        var minimum = 4
        for i in appearances.indices {
            for j in appearances.indices where j > i {
                minimum = min(minimum, AppearanceAllocator.visibleDifference(appearances[i], appearances[j]))
            }
        }
        return minimum
    }

    func occupants(_ appearances: [Appearance]) -> [AppearanceAllocator.Occupant] {
        appearances.map { .init(appearance: $0, sameRow: false) }
    }

    @Test("피부색만 다른 경우는 겹침으로 친다")
    func skinOnlyIsDuplicate() {
        let a = Appearance(skinTone: 0, hairStyle: 1, hairColor: 2, topColor: 3, accessory: .glasses, voice: 0)
        var b = a
        b.skinTone = 3
        b.voice = 4
        #expect(AppearanceAllocator.visibleDifference(a, b) == 0)
        var c = a
        c.hairColor = 5
        #expect(AppearanceAllocator.visibleDifference(a, c) == 1)
    }

    @Test("1순위가 비어 있으면 1순위를 쓰고, 겹치면 2군데 이상 다른 조합을 고른다")
    func preferredOrAvoid() {
        let preferred = Appearance.make(key: "session#x", kind: .lead)
        #expect(AppearanceAllocator.allocate(key: "session#x", kind: .lead, among: []) == preferred)

        // 피부색만 다른 사람이 있으면 겹침
        var twin = preferred
        twin.skinTone = (twin.skinTone + 1) % Appearance.skinToneCount
        let chosen = AppearanceAllocator.allocate(key: "session#x", kind: .lead, among: occupants([twin]))
        #expect(AppearanceAllocator.visibleDifference(chosen, twin) >= 2)
        // 피부색은 1순위 그대로
        #expect(chosen.skinTone == preferred.skinTone)
    }

    @Test("같은 입력이면 같은 결과")
    func deterministic() {
        var crowd: [Appearance] = []
        for index in 0..<30 {
            crowd.append(AppearanceAllocator.allocate(key: "session#\(index)", kind: .lead, among: occupants(crowd)))
        }
        let again = (0..<30).reduce(into: [Appearance]()) { list, index in
            list.append(AppearanceAllocator.allocate(key: "session#\(index)", kind: .lead, among: occupants(list)))
        }
        #expect(crowd == again)
    }

    @Test("40명이 와도 어떤 두 사람이든 2군데 이상 다르다 (세션·직접 만든 에이전트·새싹 섞어서)")
    func fortyPeople() {
        var crowd: [Appearance] = []
        for index in 0..<40 {
            let (key, kind): (String, StaffKind) = switch index % 4 {
            case 0: ("session#s\(index)", .lead)
            case 1: ("agent-\(index % 7)", .fixed)
            default: ("temp#\(index)", .temporary)
            }
            crowd.append(AppearanceAllocator.allocate(key: key, kind: kind, among: occupants(crowd)))
        }
        #expect(minimumDifference(crowd) >= 2)
    }

    @Test("세션만 40명이어도, 새싹만 20명이어도 2군데 이상 다르다")
    func fortyOfOneKind() {
        var leads: [Appearance] = []
        for index in 0..<40 {
            leads.append(AppearanceAllocator.allocate(key: "session#lead-\(index)", kind: .lead, among: occupants(leads)))
        }
        #expect(minimumDifference(leads) >= 2)

        var sprouts: [Appearance] = []
        for serial in 1...20 {
            sprouts.append(AppearanceAllocator.allocate(key: "temp#\(serial)", kind: .temporary, among: occupants(sprouts)))
        }
        #expect(sprouts.allSatisfy { $0.accessory == .sprout })
        #expect(minimumDifference(sprouts) >= 2)
    }

    @Test("조합이 바닥나면 1군데만 다른 조합으로, 그다음 가장 덜 겹치는 조합으로 물러난다")
    func fallback() {
        // 새싹 조합은 240가지(머리 모양 5 × 머리색 8 × 상의 6) → 2군데 이상 다른 사람은 많아야 30명
        var sprouts: [Appearance] = []
        for serial in 1...300 {
            sprouts.append(AppearanceAllocator.allocate(key: "temp#\(serial)", kind: .temporary, among: occupants(sprouts)))
        }
        // 처음 240명은 서로 똑같은 사람이 없음
        #expect(minimumDifference(Array(sprouts.prefix(240))) >= 1)
        // 그 뒤로도 같은 외형은 고르게 나뉨 (한 조합에 2명까지)
        let counts = Dictionary(grouping: sprouts) { [$0.hairStyle, $0.hairColor, $0.topColor] }.mapValues(\.count)
        #expect(counts.values.max() == 2)
    }

    @Test("같은 행에서는 목소리도 되도록 겹치지 않는다")
    func voices() {
        var row: [AppearanceAllocator.Occupant] = []
        for index in 0..<Appearance.voiceCount {
            let appearance = AppearanceAllocator.allocate(key: "temp#\(index)", kind: .temporary, among: row)
            row.append(.init(appearance: appearance, sameRow: true))
        }
        #expect(Set(row.map(\.appearance.voice)).count == Appearance.voiceCount)
    }

    // MARK: - 사무실에서

    @Test("같은 종류의 직접 만든 에이전트가 동시에 둘 오면 얼굴이 다르다")
    func sameTypeTwice() {
        var state = OfficeState()
        _ = apply(&state, hook.make("SessionStart"))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "code-reviewer"]))
        let reviewers = state.agents.values.filter { $0.profile.agentType == "code-reviewer" }.sorted { $0.serial < $1.serial }
        #expect(reviewers.count == 2)
        #expect(reviewers[0].profile.appearance == Appearance.make(key: "code-reviewer", kind: .fixed))
        #expect(AppearanceAllocator.visibleDifference(reviewers[0].profile.appearance, reviewers[1].profile.appearance) >= 2)
    }

    @Test("1순위가 막혀 다른 얼굴로 왔어도, 막던 사람이 없을 때 다시 오면 1순위")
    func returnsToPreferred() {
        let preferred = Appearance.make(key: "session#x", kind: .lead)
        let blocked = AppearanceAllocator.allocate(key: "session#x", kind: .lead, among: occupants([preferred]))
        #expect(AppearanceAllocator.visibleDifference(blocked, preferred) >= 2)
        #expect(AppearanceAllocator.allocate(key: "session#x", kind: .lead, among: []) == preferred)
    }

    @Test("새로 온 사람만 피해서 고르고, 이미 있는 사람의 외형은 바뀌지 않는다")
    func existingUnchanged() {
        var state = OfficeState()
        for index in 0..<30 {
            _ = apply(&state, Hook(session: "other\(index)", cwd: "/w/p\(index % 3)").make("SessionStart"))
            // 새싹끼리는 조합이 적어(2군데 이상 다르면 많아야 30명) 절반에게만 부름
            if index.isMultiple(of: 2) {
                _ = apply(&state, Hook(session: "other\(index)", cwd: "/w/p\(index % 3)").tool("PreToolUse", "Agent", id: "g\(index)", input: ["subagent_type": "general-purpose"]))
            }
        }
        let before = Dictionary(uniqueKeysWithValues: state.agents.values.map { ($0.id, $0.profile.appearance) })
        _ = apply(&state, hook.make("SessionStart"))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "r1", input: ["subagent_type": "code-reviewer"]))
        #expect(state.agents.count == 47)
        for (id, appearance) in before { #expect(state.agents[id]?.profile.appearance == appearance) }
        #expect(minimumDifference(state.agents.values.map(\.profile.appearance)) >= 2)

        // 모두 퇴근하고 s1만 다시 오면 1순위
        _ = apply(&state, hook.make("SessionEnd"))
        for index in 0..<30 { _ = apply(&state, Hook(session: "other\(index)", cwd: "/w/p\(index % 3)").make("SessionEnd")) }
        #expect(state.agents.isEmpty)
        _ = apply(&state, hook.make("SessionStart"))
        #expect(state.lead(of: SessionID("s1"))?.profile.appearance == Appearance.make(key: "session#s1", kind: .lead))
    }

    @Test("1순위를 쓰던 사람이 퇴근하면 다음에 온 같은 키는 다시 1순위")
    func returnsToPreferredAfterBlockerLeaves() {
        var state = OfficeState()
        // 같은 종류 둘: 둘째는 1순위를 피함
        _ = apply(&state, hook.make("SessionStart"))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a1", input: ["subagent_type": "code-reviewer"]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a2", input: ["subagent_type": "code-reviewer"]))
        let preferred = Appearance.make(key: "code-reviewer", kind: .fixed)
        // 1순위를 쓰던 첫째가 퇴근하고 둘째도 퇴근한 뒤 다시 오면 1순위
        _ = apply(&state, hook.tool("PostToolUse", "Agent", id: "a1", input: [:]))
        _ = apply(&state, hook.tool("PostToolUse", "Agent", id: "a2", input: [:]))
        _ = apply(&state, hook.tool("PreToolUse", "Agent", id: "a3", input: ["subagent_type": "code-reviewer"]))
        let again = state.agents.values.filter { $0.profile.agentType == "code-reviewer" }
        #expect(again.count == 1)
        #expect(again.first?.profile.appearance.hairStyle == preferred.hairStyle)
        #expect(AppearanceAllocator.visibleDifference(again.first!.profile.appearance, preferred) == 0)
    }

    @Test("메인이 퇴근해 서브가 승진해도 외형은 그대로")
    func promotionKeepsFace() throws {
        var state = OfficeState()
        let parentHint = SessionHint(hostSession: "local_a")
        let childHint = SessionHint(hostSession: "local_b", ancestors: [SessionID("A")])
        var start = try #require(HookParser.parse(Hook(session: "A").make("SessionStart"), receivedAt: Fixture.epoch))
        start.hint = parentHint
        _ = state.apply(start)
        var child = try #require(HookParser.parse(Hook(session: "B").make("SessionStart"), receivedAt: Fixture.epoch))
        child.hint = childHint
        _ = state.apply(child)
        let before = try #require(state.lead(of: SessionID("B")))
        #expect(!before.isMain)
        _ = state.apply(try #require(HookParser.parse(Hook(session: "A").make("SessionEnd"), receivedAt: Fixture.epoch)))
        let after = try #require(state.lead(of: SessionID("B")))
        #expect(after.isMain)
        #expect(after.profile.appearance == before.profile.appearance)
    }
}
