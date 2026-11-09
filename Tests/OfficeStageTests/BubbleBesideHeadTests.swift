import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M6(9): 화면 위 끝에 밀린 말풍선은 머리 옆에 두고 꼬리가 옆에서 머리를 가리킨다
/// (미니에서 문으로 나갈 때 꼬리가 상자를 뚫고 위로 솟던 것).
@Suite("머리 옆 말풍선 (M6(9))")
struct BubbleBesideHeadTests {
    func on(_ event: String, _ extra: String = "", _ session: String = "m") -> String {
        hook(event, extra, session: session, cwd: "/w/\(session)")
    }

    /// 앱의 미니 띠와 같은 보이는 영역 (`OfficeScene.syncOverlays`의 `.band`)
    static var miniBounds: MapRect {
        let extent = MiniOffice.extent()
        return MapRect(0, extent.y, extent.width + extent.x, extent.height)
    }

    /// 꼬리 끝이 상자 아래거나 상자 옆이어야 합니다 (상자를 가로지르지 않음)
    static func tailClear(_ item: OverlayItem) -> Bool {
        let f = item.frame!, tip = item.origin
        return tip.y >= f.maxY || tip.x >= f.maxX || tip.x <= f.x
    }

    @Test("미니에서 서브가 보고하고 메인이 퇴근하는 동안 말풍선 꼬리가 상자를 뚫지 않고, 상자는 화면 안에 있다")
    func miniLeaving() throws {
        var h = FloorHarness(width: MiniOffice.visibleMapWidth(), height: OfficeLayout.minHeight, band: true)
        h.hook(on("SessionStart"))
        h.select(.only(h.team("m")))  // 앱처럼 미니에 보여 줄 행을 고름 (MiniFocus)
        let read = #""tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/x/A.swift"},"agent_id":"g1","agent_type":"general-purpose""#
        var script: [(Double, String)] = [
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

        let bounds = Self.miniBounds
        let area = bounds.insetBy(4)
        var sideCount = 0
        var texts = Set<String>()
        var time = 0.0
        while time < 30 {
            while let (at, json) = script.first, at <= time {
                script.removeFirst()
                h.hook(json, at: at)
            }
            h.run(until: time)
            for item in Overlay.items(for: h.stage, options: OverlayOptions(bounds: bounds)) where item.kind == .bubble {
                let frame = try #require(item.frame)
                #expect(Self.tailClear(item), "\(time)초 \(item.text ?? ""): 꼬리 \(item.origin), 상자 \(frame)")
                #expect(frame.y >= area.y - 0.01 && frame.x >= area.x - 0.01 && frame.maxX <= area.maxX + 0.01)
                if item.origin.y < frame.maxY { sideCount += 1 }
                texts.insert(item.text ?? "")
            }
            time += 0.1
        }
        // 이 장면은 실제로 머리 옆 말풍선을 거칩니다 (보고 "끝났어요!"류, 퇴근 인사)
        #expect(sideCount > 10)
        #expect(texts.count >= 2, "\(texts)")  // 서브 보고와 메인 퇴근 인사
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
