import Foundation

/// 구운 텍스처의 층 (개선 10). 층마다 굽는 배율을 따로 정할 수 있게 나눕니다.
public enum BakeLayer: String, CaseIterable, Hashable, Sendable {
    /// 바탕·벽·행 표지 (깊이 −∞ 묶음, 사무실 창 크기만 한 한 장)
    case background
    /// 책상·의자·소파 같은 가구, 움직이는 가구(안마 롤러·모니터 진행 막대), 밤 책상 불빛
    case furniture
    /// 캐릭터 부품 (몸통·얼굴·팔다리·소품)
    case character
    /// 말풍선·상태 칩·아이콘·배지
    case overlay
}

/// 층마다 굽는 배율 (개선 10, 설계서 §8.3).
///
/// 기본은 모든 층을 **창이 놓인 화면의 배율**(`backingScaleFactor`)로 굽습니다. 층을 고정 배율로 바꾸는 것은 화질과 메모리를
/// 실측으로 견줘야 하므로 기본으로 켜지 않고, 측정할 때 환경 변수 `CLAUDE_OFFICE_BAKE_SCALE`로만 바꿉니다
/// (예: `background=1`이면 레티나에서도 바탕을 1배율로 굽고 화면에서 2배로 늘려 그림).
public struct BakeScalePolicy: Equatable, Sendable {
    /// 고정 배율을 쓰는 층 (없으면 화면 배율)
    public var overrides: [BakeLayer: Double]

    public init(overrides: [BakeLayer: Double] = [:]) {
        self.overrides = overrides
    }

    /// 지금 동작: 모든 층을 화면 배율로
    public static let standard = BakeScalePolicy()

    /// 환경 변수 이름 (측정용, 기본 꺼짐)
    public static let environmentKey = "CLAUDE_OFFICE_BAKE_SCALE"
    /// 받아들이는 고정 배율 범위
    public static let allowed: ClosedRange<Double> = 0.5...4

    /// 이 층을 굽는 배율
    public func scale(for layer: BakeLayer, screen: Double) -> Double {
        overrides[layer] ?? screen
    }

    /// 화면 배율이 `screen`일 때 쓰는 배율들 (캐시에서 남길 배율)
    public func scales(screen: Double) -> Set<Double> {
        Set(BakeLayer.allCases.map { scale(for: $0, screen: screen) })
    }

    /// `"background=1,furniture=1.5"` 꼴. 모르는 층·숫자가 아닌 값·범위 밖 값은 무시합니다 (없거나 비면 `standard`).
    public static func parse(_ text: String?) -> BakeScalePolicy {
        guard let text else { return .standard }
        var overrides: [BakeLayer: Double] = [:]
        for item in text.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let layer = BakeLayer(rawValue: pair[0]), let value = Double(pair[1]), allowed.contains(value)
            else { continue }
            overrides[layer] = value
        }
        return BakeScalePolicy(overrides: overrides)
    }
}

/// 텍스처 캐시 상한 (`TextureCacheLedger`)
public struct TextureCacheLimits: Equatable, Sendable {
    public var maxCount: Int
    public var maxPixels: Int

    public init(maxCount: Int, maxPixels: Int) {
        self.maxCount = maxCount
        self.maxPixels = maxPixels
    }

    /// 앱 기본값. 픽셀 상한 8Mi(RGBA 32MiB)는 계산한 작업 묶음(사무실 창 낮·밤 + 미니, 2배율 약 5백만 픽셀)이 들어가는 크기입니다.
    /// 장 수 400은 18명이 있는 사무실 한 조명(약 230장)과 안마 롤러·모니터 진행 막대의 주기 그림(롤러 하나 39장)이 같이 들어가는 크기입니다.
    public static let standard = TextureCacheLimits(maxCount: 400, maxPixels: 8 * 1_048_576)
}

/// 텍스처 캐시에서 무엇을 버릴지 정하는 장부 (개선 10, 설계서 §8.3). 텍스처는 들고 있지 않고 키·픽셀 수·배율·마지막으로 쓴 때만 셉니다.
///
/// - 장 수(`maxCount`)나 픽셀 합(`maxPixels`, 실제 배율의 픽셀)이 넘으면 **가장 오래 안 쓴 것부터** 버립니다 (예전에는 300장에서 통째로 비움).
/// - 혼자서 픽셀 상한을 넘는 텍스처는 담지 않습니다.
/// - 화면 배율이 바뀌면 지금 쓰지 않는 배율의 텍스처를 한꺼번에 버립니다 (`evict(keepingScales:)`).
///
/// 캐시에서 버려도 화면의 노드가 들고 있는 텍스처는 그대로 살아 있습니다. 버리는 것은 "다시 쓸지도 몰라 남겨 둔" 몫입니다.
public struct TextureCacheLedger<Key: Hashable> {
    private struct Entry {
        var pixels: Int
        var scale: Double
        var lastUse: UInt64
    }

    public let limits: TextureCacheLimits
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    /// 담긴 텍스처의 픽셀 합 (실제 배율)
    public private(set) var totalPixels = 0

    public init(limits: TextureCacheLimits = .standard) {
        self.limits = limits
    }

    public var count: Int { entries.count }
    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// 캐시에서 꺼내 씀: 가장 최근에 쓴 것으로
    public mutating func touch(_ key: Key) {
        guard entries[key] != nil else { return }
        clock += 1
        entries[key]?.lastUse = clock
    }

    /// 새로 구운 텍스처를 담습니다. 담았는지와, 자리를 내려고 버린 키들(가장 오래 안 쓴 것부터)을 돌려줍니다.
    public mutating func insert(_ key: Key, pixels: Int, scale: Double) -> (stored: Bool, evicted: [Key]) {
        let pixels = max(pixels, 0)
        var evicted: [Key] = []
        if let old = entries.removeValue(forKey: key) { totalPixels -= old.pixels }
        guard pixels <= limits.maxPixels, limits.maxCount > 0 else { return (false, evicted) }
        while !entries.isEmpty, entries.count + 1 > limits.maxCount || totalPixels + pixels > limits.maxPixels {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            totalPixels -= entries.removeValue(forKey: oldest)?.pixels ?? 0
            evicted.append(oldest)
        }
        clock += 1
        entries[key] = Entry(pixels: pixels, scale: scale, lastUse: clock)
        totalPixels += pixels
        return (true, evicted)
    }

    /// `scales`에 없는 배율의 텍스처를 모두 버립니다 (화면 배율이 바뀐 뒤)
    public mutating func evict(keepingScales scales: Set<Double>) -> [Key] {
        let gone = entries.filter { !scales.contains($0.value.scale) }.map(\.key)
        for key in gone { totalPixels -= entries.removeValue(forKey: key)?.pixels ?? 0 }
        return gone
    }
}
