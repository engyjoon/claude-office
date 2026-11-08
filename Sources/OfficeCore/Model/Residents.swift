import Foundation

/// Claude 데스크톱 앱에 열려 있는 세션 하나 = 훅을 보내기 전에 미리 "쉬는 중"으로 앉힐 사람 (설계서 §5.2, M5(5)).
public struct ResidentSession: Hashable, Sendable {
    /// 훅의 `session_id` (데스크톱 정보 파일의 `cliSessionId`)
    public var session: SessionID
    /// 데스크톱 세션 id (`local_…`)
    public var hostSession: String
    /// 이 세션을 띄운 세션들의 훅 `session_id` (가까운 부모부터). 직접 연 세션은 빈 배열.
    public var ancestors: [SessionID]
    /// 최상위 세션의 폴더 (행을 정함)
    public var rootCwd: String?
    public var title: String?
    /// 데스크톱 앱이 기록한 마지막 활동 시각. 쉼 단계(소파 → 안마 의자 → 잠)를 이 시각부터 셉니다.
    public var lastActivity: Date?

    public init(
        session: SessionID, hostSession: String, ancestors: [SessionID] = [], rootCwd: String? = nil, title: String? = nil,
        lastActivity: Date? = nil
    ) {
        self.session = session
        self.hostSession = hostSession
        self.ancestors = ancestors
        self.rootCwd = rootCwd
        self.title = title
        self.lastActivity = lastActivity
    }
}

/// 데스크톱 앱 세션 정보를 한 번 읽은 결과 (앱이 몇 초마다 만들어 `OfficeState.syncResidents`에 넘김).
public struct ResidentRoll: Hashable, Sendable {
    /// 앉힐 세션 (부모가 먼저, 행은 최근에 활동한 순)
    public var residents: [ResidentSession]
    /// 데스크톱 앱에 열려 있는(보관하지 않은) 모든 데스크톱 세션 id. 여기에 없는 데스크톱 세션은 퇴근 대상입니다.
    public var openHostSessions: Set<String>
    /// 정보 파일을 하나도 읽지 못했으면 false (읽기 실패로 모두 퇴근시키지 않게)
    public var isReliable: Bool
    /// 파일을 읽기 시작한 때. 그 뒤에 훅이 온 사람은 이번 결과로 퇴근시키지 않습니다.
    public var readAt: Date

    public init(residents: [ResidentSession], openHostSessions: Set<String>, isReliable: Bool, readAt: Date) {
        self.residents = residents
        self.openHostSessions = openHostSessions
        self.isReliable = isReliable
        self.readAt = readAt
    }
}
