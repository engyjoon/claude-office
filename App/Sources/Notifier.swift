import AppKit
import Foundation
import Intents
import OfficeCore
import UserNotifications

/// 코어의 `NotificationPlanner`가 정한 알림 동작을 macOS 알림 센터에 그대로 옮깁니다 (설계서 §10 알림, M5(3)).
///
/// - 권한은 처음 알림이 필요할 때(또는 설정 화면에서) 묻습니다. 앱을 켤 때 무조건 묻지 않습니다.
/// - 알림 소리는 넣지 않습니다. 소리는 앱의 효과음(승인 요청 노크 등)이 맡고, 집중 모드면 그쪽에서 줄입니다.
/// - 알림이 화면에 뜰지 말지는 macOS 집중 모드 규칙에 맡깁니다.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// 알림을 눌렀을 때 갈 곳
    struct Target: Equatable {
        var agent: AgentID?
        var session: SessionID?
        var term: String?
        var hostSession: String?
    }

    /// 알림 권한 상태가 바뀌면 (설정 화면 표시용)
    var onAuthorizationChange: ((UNAuthorizationStatus) -> Void)?
    /// 알림을 눌렀을 때
    var onOpen: ((Target) -> Void)?

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    /// 권한을 묻는 동안 쌓아 둔 알림
    private var queued: [OfficeNotice] = []
    private var requesting = false

    override init() {
        super.init()
        center.delegate = self
        refreshAuthorization()
    }

    // MARK: - 권한

    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.setAuthorization(status) }
            }
        }
    }

    /// 권한을 묻습니다 (아직 묻지 않았을 때만 시스템 창이 뜸). 끝나면 쌓아 둔 알림을 보냅니다.
    func requestAuthorization(then done: (() -> Void)? = nil) {
        guard !requesting else { return }
        requesting = true
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.requesting = false
                    self.center.getNotificationSettings { settings in
                        let status = settings.authorizationStatus
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.setAuthorization(status)
                                self.flushQueue()
                                done?()
                            }
                        }
                    }
                }
            }
        }
    }

    private func setAuthorization(_ status: UNAuthorizationStatus) {
        guard status != authorization else { return }
        authorization = status
        onAuthorizationChange?(status)
    }

    /// 시스템 설정의 이 앱 알림 화면
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.engyjoon.claudeoffice"
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - 알림 보내기·지우기

    func apply(_ actions: [NoticeAction]) {
        for action in actions {
            switch action {
            case .post(let notice):
                post(notice)
            case .remove(let ids):
                queued.removeAll { ids.contains($0.id) }
                center.removeDeliveredNotifications(withIdentifiers: ids)
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    private func post(_ notice: OfficeNotice) {
        switch authorization {
        case .authorized, .provisional:
            deliver(notice)
        case .notDetermined:
            // 처음 알림이 필요할 때 권한을 묻고, 허용되면 그때 보냅니다
            queued.removeAll { $0.id == notice.id }
            queued.append(notice)
            requestAuthorization()
        default:
            break  // 거부됨: 메뉴바 배지와 사무실 연출만
        }
    }

    private func flushQueue() {
        let pending = queued
        queued.removeAll()
        guard authorization == .authorized || authorization == .provisional else { return }
        pending.forEach(deliver)
    }

    private func deliver(_ notice: OfficeNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.kind.rawValue
        content.sound = nil
        // 내용만 보강하는 알림은 배너를 다시 띄우지 않고 알림 센터의 내용만 바꿉니다
        content.interruptionLevel = notice.isUpdate ? .passive : .active
        var info: [String: String] = ["agent": notice.agent.raw, "session": notice.session.raw]
        if let term = notice.term { info["term"] = term }
        if let host = notice.hostSession { info["hostSession"] = host }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 앱 창(사무실·설정)이 앞에 있어도 배너를 보여 줍니다
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let target = Target(
            agent: (info["agent"] as? String).map(AgentID.init),
            session: (info["session"] as? String).map(SessionID.init),
            term: info["term"] as? String,
            hostSession: info["hostSession"] as? String)
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isDefault { self.onOpen?(target) }
                completionHandler()
            }
        }
    }
}

/// Claude 데스크톱 앱을 앞으로 가져옵니다.
///
/// 데스크톱 앱에는 `claude://` URL 스킴이 있지만 특정 Code 세션을 여는 경로는 공개되어 있지 않습니다.
/// 그래서 앱을 활성화만 하고, 세션은 사용자가 사이드바에서 고릅니다 (M5(3) 한계).
enum DesktopAppFocuser {
    static let bundleID = "com.anthropic.claudefordesktop"

    @discardableResult
    static func focus() -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.activate()
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// macOS 집중 모드 감지 (설계서 §11.3). `INFocusStatusCenter`는 사용자가 허용해야 읽을 수 있고,
/// 허용하지 않았거나 읽을 수 없으면 "집중 모드 아님"으로 봅니다 (그러면 효과음은 평소대로).
@MainActor
enum FocusDetector {
    enum Access: Equatable {
        case notDetermined, authorized, denied, unavailable
    }

    static var access: Access {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    /// 지금 집중 모드인지 (모르면 false)
    static var isFocused: Bool {
        guard access == .authorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    static func requestAuthorization(then done: @escaping (Access) -> Void) {
        INFocusStatusCenter.default.requestAuthorization { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(access) }
            }
        }
    }
}

extension NotificationSettings {
    static let permissionKey = "notify.permission"
    static let completionKey = "notify.completion"

    /// 저장된 값이 없으면 기본값 (승인 대기 켬, 응답 완료 끔)
    init(defaults: UserDefaults) {
        self.init()
        if defaults.object(forKey: Self.permissionKey) != nil { permission = defaults.bool(forKey: Self.permissionKey) }
        if defaults.object(forKey: Self.completionKey) != nil { completion = defaults.bool(forKey: Self.completionKey) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(permission, forKey: Self.permissionKey)
        defaults.set(completion, forKey: Self.completionKey)
    }
}
