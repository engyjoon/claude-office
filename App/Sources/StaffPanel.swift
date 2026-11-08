import OfficeCore
import OfficeServer
import SwiftUI

/// 사무실 창 오른쪽 패널 (2026-11-08): 위는 Claude 데스크톱 앱에 열려 있는 디렉토리 목록(여럿 고르기),
/// 아래는 고른 디렉토리의 메인과 그 서브들이 무엇을 하는지 보여 주는 직원 현황.
/// 줄을 누르면 사무실에서 그 캐릭터를 고른 것과 같습니다 (발밑 고리 + 신원 카드).
struct StaffPanel: View {
    let model: AppModel

    var body: some View {
        let roster = model.visibleRoster
        VStack(alignment: .leading, spacing: 0) {
            DirectoryList(model: model)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("직원 현황").font(.system(size: 13, weight: .bold))
                Spacer()
                if roster.agentCount > 0 {
                    Text("\(roster.agentCount)명").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if model.hiddenOnScreen > 0 {
                Label("화면에 다 못 보여 준 \(model.hiddenOnScreen)명", systemImage: "rectangle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .help("사무실은 줄이지 않고 들어가는 만큼만 그려요 (최대 3행). 창을 넓히거나 볼 디렉토리를 줄이면 더 보여요.")
            }

            Divider()

            if model.roster.teams.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "building.2").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("아직 출근한 직원이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Claude 데스크톱 앱에서 세션을 시작하면 메인이 출근해요")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if roster.teams.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("고른 디렉토리에 출근한 직원이 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("모두 보기") { model.selectAllFolders() }.controlSize(.small)
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

/// Claude 데스크톱 앱에 열려 있는 디렉토리 목록 (체크 목록 + "모두"). 고른 디렉토리에서 연 메인마다 사무실에 한 행이 놓입니다.
private struct DirectoryList: View {
    let model: AppModel

    /// 목록이 길면 이 높이까지만 늘리고 스크롤합니다
    private static let maxListHeight: CGFloat = 200
    private static let rowHeight: CGFloat = 24

    var body: some View {
        let directories = model.directories
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("디렉토리").font(.system(size: 13, weight: .bold))
                Spacer()
                if !directories.isEmpty {
                    Text("\(directories.count)개").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if directories.isEmpty {
                Text("Claude 데스크톱 앱에 열려 있는 디렉토리가 없어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: Binding(
                            get: { model.selection.all },
                            set: { $0 ? model.selectAllFolders() : model.selectNoFolders() })
                        ) {
                            Text("모두").font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: Self.rowHeight)
                        .help("새로 연 디렉토리도 자동으로 보여요")
                        ForEach(directories) { folder in
                            row(folder)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 14)
                }
                .frame(height: min(CGFloat(directories.count + 1) * Self.rowHeight + 4, Self.maxListHeight))
                .padding(.bottom, 6)
            }
        }
    }

    private func row(_ folder: DesktopFolder) -> some View {
        let count = model.headcount(folder: folder.path)
        return Toggle(isOn: Binding(
            get: { model.isSelected(folder: folder.path) },
            set: { model.setFolder(folder.path, selected: $0) })
        ) {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(folder.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if count.people > 0 {
                    Text(count.mains > 1 ? "메인 \(count.mains) · \(count.people)명" : "\(count.people)명")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
        .help("\(folder.path)\n열린 세션 \(folder.sessions)개")
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
