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
    let main = TeamID("/w/main")

    @Test("방 하나 = 팀장실 + 파트 칸(한 줄에 2칸). 첫 띠는 휴게 공간 때문에 2줄이고, 칸이 늘면 아래로 줄이 늘어난다")
    func bands() {
        let one = OfficeLayout(rooms: [.init(team: main, cells: 1)])
        #expect(one.bands[0].cells == 2)
        #expect(one.rows == 2)
        // 메인 1 + 파트장 2 = 칸 3개 = 2줄 → 높이 666, 사무실 영역 1140×650에서 배율 ≈ 0.98
        let three = OfficeLayout(rooms: [.init(team: main, cells: 3)])
        #expect(three.rows == 2)
        #expect(three.height == 666)
        #expect(three.height == one.height)
        let scale = min(1140 / OfficeLayout.width, 650 / three.height)
        #expect(scale > 0.97)
        // 칸 5개 → 3줄
        let five = OfficeLayout(rooms: [.init(team: main, cells: 5)])
        #expect(five.rows == 3)
        #expect(five.height == three.height + OfficeLayout.rowSpacing)
        // 방이 둘이면 띠를 아래로 쌓습니다 (둘째 방부터는 최소 1줄)
        let two = OfficeLayout(rooms: [.init(team: main, cells: 1), .init(team: TeamID("/w/other"), cells: 1)])
        #expect(two.rows == 3)
        #expect(two.bands[1].top == two.bands[0].bottom)
        #expect(OfficeLayout.width == 1120)
    }

    @Test("팀장석은 왼쪽 위 팀장실, 파트 칸의 0번 책상은 맨 왼쪽 ★ 자리, 의자 자리는 책상 뒤 통로에서 들어간다")
    func seats() {
        let layout = OfficeLayout(rooms: [.init(team: main, cells: 2)])
        let office = layout.seat(main, .office)
        #expect(office.final == MapPoint(OfficeLayout.officeDeskX, OfficeLayout.firstDeskY))
        #expect(layout.bands[0].office.contains(office.final))
        #expect(layout.isWalkable(office.approach))
        #expect(!layout.isWalkable(office.final))  // 책상과 겹치는 자리
        let star = layout.seat(main, Seat(part: 1, desk: 0))
        let next = layout.seat(main, Seat(part: 1, desk: 1))
        #expect(star.final.x < next.final.x)
        #expect(star.final.x > OfficeLayout.sideWidth)
        // 책상이 모자라면 칸 앞에 섭니다
        let extra = layout.seat(main, Seat(part: 0, desk: 5))
        #expect(layout.isWalkable(extra.final))
    }

    @Test("연출 엔진이 쓰는 칸 책상 수와 칸 수 규칙이 배치와 같다")
    func deskCountMatchesChoreography() {
        #expect(Seat.desksPerPod == OfficeLayout.podDeskOffsets.count)
        for maxPart in 0..<6 {
            let layout = OfficeLayout(rooms: [.init(team: main, cells: maxPart + 1)])
            #expect(layout.bands[0].cells == Choreographer.cellCount(maxPart: maxPart))
        }
    }

    @Test("모든 구역 자리와 넘침 자리, 출입문은 걸어서 갈 수 있다")
    func zonesReachable() {
        for cells in [2, 4, 6] {
            let layout = OfficeLayout(rooms: [.init(team: main, cells: cells), .init(team: TeamID("/w/b"), cells: 2)])
            #expect(layout.isWalkable(OfficeLayout.doorPoint))
            for zone in OfficeLayout.Zone.allCases {
                for slot in layout.slots(zone) {
                    #expect(layout.isWalkable(slot.approach), "\(zone) \(slot.approach) (칸 \(cells))")
                }
                #expect(layout.overflow(zone).count >= 4, "\(zone) 넘침 자리")
            }
        }
    }

    @Test("넘침 자리는 서로 떨어져 있어 한 점에 겹치지 않는다")
    func overflowSpread() {
        let layout = OfficeLayout(rooms: [.init(team: main, cells: 2)])
        for zone in OfficeLayout.Zone.allCases {
            let points = layout.slots(zone).map(\.final) + layout.overflow(zone).map(\.final)
            for (index, point) in points.enumerated() {
                for other in points[(index + 1)...] {
                    #expect(point.distance(to: other) > 12, "\(zone) \(point) \(other)")
                }
            }
        }
    }
}

@Suite("길찾기")
struct PathfinderTests {
    let main = TeamID("/w/main")
    var layout: OfficeLayout { OfficeLayout(rooms: [.init(team: main, cells: 3), .init(team: TeamID("/w/b"), cells: 1)]) }

    func check(_ path: [MapPoint], from start: MapPoint, finder: Pathfinder) {
        var previous = start
        for point in path {
            #expect(finder.lineIsWalkable(previous, point), "\(previous) → \(point) 구간이 가구를 지납니다")
            previous = point
        }
    }

    @Test("문에서 모든 자리와 구역까지 가구를 뚫지 않고 간다")
    func doorToEverywhere() {
        let layout = self.layout
        let finder = Pathfinder(layout: layout)
        var targets: [MapPoint] = []
        for band in layout.bands {
            targets.append(OfficeLayout.seat(band, .office).approach)
            for cell in 0..<band.cells {
                for desk in 0..<5 { targets.append(OfficeLayout.seat(band, Seat(part: cell, desk: desk)).approach) }
            }
        }
        for zone in OfficeLayout.Zone.allCases { targets += layout.slots(zone).map(\.approach) }
        for target in targets {
            let path = finder.route(from: OfficeLayout.doorPoint, to: target)
            #expect(path.last == target)
            check(path, from: OfficeLayout.doorPoint, finder: finder)
        }
    }

    @Test("팀장실에는 칸막이 출입구로 들어가고, 유리 칸막이는 뚫지 않는다")
    func officeDoor() {
        let layout = self.layout
        let finder = Pathfinder(layout: layout)
        let band = layout.bands[0]
        let door = band.officeDoor
        // 칸막이를 가로지르는 직선은 막혀 있습니다 (출입구 위·아래, 아래쪽 칸막이)
        #expect(!finder.lineIsWalkable(MapPoint(160, 230), MapPoint(260, 230)))
        #expect(!finder.lineIsWalkable(MapPoint(160, 380), MapPoint(260, 380)))
        #expect(!finder.lineIsWalkable(MapPoint(100, 400), MapPoint(100, 470)))
        // 출입구 높이로는 지나갈 수 있습니다
        let middle = (door.top + door.bottom) / 2
        #expect(finder.lineIsWalkable(MapPoint(160, middle), MapPoint(260, middle)))
        // 칸에서 팀장 옆까지 가는 길은 출입구를 지납니다
        let start = OfficeLayout.seat(band, Seat(part: 1, desk: 2)).approach
        let goal = OfficeLayout.seat(band, .office).approach + MapPoint(40, 0)
        let path = finder.route(from: start, to: goal)
        check(path, from: start, finder: finder)
        var previous = start
        var crossed = false
        for point in path {
            let wall = OfficeLayout.sideWidth
            if (previous.x - wall) * (point.x - wall) <= 0, previous.x != point.x {
                let t = (wall - previous.x) / (point.x - previous.x)
                let y = previous.y + (point.y - previous.y) * t
                #expect(y > door.top && y < door.bottom, "칸막이를 \(y)에서 지남")
                crossed = true
            }
            previous = point
        }
        #expect(crossed)
        // 휴게 공간에서 팀장실로 갈 때도 아래쪽 칸막이를 돌아 출입구로 갑니다
        let fromLounge = finder.route(from: layout.slots(.lounge)[0].approach, to: goal)
        check(fromLounge, from: layout.slots(.lounge)[0].approach, finder: finder)
    }

    @Test("책상 줄을 가로지르지 않고 돌아간다")
    func aroundDesks() {
        let layout = self.layout
        let finder = Pathfinder(layout: layout)
        let start = OfficeLayout.seat(layout.bands[0], Seat(part: 2, desk: 1)).approach
        let goal = layout.slots(.research)[0].approach
        let path = finder.route(from: start, to: goal)
        #expect(path.count >= 2)
        check(path, from: start, finder: finder)
        let length = finder.length(of: path, from: start)
        #expect(length < start.distance(to: goal) * 1.8)
    }

    @Test("이미 같은 자리면 길이 없다")
    func samePoint() {
        let finder = Pathfinder(layout: layout)
        #expect(finder.route(from: OfficeLayout.doorPoint, to: OfficeLayout.doorPoint).isEmpty)
    }
}
