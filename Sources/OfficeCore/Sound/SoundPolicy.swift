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
