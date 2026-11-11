import AppKit
import Foundation
import Intents
import OfficeCore
import UserNotifications

/// 코어의 `NotificationPlanner`가 정한 알림 동작을 macOS 알림 센터에 그대로 옮깁니다 (설계서 §10 알림, M5(3)).
///
/// - 권한은 처음 알림이 필요할 때(또는 설정 화면에서) 묻습니다. 앱을 켤 때 무조건 묻지 않습니다.
/// - 허용되지 않은 상태로 기억하고 있으면 보내기 직전에 권한을 다시 읽습니다 (시스템 설정에서 나중에 허용했을 수 있음).
/// - 켤 때와 끌 때 이 앱이 띄운 알림을 알림 센터에서 지웁니다 (지난 실행의 "승인 대기"가 남지 않게).
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
    /// 보내기 전에 권한을 다시 읽는 중
    private var checking = false
    /// 보냈고 아직 코어가 지우지 않은 알림 식별자
    private var live: Set<String> = []
    /// 알림 센터에 남아 있는지 확인하는 중인 제목 바꿈 (식별자 → 가장 새 알림, M6(14))
    private var retitling: [String: OfficeNotice] = [:]

    /// 측정 실행이면 알림 센터를 건드리지 않습니다 (설치된 앱과 같은 번들 ID라 그 앱의 알림을 지우지 않게, `PerfLaunch`)
    private let inert = PerfLaunch.isMeasuring

    override init() {
        super.init()
        guard !inert else { return }
        center.delegate = self
        removeAll()
        refreshAuthorization()
    }

    // MARK: - 권한

    func refreshAuthorization(then done: (() -> Void)? = nil) {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.setAuthorization(status)
                    done?()
                }
            }
        }
    }

    /// 이 앱이 띄운 알림을 모두 지웁니다 (켤 때·끌 때)
    func removeAll() {
        guard !inert else { return }
        queued.removeAll()
        live.removeAll()
        retitling.removeAll()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// 권한을 묻습니다 (아직 묻지 않았을 때만 시스템 창이 뜸). 끝나면 쌓아 둔 알림을 보냅니다.
    func requestAuthorization(then done: (() -> Void)? = nil) {
        guard !inert, !requesting else { return }
        requesting = true
        center.requestAuthorization(options: [.alert]) { _, _ in
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
        guard !inert else { return }
        for action in actions {
            switch action {
            case .post(let notice) where notice.onlyIfDelivered:
                retitle(notice)
            case .post(let notice):
                post(notice)
            case .remove(let ids):
                queued.removeAll { ids.contains($0.id) }
                live.subtract(ids)
                ids.forEach { retitling[$0] = nil }
                center.removeDeliveredNotifications(withIdentifiers: ids)
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    private func post(_ notice: OfficeNotice) {
        if authorization == .authorized || authorization == .provisional {
            deliver(notice)
            return
        }
        // 아직 묻지 않았거나 거부로 기억하고 있으면 쌓아 두고, 지금 권한을 다시 읽은 뒤 정합니다.
        // (처음에 거부했다가 시스템 설정에서 허용했으면 이때 알게 됩니다)
        queued.removeAll { $0.id == notice.id }
        queued.append(notice)
        guard !checking else { return }
        checking = true
        refreshAuthorization { [weak self] in
            guard let self else { return }
            self.checking = false
            switch self.authorization {
            case .authorized, .provisional: self.flushQueue()
            case .notDetermined: self.requestAuthorization()  // 처음 알림이 필요할 때 권한을 묻고, 허용되면 그때 보냅니다
            default: self.queued.removeAll()  // 거부됨: 메뉴바 배지와 사무실 연출만
            }
        }
    }

    /// 직함이 바뀐 알림 (M6(14)): 알림 센터에 아직 남아 있을 때만 같은 식별자로 조용히 바꿉니다.
    /// 사용자가 지운 알림은 되살리지 않고, 권한을 묻는 동안 쌓아 둔 알림이면 그 제목만 바꿉니다.
    private func retitle(_ notice: OfficeNotice) {
        if let index = queued.firstIndex(where: { $0.id == notice.id }) {
            queued[index].title = notice.title
            return
        }
        guard live.contains(notice.id), authorization == .authorized || authorization == .provisional else { return }
        let checking = retitling[notice.id] != nil
        retitling[notice.id] = notice
        guard !checking else { return }
        center.getDeliveredNotifications { delivered in
            let ids = Set(delivered.map(\.request.identifier))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let latest = self.retitling.removeValue(forKey: notice.id), self.live.contains(notice.id) else { return }
                    if ids.contains(notice.id) {
                        self.deliver(latest)
                    } else {
                        self.live.remove(notice.id)  // 사용자가 지움
                    }
                }
            }
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
        live.insert(notice.id)
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 앱 창(사무실·설정)이 앞에 있어도 배너를 보여 줍니다. 내용만 조용히 바꾸는 알림(`isUpdate`, 수동 수준)은 배너 없이 목록만.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let quiet = notification.request.content.interruptionLevel == .passive
        completionHandler(quiet ? [.list] : [.banner, .list])
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
    static let replyKey = "notify.reply"

    /// 저장된 값이 없으면 기본값 (승인 대기 켬, 응답 완료 끔, 답변 필요 켬)
    init(defaults: UserDefaults) {
        self.init()
        if defaults.object(forKey: Self.permissionKey) != nil { permission = defaults.bool(forKey: Self.permissionKey) }
        if defaults.object(forKey: Self.completionKey) != nil { completion = defaults.bool(forKey: Self.completionKey) }
        if defaults.object(forKey: Self.replyKey) != nil { reply = defaults.bool(forKey: Self.replyKey) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(permission, forKey: Self.permissionKey)
        defaults.set(completion, forKey: Self.completionKey)
        defaults.set(reply, forKey: Self.replyKey)
    }
}
