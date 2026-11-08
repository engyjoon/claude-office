import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M4.5b 방 배치: 파트 칸 줄 늘리기·줄이기, 칸 표지·명패 단위, 공용 구역 분산과 칩 묶기, 긴 명령 모니터, 방 하나만 그리기
@Suite("무대: 방 배치")
struct RoomLayoutStageTests {
    let team = TeamID("/w/a-sdn-portal")

    @Test("파트장이 늘어 칸이 모자라면 아래로 줄을 늘리고, 맨 아래 줄이 통째로 비면 줄인다")
    func rowsGrowAndShrink() {
        var h = StageHarness()
        for index in 1...3 { h.hook(hook("SessionStart", session: "s\(index)"), at: Double(index) * 0.2) }
        h.run(until: 15)
        // 메인 1 + 파트장 2 = 칸 3개 → 2줄 (높이 666)
        #expect(h.stage.layout.bands[0].cells == 4)
        #expect(h.stage.layout.rows == 2)
        #expect(h.stage.layout.height == 666)

        h.hook(hook("SessionStart", session: "s4"), at: 16)
        h.hook(hook("SessionStart", session: "s5"), at: 16.2)
        // 파트장4의 칸(4번)이 생기며 바로 3줄
        #expect(h.stage.layout.bands[0].cells == 6)
        #expect(h.stage.layout.rows == 3)
        h.run(until: 30)
        let partLead4 = h.stage.actors.values.first { $0.agent.part == 4 }!
        #expect(partLead4.position == h.stage.layout.seat(team, Seat(part: 4, desk: 0)).final)

        // 파트장4가 퇴근하면 맨 아래 줄이 비어 (아무도 지나가지 않을 때) 2줄로 돌아갑니다
        h.hook(hook("SessionEnd", session: "s5"), at: 31)
        #expect(h.stage.layout.rows == 3)  // 아직 그 줄에서 걸어 나가는 중
        h.run(until: 50)
        #expect(h.stage.layout.rows == 2)
    }

    @Test("위 방의 줄이 늘면 아래 방은 직원과 함께 통째로 내려간다")
    func lowerBandMovesWithPeople() throws {
        var h = StageHarness()
        h.hook(hook("SessionStart", session: "a1", cwd: "/w/a"))
        h.hook(hook("SessionStart", session: "b1", cwd: "/w/b"), at: 0.2)
        h.run(until: 15)
        let before = try #require(h.actor("lead-2")).position
        let bTop = h.stage.layout.bands[1].top
        // 방 a에 파트장 4명 → a가 3줄로 늘어 방 b가 한 줄 내려갑니다
        for index in 2...5 { h.hook(hook("SessionStart", session: "a\(index)", cwd: "/w/a"), at: 15 + Double(index) * 0.1) }
        #expect(h.stage.layout.bands[1].top == bTop + OfficeLayout.rowSpacing)
        let after = try #require(h.actor("lead-2"))
        #expect(after.position == before + MapPoint(0, OfficeLayout.rowSpacing))
        #expect(after.seated)
        h.run(until: 40)
        #expect(h.actor("lead-2")?.position == h.stage.layout.seat(TeamID("/w/b"), .office).final)
    }

    @Test("칸 표지는 '팀장 칸', '팀원1 칸', '빈 칸'이고 세션 팀원 명패는 자기 칸 첫 책상에 붙는다")
    func podSignsAndPlates() {
        var h = StageHarness()
        h.hook(hook("SessionStart", session: "s1"))
        h.hook(hook("SessionStart", session: "s2"), at: 0.2)
        h.hook(hook("SessionStart", session: "s3"), at: 0.4)
        h.run(until: 15)
        #expect(h.stage.podSigns[team] == [0: "팀장 칸", 1: "팀원1 칸", 2: "팀원2 칸", 3: "빈 칸"])
        #expect(h.stage.nameplates[team]?[.office] == "★ 팀장")
        #expect(h.stage.nameplates[team]?[Seat(part: 1, desk: 0)] == "팀원1")
        #expect(h.stage.nameplates[team]?[Seat(part: 2, desk: 0)] == "팀원2")
        let svg = SVGRenderer.render(stage: h.stage)
        #expect(svg.contains("팀장 칸") && svg.contains("빈 칸"))
    }

    @Test("공용 구역 자리가 넘치면 한 점에 겹치지 않게 흩어 서고, 칩은 '책장 · N명 읽는 중' 하나로 묶는다")
    func crowdedZoneSpreads() throws {
        var h = StageHarness()
        let sessions = (1...6).map { "s\($0)" }
        for (index, session) in sessions.enumerated() { h.hook(hook("SessionStart", session: session), at: Double(index) * 0.1) }
        h.run(until: 15)
        for round in 0..<6 {
            for session in sessions {
                h.hook(hook("PreToolUse", #""tool_name":"Read","tool_use_id":"\#(session)-r\#(round)","tool_input":{"file_path":"/x/F\#(round).swift"}"#, session: session), at: 15 + Double(round) * 1.2)
            }
        }
        h.run(until: 40)
        let readers = h.stage.actors.values.filter { OfficeLayout.zone(ofKey: $0.place?.key) == .bookshelf }
        #expect(readers.count == 6)
        let points = readers.map(\.position)
        for (index, point) in points.enumerated() {
            for other in points[(index + 1)...] { #expect(point.distance(to: other) > 12, "\(point) \(other)") }
        }
        let items = Overlay.items(for: h.stage)
        let pills = items.filter { $0.kind == .pill }
        let group = try #require(pills.first { $0.text?.hasPrefix("책장 · ") == true })
        #expect(group.text == "책장 · 6명 읽는 중")
        #expect(pills.count == 1)
        // 묶음 칩은 화면 안에 있습니다
        #expect((group.frame?.y ?? -1) >= 0)
    }

    @Test("긴 명령을 기다리는 동안 모니터에 진행 표시가 깜빡이고, 안마 의자 롤러는 앉은 사람이 있을 때만 움직인다")
    func liveFurniture() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.run(until: 10)
        h.hook(tool("PreToolUse", "Bash", "b1", #"{"command":"swift build"}"#))
        h.run(until: 13)
        let lead = h.actor("lead-1")!
        #expect(lead.pose == .watching)
        #expect(lead.emote == .hourglass)
        #expect(lead.position == h.stage.layout.seat(team, .office).final)
        let live = OfficeArt.liveLayers(stage: h.stage)
        #expect(live.contains { $0.name == "monitor-lead-1" })
        // 빈 안마 의자의 롤러는 시간이 지나도 그대로
        let roller = live.first { $0.name == "massage-roller" }!
        h.run(until: 14)
        #expect(OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" } == roller)
        h.hook(tool("PostToolUse", "Bash", "b1"))
        h.run(until: 16)
        #expect(!OfficeArt.liveLayers(stage: h.stage).contains { $0.name == "monitor-lead-1" })
    }

    @Test("안마 의자에 앉으면 롤러가 오르내리고 안마 자세가 된다")
    func massageChair() {
        var h = StageHarness()
        h.hook(hook("SessionStart"))
        h.hook(hook("Stop"), at: 10)
        h.run(until: 200)
        let lead = h.actor("lead-1")!
        #expect(lead.pose == .massage)
        #expect(lead.position == OfficeLayout.massageSeat)
        let a = OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" }
        h.run(until: 200.6)
        let b = OfficeArt.liveLayers(stage: h.stage).first { $0.name == "massage-roller" }
        #expect(a != b)
        let pose = RigAnimator.pose(for: h.actor("lead-1")!, time: h.stage.time)
        #expect(pose.leftArm > 20 && pose.rightArm < -20)  // 팔은 팔걸이에
    }

    @Test("방 하나만 그리는 무대는 그 방만 띠로 놓고, 다른 방 직원은 무시한다 (M5 방 선택기 준비)")
    func singleRoomStage() {
        var config = StageConfig()
        config.room = TeamID("/w/b")
        var h = StageHarness()
        h.stage = Stage(config: config)
        h.hook(hook("SessionStart", session: "a1", cwd: "/w/a"))
        h.hook(hook("SessionStart", session: "b1", cwd: "/w/b"), at: 0.2)
        h.run(until: 15)
        #expect(h.stage.layout.bands.map(\.team.raw) == ["/w/b"])
        #expect(h.stage.actors.keys.map(\.raw) == ["lead-2"])
        // 방 b의 팀장이 왼쪽 위 팀장실에 앉습니다
        #expect(h.actor("lead-2")?.position == MapPoint(OfficeLayout.officeDeskX, OfficeLayout.firstDeskY))
    }
}
