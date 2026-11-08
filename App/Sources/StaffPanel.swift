import OfficeCore
import SwiftUI

/// 사무실 창 오른쪽의 직원 현황 패널: 맨 위에서 볼 메인을 고르고(여럿 가능), 고른 메인과 그 서브들이 무엇을 하는지 보여줍니다.
/// 줄을 누르면 사무실에서 그 캐릭터를 고른 것과 같습니다 (발밑 고리 + 신원 카드).
struct StaffPanel: View {
    let model: AppModel

    var body: some View {
        let roster = model.visibleRoster
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("직원 현황").font(.system(size: 13, weight: .bold))
                Spacer()
                if roster.agentCount > 0 {
                    Text("\(roster.agentCount)명").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            MainPicker(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if model.hiddenOnScreen > 0 {
                Label("화면에 다 못 보여 준 \(model.hiddenOnScreen)명", systemImage: "rectangle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .help("사무실은 줄이지 않고 들어가는 만큼만 그려요 (최대 3행). 창을 넓히거나 볼 메인을 줄이면 더 보여요.")
            }

            Divider()

            if model.roster.teams.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "building.2").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("아직 출근한 직원이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Claude Code 세션을 시작하면 메인이 출근해요")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if roster.teams.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("고른 메인이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("모두 보기") { model.selectAllMains() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(roster.teams) { team in
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
                Text(team.label).font(.system(size: 12, weight: .semibold))
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

/// 볼 메인 고르기 (체크 목록 + "모두"). 고른 메인마다 사무실에 한 행이 놓입니다.
private struct MainPicker: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button {
                model.selectAllMains()
            } label: {
                if model.selection.all { Label("모두", systemImage: "checkmark") } else { Text("모두") }
            }
            if !model.roster.teams.isEmpty { Divider() }
            ForEach(model.roster.teams) { team in
                Toggle(isOn: Binding(get: { model.isSelected(team.id) }, set: { model.setMain(team.id, selected: $0) })) {
                    Text(team.mainTitle.map { "\(team.label) — \($0)" } ?? team.label)
                }
            }
        } label: {
            Label(summary, systemImage: "person.2.crop.square.stack")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help("사무실과 직원 현황에 보여 줄 메인을 골라요 (여럿 가능)")
    }

    private var summary: String {
        let teams = model.roster.teams
        if model.selection.all { return teams.isEmpty ? "모든 메인" : "모든 메인 (\(teams.count))" }
        let picked = teams.filter { model.isSelected($0.id) }
        if picked.isEmpty { return "고른 메인 없음" }
        if picked.count <= 2 { return picked.map(\.mainName).joined(separator: ", ") }
        return "메인 \(picked.count)개"
    }
}

private struct StaffRow: View {
    let row: RosterRow
    let colorIndex: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(appearance: row.appearance, isLead: row.isMain, size: 32, tint: Palette.team(colorIndex).opacity(0.4))
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
        if let caller = row.calledBy { parts.append("\(caller) 호출") }
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
