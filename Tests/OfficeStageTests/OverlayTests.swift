import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 메인 1명과 서브 5명이 한 행에
private func crowdedOffice() -> StageHarness {
    var h = StageHarness()
    h.hook(hook("SessionStart"))
    for index in 1...5 {
        h.hook(tool("PreToolUse", "Agent", "a\(index)", #"{"description":"일 \#(index)","subagent_type":"general-purpose"}"#), at: Double(index))
    }
    h.run(until: 40)
    return h
}

private func say(_ h: inout StageHarness, _ raw: String, _ kind: BubbleKind, _ text: String, duration: Double? = 4) {
    h.stage.enqueue([Directive(AgentID(raw), .say(Bubble(kind: kind, text: text, duration: kind == .shout ? nil : duration)))])
}

@Suite("말풍선 표시 규칙 (설계서 §7.2)")
struct BubbleRuleTests {
    @Test("행(메인 하나와 서브들)마다 말풍선은 3개까지, 넘치면 기다렸다가 자리가 나면 뜬다")
    func perUnitLimit() {
        var h = crowdedOffice()
        let ids = ["lead-1", "member-2", "member-3", "member-4", "member-5", "member-6"]
        #expect(ids.allSatisfy { h.actor($0) != nil })
        for id in ["member-2", "member-3", "member-4"] { say(&h, id, .speech, "안녕하세요", duration: 2) }
        say(&h, "member-5", .speech, "저도요", duration: 2)
        #expect(h.actor("member-5")?.bubble == nil)
        #expect(h.actor("member-5")?.queuedBubble?.bubble.text == "저도요")
        // 메인도 같은 행으로 셉니다
        say(&h, "lead-1", .speech, "다들 고마워요", duration: 2)
        #expect(h.actor("lead-1")?.bubble == nil)
        #expect(h.actor("lead-1")?.queuedBubble != nil)
        #expect(h.stage.actors.values.filter { $0.bubble != nil }.count == 3)

        // 앞의 말풍선이 사라지면 기다리던 말풍선이 뜹니다
        h.run(until: h.now + 2.1)
        #expect(h.actor("member-5")?.bubble?.text == "저도요")
        #expect(h.actor("member-5")?.queuedBubble == nil)
    }

    @Test("말풍선 수는 행(메인)마다 따로 센다")
    func partPodsCountSeparately() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("SessionStart", session: "s2"), at: 0.5)
        for index in 1...3 {
            h.hook(tool("PreToolUse", "Agent", "a\(index)", #"{"subagent_type":"general-purpose"}"#), at: Double(index))
            h.hook(hook("PreToolUse", #""tool_name":"Agent","tool_use_id":"b\#(index)","tool_input":{"subagent_type":"general-purpose"}"#, session: "s2"), at: Double(index) + 0.5)
        }
        h.run(until: 40)
        let mainPod = h.stage.actors.values.filter { $0.agent.role == .member && $0.agent.teamID == TeamID("/w/a-sdn-portal#1") }.map(\.id.raw)
        let partPod = h.stage.actors.values.filter { $0.agent.role == .member && $0.agent.teamID == TeamID("/w/a-sdn-portal#2") }.map(\.id.raw)
        #expect(mainPod.count == 3 && partPod.count == 3)
        for id in mainPod + partPod + ["lead-2"] { say(&h, id, .speech, "네!", duration: 3) }
        // 메인1 행 3개 + 메인2 행 3개 (메인2 포함 4명 중 3개)
        #expect(h.stage.actors.values.filter { $0.bubble != nil }.count == 6)
        #expect(h.actor("lead-2")?.queuedBubble != nil)
    }

    @Test("외침 풍선은 덜 중요한 말풍선의 자리를 빼앗고, 밀려난 말풍선은 남은 시간을 들고 기다린다")
    func shoutDisplaces() {
        var h = crowdedOffice()
        say(&h, "member-5", .speech, "부탁해요!")
        say(&h, "member-2", .thought, "음…")
        say(&h, "member-3", .speech, "네!")
        say(&h, "member-4", .shout, "npm test 해도 될까요?")
        #expect(h.actor("member-4")?.bubble?.kind == .shout)
        #expect(h.actor("member-2")?.bubble == nil)  // 생각 풍선이 가장 덜 중요합니다
        #expect(h.actor("member-2")?.queuedBubble?.bubble.text == "음…")

        // 다른 말풍선이 끝나면 밀려났던 생각 풍선이 다시 뜹니다
        h.run(until: h.now + 4.2)
        #expect(h.actor("member-2")?.bubble?.text == "음…")
        #expect(h.actor("member-4")?.bubble?.kind == .shout)  // 외침 풍선은 닫을 때까지 남습니다
    }

    @Test("오래 기다린 말풍선은 버리고, 닫으면 기다리던 것도 함께 버린다")
    func queueTimeoutAndDismiss() {
        var h = crowdedOffice()
        for id in ["member-2", "member-3", "member-4"] { say(&h, id, .shout, "승인 부탁드려요!") }
        say(&h, "member-5", .speech, "저기요")
        say(&h, "member-6", .shout, "이것도요!")
        #expect(h.actor("member-5")?.queuedBubble != nil)
        h.run(until: h.now + 7)
        #expect(h.actor("member-5")?.queuedBubble == nil)  // 6초 넘게 기다린 말은 버립니다
        #expect(h.actor("member-6")?.queuedBubble != nil)  // 외침 풍선은 기다립니다
        h.stage.enqueue([Directive(AgentID("member-6"), .dismissBubble)])
        #expect(h.actor("member-6")?.queuedBubble == nil)
        h.stage.enqueue([Directive(AgentID("member-2"), .dismissBubble)])
        #expect(h.actor("member-2")?.bubble == nil)
    }

    @Test("말풍선 블립은 말풍선이 실제로 뜰 때 울린다")
    func blipFollowsBubble() {
        var h = crowdedOffice()
        _ = h.stage.drainEvents()
        for id in ["member-2", "member-3", "member-4"] { say(&h, id, .speech, "하나둘", duration: 1) }
        let blip = SoundCue.bubble(voice: 1, syllables: 2)
        h.stage.enqueue([Directive(AgentID("member-5"), .sound(blip)), Directive(AgentID("member-5"), .say(.timed(.speech, "기다려요")))])
        #expect(!h.stage.drainEvents().contains(.sound(blip, AgentID("member-5"))))
        h.run(until: h.now + 1.1)
        #expect(h.events.contains(.sound(blip, AgentID("member-5"))))
    }
}

@Suite("머리 위 그림 배치")
struct OverlayTests {
    @Test("표시 단계: 32·18·10자로 줄이고, 작으면 상태 칩을 숨기고 외침 풍선만 남긴다")
    func tiers() {
        #expect(OverlayTier(scale: 1) == .full)
        #expect(OverlayTier(scale: 0.6) == .compact)
        #expect(OverlayTier(scale: 0.3) == .tiny)
        #expect(Overlay.truncate("가나다라마바사", 5) == "가나다라…")
        #expect(Overlay.truncate("짧아요", 5) == "짧아요")

        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(tool("PreToolUse", "Edit", "e1", #"{"file_path":"/w/RouterConfig.java"}"#), at: 8)
        h.run(until: 9)
        let long = String(repeating: "가", count: 40)
        say(&h, "lead-1", .speech, long)
        let full = Overlay.items(for: h.stage)
        #expect(full.first { $0.kind == .bubble }?.text?.count == 32)
        #expect(full.contains { $0.kind == .pill && $0.text == "Edit · RouterConfig.java" })

        let compact = Overlay.items(for: h.stage, options: OverlayOptions(displayScale: 0.6))
        #expect(compact.first { $0.kind == .bubble }?.text?.count == 18)
        #expect(!compact.contains { $0.kind == .pill })

        let tiny = Overlay.items(for: h.stage, options: OverlayOptions(displayScale: 0.4))
        #expect(!tiny.contains { $0.kind == .bubble })
        say(&h, "lead-1", .shout, "git push 해도 될까요?")
        let tinyShout = Overlay.items(for: h.stage, options: OverlayOptions(displayScale: 0.4))
        #expect(tinyShout.first { $0.kind == .bubble }?.text == "git push…")

        // 마우스를 올리면 전체 문구
        say(&h, "lead-1", .speech, long)
        let hovered = Overlay.items(for: h.stage, options: OverlayOptions(hovered: AgentID("lead-1")))
        #expect(hovered.first { $0.kind == .bubble }?.text == long)
    }

    @Test("표시 수준: 요약은 상태 칩을 툴 종류로, 비공개는 말풍선·칩 없이 아이콘만")
    func privacy() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(tool("PreToolUse", "Bash", "b1", #"{"command":"npm test"}"#), at: 8)
        h.hook(tool("PermissionRequest", "Bash", "b1", #"{"command":"npm test"}"#), at: 8.2)
        h.run(until: 9)
        let detailed = Overlay.items(for: h.stage)
        #expect(detailed.contains { $0.kind == .bubble && $0.text?.contains("npm test") == true })
        #expect(detailed.contains { $0.kind == .pill && $0.text == "Bash · npm test" })

        let summary = Overlay.items(for: h.stage, options: OverlayOptions(privacy: .summary))
        #expect(summary.contains { $0.kind == .pill && $0.text == ToolCategory.shell.summaryLabel })

        let hidden = Overlay.items(for: h.stage, options: OverlayOptions(privacy: .hidden))
        #expect(!hidden.contains { $0.kind == .bubble || $0.kind == .pill })
        #expect(hidden.contains { $0.kind == .emote })
    }

    @Test("겹침 방지: 가까운 말풍선은 겹치지 않고, 화면 안에 머물며, 꼬리는 주인을 가리킨다")
    func noOverlap() throws {
        var h = crowdedOffice()
        for id in ["lead-1", "member-2", "member-3"] { say(&h, id, .speech, "바로 옆자리 동료와 동시에 말해요!") }
        h.run(until: h.now + 0.5)
        let bubbles = Overlay.items(for: h.stage).filter { $0.kind == .bubble }
        #expect(bubbles.count == 3)
        for (index, a) in bubbles.enumerated() {
            let frame = try #require(a.frame)
            #expect(frame.x >= 0 && frame.maxX <= OfficeLayout().width)
            for b in bubbles[(index + 1)...] {
                #expect(!frame.intersects(b.frame!))
            }
            // 꼬리 끝(원점)은 주인의 머리 위에 있습니다
            let owner = try #require(h.stage.actors[a.agent!])
            #expect(abs(a.origin.x - owner.position.x) < 0.01)
            #expect(a.origin.y < owner.position.y - 80)
        }
    }

    @Test("화면 가장자리에서는 말풍선을 안쪽으로 민다")
    func edgeClamp() {
        let area = MapRect(4, 4, 952, 600)
        let placed = Overlay.place(MapRect(-30, 100, 120, 27), avoiding: [], in: area)
        #expect(placed.x == 4)
        let right = Overlay.place(MapRect(900, 100, 120, 27), avoiding: [], in: area)
        #expect(right.maxX == 956)
        let stacked = Overlay.place(MapRect(100, 100, 120, 27), avoiding: [MapRect(40, 100, 240, 27)], in: area)
        #expect(stacked.maxY <= 97)
    }

    @Test("종이비행기는 날아와 팀장에게 도착하고, 하이파이브에는 반짝임이 하나 생긴다")
    func effects() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("UserPromptSubmit", #""prompt":"비밀 내용""#), at: 8)
        #expect(h.stage.effects.contains { $0.kind == .paperPlane(to: AgentID("lead-1")) })
        #expect(Overlay.items(for: h.stage).contains { $0.kind == .effect })
        h.run(until: 10)
        #expect(h.stage.effects.isEmpty)

        // 보고하러 온 팀원이 팀장 옆에서 함께 하이파이브
        var crowd = crowdedOffice()
        crowd.stage.enqueue([Directive(AgentID("member-2"), .walk(to: .beside(AgentID("lead-1"))))])
        crowd.run(until: crowd.now + 5)
        crowd.stage.enqueue([Directive(AgentID("lead-1"), .gesture(.highFive)), Directive(AgentID("member-2"), .gesture(.highFive))])
        #expect(crowd.stage.effects.filter { if case .sparkle = $0.kind { true } else { false } }.count == 1)
    }

    @Test("SVG 스냅숏에도 같은 말풍선·상태 칩·아이콘이 나온다")
    func svg() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(tool("PreToolUse", "Bash", "b1", #"{"command":"npm test"}"#), at: 8)
        h.hook(tool("PermissionRequest", "Bash", "b1", #"{"command":"npm test"}"#), at: 8.2)
        h.run(until: 9)
        let svg = SVGRenderer.render(stage: h.stage)
        #expect(svg.contains("class=\"bubble\""))
        #expect(svg.contains("class=\"pill\""))
        #expect(svg.contains("class=\"emote\""))
        #expect(svg.contains("npm test"))
        #expect(!SVGRenderer.render(stage: h.stage, overlay: nil).contains("class=\"bubble\""))
    }

    @Test("걸을 때 발소리, 타이핑할 때 키보드 소리를 낸다 (재생 여부는 설정이 정함)")
    func ambientSounds() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 3)
        #expect(h.events.contains { if case .sound(.footsteps, _) = $0 { true } else { false } })
        h.hook(tool("PreToolUse", "Edit", "e1", #"{"file_path":"/w/a.swift"}"#), at: 8)
        h.run(until: 12)
        #expect(h.events.contains { if case .sound(.typing, _) = $0 { true } else { false } })
    }

    @Test("글자 폭 어림: 한글은 영문보다 넓고, 굵은 글씨는 조금 더 넓다")
    func textMetrics() {
        #expect(TextMetrics.width("가나다", size: 12) > TextMetrics.width("abc", size: 12))
        #expect(abs(TextMetrics.width("가", size: 100) - 87) < 1)
        #expect(TextMetrics.width("가", size: 12, bold: true) > TextMetrics.width("가", size: 12))
    }
}

@Suite("답변 필요·확인 안 함 배지 (M6(4))")
struct CueBadgeTests {
    @Test("배지는 머리 왼쪽 위에 가만히 있고(Zz·♪는 오른쪽 위), 나타날 때만 빠른 그리기")
    func badgePlacement() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("UserPromptSubmit", #""prompt":"x""#), at: 1)
        h.hook(hook("Stop"), at: 2)
        h.run(until: 15)  // 출입문에서 걸어 들어와 "다 됐어요" 말풍선과 3초 뒤에 배지
        let lead = try #require(h.actor("lead-1"))
        #expect(lead.badge == .unread)
        let items = Overlay.items(for: h.stage)
        let badge = try #require(items.first { $0.kind == .badge })
        #expect(badge.origin == lead.position + Overlay.badgeOffset)
        #expect(badge.scale == 1 && badge.opacity == 1)
        #expect(RenderPacer.motion(h.stage) != .fast)
        // 한참 뒤에도 같은 자리 (통통 튀지 않음)
        h.run(until: 16.3)
        let later = try #require(Overlay.items(for: h.stage).first { $0.kind == .badge })
        #expect(later.origin == h.actor("lead-1")!.position + Overlay.badgeOffset)
    }

    @Test("답변 필요는 파란 말풍선 \"?\", 확인 안 함은 편지")
    func badgeArt() {
        let reply = OverlayArt.badge(.reply)
        #expect(reply.contains { if case .text("?", _, _, _, _, _) = $0.geometry { true } else { false } })
        #expect(OverlayArt.badge(.unread).count == 4)
    }
}
