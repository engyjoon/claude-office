import Foundation

/// 설정 값을 읽고 쓰는 곳. 앱은 `UserDefaults`, 테스트는 사전으로 된 저장소를 씁니다.
public protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// 설정 키 이전 (M5(8)). 키 이름이 바뀌어도 사용자가 고른 값을 이어받습니다.
///
/// - `settings.version`에 마지막으로 끝낸 이전 번호를 적어, 앱을 켤 때마다 한 번만 돕니다.
/// - 새 키에 이미 값이 있으면 새 값을 지키고 옛 키만 지웁니다 (두 번 돌아도 결과가 같음).
public enum SettingsMigration {
    public static let versionKey = "settings.version"

    /// 이전 단계: 번호, 옛 키 → 새 키, 더 쓰지 않아 지울 키
    public struct Step: Sendable {
        public let version: Int
        public let renames: [(old: String, new: String)]
        public var removals: [String] = []
    }

    public static let steps: [Step] = [
        // M5(8): 표시 탭의 키를 `display.`로 모으고, 창 폭을 1400으로 넓히던 때의 한 번짜리 표시를 지웁니다 (지금은 1440)
        Step(version: 1, renames: [("privacy", PrivacyLevel.settingsKey)], removals: ["office.widenedTo1400"]),
        // M5(9): 사무실 창 크기를 고정해 예전 창을 한 번 넓히고 높이던 표시가 필요 없습니다
        Step(version: 2, renames: [], removals: ["office.widenedTo1440", "office.tallerForStatusLine"]),
    ]

    public static var currentVersion: Int { steps.map(\.version).max() ?? 0 }

    /// 아직 하지 않은 이전을 합니다. 옮긴 키 이름(옛 → 새)을 돌려줍니다.
    @discardableResult
    public static func migrate(_ store: SettingsStore) -> [String] {
        let done = (store.object(forKey: versionKey) as? Int) ?? 0
        var moved: [String] = []
        for step in steps where step.version > done {
            for (old, new) in step.renames {
                guard let value = store.object(forKey: old) else { continue }
                if store.object(forKey: new) == nil {
                    store.set(value, forKey: new)
                    moved.append("\(old) → \(new)")
                }
                store.removeObject(forKey: old)
            }
            for key in step.removals { store.removeObject(forKey: key) }
        }
        if done < currentVersion { store.set(currentVersion, forKey: versionKey) }
        return moved
    }
}

extension PrivacyLevel {
    /// 표시 수준을 기억하는 키 (M5(8) 전에는 `privacy`)
    public static let settingsKey = "display.privacy"

    public init(store: SettingsStore) {
        self = (store.object(forKey: Self.settingsKey) as? String).flatMap(PrivacyLevel.init(rawValue:)) ?? .detailed
    }
}

/// 동작 줄이기 (설계서 §10, M5(8)). 켜지면 걷기 대신 순간이동하고 제스처를 생략합니다.
///
/// 기본은 macOS "동작 줄이기"(손쉬운 사용 → 디스플레이)를 따르고, 앱에서 따로 항상 켤 수도 있습니다.
public struct MotionSettings: Hashable, Sendable {
    /// macOS 손쉬운 사용의 동작 줄이기를 따름
    public var followSystem: Bool
    /// 시스템 설정과 상관없이 앱에서 항상 줄임
    public var alwaysReduce: Bool

    public static let followSystemKey = "display.reduceMotion.followSystem"
    public static let alwaysReduceKey = "display.reduceMotion.always"

    public init(followSystem: Bool = true, alwaysReduce: Bool = false) {
        self.followSystem = followSystem
        self.alwaysReduce = alwaysReduce
    }

    public init(store: SettingsStore) {
        self.init(
            followSystem: store.object(forKey: Self.followSystemKey) as? Bool ?? true,
            alwaysReduce: store.object(forKey: Self.alwaysReduceKey) as? Bool ?? false)
    }

    public func save(to store: SettingsStore) {
        store.set(followSystem, forKey: Self.followSystemKey)
        store.set(alwaysReduce, forKey: Self.alwaysReduceKey)
    }

    /// 지금 동작을 줄여야 하는지
    public func reducesMotion(systemReduceMotion: Bool) -> Bool {
        alwaysReduce || (followSystem && systemReduceMotion)
    }

    /// 설정 창에 보여 줄 지금 상태
    public func summary(systemReduceMotion: Bool) -> String {
        guard reducesMotion(systemReduceMotion: systemReduceMotion) else {
            return systemReduceMotion ? "지금: 평소대로 움직여요 (시스템은 켜져 있지만 따르지 않음)" : "지금: 평소대로 움직여요"
        }
        return alwaysReduce ? "지금: 줄이는 중 (앱에서 항상 켬)" : "지금: 줄이는 중 (시스템 설정을 따름)"
    }
}

/// 사무실 조명을 켜는 기준 (M6(6), 설정 → 일반 "사무실 조명"). 밤이면 사무실 장면을 저녁 조명으로 그립니다.
public enum LightingMode: String, Hashable, Sendable, CaseIterable {
    /// macOS 모양(라이트·다크)을 따름. 직원 패널·현황 줄과 늘 맞고, macOS "자동" 모양이면 해 질 녘에 저절로 바뀝니다.
    case system
    /// 해 질 녘~새벽 (위치 정보 없이 고정 시각 19시~7시)
    case evening
    case alwaysDay
    case alwaysNight

    public static let settingsKey = "office.lighting"
    /// 해 질 녘 모드에서 밤이 시작하는 시각과 끝나는 시각 (시)
    public static let nightStartHour = 19
    public static let nightEndHour = 7

    public init(store: SettingsStore) {
        self = (store.object(forKey: Self.settingsKey) as? String).flatMap(LightingMode.init(rawValue:)) ?? .system
    }

    public func save(to store: SettingsStore) {
        store.set(rawValue, forKey: Self.settingsKey)
    }

    /// 지금 밤인지
    /// - Parameters:
    ///   - systemDark: macOS가 다크 모양인지
    ///   - hour: 지금 시각의 시 (0~23, 사용자 달력 기준)
    public func isNight(systemDark: Bool, hour: Int) -> Bool {
        switch self {
        case .system: systemDark
        case .evening: hour >= Self.nightStartHour || hour < Self.nightEndHour
        case .alwaysDay: false
        case .alwaysNight: true
        }
    }

    public var title: String {
        switch self {
        case .system: "시스템 모양 따라"
        case .evening: "해 질 녘~새벽 (19시~7시)"
        case .alwaysDay: "항상 낮"
        case .alwaysNight: "항상 밤"
        }
    }

    public var detail: String {
        switch self {
        case .system: "macOS가 다크 모드면 밤이에요. 시스템 설정 → 모양을 \"자동\"으로 두면 해 질 녘에 맞춰 바뀌어요."
        case .evening: "다크 모드와 상관없이 저녁 7시부터 아침 7시까지 밤이에요."
        case .alwaysDay: "늘 밝은 낮 사무실이에요."
        case .alwaysNight: "늘 불을 켠 저녁 사무실이에요."
        }
    }
}
