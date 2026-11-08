import OfficeCore
import SwiftUI

/// 사무실 창 오른쪽의 직원 현황 패널: 팀별로 누가 무엇을 하는지 보여줍니다.
/// 줄을 누르면 사무실에서 그 캐릭터를 고른 것과 같습니다 (발밑 고리 + 신원 카드).
struct StaffPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("직원 현황").font(.system(size: 13, weight: .bold))
                Spacer()
                if model.roster.agentCount > 0 {
                    Text("\(model.roster.agentCount)명").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if model.roster.teams.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "building.2").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("아직 출근한 직원이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Claude Code 세션을 시작하면 팀장이 출근해요")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.roster.teams) { team in
                            teamSection(team)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    private func teamSection(_ team: RosterTeam) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Palette.team(team.colorIndex))
                    .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.8))
                    .frame(width: 8, height: 8)
                Text(team.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(team.rows.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ForEach(team.rows) { row in
                StaffRow(row: row, colorIndex: team.colorIndex, selected: model.selectedAgent == row.id)
                    .onTapGesture { model.select(model.selectedAgent == row.id ? nil : row.id) }
            }
        }
    }
}

private struct StaffRow: View {
    let row: RosterRow
    let colorIndex: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(appearance: row.appearance, isLead: row.isTeamLead, size: 32, tint: Palette.team(colorIndex).opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    StatusChip(status: row.status)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Palette.team(colorIndex).opacity(0.35) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Palette.team(colorIndex) : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .help("누르면 사무실에서 이 직원을 보여줘요")
    }

    private func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let title = row.sessionTitle { parts.append(title) }
        if let lead = row.calledBy, row.part > 0 { parts.append("\(lead) 칸") }
        if let detail = row.detail { parts.append(detail) }
        if let elapsed = AgentCard.elapsed(since: row.since, now: now) { parts.append(elapsed) }
        if parts.isEmpty {
            switch row.kind {
            case .lead: parts.append(TerminalFocuser.displayName(for: row.term) ?? "Claude Code 세션")
            case .fixed, .temporary: parts.append("서브에이전트")
            }
        }
        return parts.joined(separator: " · ")
    }
}
