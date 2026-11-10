import AppKit
import Observation
import ServiceManagement

/// 로그인 시 실행 (설정 → 일반, M5(8)). `SMAppService.mainApp`으로 이 앱을 로그인 항목에 넣고 뺍니다.
///
/// 로컬(ad-hoc) 서명 앱도 등록은 되지만, macOS가 "승인 필요"로 두면 시스템 설정 → 일반 → 로그인 항목에서 켜야 합니다.
@MainActor
@Observable
final class LoginItem {
    enum State: Equatable {
        case enabled, disabled, requiresApproval, notFound
    }

    private(set) var state: State = .disabled
    /// 마지막으로 켜기·끄기에 실패한 까닭
    private(set) var lastError: String?

    init() { refresh() }

    func refresh() {
        state = Self.state(of: SMAppService.mainApp.status)
    }

    /// 토글이 켜진 것으로 보일지 (승인을 기다리는 중도 켠 것으로)
    var isOn: Bool { state == .enabled || state == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = (error as NSError).localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// /Applications 밖(빌드 폴더 등)에서 실행 중이면 그 경로를 돌려줍니다
    var runningOutsideApplications: String? {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") ? nil : path
    }

    var statusText: String {
        switch state {
        case .enabled: "켜짐"
        case .disabled: "꺼짐"
        case .requiresApproval: "승인 필요 · 시스템 설정에서 Claude Office를 켜 주세요"
        case .notFound: "등록되지 않음"
        }
    }

    private static func state(of status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .disabled
        }
    }
}
