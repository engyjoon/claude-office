import AppKit

/// 메뉴바 앱(LSUIElement)의 창을 다른 앱 창 위로 가져옵니다 (M5(8) 설정 창, M6(17) 사무실 창).
///
/// - 미니 사무실은 앱을 활성화하지 않는 패널(`.nonactivatingPanel`)이라 눌러도 앱이 앞으로 오지 않습니다.
///   macOS 14의 협력 활성화 `NSApp.activate()`는 지금 앞에 있는 앱이 양보하지 않으면 거절될 수 있어서,
///   그때 연 창은 다른 앱 창 뒤에 깔립니다. 그래서 `activate(ignoringOtherApps:)`(14에서 폐기 예정이지만 동작함)로 활성화합니다.
/// - SwiftUI `openWindow`는 창을 비동기로 만들거나 앞으로 가져오므로, 창이 생길 때까지 몇 번(0~0.6초) 다시 올립니다.
/// - 최소화돼 있으면 Dock에서 꺼내고, 다른 Space에 있으면 지금 Space로 데려옵니다(그 Space로 화면이 넘어가지 않게).
@MainActor
enum WindowFront {
    static let retryDelays: [Double] = [0.0, 0.1, 0.3, 0.6]

    /// 앱을 활성화하고 `open`(창 열기)을 부른 뒤, `find`로 찾은 창을 맨 앞으로 몇 번 올립니다.
    static func bring(open: (() -> Void)? = nil, find: @escaping @MainActor () -> NSWindow?) {
        // 활성화하기 전에 앱 전환기에 올려 둡니다 (활성화한 뒤에 바꾸면 메뉴 막대가 앞 앱의 것으로 남을 수 있음)
        SwitcherPresence.show()
        activateApp()
        open?()
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let window = find() else { return }
                    raise(window)
                }
            }
        }
    }

    /// 창 하나를 맨 앞의 키 창으로
    static func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isOnActiveSpace, !window.collectionBehavior.contains(.canJoinAllSpaces) {
            // 잠깐 "지금 Space로 옮기기"를 켜고 앞으로 올린 뒤 되돌립니다
            let behavior = window.collectionBehavior
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.collectionBehavior = behavior
        }
        if !NSApp.isActive { activateApp() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 보통 창(사무실·이벤트 로그·설정·환영 창)이 떠 있는 동안만 앱을 앱 전환기(⌘Tab)와 Dock에 올립니다.
///
/// 메뉴바 앱(LSUIElement)은 액세서리 앱이라 창이 떠 있어도 앱 전환기에 없어서, 다른 앱 창을 누른 뒤에는
/// 키보드로 사무실 창에 돌아올 수 없었습니다 (사용자 제보 2026-11-19). 그래서 창이 하나라도 떠 있거나 최소화돼 있으면
/// `.regular`, 다 닫히면 다시 `.accessory`(메뉴바 아이콘만)로 바꿉니다.
/// - 미니 사무실·메뉴바 드롭다운은 패널이라 세지 않습니다 (미니만 떠 있을 때는 전처럼 Dock에 없음).
/// - 창이 닫히는 순간에는 아직 `isVisible`이 true라서 닫히는 창은 빼고 셉니다.
@MainActor
enum SwitcherPresence {
    private static var observers: [NSObjectProtocol] = []

    /// 창이 뜨고 닫히고 최소화되는 것을 지켜봅니다 (앱이 준비된 뒤 한 번)
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { update(closing: closing) }
        })
        update()
    }

    /// 창을 열기 직전에: 앱 전환기에 올림 (창이 끝내 안 열리면 다음 `update`가 되돌림)
    static func show() {
        apply(.regular)
    }

    static func update(closing: NSWindow? = nil) {
        guard let app = NSApp else { return }
        let hasWindow = app.windows.contains { $0 !== closing && counts($0) }
        apply(hasWindow ? .regular : .accessory)
    }

    /// 제목 막대가 있는 보통 창이 떠 있거나 최소화돼 있음 (패널·메뉴바 창은 아님)
    private static func counts(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard let app = NSApp, app.activationPolicy() != policy else { return }
        app.setActivationPolicy(policy)
    }
}

/// 사무실 창 (`Window(OfficeWindowView.title, id: WindowID.office)`). SwiftUI 창은 객체를 직접 받을 수 없어 제목으로 찾고,
/// 찾는 곳은 여기 하나입니다 (개선 11).
@MainActor
enum OfficeWindow {
    /// 이 창이 사무실 창인지
    static func owns(_ window: NSWindow?) -> Bool {
        window?.title == OfficeWindowView.title
    }

    /// 조건에 맞는 사무실 창 (앱이 아직 준비되지 않았으면 nil)
    static func first(where condition: (NSWindow) -> Bool = { _ in true }) -> NSWindow? {
        NSApp?.windows.first { owns($0) && condition($0) }
    }

    /// 떠 있든 최소화돼 있든 닫힌 뒤 남아 있든, 사무실 창 객체
    static var window: NSWindow? { first() }

    /// 떠 있음 (최소화·닫힘이 아님)
    static var isOpen: Bool {
        first { $0.isVisible && !$0.isMiniaturized } != nil
    }

    /// 떠 있거나 Dock에 최소화돼 있음 (닫지 않음)
    static var isOpenOrMinimized: Bool {
        first { $0.isVisible || $0.isMiniaturized } != nil
    }

    /// 떠 있는 사무실 창을 닫습니다
    static func close() {
        first { $0.isVisible }?.close()
    }
}

/// 설정 창을 앞으로 가져옵니다. 메뉴바 앱은 활성화가 끝나기 전에 설정 창이 열리면
/// 다른 앱 창 뒤에 깔리기 쉬워서, 활성화한 뒤 창이 생길 때까지 몇 번 앞으로 올립니다 (M5(8)).
enum SettingsWindow {
    @MainActor static func bringToFront() {
        WindowFront.bring { window }
    }

    /// SwiftUI `Settings` 장면의 창
    @MainActor static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" && $0.isVisible }
    }
}
