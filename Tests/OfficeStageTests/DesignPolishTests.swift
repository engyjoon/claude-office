import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 개선 8: 화면 디자인 다듬기 — 칩 주인·폭, 밤 이모트, 같은 폴더 행 표지, 글자 폭, 종이비행기 텍스처
@Suite("화면 디자인 다듬기 (개선 8)")
struct DesignPolishTests {
    static let longCommand = "Bash · swift build --configuration release"

    /// 메인 1명과 서브 5명이 한 행에, 모두 긴 상태 칩
    static func crowdedWithPills() -> StageHarness {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        for index in 1...5 {
            h.hook(tool("PreToolUse", "Agent", "a\(index)", #"{"description":"일 \#(index)","subagent_type":"general-purpose"}"#), at: Double(index))
        }
        h.run(until: 40)
        let ids = ["lead-1", "member-2", "member-3", "member-4", "member-5", "member-6"]
        h.stage.enqueue(ids.map { Directive(AgentID($0), .status(StatusPill(category: .shell, text: longCommand))) })
        h.run(until: h.now + 0.5)
        return h
    }

    static func pills(_ items: [OverlayItem]) -> [OverlayItem] { items.filter { $0.kind == .pill && $0.agent != nil } }

    @Test("칩은 제 머리 위 자기 몫(책상 간격)에 맞춰 줄이고, 옆 사람 머리 위로 밀리거나 위로 쌓이지 않는다")
    func pillsStayOverOwner() throws {
        let h = Self.crowdedWithPills()
        let pills = Self.pills(Overlay.items(for: h.stage))
        #expect(pills.count == 6)
        for (index, pill) in pills.enumerated() {
            let frame = try #require(pill.frame)
            let owner = try #require(h.stage.actors[pill.agent!])
            // 주인의 머리가 칩 아래에 있고, 칩은 머리 바로 위 한 줄에 있습니다
            #expect(frame.x < owner.position.x && owner.position.x < frame.maxX, "\(pill.id)")
            #expect(abs(frame.maxY - (owner.position.y + Overlay.headTop)) < 0.01, "\(pill.id) 쌓임")
            for other in pills[(index + 1)...] {
                #expect(!frame.intersects(other.frame!), "\(pill.id) ↔ \(other.id)")
            }
            // 옆 사람의 머리 위로 넘어가지 않습니다
            for neighbor in h.stage.actors.values where neighbor.id != owner.id && abs(neighbor.position.y - owner.position.y) < 1 {
                #expect(!(frame.x < neighbor.position.x && neighbor.position.x < frame.maxX), "\(pill.id)가 \(neighbor.id) 머리 위")
            }
            #expect(pill.text?.hasSuffix("…") == true)
        }
        // 서브 사이(92)는 89pt 안, 메인과 첫 서브 사이(110)는 더 넓게
        let byID = Dictionary(uniqueKeysWithValues: pills.map { ($0.agent!.raw, $0.frame!) })
        let inner = try #require(byID["member-3"])
        #expect(inner.width <= OfficeLayout.deskSpacing - Overlay.gap + 0.01)
        #expect(try #require(byID["member-2"]).width > inner.width)
        #expect(try #require(byID["lead-1"]).width > inner.width)
    }

    @Test("마우스를 올리거나 고른 사람의 칩만 전체를 보여 주고, 다른 칩을 밀지 않고 맨 위에 덮는다")
    func expandedPill() throws {
        let h = Self.crowdedWithPills()
        let normal = Self.pills(Overlay.items(for: h.stage))
        let target = AgentID("member-4")
        for options in [OverlayOptions(hovered: target), OverlayOptions(selected: target)] {
            let items = Overlay.items(for: h.stage, options: options)
            let pills = Self.pills(items)
            let expanded = try #require(pills.first { $0.agent == target })
            #expect(expanded.text == Self.longCommand)
            // 칩 가운데 맨 나중(맨 위)에 그립니다
            #expect(pills.last?.agent == target)
            // 다른 사람 칩은 그대로
            for pill in pills where pill.agent != target {
                #expect(pill == normal.first { $0.id == pill.id })
            }
        }
    }

    @Test("미니 띠(390, 칸 3개)에서도 긴 칩 셋이 한 줄로 겹치지 않는다")
    func miniPillsDoNotOverlap() throws {
        var h = FloorHarness(width: MiniOffice.visibleMapWidth(), height: OfficeLayout.minHeight, band: true)
        func on(_ event: String, _ extra: String) -> String { hook(event, extra, session: "m", cwd: "/w/m") }
        h.hook(on("SessionStart", ""))
        h.select(.only(h.team("m")))
        h.hook(on("UserPromptSubmit", #""prompt":"x""#), at: 0.5)
        for (index, agent) in ["g1", "g2"].enumerated() {
            h.hook(on("PreToolUse", #""tool_name":"Agent","tool_use_id":"a\#(index)","tool_input":{"description":"일","subagent_type":"general-purpose"}"#), at: 1 + Double(index))
            h.hook(on("SubagentStart", #""agent_id":"\#(agent)","agent_type":"general-purpose""#), at: 1.2 + Double(index))
        }
        h.run(until: 15)
        let agentField = { (agent: String) in #","agent_id":"\#(agent)","agent_type":"general-purpose""# }
        h.hook(on("PreToolUse", #""tool_name":"WebSearch","tool_use_id":"w1","tool_input":{"query":"NSPanel floating window level"}"# + agentField("g1")), at: 16)
        h.hook(on("PreToolUse", #""tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/x/VeryLongFileNameForTesting.swift"}"# + agentField("g2")), at: 16.2)
        h.hook(on("PreToolUse", #""tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"swift test --parallel --verbose"}"#), at: 16.4)
        h.run(until: 22)
        let pills = Self.pills(Overlay.items(for: h.stage, options: OverlayOptions(bounds: BubbleBesideHeadTests.miniBounds)))
        #expect(pills.count == 3)
        let area = BubbleBesideHeadTests.miniBounds.insetBy(4)
        for (index, pill) in pills.enumerated() {
            let frame = try #require(pill.frame)
            let owner = try #require(h.stage.actors[pill.agent!])
            #expect(frame.x < owner.position.x && owner.position.x < frame.maxX, "\(pill.id)")
            #expect(frame.x >= area.x && frame.maxX <= area.maxX && frame.y >= area.y)
            for other in pills[(index + 1)...] {
                #expect(!frame.intersects(other.frame!, gap: Overlay.gap - 0.01), "\(pill.id) ↔ \(other.id)")
            }
        }
    }

    @Test("칩 폭 재기: 풀어 쓴(NFD) 한글은 합친 한글과 같은 폭, 이모지 잇기·변형 선택자·피부색은 한 글자")
    func textWidthGraphemes() {
        let nfc = "디자인 다듬기.md"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count > nfc.unicodeScalars.count)
        #expect(TextMetrics.width(nfd, size: 10) == TextMetrics.width(nfc, size: 10))
        let one = TextMetrics.width("😀", size: 10)
        #expect(TextMetrics.width("👨‍👩‍👧", size: 10) == one)  // ZWJ로 이은 가족
        #expect(TextMetrics.width("❤️", size: 10) == TextMetrics.width("❤", size: 10))  // 변형 선택자
        #expect(TextMetrics.width("👍🏽", size: 10) == one)  // 피부색
        #expect(TextMetrics.width("🇰🇷", size: 10) == one)  // 국기
        #expect(TextMetrics.width("e\u{301}", size: 10) == TextMetrics.width("é", size: 10))
        // 풀어 쓴 파일 이름도 칩이 세 배로 넓어지지 않습니다
        #expect(Overlay.fitPill("Read · " + nfd, maxWidth: 400).width == Overlay.fitPill("Read · " + nfc, maxWidth: 400).width)
    }

    @Test("밤에는 ♪·Zz·전구 빛줄기·외침 선을 밝은 색으로, 낮에는 잉크 그대로. 렌더러가 같은 데이터를 쓴다")
    func nightEmotes() {
        let bright = Paint.color(CharacterArt.nightOutlineEdge)
        func paints(_ shapes: [ArtShape]) -> [Paint] { shapes.flatMap { [$0.fill, $0.stroke].compactMap { $0 } } }
        for emote in [Emote.note, .zzz, .bulb] {
            #expect(paints(OverlayArt.emote(emote, lighting: .night)).contains(bright), "\(emote)")
            #expect(!paints(OverlayArt.emote(emote, lighting: .day)).contains(bright), "\(emote)")
            #expect(OverlayArt.emote(emote) == OverlayArt.emote(emote, lighting: .day))
        }
        // ♪·Zz는 잉크를 하나도 쓰지 않습니다 (선과 글자뿐)
        for emote in [Emote.note, .zzz] {
            #expect(!paints(OverlayArt.emote(emote, lighting: .night)).contains(.swatch(.ink)))
        }
        let frame = MapRect(-40, -36, 80, 27)
        #expect(paints(OverlayArt.bubble(.shout, text: "!", frame: frame, lighting: .night)).contains(bright))
        #expect(!paints(OverlayArt.bubble(.shout, text: "!", frame: frame)).contains(bright))

        // 무대가 조명을 넘기고, SVG에도 그 색이 나옵니다 (앱의 OverlayNode도 같은 OverlayItem.shapes를 그림)
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 12)
        h.stage.enqueue([Directive(AgentID("lead-1"), .emote(.zzz))])
        h.run(until: h.now + 1)
        let night = Overlay.items(for: h.stage, options: OverlayOptions(lighting: .night)).first { $0.kind == .emote }
        #expect(night.map { paints($0.shapes).contains(bright) } == true)
        #expect(SVGRenderer.render(stage: h.stage, lighting: .night).contains(CharacterArt.nightOutlineEdge.hex))
        #expect(!SVGRenderer.render(stage: h.stage, lighting: .day).contains(CharacterArt.nightOutlineEdge.hex))
    }

    @Test("종이비행기는 15° 단위로 기울여, 한 번 나는 동안 같은 그림을 여러 번 다시 쓴다")
    func paperPlaneAngles() {
        #expect(OverlayArt.snappedPlaneAngle(0.1) == 0)
        #expect(abs(OverlayArt.snappedPlaneAngle(-1.0) - (-Double.pi / 3)) < 1e-9)
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("UserPromptSubmit", #""prompt":"x""#), at: 8)
        var shapes = Set<[ArtShape]>()
        var frames = 0
        while h.stage.effects.contains(where: { if case .paperPlane = $0.kind { true } else { false } }) {
            for item in Overlay.items(for: h.stage) where item.kind == .effect { shapes.insert(item.shapes) }
            frames += 1
            h.run(until: h.now + 1.0 / 30)
        }
        #expect(frames > 20)
        #expect(shapes.count <= 8, "\(shapes.count)가지 (프레임 \(frames))")
    }

    @Test("같은 폴더의 메인이 둘 이상 보이면 행 표지에 세션 제목을 덧붙인다 (상세일 때만, 제목이 없으면 그대로)")
    func signTitles() {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "a", cwd: "/w/claude-office"), hint: SessionHint(title: "화면 디자인 다듬기"))
        h.hook(hook("SessionStart", session: "b", cwd: "/w/notes"), hint: SessionHint(title: "메모"), at: 0.5)
        h.run(until: 2)
        #expect(h.stage.signTitles.isEmpty)  // 폴더가 다르면 덧붙이지 않음

        // 같은 폴더의 둘째 메인 (제목 모름: 터미널 세션) → 제목을 아는 첫 메인만 덧붙임
        h.hook(hook("SessionStart", session: "c", cwd: "/w/claude-office"), at: 2.5)
        h.run(until: 6)
        let a = h.team("a"), c = h.team("c")
        #expect(h.stage.teams.count == 3)
        #expect(h.stage.signTitles == [a: "화면 디자인 다듬기"])
        #expect(h.stage.signTitles[c] == nil)

        // 표지: 둘째 줄 글자, 제목 줄은 첫 서브 책상 앞에 닿지 않을 폭
        let detailed = SVGRenderer.render(stage: h.stage)
        #expect(detailed.contains("화면 디자인 다듬기"))
        #expect(!SVGRenderer.render(stage: h.stage, overlay: OverlayOptions(privacy: .summary)).contains("화면 디자인 다듬기"))
        let sign = OfficeArt.sign("claude-office", title: "훅 서버·설정 파일 안전 점검", at: MapPoint(OfficeLayout.deskX(0), 366), color: 0)
        let plain = OfficeArt.sign("claude-office", at: MapPoint(OfficeLayout.deskX(0), 366), color: 0)
        #expect(sign.count == plain.count + 1)
        guard case .rect(let box, _) = sign[0].geometry else { Issue.record("표지 상자"); return }
        #expect(box.maxX <= OfficeLayout.deskX(1) - OfficeLayout.deskWidth / 2 - 3)
        #expect(box.height == OfficeArt.signTitleHeight)
        guard case .text(let title, _, _, _, _, _) = sign.last!.geometry else { Issue.record("제목 줄"); return }
        #expect(title.hasSuffix("…") && !title.hasSuffix(" …"))
        // 제목이 없으면 지금 모양 그대로
        #expect(OfficeArt.sign("claude-office", title: nil, at: MapPoint(70, 366), color: 1) == OfficeArt.sign("claude-office", at: MapPoint(70, 366), color: 1))
    }
}
