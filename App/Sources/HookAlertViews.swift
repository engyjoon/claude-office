import AppKit
import OfficeCore
import OfficeServer
import SwiftUI

/// 연동 경고(`HookAlert`)의 아이콘·색 (메뉴 배너, 사무실 창 띠, 메뉴바 아이콘이 같게 씀, 개선 6)
enum HookAlertStyle {
    static func symbol(_ alert: HookAlert) -> String {
        switch alert.kind {
        case .serverFailed, .endpointLost: "exclamationmark.triangle.fill"
        case .settingsUnreadable: "doc.badge.ellipsis"
        case .blocked: "hand.raised.fill"
        case .notInstalled: "link.badge.plus"
        case .scriptNeedsFix, .missingEvents: "arrow.triangle.2.circlepath"
        }
    }

    static func tint(_ alert: HookAlert) -> Color { alert.isError ? .red : .orange }
    static func nsTint(isError: Bool) -> NSColor { isError ? .systemRed : .systemOrange }
}

/// 경고의 버튼: 설치·다시 설치(설치 중이면 잠김), 아니면 설정 → 연동
struct HookAlertButton: View {
    let model: AppModel
    let alert: HookAlert

    var body: some View {
        Button(model.isInstalling && alert.action != .openSettings ? "설치 중…" : alert.actionLabel) {
            model.perform(alert.action)
        }
        .disabled(model.isInstalling && alert.action != .openSettings)
    }
}

/// 사무실 창 위쪽의 얇은 띠 (개선 6): 훅이 끊겼는데 미리 출근한 세션들 때문에 사무실이 멀쩡해 보이지 않게.
/// 경고가 있으면 그 한 줄과 [훅 설치]/[다시 설치]/[연동 설정…], 경고가 사라진 뒤에는 마지막 설치 결과를 닫을 때까지.
struct HookAlertStrip: View {
    let model: AppModel
    static let height: CGFloat = 30

    /// 띠를 보여 줄지 (창 높이 계산용)
    @MainActor static func isShown(_ model: AppModel) -> Bool {
        model.hookAlert != nil || model.installOutcome != nil
    }

    var body: some View {
        if let alert = model.hookAlert {
            // 설치에 실패했으면 그 까닭을, 아니면 경고 한 줄
            let failure = model.installOutcome.flatMap { $0.succeeded ? nil : $0.text }
            strip(symbol: HookAlertStyle.symbol(alert), tint: HookAlertStyle.tint(alert), text: failure ?? alert.summary) {
                HookAlertButton(model: model, alert: alert)
                if alert.action != .openSettings {
                    Button("자세히…") { model.openSettingsWindow(tab: .connection) }
                        .buttonStyle(.link)
                }
                if failure != nil { closeButton }
            }
        } else if let outcome = model.installOutcome {
            strip(symbol: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
                  tint: outcome.succeeded ? .green : .red, text: outcome.text) {
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button {
            model.dismissInstallOutcome()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("설치 결과 닫기")
    }

    private func strip(symbol: String, tint: Color, text: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("연동 상태")
    }
}

/// 첫 실행 환영 창 (개선 6). 메뉴바 드롭다운(`MenuBarExtra`)은 코드로 열 수 없어서 작은 창을 한 번 엽니다.
/// 훅이 설치되지 않은 첫 실행에만 열리고(`AppModel.showWelcomeIfFirstRun`), 본 것은 UserDefaults에 기억합니다.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            WindowFront.raise(window)
            return
        }
        let controller = NSHostingController(rootView: WelcomeView(model: model) { close() })
        let window = NSWindow(contentViewController: controller)
        window.title = "Claude Office 시작하기"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        WindowFront.bring { window }
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct WelcomeView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text("Claude Office에 오신 것을 환영해요").font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code 세션과 서브에이전트가 가상 사무실의 직원으로 출근해 일하는 모습을 보여 줘요.")
                Text("메뉴바의 건물 아이콘에서 현황을 보고, 승인을 기다리는 세션으로 바로 갈 수 있어요.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Text("시작하려면 Claude Code 훅을 설치해 주세요. ~/.claude/settings.json에 훅을 더하고 기존 설정은 백업해요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = model.installOutcome {
                Label(outcome.text, systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("닫기", action: close)
                Spacer()
                Button("사무실 보기") {
                    model.openOfficeWindow()
                    close()
                }
                let installed = model.installOutcome?.succeeded == true
                Button(model.isInstalling ? "설치 중…" : installed ? "설치됨" : "훅 설치") { model.installHooks() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isInstalling || installed)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
