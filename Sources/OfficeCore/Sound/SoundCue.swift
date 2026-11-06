import Foundation

/// 설정에서 켜고 끄는 효과음 항목 (설계서 §11.2)
public enum SoundGroup: String, Hashable, Sendable, CaseIterable, Codable {
    case approval, inputWaiting, completion, bubble, door, error, chatter, footsteps, typing

    public var displayName: String {
        switch self {
        case .approval: "승인 요청"
        case .inputWaiting: "입력 대기"
        case .completion: "작업 완료"
        case .bubble: "말풍선"
        case .door: "출근·퇴근"
        case .error: "오류"
        case .chatter: "잡담"
        case .footsteps: "발소리"
        case .typing: "타이핑"
        }
    }

    /// 놓치면 안 되는 소리. 사무실이 화면에 안 보여도 울립니다.
    public var isAlert: Bool {
        switch self {
        case .approval, .inputWaiting, .completion: true
        default: false
        }
    }

    public var enabledByDefault: Bool {
        switch self {
        case .chatter, .footsteps, .typing: false
        default: true
        }
    }

    /// 같은 항목을 다시 울리기 전 최소 간격(초)
    public var minimumInterval: Double {
        switch self {
        case .approval: 5
        case .inputWaiting, .completion: 2
        case .door: 1
        case .bubble: 0.4
        case .error: 0.8
        case .chatter: 3
        case .footsteps: 0.25
        case .typing: 0.15
        }
    }

    /// 동시 재생 슬롯이 꽉 찼을 때 남길 순서 (클수록 중요)
    public var priority: Int {
        switch self {
        case .approval: 9
        case .inputWaiting: 8
        case .completion: 7
        case .error: 6
        case .door: 5
        case .bubble: 4
        case .chatter: 2
        case .footsteps, .typing: 1
        }
    }
}

/// 연출 엔진이 내보내는 효과음 요청
public enum SoundCue: Hashable, Sendable, CustomStringConvertible {
    /// 똑똑 (승인 요청)
    case knock
    /// 뾰롱 (입력 대기)
    case inputWaiting
    /// 띠리링 (팀장 응답 완료)
    case turnComplete
    /// 띠링 (팀원 보고, 더 짧은 2음)
    case memberReport
    /// 톡 + 음절 블립. voice는 직원 목소리 높이 단계, syllables는 블립 개수
    case bubble(voice: Int, syllables: Int)
    /// 딸랑 (출근·퇴근)
    case door
    /// 뿅? (오류)
    case error
    case chatter
    case footsteps
    case typing

    public var group: SoundGroup {
        switch self {
        case .knock: .approval
        case .inputWaiting: .inputWaiting
        case .turnComplete, .memberReport: .completion
        case .bubble: .bubble
        case .door: .door
        case .error: .error
        case .chatter: .chatter
        case .footsteps: .footsteps
        case .typing: .typing
        }
    }

    public var description: String {
        switch self {
        case .knock: "똑똑"
        case .inputWaiting: "뾰롱"
        case .turnComplete: "띠리링"
        case .memberReport: "띠링"
        case .bubble(let voice, let syllables): "톡·블립(목소리 \(voice), \(syllables)음절)"
        case .door: "딸랑"
        case .error: "뿅?"
        case .chatter: "소곤"
        case .footsteps: "톡톡"
        case .typing: "타닥"
        }
    }
}
