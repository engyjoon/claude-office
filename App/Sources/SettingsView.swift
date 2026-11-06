import OfficeCore
import OfficeServer
import SwiftUI

/// 설정 창 (설계서 §10). M2에서는 연동과 표시만 있습니다. 효과음·알림·직원 꾸미기는 이후 단계에서 추가합니다.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ConnectionSettings(model: model)
                .tabItem { Label("연동", systemImage: "link") }
            DisplaySettings(model: model)
                .tabItem { Label("표시", systemImage: "eye") }
        }
        .frame(width: 520, height: 400)
    }
}

struct ConnectionSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("훅 서버") {
                LabeledContent("상태") {
                    switch model.serverState {
                    case .running(let port): Text("실행 중 · 127.0.0.1:\(port)")
                    case .stopped: Text("멈춤")
                    case .failed(let message): Text("오류 · \(message)").foregroundStyle(.red)
                    }
                }
                LabeledContent("받은 훅", value: "\(model.receivedHooks)개")
                Button("서버 다시 시작") { model.startServer() }
            }

            Section("Claude Code 훅") {
                LabeledContent("상태") { Text(statusText) }
                LabeledContent("스크립트") { Text(model.installer.scriptURL.path).textSelection(.enabled).font(.caption) }
                LabeledContent("설정 파일") { Text(model.installer.settingsURL.path).textSelection(.enabled).font(.caption) }
                HStack {
                    Button(isInstalled ? "다시 설치" : "훅 설치") { model.installHooks() }
                        .disabled(model.isInstalling)
                    Button("제거", role: .destructive) { model.uninstallHooks() }
                        .disabled(!isInstalled || model.isInstalling)
                    Button("연결 확인") { model.sendTestHook() }
                        .disabled(!isInstalled)
                    if model.isInstalling { ProgressView().controlSize(.small) }
                }
                if let message = model.installMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHookStatus() }
    }

    private var isInstalled: Bool {
        switch model.hookStatus {
        case .installed, .scriptMissingOrOutdated: true
        default: false
        }
    }

    private var statusText: String {
        switch model.hookStatus {
        case .notInstalled: "설치 안 됨"
        case .installed(let events): "설치됨 · 이벤트 \(events.count)개"
        case .scriptMissingOrOutdated: "스크립트 업데이트 필요"
        case .settingsUnreadable(let reason): "설정 파일을 읽을 수 없음 · \(reason)"
        }
    }
}

struct DisplaySettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("말풍선과 상태에 보여줄 내용") {
                Picker("표시 수준", selection: Binding(get: { model.privacy }, set: { model.setPrivacy($0) })) {
                    Text("상세 — 파일명, 명령어까지").tag(PrivacyLevel.detailed)
                    Text("요약 — 툴 종류만").tag(PrivacyLevel.summary)
                    Text("비공개 — 아이콘과 표정만").tag(PrivacyLevel.hidden)
                }
                .pickerStyle(.radioGroup)
                Text("회의에서 화면을 공유할 때는 요약이나 비공개를 권해요. 비밀번호·토큰처럼 보이는 값과 프롬프트 내용은 어느 수준에서도 보여주지 않아요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
