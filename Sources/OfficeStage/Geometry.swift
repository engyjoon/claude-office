import Foundation

/// 사무실 맵 좌표 (단위: pt, 원점은 왼쪽 위, y는 아래로 증가). 미리보기 SVG와 같은 좌표계입니다.
/// SpriteKit(y가 위로 증가)으로 옮길 때는 렌더러가 뒤집습니다.
public struct MapPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = MapPoint(0, 0)

    public static func + (lhs: MapPoint, rhs: MapPoint) -> MapPoint { MapPoint(lhs.x + rhs.x, lhs.y + rhs.y) }
    public static func - (lhs: MapPoint, rhs: MapPoint) -> MapPoint { MapPoint(lhs.x - rhs.x, lhs.y - rhs.y) }
    public static func * (lhs: MapPoint, rhs: Double) -> MapPoint { MapPoint(lhs.x * rhs, lhs.y * rhs) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: MapPoint) -> Double { (other - self).length }

    public var description: String { String(format: "(%.0f, %.0f)", x, y) }
}

public struct MapRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: MapPoint { MapPoint(x + width / 2, y + height / 2) }

    public func contains(_ point: MapPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }

    public func insetBy(_ amount: Double) -> MapRect {
        MapRect(x + amount, y + amount, width - amount * 2, height - amount * 2)
    }
}
