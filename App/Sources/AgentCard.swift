import OfficeCore
import SwiftUI

/// 사무실 창에서 캐릭터를 클릭하면 뜨는 신원 카드 (설계서 §10 "클릭: 인스펙터에서 상세 보기"의 간단한 형태)
///
/// 누구인지(메인/서브, 어느 행, 어느 세션)를 먼저 보여주고, 지금 하는 일은 메뉴 목록과 같은 표현을 씁니다.
/// 폴더 경로와 세부 내용은 표시 수준이 "상세"일 때만 보입니다.
struct AgentCard: View {
    let row: RosterRow
    let team: RosterTeam
    let privacy: PrivacyLevel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(appearance: row.appearance, isLead: row.isMain, size: 48, tint: Palette.team(team.colorIndex).opacity(0.45))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 15, weight: .bold))
                    Text(kindLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("닫기")
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if let agentType = row.agentType {
                    // 서브에이전트면 어떤 에이전트인지 (화면의 이름에는 쓰지 않고 여기에만 보여 줍니다)
                    GridRow {
                        label("에이전트")
                        Text("\(agentType) · \(row.kind == .fixed ? "직접 만든 에이전트" : "기본 에이전트")")
                            .font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                    }
                } else if let title = row.sessionTitle {
                    GridRow {
                        label("세션")
                        Text(title).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                    }
                }
                GridRow {
                    label("행")
                    HStack(spacing: 5) {
                        Circle().fill(Palette.team(team.colorIndex))
                            .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 0.8))
                            .frame(width: 9, height: 9)
                        Text(team.label).font(.system(size: 12, weight: .semibold))
                    }
                }
                if privacy == .detailed {
                    GridRow {
                        label("폴더")
                        Text(Self.abbreviated(team.folder))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                GridRow {
                    label("지금")
                    VStack(alignment: .leading, spacing: 3) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            HStack(spacing: 6) {
                                StatusChip(status: row.status)
                                if let elapsed = Self.elapsed(since: row.since, now: context.date) {
                                    Text(elapsed).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: 12))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    label("세션")
                    Text(String(row.session.raw.prefix(8)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(row.session.raw)
                }
                if let term = TerminalFocuser.displayName(for: row.term) {
                    GridRow {
                        label("어디서")
                        HStack(spacing: 6) {
                            Text(term).font(.system(size: 12))
                            if TerminalFocuser.bundleIDs[row.term ?? ""] != nil {
                                Button("앞으로") { TerminalFocuser.focus(term: row.term) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.team(team.colorIndex), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var kindLabel: String {
        switch row.kind {
        case .lead: row.isMain ? "직접 연 세션 · 메인" : "\(row.mainName)에서 띄운 세션 · 서브"
        case .fixed, .temporary: "서브에이전트 · 서브\(row.calledBy.map { " (\($0) 호출)" } ?? "")"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func elapsed(since: Date, now: Date) -> String? {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "\(minutes)분째" }
        return "\(minutes / 60)시간 \(minutes % 60)분째"
    }
}
