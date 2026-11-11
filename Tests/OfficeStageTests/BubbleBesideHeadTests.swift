import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M6(9): 화면 위 끝에 밀린 말풍선은 머리 옆에 두고 꼬리가 옆에서 머리를 가리킨다
/// (미니에서 문으로 나갈 때 꼬리가 상자를 뚫고 위로 솟던 것). 미니는 이제 말풍선을 띄우지 않으므로(`StageConfig.showsBubbles`)
/// 머리 옆 자리는 사무실 창 위 끝에서 쓰입니다.
@Suite("머리 옆 말풍선 (M6(9))")
struct BubbleBesideHeadTests {
    /// 앱의 미니 띠와 같은 보이는 영역 (`OfficeScene.syncOverlays`의 `.band`)
    static var miniBounds: MapRect {
        let extent = MiniOffice.extent()
        return MapRect(0, extent.y, extent.width + extent.x, extent.height)
    }

    /// 서브가 일하고 보고한 뒤 메인이 퇴근하는 장면 (보고 "끝났어요!"류, 퇴근 인사 말풍선이 뜸)
    static let leavingScript: [(Double, String)] = {
        func on(_ event: String, _ extra: String = "") -> String { hook(event, extra, session: "m", cwd: "/w/m") }
        let read = #""tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/x/A.swift"},"agent_id":"g1","agent_type":"general-purpose""#
        return [
            (1, on("UserPromptSubmit", #""prompt":"x""#)),
            (2, on("PreToolUse", #""tool_name":"Agent","tool_use_id":"a1","tool_input":{"description":"일","subagent_type":"general-purpose"}"#)),
            (2.2, on("SubagentStart", #""agent_id":"g1","agent_type":"general-purpose""#)),
            (8, on("PreToolUse", read)),
            (9, on("PostToolUse", read + #","tool_response":{}"#)),
            (12, on("SubagentStop", #""stop_hook_active":false,"agent_id":"g1","agent_type":"general-purpose""#)),
            (12.2, on("PostToolUse", #""tool_name":"Agent","tool_use_id":"a1","tool_input":{"subagent_type":"general-purpose"},"tool_response":{"status":"completed"}"#)),
            (14, on("Stop")),
            (25, on("SessionEnd", #""reason":"exit""#)),
        ]
    }()

    /// 장면을 0.1초마다 돌리며 매번 머리 위 그림을 모읍니다
    static func play(_ h: inout FloorHarness, bounds: MapRect?) -> [(Double, [OverlayItem])] {
        var script = leavingScript
        var frames: [(Double, [OverlayItem])] = []
        var time = 0.0
        while time < 30 {
            while let (at, json) = script.first, at <= time {
                script.removeFirst()
                h.hook(json, at: at)
            }
            h.run(until: time)
            frames.append((time, Overlay.items(for: h.stage, options: OverlayOptions(bounds: bounds))))
            time += 0.1
        }
        return frames
    }

    static func isBubbleSound(_ event: StageEvent) -> Bool {
        if case .sound(let cue, _) = event { return cue.group == .bubble || cue.group == .chatter }
        return false
    }

    @Test("미니에는 말풍선이 없고 말풍선 블립도 울리지 않는다. 상태 칩은 그대로 보인다 (사무실 창은 같은 장면에서 말풍선을 띄움)")
    func miniHasNoBubbles() {
        var office = FloorHarness()
        office.hook(hook("SessionStart", session: "m", cwd: "/w/m"))
        let officeFrames = Self.play(&office, bounds: nil)
        let officeBubbles = Set(officeFrames.flatMap { $0.1 }.filter { $0.kind == .bubble }.compactMap(\.text))
        #expect(officeBubbles.count >= 2, "\(officeBubbles)")  // 서브 보고와 메인 퇴근 인사

        var mini = FloorHarness(width: MiniOffice.visibleMapWidth(), height: OfficeLayout.minHeight, band: true)
        mini.hook(hook("SessionStart", session: "m", cwd: "/w/m"))
        mini.select(.only(mini.team("m")))  // 앱처럼 미니에 보여 줄 행을 고름 (MiniFocus)
        let miniFrames = Self.play(&mini, bounds: Self.miniBounds)
        #expect(!mini.stage.config.showsBubbles)
        for (time, items) in miniFrames {
            #expect(!items.contains { $0.kind == .bubble }, "\(time)초에 말풍선")
        }
        #expect(miniFrames.contains { $0.1.contains { $0.kind == .pill } })
        #expect(!mini.events.contains(where: Self.isBubbleSound))
        #expect(mini.stage.actors.values.allSatisfy { $0.bubble == nil && $0.queuedBubble == nil })
    }

    @Test("머리 옆 자리는 오른쪽부터, 오른쪽 끝에 닿으면 왼쪽, 다른 말풍선이 있으면 비켜 간다")
    func besideHead() {
        let area = MapRect(4, 230, 362, 172)
        let right = Overlay.besideHead(width: 100, height: 27, headX: 100, top: 200, avoiding: [], in: area)
        #expect(right.direction == 1 && right.frame.x == 130 && right.frame.y == 230)

        let left = Overlay.besideHead(width: 100, height: 27, headX: 300, top: 240, avoiding: [], in: area)
        #expect(left.direction == -1 && left.frame.maxX == 270 && left.frame.y == 240)

        // 오른쪽 자리에 다른 말풍선이 있으면 그 너머로
        let blocker = MapRect(120, 230, 60, 27)
        let shifted = Overlay.besideHead(width: 100, height: 27, headX: 100, top: 230, avoiding: [blocker], in: area)
        #expect(shifted.direction == 1 && shifted.frame.x >= blocker.maxX && !shifted.frame.intersects(blocker))

        // 오른쪽 너머가 화면 밖이면 왼쪽
        let wide = MapRect(120, 230, 240, 27)
        let other = Overlay.besideHead(width: 60, height: 27, headX: 100, top: 230, avoiding: [wide], in: area)
        #expect(other.direction == -1 && other.frame.maxX <= 70)
    }

    @Test("꼬리 변: 꼬리 끝이 아래면 아래, 옆이면 옆, 상자 안이면 꼬리 없음")
    func tailSides() {
        let f = MapRect(-50, -36, 100, 27)
        #expect(OverlayArt.tailSide(f, tip: MapPoint(0, 0)) == .bottom)
        #expect(OverlayArt.tailSide(f, tip: MapPoint(60, -20)) == .right)
        #expect(OverlayArt.tailSide(f, tip: MapPoint(-60, -50)) == .left)
        #expect(OverlayArt.tailSide(f, tip: MapPoint(0, -20)) == .none)

        func points(_ commands: [PathCommand]) -> [MapPoint] {
            commands.compactMap {
                switch $0 {
                case .move(let p), .line(let p): p
                case .quad(_, let p): p
                default: nil
                }
            }
        }
        // 옆 꼬리: 꼬리 끝을 지나고, 나머지 점은 모두 상자 둘레 위
        let side = MapRect(30, -20, 100, 27)
        let tip = MapPoint(10, -5)
        let path = points(OverlayArt.tailRect(side, radius: 11, tip: tip))
        #expect(path.contains(tip))
        for p in path where p != tip {
            #expect(p.x >= side.x - 0.01 && p.x <= side.maxX + 0.01 && p.y >= side.y - 0.01 && p.y <= side.maxY + 0.01)
        }
        // 꼬리 끝이 상자 안이면 꼬리를 그리지 않습니다
        #expect(!points(OverlayArt.tailRect(f, radius: 11, tip: MapPoint(0, -20))).contains(MapPoint(0, -20)))
    }
}
