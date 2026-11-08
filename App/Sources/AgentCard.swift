import OfficeCore
import SwiftUI

/// 사무실 창에서 캐릭터(또는 세션 패널의 줄)를 고르면 오른쪽 위에 뜨는 인스펙터 (설계서 §10, M5(7)).
///
/// 위는 지금까지의 신원 카드 그대로(누구인지, 행, 지금 하는 일, 세션, 어디서 + [앱으로]/[터미널로])이고,
/// 아래에 메인이면 그 행의 서브 목록, 서브면 소속 메인, 그리고 "최근 일" 타임라인이 붙습니다.
/// 타임라인은 기본으로 최근 3줄만 보이고 "모두 보기"로 최근 15줄까지 펼칩니다. 창보다 길어지면 카드 전체를 스크롤합니다.
/// 폴더 경로·세션 제목·세부 내용·타임라인의 파일명·명령은 표시 수준이 "상세"일 때만 보입니다.
struct AgentCard: View {
    let row: RosterRow
    let team: RosterTeam
    let privacy: PrivacyLevel
    let timeline: AgentTimeline
    /// 다른 사람으로 고르기 (서브 목록, 소속 메인)
    let onSelect: (AgentID) -> Void
    /// 그 세션의 Claude 앱이나 터미널을 앞으로
    let onFocus: () -> Void
    let onClose: () -> Void
    /// 창이 보일 때만 시계 글자를 다시 그림 (M6(1))
    @Environment(\.liveClock) private var liveClock

    /// 타임라인을 펼쳤는지 (앱을 다시 켜도 기억)
    @AppStorage("inspector.timelineExpanded") private var expanded = false

    static let width: CGFloat = 288
    /// 접었을 때 보여 주는 타임라인 줄 수
    static let collapsedLines = 3

    var body: some View {
        // 창이 낮아 다 들어가지 않을 때만 스크롤 (평소에는 내용 높이만큼)
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(width: Self.width, alignment: .leading)
        // 반투명 재질은 다크 모드에서 밝은 사무실 위에 탁한 회색이 되어 소제목이 묻혀서(화면 확인), 창 배경색을 꽉 채워 씁니다
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.team(team.colorIndex), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            details
            if row.isMain, !subs.isEmpty {
                Divider()
                subList
            }
            Divider()
            timelineSection
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: - 누구

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(appearance: row.appearance, isLead: row.isMain, size: 48, tint: Palette.team(team.colorIndex).opacity(0.45))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 15, weight: .bold))
                Text(kindLabel).font(.system(size: 11)).foregroundStyle(Self.labelColor)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("닫기 (Esc)")
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            if !row.isMain, let main {
                // 서브면 소속 메인 (누르면 메인으로)
                GridRow {
                    label("소속")
                    Button { onSelect(main.id) } label: {
                        HStack(spacing: 4) {
                            Avatar(appearance: main.appearance, isLead: true, size: 18, tint: Palette.team(team.colorIndex).opacity(0.4))
                            Text("\(main.name)의 서브").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("눌러서 \(main.name) 보기")
                }
            }
            if let agentType = row.agentType {
                // 서브에이전트면 어떤 에이전트인지 (화면의 이름에는 쓰지 않고 여기에만 보여 줍니다)
                GridRow {
                    label("에이전트")
                    Text("\(agentType) · \(row.kind == .fixed ? "직접 만든 에이전트" : "기본 에이전트")")
                        .font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                }
            } else if let title = row.sessionTitle {
                GridRow {
                    label("제목")
                    Text(title).font(.system(size: 12)).lineLimit(2).textSelection(.enabled)
                }
            }
            GridRow {
                label("행")
                HStack(spacing: 5) {
                    Circle().fill(Palette.team(team.colorIndex))
                        .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 0.8))
                        .frame(width: 9, height: 9)
                    Text(team.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
            }
            if privacy == .detailed {
                GridRow {
                    label("폴더")
                    Text(Self.abbreviated(team.folder))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.labelColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            GridRow {
                label("지금")
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(NextChangeSchedule.every(1, live: liveClock)) { context in
                        HStack(spacing: 6) {
                            StatusChip(status: row.status)
                            if let elapsed = StatusLine.elapsed(context.date.timeIntervalSince(row.since)) {
                                Text(elapsed).font(.system(size: 11)).foregroundStyle(Self.labelColor).monospacedDigit()
                            }
                        }
                    }
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            GridRow {
                label("세션")
                Text(String(row.session.raw.prefix(8)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.labelColor)
                    .textSelection(.enabled)
                    .help(row.session.raw)
            }
            if let place {
                GridRow {
                    label("어디서")
                    HStack(spacing: 6) {
                        Text(place).font(.system(size: 12)).lineLimit(1)
                        if let focus = row.focusLabel {
                            Button(focus, action: onFocus)
                                .controlSize(.mini)
                                .help(row.hostSession != nil
                                    ? "Claude 데스크톱 앱에서 이 세션을 열어요. 캐릭터를 더블클릭해도 돼요."
                                    : "이 세션이 열린 \(place) 창을 앞으로 가져와요. 캐릭터를 더블클릭해도 돼요.")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 서브 목록 (메인일 때)

    private var subList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("서브 \(subs.count)명")
            ForEach(subs) { sub in
                Button { onSelect(sub.id) } label: {
                    HStack(spacing: 6) {
                        Avatar(appearance: sub.appearance, isLead: false, size: 22, tint: Palette.team(team.colorIndex).opacity(0.35))
                        Text(sub.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let caller = sub.calledBy, caller != row.name {
                            Text("\(caller) 호출").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        StatusChip(status: sub.status)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("눌러서 \(sub.name) 보기")
            }
        }
    }

    // MARK: - 최근 일

    private var timelineSection: some View {
        let items = expanded ? timeline.items : Array(timeline.items.suffix(Self.collapsedLines))
        let hidden = timeline.items.count - items.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("최근 일")
                Spacer()
                if timeline.items.count > Self.collapsedLines {
                    Button(expanded ? "접기" : "모두 보기 (\(timeline.items.count))") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            if items.isEmpty {
                Text("아직 기록이 없어요").font(.system(size: 11)).foregroundStyle(Self.labelColor)
            } else {
                // 새 일은 아래에 붙습니다 (시간 순서). 접혀 있으면 앞이 더 있다는 표시만.
                TimelineView(NextChangeSchedule.every(1, live: liveClock)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        if hidden > 0 || (expanded && timeline.truncated) {
                            Text("…").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        ForEach(items) { item in
                            TimelineRow(item: item, now: context.date)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 도움

    /// 메인일 때 같은 행의 다른 사람들 (서브 세션과 서브에이전트)
    private var subs: [RosterRow] { team.rows.filter { !$0.isMain && $0.id != row.id } }

    private var main: RosterRow? { team.rows.first { $0.isMain } }

    /// "Claude 데스크톱 앱", "iTerm2", 모르면 nil
    private var place: String? {
        row.hostSession != nil ? "Claude 데스크톱 앱" : TerminalFocuser.displayName(for: row.term)
    }

    private var kindLabel: String {
        switch row.kind {
        case .lead: row.isMain ? "직접 연 세션 · 메인" : "\(row.mainName)에서 띄운 세션 · 서브"
        case .fixed, .temporary: "서브에이전트 · 서브\(row.calledBy.map { " (\($0) 호출)" } ?? "")"
        }
    }

    /// 소제목·시각 글자색: `.secondary`보다 진하게 (화면 확인: 다크 모드에서 잘 안 보임)
    static let labelColor = Color.primary.opacity(0.68)

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Self.labelColor)
            .gridColumnAlignment(.trailing)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(Self.labelColor)
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

/// 타임라인 한 줄: "12초 전 · Edit auth.ts". 승인 대기는 노랑 형광펜, 실패·거부는 빨강 (현황 줄과 같은 색).
private struct TimelineRow: View {
    let item: AgentTimeline.Item
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.when(now: now))
                .font(.system(size: 11))
                .foregroundStyle(AgentCard.labelColor)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Text(styled(now: now))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(item.text(now: now))
    }

    private func styled(now: Date) -> AttributedString {
        var text = AttributedString(item.text)
        switch item.tone {
        case .normal: text.foregroundColor = .primary
        case .muted: text.foregroundColor = .secondary
        case .attention:
            text.foregroundColor = Palette.ink  // 어두운 모드에서도 흰 글자가 되지 않게
            text.backgroundColor = Palette.attention
        case .error: text.foregroundColor = .red
        }
        if let since = item.since, let elapsed = StatusLine.elapsed(now.timeIntervalSince(since)) {
            var suffix = AttributedString(" (\(elapsed))")
            suffix.foregroundColor = .secondary
            text += suffix
        }
        return text
    }
}
