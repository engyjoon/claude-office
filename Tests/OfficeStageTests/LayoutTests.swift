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
    let main = TeamID("/w/main#1")
    let other = TeamID("/w/b#2")

    @Test("행 하나 = 메인 하나: 가장 왼쪽이 메인 책상, 오른쪽으로 서브 책상이 사람 수만큼. 행은 위에서 아래로")
    func rows() {
        let layout = OfficeLayout(rooms: [.init(team: main, desks: 4), .init(team: other, desks: 1)])
        #expect(layout.rows.map(\.desks) == [4, 1])
        #expect(layout.rows.map(\.index) == [0, 1])
        let mainDesk = layout.seat(main, .main)
        let firstSub = layout.seat(main, Seat(desk: 1))
        let secondSub = layout.seat(main, Seat(desk: 2))
        #expect(mainDesk.final.x < firstSub.final.x && firstSub.final.x < secondSub.final.x)
        #expect(secondSub.final.x - firstSub.final.x == OfficeLayout.deskSpacing)
        // 메인 책상과 첫 서브 책상 사이는 조금 더 띄웁니다
        #expect(firstSub.final.x - mainDesk.final.x == OfficeLayout.deskSpacing + OfficeLayout.mainGap)
        #expect(layout.seat(other, .main).final.y - mainDesk.final.y == layout.rowSpacing)
        // 의자 자리는 책상 뒤 통로에서 들어갑니다
        #expect(mainDesk.approach == mainDesk.final + MapPoint(0, -OfficeLayout.approachOffset))
        #expect(mainDesk.team == main && mainDesk.seat == .main)
        // 책상 수만큼만 장애물 (빈 책상 없음)
        let deskObstacles = layout.obstacles.filter { $0.width == OfficeLayout.deskWidth }
        #expect(deskObstacles.count == 5)
    }

    @Test("공용 공간(휴게·책장·화이트보드·출입문·탕비 코너)은 모두 첫 행 위에 있고 행과 겹치지 않는다")
    func commonAreaOnTop() {
        for width in [OfficeLayout.minWidth, 1140, 1400, 1800] {
            let layout = OfficeLayout(width: width, height: 648, rooms: [.init(team: main, desks: 12)])
            let firstRowTop = layout.rows[0].deskY - 60  // 의자 윗면
            for zone in OfficeLayout.Zone.allCases {
                for slot in layout.slots(zone) {
                    #expect(slot.final.y < firstRowTop, "\(zone) \(slot.final)")
                    #expect(slot.final.x > 0 && slot.final.x < layout.width, "\(zone) \(slot.final) 폭 \(width)")
                }
            }
            for rect in OfficeLayout.sofas + OfficeLayout.massageSeats.map(OfficeLayout.massageChair) {
                #expect(rect.maxY < firstRowTop)
            }
            // 휴게 공간: 소파 구역(3인용 둘) → 빈 공간 → 안마 구역(의자 둘), 화이트보드 앞을 막지 않습니다
            #expect(OfficeLayout.sofaArea.maxX + 40 < OfficeLayout.massageArea.x)
            #expect(layout.slots(.whiteboard).allSatisfy { $0.final.x > OfficeLayout.massageSeats[1].x + 30 + 20 })
            #expect(layout.slots(.lounge).count == 6 && layout.slots(.massageChair).count == 2)
            #expect(layout.doorPoint.y < firstRowTop)
            // 뒷벽 가구는 서로 겹치지 않고 화면 안에 있습니다
            let garden = layout.gardenFrame
            // 액자 → 시계 → 화이트보드 순서, 액자는 안마 의자 등판과 겹치지 않음, 화이트보드와 출입문 사이는 넉넉히
            let clock = layout.clockCenter
            #expect(garden.maxX + 18 < clock.x - 18 && clock.x + 18 + 18 < layout.whiteboardX && garden.width >= 160)
            #expect(garden.maxY + 24 < OfficeLayout.massageSeat.y - 108 || garden.maxX < OfficeLayout.massageArea.x)
            #expect(layout.doorX - (layout.whiteboardX + 128) >= 60)
            let walls: [(Double, Double)] = [(garden.x, garden.width)]
                + [(layout.whiteboardX, 128), (layout.doorX, 72), (layout.pantryX, 202)]
            for (index, a) in walls.enumerated() {
                #expect(a.0 + a.1 <= layout.width)
                for b in walls[(index + 1)...] { #expect(a.0 + a.1 <= b.0 || b.0 + b.1 <= a.0, "폭 \(width): \(a) \(b)") }
            }
        }
    }

    @Test("화면 크기별 수용 수: 배율 1로 들어가는 책상 수·행 수, 행은 최대 3개")
    func capacity() {
        // 기본 창 (1400×760 − 패널 260): 한 행에 11명(메인 + 서브 10), 3행
        #expect(OfficeLayout.capacity(width: 1140, height: 708) == .init(columns: 11, rows: 3))
        // 패널을 숨기면 더 넓게
        #expect(OfficeLayout.capacity(width: 1400, height: 708).columns == 14)
        // 언제나 3행 (사무실 창이 3행 높이보다 낮아지지 않고, 더 낮은 화면은 줄여서 보여 줌). 아무리 커도 3행까지
        #expect(OfficeLayout.minHeight == 342 + 150 * 2 + 36)
        #expect(OfficeLayout.capacity(width: 1140, height: 520).rows == 3)
        #expect(OfficeLayout.capacity(width: 2400, height: 1600).rows == 3)
        #expect(OfficeLayout.displayScale(viewWidth: 1140, viewHeight: 600) < 1)
        // 들어간다고 센 마지막 책상과 "+N"은 화면 안에 있습니다
        for width in [OfficeLayout.minWidth, 1140, 1400, 2000] {
            let capacity = OfficeLayout.capacity(width: width, height: 708)
            let layout = OfficeLayout(width: width, height: 708, rooms: [.init(team: main, desks: capacity.columns, hidden: 3)])
            #expect(layout.rows[0].endX + OfficeLayout.moreBadgeWidth <= width)
            let more = OfficeLayout(width: width, height: 708, rooms: [.init(team: main, desks: capacity.columns + 1)])
            #expect(more.rows[0].endX + OfficeLayout.moreBadgeWidth > width - 8)
            // 3행이 화면 높이 안에 들어갑니다
            let full = OfficeLayout(width: width, height: 708, rooms: (0..<3).map { .init(team: TeamID("t\($0)"), desks: 1) })
            #expect(full.height == 708)
        }
    }

    @Test("행 간격은 최소 150이고, 화면이 높으면 3행이 아래 빈 공간까지 고르게 쓰도록 벌어진다")
    func rowSpacingFollowsHeight() {
        #expect(OfficeLayout.rowSpacing(height: 500) == 150)
        #expect(OfficeLayout.rowSpacing(height: 708) == 165)
        #expect(OfficeLayout.rowSpacing(height: 1000) == 311)
        for height in [708.0, 900, 1200] {
            let layout = OfficeLayout(width: 1140, height: height, rooms: (0..<3).map { .init(team: TeamID("t\($0)"), desks: 1) })
            // 마지막 행 아래에는 여백만 남습니다
            #expect(abs(layout.rows[2].deskY + OfficeLayout.bottomMargin - height) <= 2)
            #expect(layout.rows[1].deskY - layout.rows[0].deskY == layout.rowSpacing)
            // 행 하나뿐이어도 자리는 같은 간격 기준 (행이 늘어도 위 행은 움직이지 않음)
            let one = OfficeLayout(width: 1140, height: height, rooms: [.init(team: TeamID("t0"), desks: 1)])
            #expect(one.rows[0].deskY == layout.rows[0].deskY && one.height == height)
        }
    }

    @Test("배율은 1로 고정 (사무실이 화면 크기를 따라감). 최소 크기보다 작은 화면에서만 줄인다")
    func displayScale() {
        #expect(OfficeLayout.displayScale(viewWidth: 1140, viewHeight: 708) == 1)
        #expect(OfficeLayout.displayScale(viewWidth: 1400, viewHeight: 900) == 1)
        #expect(OfficeLayout.displayScale(viewWidth: 2560, viewHeight: 1400) == 1)
        #expect(OfficeLayout.displayScale(viewWidth: OfficeLayout.minWidth / 2, viewHeight: 708) == 0.5)
        let layout = OfficeLayout(width: 1300, height: 760)
        #expect(layout.width == 1300 && layout.height == 760)
        #expect(OfficeLayout(width: 500, height: 200).width == OfficeLayout.minWidth)
    }

    @Test("모든 구역 자리와 넘침 자리, 출입문은 걸어서 갈 수 있다")
    func zonesReachable() {
        for desks in [1, 6, 12] {
            let layout = OfficeLayout(rooms: [.init(team: main, desks: desks), .init(team: other, desks: 3)])
            #expect(layout.isWalkable(layout.doorPoint))
            for zone in OfficeLayout.Zone.allCases {
                for slot in layout.slots(zone) {
                    #expect(layout.isWalkable(slot.approach), "\(zone) \(slot.approach) (책상 \(desks))")
                }
                #expect(layout.overflow(zone).count >= 4, "\(zone) 넘침 자리")
            }
        }
    }

    @Test("넘침 자리는 서로 떨어져 있어 한 점에 겹치지 않는다")
    func overflowSpread() {
        let layout = OfficeLayout(rooms: [.init(team: main, desks: 4)])
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
    let main = TeamID("/w/main#1")
    var layout: OfficeLayout {
        OfficeLayout(rooms: [.init(team: main, desks: 8), .init(team: TeamID("/w/b#2"), desks: 3), .init(team: TeamID("/w/c#3"), desks: 11)])
    }

    func check(_ path: [MapPoint], from start: MapPoint, finder: Pathfinder) {
        var previous = start
        for point in path {
            #expect(finder.lineIsWalkable(previous, point), "\(previous) → \(point) 구간이 가구를 지납니다")
            previous = point
        }
    }

    @Test("문에서 모든 책상과 구역까지 가구를 뚫지 않고 간다")
    func doorToEverywhere() {
        let layout = self.layout
        let finder = Pathfinder(layout: layout)
        var targets: [MapPoint] = []
        for row in layout.rows {
            for desk in 0..<row.desks { targets.append(OfficeLayout.seat(row, Seat(desk: desk)).approach) }
        }
        for zone in OfficeLayout.Zone.allCases { targets += layout.slots(zone).map(\.approach) }
        for target in targets {
            let path = finder.route(from: layout.doorPoint, to: target)
            #expect(path.last == target)
            check(path, from: layout.doorPoint, finder: finder)
        }
    }

    @Test("책상 줄을 가로지르지 않고 돌아간다")
    func aroundDesks() {
        let layout = self.layout
        let finder = Pathfinder(layout: layout)
        let start = OfficeLayout.seat(layout.rows[1], Seat(desk: 2)).approach
        let goal = layout.slots(.whiteboard)[0].approach
        let path = finder.route(from: start, to: goal)
        #expect(path.count >= 2)
        check(path, from: start, finder: finder)
        let length = finder.length(of: path, from: start)
        #expect(length < start.distance(to: goal) * 2.2)  // 행 끝을 돌아 올라갑니다
    }

    @Test("이미 같은 자리면 길이 없다")
    func samePoint() {
        let finder = Pathfinder(layout: layout)
        #expect(finder.route(from: layout.doorPoint, to: layout.doorPoint).isEmpty)
    }
}
