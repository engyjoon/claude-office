import Foundation
import OfficeCore

/// 직원이 서는 자리. `approach`까지는 길찾기로 걷고, 마지막에 `final`로 한 걸음 들어갑니다.
/// (책상 뒤 의자, 소파처럼 가구와 겹치는 자리 때문입니다)
public struct Place: Hashable, Sendable {
    public var final: MapPoint
    public var approach: MapPoint
    /// 여러 직원이 같은 자리에 서지 않도록 예약할 때 쓰는 키
    public var key: String?

    public init(final: MapPoint, approach: MapPoint? = nil, key: String? = nil) {
        self.final = final
        self.approach = approach ?? final
        self.key = key
    }
}

/// 사무실 배치 (설계서 §8.1, 미리보기와 같은 960pt 폭 3/4 탑다운 맵).
///
/// - 뒷벽(y < 160)에 책장·창문·화이트보드·출입문·서버랙이 있습니다.
/// - 책상 섬은 두 열로 놓이고, 팀이 늘면 아래로 줄이 늘어납니다.
/// - 맨 아래 줄 밑에 리서치 코너(왼쪽)와 휴게실(오른쪽)이 따라 내려갑니다.
public struct OfficeLayout: Hashable, Sendable {
    public static let width = 960.0
    public static let tile = 16.0
    public static let wallBottom = 160.0
    public static let walkTop = 172.0
    public static let firstDeskY = 346.0
    public static let rowSpacing = 190.0
    public static let islandCentersX = [245.0, 675.0]
    /// 섬 안 책상 x 위치 (섬 중심 기준). 0번이 팀장석이고, 팀장 양옆으로 팀원이 앉습니다.
    public static let deskOffsets = [-46.0, 46.0, -138.0, 138.0]
    public static let deskWidth = 82.0
    public static let approachOffset = 46.0
    public static let doorPoint = MapPoint(712, 180)

    /// 지금까지 열린 책상 섬 수
    public private(set) var islandCount: Int

    public init(islandCount: Int = 1) {
        self.islandCount = max(islandCount, 1)
    }

    public mutating func ensureIsland(_ island: Int) {
        islandCount = max(islandCount, island + 1)
    }

    public var rows: Int { (islandCount + 1) / 2 }
    public var height: Double { bottomZoneY + 120 }
    /// 맨 아래 책상 줄의 발 위치
    public var lastDeskY: Double { Self.deskY(row: rows - 1) }
    /// 리서치 코너와 휴게실의 기준선 (미리보기의 소파 앉는 자리 y = 520)
    public var bottomZoneY: Double { lastDeskY + 174 }

    public static func deskY(row: Int) -> Double { firstDeskY + Double(row) * rowSpacing }

    public static func islandCenter(_ island: Int) -> MapPoint {
        MapPoint(islandCentersX[island % 2], deskY(row: island / 2))
    }

    // MARK: - 자리

    public static func seat(island: Int, index: Int) -> Place {
        let center = islandCenter(island)
        let key = "seat:\(island):\(index)"
        if index < deskOffsets.count {
            let x = center.x + deskOffsets[index]
            return Place(final: MapPoint(x, center.y), approach: MapPoint(x, center.y - approachOffset), key: key)
        }
        // 책상이 모자라면 섬 앞에 서서 일합니다
        let extra = index - deskOffsets.count
        let x = center.x - 150 + Double(extra % 6) * 60
        let y = center.y + 74 + Double(extra / 6) * 30
        return Place(final: MapPoint(x, y), key: key)
    }

    public enum Zone: String, Hashable, Sendable, CaseIterable {
        case bookshelf, whiteboard, serverRack, research, lounge
    }

    /// 구역마다 여러 명이 설 수 있는 자리
    public func slots(_ zone: Zone) -> [Place] {
        let b = bottomZoneY
        let points: [(MapPoint, MapPoint?)]
        switch zone {
        case .bookshelf: points = [(MapPoint(84, 198), nil), (MapPoint(132, 202), nil), (MapPoint(196, 206), nil)]
        case .whiteboard: points = [(MapPoint(560, 198), nil), (MapPoint(616, 200), nil)]
        case .serverRack: points = [(MapPoint(836, 214), nil), (MapPoint(896, 218), nil), (MapPoint(780, 222), nil)]
        case .research: points = [(MapPoint(132, b + 14), nil), (MapPoint(190, b + 30), nil), (MapPoint(244, b + 18), nil)]
        case .lounge:
            // 소파에 앉는 두 자리는 소파 앞에서 들어갑니다
            points = [
                (MapPoint(770, b), MapPoint(770, b + 34)), (MapPoint(826, b), MapPoint(826, b + 34)),
                (MapPoint(700, b + 30), nil), (MapPoint(888, b + 44), nil),
            ]
        }
        return points.enumerated().map { index, item in
            Place(final: item.0, approach: item.1, key: "\(zone.rawValue):\(index)")
        }
    }

    public static func zone(for spot: Spot) -> Zone? {
        switch spot {
        case .bookshelf: .bookshelf
        case .whiteboard: .whiteboard
        case .serverRack: .serverRack
        case .research: .research
        case .lounge: .lounge
        case .door, .seat, .beside: nil
        }
    }

    // MARK: - 장애물과 걸을 수 있는 칸

    /// 걸어서 지나갈 수 없는 가구 (발 위치 기준)
    public var obstacles: [MapRect] {
        var rects: [MapRect] = []
        for island in 0..<(rows * 2) {
            let center = Self.islandCenter(island)
            for offset in Self.deskOffsets {
                rects.append(MapRect(center.x + offset - Self.deskWidth / 2, center.y - 33, Self.deskWidth, 38))
            }
        }
        let b = bottomZoneY
        rects.append(MapRect(36, b - 32, 52, 44))  // 지구본
        rects.append(MapRect(16, b - 56, 26, 30))  // 스탠드 조명
        rects.append(MapRect(730, b - 52, 132, 58))  // 소파
        rects.append(MapRect(876, b - 58, 70, 52))  // 커피머신 카운터
        rects.append(MapRect(650, b - 26, 40, 26))  // 휴게실 화분
        return rects
    }

    public var gridColumns: Int { Int(Self.width / Self.tile) }
    public var gridRows: Int { Int((height / Self.tile).rounded(.up)) }

    public func cellCenter(column: Int, row: Int) -> MapPoint {
        MapPoint((Double(column) + 0.5) * Self.tile, (Double(row) + 0.5) * Self.tile)
    }

    public func cell(for point: MapPoint) -> (column: Int, row: Int) {
        (min(max(Int(point.x / Self.tile), 0), gridColumns - 1), min(max(Int(point.y / Self.tile), 0), gridRows - 1))
    }

    public func isWalkable(_ point: MapPoint) -> Bool {
        guard point.x >= 8, point.x <= Self.width - 8, point.y >= Self.walkTop, point.y <= height - 8 else { return false }
        return !obstacles.contains { $0.contains(point) }
    }

    /// 걸을 수 있는 칸 지도 (행 우선)
    public func walkableGrid() -> [Bool] {
        let obstacles = self.obstacles
        var grid = [Bool](repeating: false, count: gridColumns * gridRows)
        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                let center = cellCenter(column: column, row: row)
                let inside = center.x >= 8 && center.x <= Self.width - 8 && center.y >= Self.walkTop && center.y <= height - 8
                grid[row * gridColumns + column] = inside && !obstacles.contains { $0.insetBy(-4).contains(center) }
            }
        }
        return grid
    }
}
