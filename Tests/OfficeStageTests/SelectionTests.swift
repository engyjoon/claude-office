import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

@Suite("고른 직원 표시: 머리 위 ▼ + 몸 외곽선 (M6(15))")
struct SelectionMarkerTests {
    private let lead = AgentID("lead-1")

    @Test("▼는 고른 직원 머리 바로 위 가운데에 가만히 있고, 고르지 않으면 없다")
    func markerAboveHead() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 15)
        let actor = try #require(h.actor("lead-1"))
        #expect(!Overlay.items(for: h.stage).contains { $0.kind == .selection })

        let items = Overlay.items(for: h.stage, options: OverlayOptions(selected: lead))
        let marker = try #require(items.first { $0.kind == .selection })
        #expect(marker.agent == lead)
        #expect(marker.origin == MapPoint(actor.position.x, actor.position.y + Overlay.headTop - 2))
        #expect(marker.scale == 1 && marker.opacity == 1)
        // 머리 위 그림은 가구·직원보다 위 층이라 소파·책상 앞판에 가려지지 않습니다 (오버레이 층)
        #expect(try #require(marker.frame).maxY <= actor.position.y + Overlay.headTop)
    }

    @Test("상태 칩이 있으면 ▼는 칩 위, 말풍선은 ▼ 위로 올라가고, 승인 대기 \"!\"와 겹치지 않는다")
    func markerAbovePillBelowBubble() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(tool("PreToolUse", "Bash", "b1", #"{"command":"npm test"}"#), at: 8)
        h.hook(tool("PermissionRequest", "Bash", "b1", #"{"command":"npm test"}"#), at: 8.2)
        h.run(until: 9)
        let items = Overlay.items(for: h.stage, options: OverlayOptions(selected: lead))
        let marker = try #require(items.first { $0.kind == .selection })
        let markerFrame = try #require(marker.frame)
        let pill = try #require(items.first { $0.kind == .pill && $0.agent == lead })
        let pillFrame = try #require(pill.frame)
        #expect(markerFrame.maxY <= pillFrame.y - 2 + 0.001)
        #expect(!markerFrame.intersects(pillFrame))

        let bubble = try #require(items.first { $0.kind == .bubble && $0.agent == lead })
        #expect(!markerFrame.intersects(try #require(bubble.frame)))
        #expect(bubble.origin.y <= markerFrame.y - 1 + 0.001)

        let emote = try #require(items.first { $0.kind == .emote && $0.agent == lead })
        #expect(abs(emote.origin.x - marker.origin.x) >= 20)
    }

    @Test("머리 왼쪽 위 배지(✉)와 ▼는 떨어져 있다")
    func markerBesideBadge() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("UserPromptSubmit", #""prompt":"x""#), at: 1)
        h.hook(hook("Stop"), at: 2)
        h.run(until: 15)
        let items = Overlay.items(for: h.stage, options: OverlayOptions(selected: lead))
        let badge = try #require(items.first { $0.kind == .badge })
        let marker = try #require(items.first { $0.kind == .selection })
        // 배지 반지름 약 11.5, ▼ 반폭 9
        #expect(abs(badge.origin.x - marker.origin.x) >= 9 + 11.5)
    }

    @Test("▼ 그림: 팀 색 채움, 바깥 밝은 테(밤은 따뜻한 흰색), 대비 증가면 잉크 테두리 2.4")
    func markerArt() {
        let team = Swatch.mint.color
        let day = OverlayArt.selectionMarker(team: team)
        #expect(day.count == 2)
        #expect(day[0].fill == .color(ArtColor(0xFFFFFF)))
        #expect(day[1].fill == .color(team) && day[1].stroke == .swatch(.ink) && day[1].lineWidth == 1.8)
        #expect(OverlayArt.selectionMarker(team: team, lighting: .night)[0].fill == .color(CharacterArt.nightOutlineEdge))
        #expect(OverlayArt.selectionMarker(team: team, contrast: true)[1].lineWidth == 2.4)
    }

    @Test("외곽선 층: 밝은 테 → 팀 색 테, 대비 증가면 바깥에 잉크 테")
    func outlineLayers() {
        let team = Swatch.peach.color
        let day = CharacterArt.outlineLayers(team: team, lighting: .day, contrast: false)
        #expect(day.map(\.color) == [ArtColor(0xFFFFFF), team])
        #expect(day[0].width > day[1].width)
        let night = CharacterArt.outlineLayers(team: team, lighting: .night, contrast: true)
        #expect(night.map(\.color) == [Swatch.ink.color, CharacterArt.nightOutlineEdge, team])
        #expect(night[0].width > night[1].width)
    }

    @Test("실루엣은 모든 도형을 한 색 굵은 선으로 바꾸고, 반투명 그림자와 글자는 뺀다")
    func silhouette() {
        let color = Swatch.lavender.color
        let legs = CharacterArt.silhouette(CharacterArt.seatedLegs(.sofa), color: color, width: 9)
        // 앉은 다리 밑 그림자(반투명)는 빠집니다
        #expect(legs.count == CharacterArt.seatedLegs(.sofa).count - 1)
        #expect(legs.allSatisfy { $0.fill == .color(color) && $0.stroke == .color(color) && $0.lineWidth == 9 })
        let mixed: [ArtShape] = [.text("x", 0, 0, size: 10), .line("M0,0 L4,4"), .circle(0, 0, 3, fill: .skin, opacity: 0.5)]
        let lines = CharacterArt.silhouette(mixed, color: color, width: 5)
        #expect(lines.count == 1)
        #expect(lines[0].fill == nil && lines[0].stroke == .color(color))
        #expect(CharacterArt.headOutline(Appearance.make(key: "a", kind: .lead)).first == CharacterArt.face.first)
    }

    @Test("SVG 스냅숏도 고른 직원을 외곽선과 ▼로 그린다")
    func svg() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 15)
        let plain = SVGRenderer.render(stage: h.stage)
        let selected = SVGRenderer.render(stage: h.stage, selected: lead)
        #expect(!plain.contains("class=\"selection\""))
        #expect(selected.contains("class=\"selection\""))
        // 팀 색(민트) 굵은 테가 몸 둘레에
        #expect(selected.contains("stroke=\"\(Swatch.mint.color.hex)\" stroke-width=\"5.5\""))
        #expect(!plain.contains("stroke-width=\"5.5\""))
    }
}
