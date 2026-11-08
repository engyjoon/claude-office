import AppKit
import OfficeCore
import OfficeServer
import SwiftUI

/// 사무실 창 오른쪽 패널 (2026-11-08): 위는 Claude 데스크톱 앱에 열려 있는 디렉토리 드롭다운(하나만 고르기),
/// 아래 "세션"은 고른 디렉토리의 메인과 그 서브들이 무엇을 하는지 보여 줍니다.
/// 줄을 누르면 사무실에서 그 캐릭터를 고른 것과 같습니다 (발밑 고리 + 신원 카드).
struct StaffPanel: View {
    let model: AppModel

    var body: some View {
        let roster = model.visibleRoster
        VStack(alignment: .leading, spacing: 0) {
            DirectoryList(model: model)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("세션").font(.system(size: 13, weight: .bold))
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
                    .help("사무실은 줄이지 않고 들어가는 만큼만 그려요 (최대 3행). 창을 넓히면 더 보여요.")
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

/// Claude 데스크톱 앱에 열려 있는 디렉토리 드롭다운 ("모두" 또는 디렉토리 하나). 고른 디렉토리에서 연 메인마다 사무실에 한 행이 놓입니다.
private struct DirectoryList: View {
    let model: AppModel

    var body: some View {
        let options = model.directoryOptions
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("디렉토리").font(.system(size: 13, weight: .bold))
                Spacer()
                if !model.directories.isEmpty {
                    Text("열린 \(model.directories.count)개").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            // SwiftUI .menu Picker는 내용 폭만큼만 그려져 가운데에 놓이므로, 행 폭을 그대로 받는 NSPopUpButton을 씁니다.
            DirectoryPopUp(
                items: [DirectoryPopUp.Item(title: label(nil), path: nil)]
                    + options.map { DirectoryPopUp.Item(title: label($0), path: $0.path) },
                selection: model.selectedFolder,
                tooltip: model.selectedFolder ?? "Claude 데스크톱 앱에 열린 모든 디렉토리 (새로 연 디렉토리도 자동으로 보여요)",
                onSelect: { model.selectFolder($0) })
                .frame(maxWidth: .infinity)
            if model.directories.isEmpty {
                Text("Claude 데스크톱 앱에 열려 있는 디렉토리가 없어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// "claude-office · 메인 2 · 7명"
    private func label(_ folder: DesktopFolder?) -> String {
        guard let folder else {
            let people = model.roster.agentCount
            return people > 0 ? "모두 · \(people)명" : "모두"
        }
        let count = model.headcount(folder: folder.path)
        var text = folder.name
        if !model.directories.contains(where: { $0.path == folder.path }) { text += " (닫힘)" }
        if count.people > 0 { text += count.mains > 1 ? " · 메인 \(count.mains) · \(count.people)명" : " · \(count.people)명" }
        return text
    }
}

/// 디렉토리 드롭다운 (2026-11-08): 받은 폭을 가득 채우는 팝업 버튼.
/// 글자는 왼쪽 정렬, 위아래 화살표는 오른쪽 끝, 긴 이름은 가운데를 줄여(…) 보여 줍니다.
/// 첫 항목("모두")과 디렉토리 항목 사이에는 구분선을 넣습니다.
private struct DirectoryPopUp: NSViewRepresentable {
    struct Item: Equatable {
        let title: String
        /// nil이면 "모두"
        let path: String?
    }

    let items: [Item]
    let selection: String?
    let tooltip: String
    let onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.alignment = .left
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.items != items {
            context.coordinator.items = items
            // addItem(withTitle:)은 같은 제목을 지우므로 메뉴 항목을 직접 넣습니다.
            let menu = NSMenu()
            for (index, item) in items.enumerated() {
                if index == 1 { menu.addItem(.separator()) }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.representedObject = item.path
                menu.addItem(menuItem)
            }
            button.menu = menu
        }
        let selected = button.menu?.items.first { !$0.isSeparatorItem && ($0.representedObject as? String) == selection }
        if let selected, button.selectedItem !== selected { button.select(selected) }
        button.toolTip = tooltip
    }

    /// 높이는 버튼 고유 높이, 폭은 받은 폭 그대로 (내용 폭으로 줄지 않게)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = button.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsic.width
        return CGSize(width: width, height: intrinsic.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: [Item] = []
        var onSelect: (String?) -> Void = { _ in }

        @objc func changed(_ sender: NSPopUpButton) {
            onSelect(sender.selectedItem?.representedObject as? String)
        }
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
