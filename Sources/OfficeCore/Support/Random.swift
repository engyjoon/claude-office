/// 실행할 때마다 값이 바뀌는 Swift `Hasher` 대신 쓰는 안정적인 해시 (FNV-1a 64비트).
/// 고정 직원의 외형과 목소리가 앱을 다시 켜도 같게 유지되도록 합니다.
public enum StableHash {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return mix(hash)
    }

    /// 하위 비트가 고르게 섞이도록 한 번 더 섞습니다 (SplitMix64 마무리 단계).
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 시드를 정할 수 있는 난수 생성기 (SplitMix64). 테스트에서 대사 선택을 재현하기 위해 씁니다.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// -1...1 범위의 실수 (노이즈 합성용)
    public mutating func nextSignedUnit() -> Float {
        Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1
    }
}
