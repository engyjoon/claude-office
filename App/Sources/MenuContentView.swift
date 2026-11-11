import AppKit
import OfficeCore
import OfficeServer
import SwiftUI

/// 메뉴바 드롭다운 (설계서 §10, 미리보기의 "사무실 현황")
struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// 메뉴바 창 안의 ScrollView는 내용 높이를 스스로 정하지 않아 0으로 접힐 수 있습니다 (M2 첫 실행에서 발견).
    /// 내용 높이를 재서 직접 맞춥니다.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    banners
                    if !model.roster.waiting.isEmpty {
                        section(title: "승인 대기 \(model.roster.waiting.count)", rows: model.roster.waiting, highlight: true)
                    }
                    ForEach(model.roster.teams) { team in
                        section(title: team.label, rows: team.rows, highlight: false, colorIndex: team.colorIndex)
                    }
                    if model.roster.teams.isEmpty {
                        emptyState
                    }
                }
                .padding(12)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            .frame(height: min(max(contentHeight, 60), 420))
            .onPreferenceChange(ContentHeightKey.self) { height in
                contentHeight = height
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear {
            model.registerOpenWindow(openWindow)
            model.refreshHookStatus()  // 배너: Claude Code를 올렸거나 settings.json을 고쳤을 때
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("사무실 현황").font(.headline)
            Spacer()
            Text("메인 \(model.roster.teams.count) · 직원 \(model.roster.agentCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 연동 경고 (`HookAlert`, 사무실 창 띠·메뉴바 아이콘과 같은 판정)와 마지막 설치 결과 (개선 6)
    @ViewBuilder
    private var banners: some View {
        if let outcome = model.installOutcome {
            Banner(systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
                   tint: outcome.succeeded ? .green : .red, text: outcome.text) {
                Button {
                    model.dismissInstallOutcome()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("설치 결과 닫기")
            }
        }
        if let alert = model.hookAlert {
            Banner(systemImage: HookAlertStyle.symbol(alert), tint: HookAlertStyle.tint(alert), text: alert.detail) {
                HookAlertButton(model: model, alert: alert)
            }
        }
    }

    private func section(title: String, rows: [RosterRow], highlight: Bool, colorIndex: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let colorIndex {
                    Circle().fill(Palette.team(colorIndex)).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                RosterRowView(row: row, highlight: highlight, destination: model.destination(for: row)) { model.focusAgent(row.id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("아직 출근한 직원이 없어요").font(.subheadline.weight(.semibold))
            Text("Claude 데스크톱 앱이나 터미널에서 세션을 시작하면 메인이 출근해요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            // 키보드 (M6(7)): 드롭다운이 열려 있으면 ⌘O·⌘L·⌘,·⌘Q로 바로 (버튼 Tab 이동은 시스템 "키보드 탐색"을 켰을 때만)
            // 메뉴바 앱은 창이 다른 앱 뒤에 열리기 쉬워 활성화한 뒤 앞으로 올립니다 (M6(17), `WindowFront`)
            Button("사무실 창 열기") {
                model.openOfficeWindow()
            }
            .keyboardShortcut("o")
            Button("이벤트 로그") {
                WindowFront.bring(open: { openWindow(id: WindowID.eventLog) }) {
                    NSApp.windows.first { $0.title == EventLogView.title && ($0.isVisible || $0.isMiniaturized) }
                }
            }
            .keyboardShortcut("l")
            Button("설정…") {
                openSettings()
                // 메뉴바 앱은 설정 창이 다른 앱 뒤에 열리기 쉬워 활성화한 뒤 앞으로 올립니다 (M5(8))
                SettingsWindow.bringToFront()
            }
            .keyboardShortcut(",")
            Spacer()
            Button {
                model.setMiniEnabled(!model.miniSettings.enabled)
            } label: {
                Image(systemName: model.miniSettings.enabled ? "pip.fill" : "pip")
            }
            .accessibilityLabel(model.miniSettings.enabled ? "미니 사무실 끄기" : "미니 사무실 켜기")
            .help(model.miniSettings.enabled ? "미니 사무실 끄기 (켜 두면 사무실 창이 닫혀 있을 때 화면 구석에 보여요)" : "미니 사무실 켜기")
            Button {
                var settings = model.soundSettings
                settings.masterEnabled.toggle()
                model.setSoundSettings(settings)
            } label: {
                Image(systemName: model.soundSettings.masterEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .accessibilityLabel(model.soundSettings.masterEnabled ? "효과음 끄기" : "효과음 켜기")
            .help(model.soundSettings.masterEnabled ? "효과음 끄기" : "효과음 켜기")
            Button("종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RosterRowView: View {
    let row: RosterRow
    let highlight: Bool
    /// 이 세션으로 갈 곳 (띄운 앱까지 반영, `AppModel.destination(for:)`)
    let destination: SessionDestination?
    /// 그 세션으로 이동 (데스크톱 앱 세션이면 Claude 앱, CLI면 터미널). 모델의 `focusAgent`를 거칩니다 (응답 확인·로그).
    let focus: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Avatar(appearance: row.appearance, isLead: row.isMain)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if highlight, let destination {
                // 승인 대기 줄: 알림을 누른 것과 같은 곳으로
                Button(destination.label, action: focus)
                    .controlSize(.small)
                    .help(destination.buttonHelp)
            } else {
                StatusChip(status: row.status)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(highlight ? Palette.attention.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if row.canFocus { focus() } }
        .help(destination?.doubleClickHelp ?? "")
        // VoiceOver (M6(7)): 한 문장으로 읽고, 누르기 = 그 세션으로 이동 (승인 대기 줄의 [앱으로] 버튼과 같음)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((highlight ? "승인 대기, " : "") + AccessibilityText.row(row))
        .accessibilityHint(row.focusLabel.map { "누르면 \($0) 이동해요." } ?? "")
        .accessibilityAddTraits(row.canFocus ? .isButton : [])
        .accessibilityAction { if row.canFocus { focus() } }
    }

    private func subtitle(now: Date) -> String {
        var parts: [String] = []
        if highlight { parts.append("\(row.mainName) · \(row.teamName)") }
        if let caller = row.calledBy { parts.append("\(caller) 호출") }
        if let detail = row.detail { parts.append(detail) }
        if parts.isEmpty, let title = row.sessionTitle { parts.append(title) }
        let quiet: Set<RosterStatus> = [.waitingForInput, .idle, .waitingForPermission, .awaitingReply, .unread]
        if quiet.contains(row.status), let elapsed = ElapsedText.duration(now.timeIntervalSince(row.since), showSeconds: false) {
            parts.append("\(row.status.label) \(elapsed)")
        }
        if parts.isEmpty, let term = SessionDestination.displayName(term: row.term) {
            // 상태는 오른쪽 칩에 있으므로, 세부 정보가 없으면 어느 터미널의 세션인지 보여줍니다
            parts.append(term)
        }
        return parts.isEmpty ? (row.role == .lead ? "Claude Code 세션" : "서브에이전트") : parts.joined(separator: " · ")
    }
}

struct StatusChip: View {
    let status: RosterStatus
    @Environment(\.colorScheme) private var colorScheme
    /// 시스템 "대비 증가" (M6(7)): 모든 칩에 진한 테두리
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tone = status.tone
        let increased = contrast == .increased
        Text(status.label)
            .font(.system(size: 11, weight: tone == .attention || increased ? .semibold : .regular))
            .foregroundStyle(Palette.chipText(tone))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Palette.chip(tone, dark: colorScheme == .dark, increased: increased), in: Capsule())
            // 승인 대기는 테두리로 한 번 더 눈에 띄게 (어두운 바탕에서도 칩 경계가 보이게)
            .overlay {
                if increased {
                    Capsule().strokeBorder(Palette.chipEdge(tone), lineWidth: 1.2)
                } else if tone == .attention {
                    Capsule().strokeBorder(Color(hex: 0xC99A1E), lineWidth: 1)
                }
            }
            .accessibilityLabel(AccessibilityText.status(status))
    }
}

/// 사무실 캐릭터의 얼굴 초상 (메인은 가슴에 별, 기본 에이전트는 머리에 새싹)
struct Avatar: View {
    let appearance: Appearance
    let isLead: Bool
    var size: CGFloat = 26
    var tint: Color = Color(hex: 0xFFF8EC)

    var body: some View {
        CharacterPortrait(appearance: appearance, isLead: isLead, tint: tint)
            .frame(width: size, height: size)
    }
}

extension Banner where Accessory == EmptyView {
    init(systemImage: String, tint: Color, text: String) {
        self.init(systemImage: systemImage, tint: tint, text: text) { EmptyView() }
    }
}

struct Banner<Accessory: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    let accessory: Accessory

    init(systemImage: String, tint: Color, text: String, @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.tint = tint
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory.controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
