import Foundation

/// 사무실 안의 장소 (설계서 §8.1). 실제 좌표는 씬이 맵에서 정합니다.
public enum Spot: Hashable, Sendable, CustomStringConvertible {
    case door
    case seat(TeamID, Int)
    /// 특정 직원 바로 옆 (위임·보고 대화용)
    case beside(AgentID)
    case bookshelf
    case serverRack
    case research
    case whiteboard
    case lounge

    public var isSeat: Bool {
        if case .seat = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .door: "문"
        case .seat(let team, let index): "자리(\(team.raw.split(separator: "/").last ?? "")#\(index))"
        case .beside(let agent): "\(agent) 옆"
        case .bookshelf: "책장"
        case .serverRack: "서버랙"
        case .research: "리서치 코너"
        case .whiteboard: "화이트보드"
        case .lounge: "휴게실"
        }
    }
}

/// 계속 유지되는 자세
public enum Pose: String, Hashable, Sendable {
    case standing, sitting, typing, reading, thinking, writingBoard, holdingCup, raisingHand, sleeping, sorting
}

/// 한 번 하고 끝나는 동작 (설계서 §9.3 제스처 12종 중 상황 연출에 쓰는 것)
public enum Gesture: String, Hashable, Sendable {
    case wave, nod, beckon, thumbsUp, cheer, highFive, tilt, scratchHead, stretch, sip
}

/// 표정 10종 (설계서 §9.3)
public enum Expression: String, Hashable, Sendable {
    case neutral, happy, focus, think, surprised, troubled, sleepy, proud, sad, eager
}

/// 머리 위 아이콘
public enum Emote: String, Hashable, Sendable {
    case exclamation, question, bulb, sweat, sparkle, zzz, note
}

public enum BubbleKind: String, Hashable, Sendable {
    case speech, thought, shout, whisper
}

public struct Bubble: Hashable, Sendable {
    public var kind: BubbleKind
    public var text: String
    /// 표시 시간(초). nil이면 `dismissBubble`이 올 때까지 유지합니다 (승인 대기 외침 풍선).
    public var duration: Double?

    public init(kind: BubbleKind, text: String, duration: Double?) {
        self.kind = kind
        self.text = text
        self.duration = duration
    }

    /// 설계서 §7.2: 1.8초 + 글자당 60ms, 최대 6초
    public static func timed(_ kind: BubbleKind, _ text: String) -> Bubble {
        Bubble(kind: kind, text: text, duration: min(6, 1.8 + 0.06 * Double(text.count)))
    }
}

/// 머리 위 상태 칩 ("Edit · auth.ts")
public struct StatusPill: Hashable, Sendable {
    public var category: ToolCategory
    public var text: String
}

public enum Prop: String, Hashable, Sendable {
    case book, cup, documents, marker
}

public enum Effect: Hashable, Sendable {
    /// 새 프롬프트가 종이비행기로 날아와 팀장에게 도착
    case paperPlane(to: AgentID)
}

/// 연출 엔진이 씬에 내리는 지시.
///
/// 씬은 직원마다 대기열을 하나씩 두고 지시를 **순서대로** 실행합니다.
/// - `walk`는 도착할 때까지, `wait`는 그 시간만큼 다음 지시를 막습니다.
/// - `signal`/`await`로 두 직원의 대기열을 맞춥니다 (보고하러 온 팀원이 도착한 뒤 팀장이 하이파이브).
/// - `clearQueue`는 아직 실행하지 않은 지시를 버립니다 (승인 대기처럼 급한 일).
/// - `agent`가 nil인 지시(팀 열기, 효과, 전역 효과음)는 즉시 실행합니다.
public struct Directive: Hashable, Sendable, CustomStringConvertible {
    public enum Action: Hashable, Sendable {
        case openTeam(Team)
        case spawn(Agent, at: Spot)
        case despawn
        case clearQueue
        case walk(to: Spot)
        case sit
        case stand
        case pose(Pose)
        case gesture(Gesture)
        case express(Expression)
        case emote(Emote?)
        case say(Bubble)
        case dismissBubble
        case status(StatusPill?)
        case prop(Prop?)
        case wait(Double)
        case signal(String)
        case await(String, timeout: Double)
        case effect(Effect)
        case sound(SoundCue)
    }

    public var agent: AgentID?
    public var action: Action

    public init(_ agent: AgentID?, _ action: Action) {
        self.agent = agent
        self.action = action
    }

    public var description: String {
        let who = agent.map { "\($0)" } ?? "*"
        let what: String
        switch action {
        case .openTeam(let team): what = "팀 열기 \(team.name) (섬 \(team.island))"
        case .spawn(let agent, let spot): what = "등장 \(agent.profile.displayName) @\(spot)"
        case .despawn: what = "퇴장"
        case .clearQueue: what = "대기열 비우기"
        case .walk(let spot): what = "걷기 → \(spot)"
        case .sit: what = "앉기"
        case .stand: what = "일어서기"
        case .pose(let pose): what = "자세 \(pose.rawValue)"
        case .gesture(let gesture): what = "제스처 \(gesture.rawValue)"
        case .express(let expression): what = "표정 \(expression.rawValue)"
        case .emote(let emote): what = "아이콘 \(emote?.rawValue ?? "없음")"
        case .say(let bubble): what = "말풍선[\(bubble.kind.rawValue)] \"\(bubble.text)\""
        case .dismissBubble: what = "말풍선 닫기"
        case .status(let pill): what = "상태 칩 \(pill.map { "\"\($0.text)\"" } ?? "없음")"
        case .prop(let prop): what = "소품 \(prop?.rawValue ?? "없음")"
        case .wait(let seconds): what = "대기 \(seconds)초"
        case .signal(let name): what = "신호 \(name)"
        case .await(let name, let timeout): what = "신호 기다림 \(name) (최대 \(timeout)초)"
        case .effect(let effect): what = "효과 \(effect)"
        case .sound(let cue): what = "효과음 \(cue)"
        }
        return "\(who): \(what)"
    }
}
