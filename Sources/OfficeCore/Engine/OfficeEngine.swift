import Foundation

/// 훅 이벤트 → 의미 상태(OfficeState) → 연출 지시(Choreographer)를 한 번에 처리하는 진입점.
///
/// 앱은 이 값을 메인 액터에서 하나만 들고,
/// - 훅을 받으면 `handle(hookPayload:term:at:)`
/// - 화면 주기(예: 0.25초)마다 `tick(at:)`
/// 을 불러 나온 지시를 씬과 효과음 플레이어에 넘깁니다.
public struct OfficeEngine: Sendable {
    public private(set) var state = OfficeState()
    public private(set) var choreographer: Choreographer

    public init(
        privacy: PrivacyLevel = .detailed, config: ChoreographyConfig = .init(), book: DialogueBook = .korean,
        seed: UInt64 = UInt64.random(in: 0...UInt64.max)
    ) {
        choreographer = Choreographer(privacy: privacy, config: config, book: book, seed: seed)
    }

    public var privacy: PrivacyLevel {
        get { choreographer.privacy }
        set { choreographer.privacy = newValue }
    }

    public mutating func handle(_ event: OfficeEvent) -> [Directive] {
        let beats = state.apply(event)
        return choreographer.handle(beats, at: event.at)
    }

    /// 파싱할 수 없거나 무시하는 이벤트면 빈 배열을 돌려줍니다.
    public mutating func handle(hookPayload data: Data, term: String? = nil, at now: Date) throws -> [Directive] {
        guard let event = try HookParser.parse(data, term: term, receivedAt: now) else { return [] }
        return handle(event)
    }

    public mutating func tick(at now: Date) -> [Directive] {
        choreographer.tick(at: now)
    }
}
