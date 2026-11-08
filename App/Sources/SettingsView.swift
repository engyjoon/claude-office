import OfficeCore
import OfficeServer
import SwiftUI

/// 설정 창 (설계서 §10). 연동, 표시, 효과음(M4). 알림·직원 꾸미기는 이후 단계에서 추가합니다.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ConnectionSettings(model: model)
                .tabItem { Label("연동", systemImage: "link") }
            DisplaySettings(model: model)
                .tabItem { Label("표시", systemImage: "eye") }
            SoundSettingsView(model: model)
                .tabItem { Label("효과음", systemImage: "speaker.wave.2") }
        }
        .frame(width: 540, height: 520)
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

/// 효과음 설정 (설계서 §11.2·§11.3): 전체 소리, 전체 음량, 항목별 켜기·끄기와 미리 듣기
struct SoundSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("효과음 켜기", isOn: binding(\.masterEnabled))
                LabeledContent("음량") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: binding(\.volume), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        Text("\(Int((model.soundSettings.volume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.soundSettings.masterEnabled)
            } footer: {
                Text("알림 소리는 사무실 창이 안 보여도 울리고, 장식 소리는 사무실 창이 화면에 보일 때만 울려요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("알림") {
                ForEach(SoundGroup.allCases.filter(\.isAlert), id: \.self, content: row)
            }
            Section("장식") {
                ForEach(SoundGroup.allCases.filter { !$0.isAlert }, id: \.self, content: row)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ group: SoundGroup) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { model.soundSettings.enabledGroups.contains(group) },
                set: { enabled in
                    var settings = model.soundSettings
                    settings.set(group, enabled: enabled)
                    model.setSoundSettings(settings)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                    Text(group.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                model.previewSound(group)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("미리 듣기")
        }
        .disabled(!model.soundSettings.masterEnabled)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SoundSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.soundSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.soundSettings
                settings[keyPath: keyPath] = value
                model.setSoundSettings(settings)
            }
        )
    }
}
