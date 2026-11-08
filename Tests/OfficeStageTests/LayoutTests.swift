import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

@Suite("벡터 경로 파서")
struct VectorPathTests {
    @Test("절대·상대 명령과 암묵적 반복을 읽는다")
    func parse() {
        let commands = VectorPath.parse("M-24,6 C-26,-22 -12,-27 0,-27 L10 10 h5 v-5 q1,-2 3,0 t3,0 Z")
        #expect(commands.first == .move(MapPoint(-24, 6)))
        #expect(commands[1] == .cubic(control1: MapPoint(-26, -22), control2: MapPoint(-12, -27), to: MapPoint(0, -27)))
        #expect(commands[2] == .line(MapPoint(10, 10)))
        #expect(commands[3] == .line(MapPoint(15, 10)))
        #expect(commands[4] == .line(MapPoint(15, 5)))
        #expect(commands[5] == .quad(control: MapPoint(16, 3), to: MapPoint(18, 5)))
        #expect(commands[6] == .quad(control: MapPoint(20, 7), to: MapPoint(21, 5)))
        #expect(commands.last == .close)
        // M 뒤의 좌표는 L, 마지막 경로 문자열로 다시 쓰기
        #expect(VectorPath.parse("M0,0 10,0 10,10") == [.move(.zero), .line(MapPoint(10, 0)), .line(MapPoint(10, 10))])
        #expect(VectorPath.svg(VectorPath.parse("M1.5,2 L3,4 Z")) == "M1.5,2 L3,4 Z")
    }

    @Test("지수 표기와 붙어 있는 음수를 읽는다")
    func numbers() {
        #expect(VectorPath.parse("M1e1-2L.5.5") == [.move(MapPoint(10, -2)), .line(MapPoint(0.5, 0.5))])
    }
}

@Suite("사무실 배치")
struct LayoutTests {
    @Test("책상 섬은 두 열로 놓이고, 팀이 늘면 아래로 줄이 늘어난다")
    func islands() {
        var layout = OfficeLayout()
        #expect(layout.rows == 1)
        #expect(OfficeLayout.islandCenter(0) == MapPoint(245, 346))
        #expect(OfficeLayout.islandCenter(1) == MapPoint(675, 346))
        #expect(OfficeLayout.islandCenter(2) == MapPoint(245, 536))
        let shortHeight = layout.height
        layout.ensureIsland(2)
        #expect(layout.rows == 2)
        #expect(layout.height == shortHeight + OfficeLayout.rowSpacing)
    }

    @Test("팀장석은 섬 가운데 왼쪽, 의자 자리는 책상 뒤 통로에서 들어간다")
    func seats() {
        let lead = OfficeLayout.seat(island: 0, index: 0)
        #expect(lead.final == MapPoint(199, 346))
        #expect(lead.approach == MapPoint(199, 300))
        let layout = OfficeLayout()
        #expect(layout.isWalkable(lead.approach))
        #expect(!layout.isWalkable(lead.final))  // 책상과 겹치는 자리
        // 책상이 모자라면 섬 앞에 섭니다
        let extra = OfficeLayout.seat(island: 0, index: 5)
        #expect(layout.isWalkable(extra.final))
    }

    @Test("모든 구역 자리와 출입문은 걸어서 갈 수 있다")
    func zonesReachable() {
        for rows in [1, 2, 3] {
            let layout = OfficeLayout(islandCount: rows * 2)
            #expect(layout.isWalkable(OfficeLayout.doorPoint))
            for zone in OfficeLayout.Zone.allCases {
                for slot in layout.slots(zone) {
                    #expect(layout.isWalkable(slot.approach), "\(zone) \(slot.approach) (\(rows)줄)")
                }
            }
        }
    }
}

@Suite("길찾기")
struct PathfinderTests {
    let layout = OfficeLayout(islandCount: 2)

    func check(_ path: [MapPoint], from start: MapPoint, finder: Pathfinder) {
        var previous = start
        for point in path {
            #expect(finder.lineIsWalkable(previous, point), "\(previous) → \(point) 구간이 가구를 지납니다")
            previous = point
        }
    }

    @Test("문에서 모든 좌석과 구역까지 가구를 뚫지 않고 간다")
    func doorToEverywhere() {
        let finder = Pathfinder(layout: layout)
        var targets: [MapPoint] = []
        for island in 0..<2 {
            for seat in 0..<4 { targets.append(OfficeLayout.seat(island: island, index: seat).approach) }
        }
        for zone in OfficeLayout.Zone.allCases { targets += layout.slots(zone).map(\.approach) }
        for target in targets {
            let path = finder.route(from: OfficeLayout.doorPoint, to: target)
            #expect(path.last == target)
            check(path, from: OfficeLayout.doorPoint, finder: finder)
        }
    }

    @Test("책상 줄을 가로지르지 않고 돌아간다")
    func aroundDesks() {
        let finder = Pathfinder(layout: layout)
        let start = OfficeLayout.seat(island: 0, index: 0).approach
        let goal = layout.slots(.research)[0].approach
        let path = finder.route(from: start, to: goal)
        #expect(path.count >= 2)
        check(path, from: start, finder: finder)
        // 직선 거리보다 조금 길지만 너무 돌아가지 않습니다
        let length = finder.length(of: path, from: start)
        #expect(length < start.distance(to: goal) * 1.8)
    }

    @Test("이미 같은 자리면 길이 없다")
    func samePoint() {
        let finder = Pathfinder(layout: layout)
        #expect(finder.route(from: OfficeLayout.doorPoint, to: OfficeLayout.doorPoint).isEmpty)
    }
}
