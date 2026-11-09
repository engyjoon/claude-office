import AppKit
import OfficeCore
import OfficeServer
import SwiftUI
import UserNotifications

/// 설정 창 (설계서 §10, M5(8)): 일반 · 연동 · 표시 · 미니 사무실 · 알림 · 효과음.
/// 직원 꾸미기는 M6 이후에 붙입니다.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        // 마지막에 본 탭은 SwiftUI가 기억합니다
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("일반", systemImage: "gearshape") }
            ConnectionSettings(model: model)
                .tabItem { Label("연동", systemImage: "link") }
            DisplaySettings(model: model)
                .tabItem { Label("표시", systemImage: "eye") }
            MiniOfficeSettingsView(model: model)
                .tabItem { Label("미니 사무실", systemImage: "pip") }
            NotificationSettingsView(model: model)
                .tabItem { Label("알림", systemImage: "bell") }
            SoundSettingsView(model: model)
                .tabItem { Label("효과음", systemImage: "speaker.wave.2") }
        }
        .frame(width: 580, height: 560)
        // 설정 창이 다른 앱 뒤에 열리지 않게 (메뉴바 앱은 활성화가 늦게 끝남)
        .onAppear { SettingsWindow.bringToFront() }
    }
}

// MARK: - 공용 조각

/// 항목 아래 짧은 설명
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 제목 + 설명이 있는 토글
struct DetailToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Footnote(detail)
            }
        }
    }
}

/// 상태 점 (훅 상태)
struct LevelDot: View {
    let level: HookHealth.Level

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.small)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .idle: "circle.dashed"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch level {
        case .ok: .green
        case .idle: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    private var label: String {
        switch level {
        case .ok: "정상"
        case .idle: "아직 없음"
        case .warning: "확인 필요"
        case .error: "오류"
        }
    }
}

// MARK: - 일반

struct GeneralSettings: View {
    let model: AppModel
    @State private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                DetailToggle(
                    "로그인 시 실행",
                    detail: "Mac에 로그인하면 메뉴바에 Claude Office를 바로 띄워요.",
                    isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
                LabeledContent("상태") {
                    Text(loginItem.statusText)
                        .foregroundStyle(loginItem.state == .requiresApproval ? .orange : .secondary)
                }
                if loginItem.state == .requiresApproval || loginItem.lastError != nil {
                    Button("시스템 설정 열기") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.lastError {
                    Footnote("바꾸지 못했어요: \(error)")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("시작")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let path = loginItem.runningOutsideApplications {
                        Footnote("지금 실행 중인 앱이 /Applications 밖에 있어요(\(path)). make install로 설치한 앱에서 켜 주세요.")
                            .foregroundStyle(.orange)
                    }
                    Footnote("로컬 서명(ad-hoc) 앱이라 macOS가 승인을 따로 요구하거나, 다시 설치한 뒤 꺼질 수 있어요. 그럴 때는 시스템 설정 → 일반 → 로그인 항목에서 확인해 주세요.")
                }
            }

            Section {
                Picker("사무실 조명", selection: Binding(get: { model.lightingMode }, set: { model.setLightingMode($0) })) {
                    ForEach(LightingMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Footnote(mode.detail)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                LabeledContent("지금") {
                    Text(model.isNight ? "밤 (저녁 조명)" : "낮")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("사무실 조명")
            } footer: {
                Footnote("밤에는 벽·바닥·가구를 어둡게 하고 창밖을 밤하늘로 바꿔요. 사람 있는 책상만 스탠드와 화면 불빛이 켜져요. 직원과 말풍선은 낮 색 그대로예요. 사무실 창과 미니 사무실에 모두 적용돼요.")
            }

            Section("앱 정보") {
                LabeledContent("버전", value: Self.version)
                HStack {
                    Button("사무실 창 열기") { model.openOfficeWindow() }
                    Button(model.miniSettings.enabled ? "미니 사무실 끄기" : "미니 사무실 켜기") {
                        model.setMiniEnabled(!model.miniSettings.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()  // 시스템 설정에서 승인하고 돌아왔을 때
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - 연동

struct ConnectionSettings: View {
    let model: AppModel
    @State private var confirmingUninstall = false
    /// "12초 전"이 흐르도록 1초마다 다시 판정합니다
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                let health = model.hookHealth(now: now)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LevelDot(level: health.level)
                    Text(health.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(health.items) { item in
                    LabeledContent(item.label) {
                        HStack(spacing: 4) {
                            Text(item.value).textSelection(.enabled)
                            LevelDot(level: item.level)
                        }
                    }
                }
            } header: {
                Text("훅 상태")
            } footer: {
                Footnote("Claude Code가 훅 스크립트(~/.claude/hooks/claude-office.sh)를 실행하면 이 앱의 로컬 서버로 이벤트가 와요. 받은 이벤트 수는 앱을 켤 때마다 0부터 셉니다.")
            }

            Section {
                HStack {
                    Button(isRegistered ? "다시 설치" : "훅 설치") { model.installHooks() }
                        .disabled(model.isInstalling)
                    Button("제거…", role: .destructive) { confirmingUninstall = true }
                        .disabled(!isRegistered || model.isInstalling)
                    Spacer()
                    Button("테스트 이벤트 보내기") { model.sendTestEvents() }
                        .disabled(!isRegistered || model.isSendingTest || model.isInstalling)
                    if model.isInstalling || model.isSendingTest { ProgressView().controlSize(.small) }
                }
                if let message = model.installMessage {
                    Footnote(message)
                }
            } header: {
                Text("조작")
            } footer: {
                Footnote("테스트 이벤트는 설치된 훅 스크립트로 가짜 세션을 보내요: \"Claude Office 테스트\" 디렉토리에 직원이 잠깐 출근해 파일을 읽고 퇴근해요(약 \(Int(HookTestScenario.duration))초). 알림은 띄우지 않아요. 다시 설치는 settings.json을 백업한 뒤 이 앱의 훅만 고치고, 제거도 이 앱의 훅만 지워요.")
            }

            Section {
                Button("서버 다시 시작") {
                    model.startServer()
                    model.refreshHookStatus()
                }
                LabeledContent("엔드포인트 파일") {
                    Text(model.endpointURL.path).font(.caption).textSelection(.enabled)
                }
                LabeledContent("설정 파일") {
                    Text(model.installer.settingsURL.path).font(.caption).textSelection(.enabled)
                }
            } header: {
                Text("서버와 파일")
            } footer: {
                Footnote("서버는 127.0.0.1에서만 받고, 앱을 켤 때 빈 포트를 골라 토큰과 함께 엔드포인트 파일에 적어요. 훅 스크립트는 이 파일을 읽어 보내므로 포트를 따로 맞출 필요가 없어요.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHookStatus() }
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshHookStatus()  // 터미널에서 settings.json을 고치고 돌아왔을 때
        }
        .confirmationDialog("Claude Office 훅을 제거할까요?", isPresented: $confirmingUninstall) {
            Button("제거", role: .destructive) { model.uninstallHooks() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("~/.claude/settings.json에서 이 앱의 훅만 지우고 훅 스크립트를 삭제해요. 다른 훅과 설정은 그대로예요. 제거하면 Claude Code 세션이 사무실에 나타나지 않아요.")
        }
    }

    private var isRegistered: Bool {
        switch model.hookStatus {
        case .installed, .scriptMissingOrOutdated: true
        default: false
        }
    }
}

// MARK: - 표시

struct DisplaySettings: View {
    let model: AppModel
    @AppStorage("office.showStaffPanel") private var showStaffPanel = true

    var body: some View {
        Form {
            Section {
                Picker("표시 수준", selection: Binding(get: { model.privacy }, set: { model.setPrivacy($0) })) {
                    ForEach(PrivacyLevel.allCases, id: \.self) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(level))
                            Footnote(Self.detail(level))
                        }
                        .padding(.vertical, 2)
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("표시 수준")
            } footer: {
                Footnote("말풍선, 상태 칩, 현황 줄, 인스펙터, 알림에 같이 적용돼요. 회의에서 화면을 공유할 때는 요약이나 비공개를 권해요. 비밀번호·토큰처럼 보이는 값과 프롬프트 내용은 어느 수준에서도 보여 주지 않아요.")
            }

            Section {
                DetailToggle(
                    "시스템 설정 따르기",
                    detail: "macOS 손쉬운 사용 → 디스플레이 → 동작 줄이기를 따라요. 지금 시스템: \(model.systemReduceMotion ? "켜짐" : "꺼짐")",
                    isOn: motion(\.followSystem))
                DetailToggle(
                    "항상 동작 줄이기",
                    detail: "시스템 설정과 상관없이 이 앱에서만 늘 줄여요.",
                    isOn: motion(\.alwaysReduce))
                LabeledContent("상태") {
                    Text(model.motionSettings.summary(systemReduceMotion: model.systemReduceMotion))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("동작 줄이기")
            } footer: {
                Footnote("줄이면 직원이 걸어 다니지 않고 갈 자리로 바로 옮겨요(순간이동). 손 흔들기·하이파이브 같은 제스처도 생략해요. 사무실 창과 미니 사무실에 모두 적용돼요.")
            }

            Section("사무실 창") {
                DetailToggle(
                    "오른쪽 패널 보이기",
                    detail: "디렉토리 드롭다운과 세션 목록이에요. 사무실 창 도구 막대의 패널 버튼으로도 바꿀 수 있어요.",
                    isOn: $showStaffPanel)
            }
        }
        .formStyle(.grouped)
    }

    private func motion(_ keyPath: WritableKeyPath<MotionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.motionSettings[keyPath: keyPath] }, set: { value in
            var settings = model.motionSettings
            settings[keyPath: keyPath] = value
            model.setMotionSettings(settings)
        })
    }

    static func title(_ level: PrivacyLevel) -> String {
        switch level {
        case .detailed: "상세"
        case .summary: "요약"
        case .hidden: "비공개"
        }
    }

    static func detail(_ level: PrivacyLevel) -> String {
        switch level {
        case .detailed: "파일명, 명령어, 세션 제목까지 보여 줘요. 예: \"Edit auth.ts\", \"Bash npm test\""
        case .summary: "도구 종류만 보여 줘요. 예: \"파일 편집 중\", \"Bash\""
        case .hidden: "말풍선 글 없이 아이콘과 표정만 보여 줘요."
        }
    }
}

// MARK: - 미니 사무실

/// 미니 사무실 (설계서 §10.1). 표시 탭에 넣으면 길어져 스크롤이 생기고, 따로 떠 있는 창의 설정이라 탭을 나눴습니다.
struct MiniOfficeSettingsView: View {
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
            Section {
                DetailToggle(
                    "미니 사무실 보기",
                    detail: "사무실 창이 닫혀 있을 때 화면 구석에 메인 한 명과 일하는 서브 2명을 사무실 그대로 보여 줘요. 메뉴바와 사무실 창 도구 막대(⇧⌘M)에서도 켤 수 있어요.",
                    isOn: mini(\.enabled))
                DetailToggle(
                    "내 답변이 필요하면 그 메인으로 바꾸기",
                    detail: "승인·질문·계획 승인을 기다리는 메인 → 응답을 끝낸 메인(10분) → 가장 마지막에 요청한 메인 순으로 보여 줘요. 끄면 답변 대기로는 바꾸지 않아요.",
                    isOn: mini(\.autoSwitch))
            } header: {
                Text("보기")
            } footer: {
                Footnote("미니를 누르면 미니는 숨고 사무실 창이 열려요(사무실 창을 닫으면 다시 나타나요). 캐릭터를 더블클릭하면 그 세션의 앱이나 터미널로 가요.")
            }

            Section {
                LabeledContent("투명도") {
                    HStack {
                        Slider(value: mini(\.opacity), in: 0.5...1)
                        Text("\(Int((model.miniSettings.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("위치") {
                    Button("기본 위치로 (화면 오른쪽 아래)") { model.resetMiniPosition() }
                        .disabled(!model.miniSettings.enabled)
                }
            } header: {
                Text("모양과 위치")
            } footer: {
                Footnote("미니는 끌어서 옮길 수 있고, 디스플레이마다 위치를 기억해요.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 알림

/// 알림 설정 (설계서 §10 알림, M5(3)): 승인 대기·답변 필요(M6(4c))·응답 완료 켜기·끄기, 권한 상태, 집중 모드
struct NotificationSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                DetailToggle(
                    "승인 대기 알림",
                    detail: "누군가 권한 승인을 기다리기 시작하면 바로 알려요. 대기가 풀리면 알림 센터에서 지워요.",
                    isOn: binding(\.permission))
                DetailToggle(
                    "답변 필요 알림",
                    detail: "세션이 질문이나 결정 요청으로 응답을 마치면 한 번 알려요. 데스크톱 앱에서 그 세션을 보고 있으면 띄우지 않고, 답하면 지워요.",
                    isOn: binding(\.reply))
                DetailToggle(
                    "응답 완료 알림",
                    detail: "세션이 응답을 마치면(Stop) 알려요. 세션마다 마지막 하나만 남아요.",
                    isOn: binding(\.completion))
            } header: {
                Text("알림 종류")
            } footer: {
                Footnote("알림을 누르면 그 세션으로 가요: Claude 데스크톱 앱 세션은 앱에서 그 세션 화면을, 터미널 세션은 그 터미널을 앞으로 가져와요. 사무실 창이 열려 있으면 그 캐릭터도 골라요. 표시 수준이 요약·비공개면 알림에도 파일명·명령을 쓰지 않아요.")
            }

            Section {
                LabeledContent("상태") { Text(authorizationText).foregroundStyle(.secondary) }
                HStack {
                    if model.notificationAuthorization == .notDetermined {
                        Button("알림 허용 요청") { model.requestNotificationAuthorization() }
                    }
                    Button("시스템 설정 열기") { Notifier.openSystemSettings() }
                }
            } header: {
                Text("알림 권한")
            } footer: {
                Footnote("처음 알림이 필요할 때 macOS가 허용할지 물어요. 거부해도 메뉴바와 사무실 연출은 그대로예요.")
            }

            Section {
                DetailToggle(
                    "집중 모드 중에는 알림 효과음 끄기",
                    detail: "노크·완료 같은 알림 효과음만 줄여요. 알림이 화면에 뜰지는 macOS 집중 모드 규칙을 따라요.",
                    isOn: Binding(
                        get: { model.soundSettings.respectFocusMode },
                        set: { value in
                            var settings = model.soundSettings
                            settings.respectFocusMode = value
                            model.setSoundSettings(settings)
                        }))
                LabeledContent("집중 모드") { Text(focusText).foregroundStyle(.secondary) }
                if model.focusAccess == .notDetermined {
                    Button("집중 모드 상태 읽기 허용 요청") { model.requestFocusAccess() }
                }
            } header: {
                Text("집중 모드")
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
        case .notDetermined: "아직 묻지 않음"
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

// MARK: - 효과음

/// 효과음 설정 (설계서 §11.2·§11.3): 전체 소리, 전체 음량, 항목별 켜기·끄기와 미리 듣기
struct SoundSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("효과음 켜기", isOn: binding(\.masterEnabled))
                LabeledContent("음량") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: binding(\.volume), in: 0...1).accessibilityLabel("음량")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("\(Int((model.soundSettings.volume * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.soundSettings.masterEnabled)
            } header: {
                Text("전체")
            } footer: {
                Footnote("알림 소리는 사무실 창이 안 보여도 울리고, 장식 소리는 사무실 창이나 미니 사무실이 화면에 보일 때만 울려요.")
            }

            Section("알림 소리") {
                ForEach(SoundGroup.allCases.filter(\.isAlert), id: \.self, content: row)
            }
            Section("장식 소리") {
                ForEach(SoundGroup.allCases.filter { !$0.isAlert }, id: \.self, content: row)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ group: SoundGroup) -> some View {
        HStack {
            DetailToggle(
                group.displayName, detail: group.detail,
                isOn: Binding(
                    get: { model.soundSettings.enabledGroups.contains(group) },
                    set: { enabled in
                        var settings = model.soundSettings
                        settings.set(group, enabled: enabled)
                        model.setSoundSettings(settings)
                    }))
            Button {
                model.previewSound(group)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("미리 듣기")
            .accessibilityLabel("\(group.displayName) 미리 듣기")
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
