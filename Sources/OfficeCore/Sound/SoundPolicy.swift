import Foundation

/// 사용자 효과음 설정 (설계서 §11.3)
public struct SoundSettings: Hashable, Sendable, Codable {
    public var masterEnabled = true
    /// 0...1, 기본 35%
    public var volume = 0.35
    public var enabledGroups: Set<SoundGroup> = Set(SoundGroup.allCases.filter(\.enabledByDefault))
    /// macOS 집중 모드가 켜져 있으면 알림성 소리까지 끕니다
    public var respectFocusMode = true

    public init() {}

    public func isEnabled(_ group: SoundGroup) -> Bool {
        masterEnabled && enabledGroups.contains(group)
    }

    public mutating func set(_ group: SoundGroup, enabled: Bool) {
        if enabled { enabledGroups.insert(group) } else { enabledGroups.remove(group) }
    }
}

/// 재생할 때의 화면 상황
public struct SoundContext: Hashable, Sendable {
    /// 미니 사무실이나 메인 창이 화면에 보이는지
    public var officeVisible: Bool
    public var focusModeActive: Bool

    public init(officeVisible: Bool, focusModeActive: Bool = false) {
        self.officeVisible = officeVisible
        self.focusModeActive = focusModeActive
    }
}

/// 효과음을 실제로 울릴지 정하는 문지기. 설정, 화면 상황, 연속 재생 제한, 동시 재생 수를 봅니다.
public struct SoundPolicy: Sendable {
    public enum Decision: Hashable, Sendable {
        case play(gain: Double)
        case skip(Reason)
    }

    public enum Reason: String, Hashable, Sendable {
        case muted, groupDisabled, officeHidden, focusMode, tooSoon, busy
    }

    public var settings: SoundSettings
    public var maxConcurrent = 3

    private var lastPlayed: [SoundGroup: Date] = [:]
    private var playing: [(group: SoundGroup, until: Date)] = []

    public init(settings: SoundSettings = .init()) {
        self.settings = settings
    }

    public mutating func decide(_ cue: SoundCue, duration: Double, at now: Date, context: SoundContext) -> Decision {
        let group = cue.group
        guard settings.masterEnabled else { return .skip(.muted) }
        guard settings.enabledGroups.contains(group) else { return .skip(.groupDisabled) }
        if context.focusModeActive && settings.respectFocusMode { return .skip(.focusMode) }
        if !group.isAlert && !context.officeVisible { return .skip(.officeHidden) }
        if let last = lastPlayed[group], now.timeIntervalSince(last) < group.minimumInterval { return .skip(.tooSoon) }

        playing.removeAll { $0.until <= now }
        if playing.count >= maxConcurrent {
            // 더 중요한 소리면 가장 덜 중요한 소리의 자리를 넘겨받습니다
            guard let weakest = playing.indices.min(by: { playing[$0].group.priority < playing[$1].group.priority }),
                playing[weakest].group.priority < group.priority
            else { return .skip(.busy) }
            playing.remove(at: weakest)
        }
        playing.append((group, now.addingTimeInterval(duration)))
        lastPlayed[group] = now
        return .play(gain: settings.volume)
    }
}

// MARK: - 저장 (설계서 §11.5: sound.enabled, sound.volume, sound.<항목>.enabled)

extension SoundSettings {
    public static let enabledKey = "sound.enabled"
    public static let volumeKey = "sound.volume"
    public static let respectFocusKey = "sound.respectFocus"

    public static func key(for group: SoundGroup) -> String { "sound.\(group.rawValue).enabled" }

    /// 저장된 값이 없는 항목은 기본값을 씁니다
    public init(defaults: UserDefaults) {
        self.init()
        if defaults.object(forKey: Self.enabledKey) != nil {
            masterEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        if defaults.object(forKey: Self.volumeKey) != nil {
            volume = min(max(defaults.double(forKey: Self.volumeKey), 0), 1)
        }
        if defaults.object(forKey: Self.respectFocusKey) != nil {
            respectFocusMode = defaults.bool(forKey: Self.respectFocusKey)
        }
        for group in SoundGroup.allCases where defaults.object(forKey: Self.key(for: group)) != nil {
            set(group, enabled: defaults.bool(forKey: Self.key(for: group)))
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(masterEnabled, forKey: Self.enabledKey)
        defaults.set(volume, forKey: Self.volumeKey)
        defaults.set(respectFocusMode, forKey: Self.respectFocusKey)
        for group in SoundGroup.allCases {
            defaults.set(enabledGroups.contains(group), forKey: Self.key(for: group))
        }
    }
}

extension SoundGroup {
    /// 설정 화면의 "미리 듣기"로 들려줄 소리
    public var sampleCue: SoundCue {
        switch self {
        case .approval: .knock
        case .inputWaiting: .inputWaiting
        case .completion: .turnComplete
        case .bubble: .bubble(voice: 2, syllables: 3)
        case .door: .door
        case .error: .error
        case .chatter: .chatter
        case .footsteps: .footsteps
        case .typing: .typing
        }
    }

    /// 설정 화면의 설명 (설계서 §11.2)
    public var detail: String {
        switch self {
        case .approval: "똑똑 · 권한 승인을 기다릴 때. 30초마다 최대 2번 더"
        case .inputWaiting: "뾰롱 · 응답을 마치고 내 입력을 기다릴 때"
        case .completion: "띠리링 · 팀장 응답 완료, 팀원 보고는 짧은 2음"
        case .bubble: "톡 + 블립 · 말풍선이 뜰 때. 직원마다 목소리 높이가 달라요"
        case .door: "딸랑 · 출근·퇴근"
        case .error: "뿅? · 툴 오류"
        case .chatter: "소곤 · 휴게실 잡담"
        case .footsteps: "톡톡 · 걸을 때"
        case .typing: "타닥 · 편집 중"
        }
    }
}
