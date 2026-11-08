import AppKit
import OfficeCore
import OfficeServer
import SwiftUI
import UserNotifications

/// 설정 창 (설계서 §10). 연동, 표시, 알림(M5(3)), 효과음(M4). 직원 꾸미기는 이후 단계에서 추가합니다.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ConnectionSettings(model: model)
                .tabItem { Label("연동", systemImage: "link") }
            DisplaySettings(model: model)
                .tabItem { Label("표시", systemImage: "eye") }
            NotificationSettingsView(model: model)
                .tabItem { Label("알림", systemImage: "bell") }
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

    private func mini<Value>(_ keyPath: WritableKeyPath<MiniOfficeSettings, Value>) -> Binding<Value> {
        Binding(get: { model.miniSettings[keyPath: keyPath] }, set: { value in
            var settings = model.miniSettings
            settings[keyPath: keyPath] = value
            model.setMiniSettings(settings)
        })
    }

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
            Section("미니 사무실") {
                Toggle("미니 사무실 보기", isOn: mini(\.enabled))
                Toggle("내 답변이 필요하면(승인·질문·계획) 그 메인으로 바꾸기", isOn: mini(\.autoSwitch))
                Slider(value: mini(\.opacity), in: 0.5...1) {
                    Text("투명도")
                } minimumValueLabel: {
                    Text("50%").font(.caption)
                } maximumValueLabel: {
                    Text("100%").font(.caption)
                }
                Button("기본 위치로 (화면 오른쪽 아래)") { model.resetMiniPosition() }
                    .disabled(!model.miniSettings.enabled)
                Text("화면 구석에 메인 한 명과 일하는 서브 2명을 사무실 그대로(줄이지 않고) 보여 줘요. 자동이면 내 답변이 필요한 메인 → 응답을 끝낸 메인(10분 동안, [앱으로]를 누르면 확인) → 가장 마지막에 요청한 메인 순이에요. 머리줄에서 메인을 고르면 고정돼요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// 알림 설정 (설계서 §10 알림, M5(3)): 승인 대기·응답 완료 켜기·끄기, 권한 상태, 집중 모드
struct NotificationSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.permission)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("승인 대기 알림")
                        Text("누군가 권한 승인을 기다리기 시작하면 바로 알려요. 대기가 풀리면 알림 센터에서 지워요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: binding(\.completion)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("응답 완료 알림")
                        Text("세션이 응답을 마치면(Stop) 알려요. 세션마다 마지막 하나만 남아요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("알림을 누르면 그 세션으로 가요: 터미널 세션은 그 터미널을, Claude 데스크톱 앱 세션은 데스크톱 앱을 앞으로 가져와요 (세션까지 열어 주는 공개된 방법이 없어 세션은 사이드바에서 골라 주세요). 사무실 창이 열려 있으면 그 캐릭터도 골라요. 표시 수준이 요약·비공개면 알림에도 파일명·명령을 쓰지 않아요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("알림 권한") {
                LabeledContent("상태") { Text(authorizationText) }
                HStack {
                    if model.notificationAuthorization == .notDetermined {
                        Button("알림 허용 요청") { model.requestNotificationAuthorization() }
                    }
                    Button("시스템 설정 열기") { Notifier.openSystemSettings() }
                }
            }

            Section {
                Toggle("집중 모드 중에는 알림 효과음 끄기", isOn: Binding(
                    get: { model.soundSettings.respectFocusMode },
                    set: { value in
                        var settings = model.soundSettings
                        settings.respectFocusMode = value
                        model.setSoundSettings(settings)
                    }))
                LabeledContent("집중 모드") { Text(focusText) }
                if model.focusAccess == .notDetermined {
                    Button("집중 모드 상태 읽기 허용 요청") { model.requestFocusAccess() }
                }
            } header: {
                Text("집중 모드")
            } footer: {
                Text("알림이 화면에 뜰지는 macOS 집중 모드 규칙을 따라요. 이 앱은 집중 모드일 때 노크·완료 같은 효과음만 줄여요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationAuthorization()  // 시스템 설정에서 돌아왔을 때
        }
    }

    private var authorizationText: String {
        switch model.notificationAuthorization {
        case .notDetermined: "아직 묻지 않음 (처음 알림이 필요할 때 물어요)"
        case .denied: "허용 안 됨 · 시스템 설정에서 켤 수 있어요"
        case .authorized: "허용됨"
        case .provisional: "조용히 허용됨"
        default: "알 수 없음"
        }
    }

    private var focusText: String {
        switch model.focusAccess {
        case .authorized: model.isFocusModeOn == true ? "지금 켜져 있음" : "지금 꺼져 있음"
        case .notDetermined: "상태를 읽어도 되는지 아직 묻지 않음"
        case .denied: "상태 읽기 허용 안 됨 · 효과음은 평소대로"
        case .unavailable: "이 앱에서 읽을 수 없음 · 효과음은 평소대로"
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.notificationSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.notificationSettings
                settings[keyPath: keyPath] = value
                model.setNotificationSettings(settings)
            }
        )
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
