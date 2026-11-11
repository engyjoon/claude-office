import Foundation
import OfficeCore

/// 훅 연동이 고장 났을 때 사무실 창 띠·메뉴바 아이콘·메뉴 배너에 보여 줄 경고 하나 (설계서 §10, 개선 6).
///
/// 미리 출근한 세션들이 앉아 있으면 훅이 끊겨도 사무실은 멀쩡해 보입니다. 그래서 고장이면 가장 급한 하나를 골라
/// 어디서든 보이게 합니다. 정상이거나 아직 이벤트가 없을 뿐이면 nil.
public struct HookAlert: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 훅 서버를 시작하지 못함 (멈춤)
        case serverFailed
        /// ~/.claude/settings.json을 읽을 수 없음
        case settingsUnreadable
        /// `disableAllHooks`·`allowManagedHooksOnly`로 막힘
        case blocked
        /// 훅이 설치되지 않음
        case notInstalled
        /// 훅 스크립트가 없거나 옛 버전이거나 실행 권한이 없음
        case scriptNeedsFix
        /// 이 Claude Code 버전에서 받을 수 있는 이벤트가 빠짐
        case missingEvents
    }

    /// 띠에서 바로 할 수 있는 일
    public enum Action: Hashable, Sendable {
        case install, reinstall
        /// 설정 → 연동에서 보기 (서버 다시 시작, 파일 고치기 등)
        case openSettings
    }

    public let kind: Kind
    /// 빨강(고장)이면 error, 주황(손볼 것)이면 warning
    public let isError: Bool
    /// 한 줄 (사무실 창 띠, 메뉴바 아이콘 VoiceOver)
    public let summary: String
    /// 자세한 문장 (메뉴 배너)
    public let detail: String
    public let action: Action

    /// 버튼 문구 ("훅 설치", "다시 설치", "연동 설정…")
    public var actionLabel: String {
        switch action {
        case .install: "훅 설치"
        case .reinstall: "다시 설치"
        case .openSettings: "연동 설정…"
        }
    }

    public static func evaluate(_ input: HookHealth.Input) -> HookAlert? {
        if input.port == nil {
            let reason = input.serverError.map { " \($0)" } ?? ""
            return HookAlert(kind: .serverFailed, isError: true, summary: "훅 서버가 멈춰 있어 세션 소식을 받지 못해요",
                             detail: "훅 서버를 시작하지 못했어요.\(reason)", action: .openSettings)
        }
        switch input.status {
        case .settingsUnreadable(let reason):
            return HookAlert(kind: .settingsUnreadable, isError: true, summary: "~/.claude/settings.json을 읽을 수 없어요",
                             detail: "~/.claude/settings.json을 읽을 수 없어요. \(reason)", action: .openSettings)
        case .notInstalled:
            if let blocker = input.blocker { return blocked(blocker) }
            return HookAlert(kind: .notInstalled, isError: false, summary: "Claude Code 훅이 설치되지 않아 세션이 나타나지 않아요",
                             detail: "Claude Code 훅이 설치되어 있지 않아요.", action: .install)
        case .installed(let events), .scriptMissingOrOutdated(let events):
            if let blocker = input.blocker { return blocked(blocker) }
            var scriptStale = input.script != .current
            if case .scriptMissingOrOutdated = input.status { scriptStale = true }
            if scriptStale {
                return HookAlert(kind: .scriptNeedsFix, isError: false, summary: "훅 스크립트를 업데이트해야 해요",
                                 detail: "훅 스크립트를 업데이트해야 해요.", action: .reinstall)
            }
            let missing = HookSettingsEditor.missingEvents(installed: events, version: input.version)
            if !missing.isEmpty, let version = input.version {
                return HookAlert(kind: .missingEvents, isError: false, summary: "받을 수 있는 이벤트 \(missing.count)개가 빠져 있어요",
                                 detail: "Claude Code \(version)에서 받을 수 있는 이벤트 \(missing.count)개가 빠져 있어요.",
                                 action: .reinstall)
            }
            return nil
        }
    }

    private static func blocked(_ blocker: HookBlocker) -> HookAlert {
        HookAlert(kind: .blocked, isError: true, summary: "설정 때문에 훅이 실행되지 않아요", detail: blocker.message,
                  action: .openSettings)
    }
}
