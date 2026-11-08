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
        .onAppear { model.registerOpenWindow(openWindow) }
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

    @ViewBuilder
    private var banners: some View {
        if case .failed(let message) = model.serverState {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .red, text: "훅 서버를 시작하지 못했어요. \(message)")
        }
        switch model.hookStatus {
        case .notInstalled:
            Banner(systemImage: "link.badge.plus", tint: .orange, text: "Claude Code 훅이 설치되어 있지 않아요.") {
                Button("설치") { model.installHooks() }.disabled(model.isInstalling)
            }
        case .scriptMissingOrOutdated:
            Banner(systemImage: "arrow.triangle.2.circlepath", tint: .orange, text: "훅 스크립트를 업데이트해야 해요.") {
                Button("다시 설치") { model.installHooks() }.disabled(model.isInstalling)
            }
        case .settingsUnreadable(let reason):
            Banner(systemImage: "doc.badge.ellipsis", tint: .red, text: "~/.claude/settings.json을 읽을 수 없어요. \(reason)")
        case .installed:
            EmptyView()
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
            ForEach(rows) { row in
                RosterRowView(row: row, highlight: highlight) { model.focusSession(of: row) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("아직 출근한 직원이 없어요").font(.subheadline.weight(.semibold))
            Text("터미널에서 claude를 실행하면 메인이 출근해요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("사무실 보기") {
                NSApp.activate()
                openWindow(id: WindowID.office)
            }
            Button("이벤트 로그") {
                NSApp.activate()
                openWindow(id: WindowID.eventLog)
            }
            Button("설정…") {
                NSApp.activate()
                openSettings()
            }
            Spacer()
            Button {
                model.setMiniEnabled(!model.miniSettings.enabled)
            } label: {
                Image(systemName: model.miniSettings.enabled ? "pip.fill" : "pip")
            }
            .help(model.miniSettings.enabled ? "미니 사무실 끄기 (켜 두면 사무실 창이 닫혀 있거나 최소화돼 있을 때 화면 구석에 보여요)" : "미니 사무실 켜기")
            Button {
                var settings = model.soundSettings
                settings.masterEnabled.toggle()
                model.setSoundSettings(settings)
            } label: {
                Image(systemName: model.soundSettings.masterEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .help(model.soundSettings.masterEnabled ? "효과음 끄기" : "효과음 켜기")
            Button("종료") { NSApp.terminate(nil) }
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
    /// 그 세션으로 이동 (데스크톱 앱 세션이면 Claude 앱, CLI면 터미널)
    var focus: (() -> Void)?

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
            if highlight, row.canFocus {
                // 승인 대기 줄: 알림을 누른 것과 같은 곳으로
                Button(row.hostSession != nil ? "앱으로" : "터미널로") { focusSession() }
                    .controlSize(.small)
                    .help(row.hostSession != nil ? "Claude 데스크톱 앱을 앞으로 가져와요 (세션은 사이드바에서 골라 주세요)" : "")
            } else {
                StatusChip(status: row.status)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(highlight ? Palette.attention.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { focusSession() }
        .help(row.hostSession != nil ? "더블클릭하면 Claude 데스크톱 앱을 앞으로 가져와요"
            : row.term.map { "더블클릭하면 \($0)을(를) 앞으로 가져와요" } ?? "")
    }

    private func focusSession() {
        if let focus { focus() } else { TerminalFocuser.focus(term: row.term) }
    }

    private func subtitle(now: Date) -> String {
        var parts: [String] = []
        if highlight { parts.append("\(row.mainName) · \(row.teamName)") }
        if let caller = row.calledBy { parts.append("\(caller) 호출") }
        if let detail = row.detail { parts.append(detail) }
        if parts.isEmpty, let title = row.sessionTitle { parts.append(title) }
        let minutes = Int(now.timeIntervalSince(row.since) / 60)
        if minutes >= 1, row.status == .waitingForInput || row.status == .idle || row.status == .waitingForPermission {
            parts.append("\(row.status.label) \(minutes)분")
        }
        if parts.isEmpty, let term = TerminalFocuser.displayName(for: row.term) {
            // 상태는 오른쪽 칩에 있으므로, 세부 정보가 없으면 어느 터미널의 세션인지 보여줍니다
            parts.append(term)
        }
        return parts.isEmpty ? (row.role == .lead ? "Claude Code 세션" : "서브에이전트") : parts.joined(separator: " · ")
    }
}

struct StatusChip: View {
    let status: RosterStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Palette.chip(status.tone), in: Capsule())
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
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory.controlSize(.small)
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
