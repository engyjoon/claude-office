import Foundation

/// 지연 표본의 요약 (디버그 계측, 설계서 §8.3·M6(1)). 단위는 호출하는 쪽이 정합니다(앱은 밀리초).
public struct LatencySummary: Hashable, Sendable, CustomStringConvertible {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double

    public static let empty = LatencySummary(count: 0, p50: 0, p95: 0, max: 0)

    public init(count: Int, p50: Double, p95: Double, max: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.max = max
    }

    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        self.init(
            count: sorted.count, p50: Self.percentile(sorted, 0.5), p95: Self.percentile(sorted, 0.95),
            max: sorted.last ?? 0)
    }

    /// 정렬된 표본의 백분위 (가장 가까운 순위 방식: 표본 중 하나를 고름, 비면 0)
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(Swift.max(rank, 1), sorted.count) - 1]
    }

    public var description: String {
        count == 0 ? "n=0" : String(format: "n=%d p50=%.1f p95=%.1f max=%.1f", count, p50, p95, max)
    }
}
