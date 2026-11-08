import OfficeCore
import SwiftUI

/// 사무실 바로 아래 세 줄짜리 실시간 현황 (설계서 §10.2, M5(9)). 신원 카드가 "누구"라면 이 줄은 "무엇을 하고 있는지"입니다.
///
/// 내용은 OfficeCore의 `StatusLine`이 정하고(행 순서·표시 수준·묶기), 여기서는 색과 시간만 붙입니다.
/// - 아무도 안 골랐으면 사무실의 행과 같은 순서로 행마다 한 줄: "● 디렉토리 · 메인1 · 그 행의 가장 최근 일 (3초 전)".
/// - 캐릭터를 골랐으면 그 사람의 최근 일 세 개 (최신이 아래), 첫 줄 맨 앞에 "● 디렉토리 · 직함".
/// 점·디렉토리·직함·본문을 칸으로 나눠 세 줄의 왼쪽을 칸마다 맞춥니다. 줄 위치는 고정이고, 바뀔 때 움직임 없이 바로 바꿉니다.
struct StatusLineView: View {
    let line: StatusLine
    @Environment(\.liveClock) private var live

    /// 한 줄 높이
    static let lineHeight: CGFloat = 18
    /// 위아래 여백
    static let verticalPadding: CGFloat = 6
    /// 전체 높이 (사무실 영역은 줄어들지 않고 창 높이에 이만큼 더합니다)
    static let height: CGFloat = lineHeight * CGFloat(StatusLine.lineCount) + verticalPadding * 2

    var body: some View {
        // 시간 글자가 바뀌는 순간에만 다시 그립니다 (M6(1)): 1분 안쪽 "12초째"·"3초 전"은 1초마다, "3분째"는 1분마다, 쉬는 중 → 잠든 중
        // 창이 안 보이면 멈춥니다 (`liveClock`)
        TimelineView(NextChangeSchedule { [line, live] in live ? line.nextChange(after: $0) : nil }) { context in
            // 칸: 점 | 디렉토리 | 직함 | 본문. 칸마다 왼쪽을 맞춰 세 줄의 디렉토리·직함·본문 시작이 같습니다 (M5(9) 화면 확인).
            // 디렉토리를 하나 골라 폴더 이름이 없으면 그 칸을 뺍니다.
            let showsFolder = line.lines.contains { $0.folder != nil }
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 0) {
                ForEach(0..<StatusLine.lineCount, id: \.self) { index in
                    GridRow {
                        if index < line.lines.count {
                            let item = line.lines[index]
                            dot(item)
                            if showsFolder { folder(item) }
                            title(item)
                            body(item, now: context.date)
                                .help(item.text(now: context.date))
                        } else {
                            Color.clear.gridCellColumns(showsFolder ? 4 : 3)
                        }
                    }
                    .frame(height: Self.lineHeight)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // 줄 내용이 바뀔 때 흐려지거나 미끄러지지 않게 합니다
        .transaction { $0.animation = nil }
    }

    /// 첫 칸: 행 색 점 (안내 줄은 말풍선 아이콘, 고른 사람의 둘째·셋째 줄은 빈 칸)
    @ViewBuilder
    private func dot(_ item: StatusLine.Line) -> some View {
        if let colorIndex = item.colorIndex {
            Circle().fill(Palette.team(colorIndex))
                .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.8))
                .frame(width: 8, height: 8)
        } else if line.mode == .office, item.head == nil {
            Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            Color.clear.frame(width: 8, height: 8)
        }
    }

    /// 둘째 칸: 흐린 디렉토리 이름 ("모두"일 때)
    @ViewBuilder
    private func folder(_ item: StatusLine.Line) -> some View {
        if let folder = item.folder {
            Text("\(folder) ·").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// 셋째 칸: 직함
    @ViewBuilder
    private func title(_ item: StatusLine.Line) -> some View {
        if let head = item.head {
            Text("\(head) ·")
                .font(.system(size: 12, weight: line.mode == .agent ? .bold : .semibold))
                .lineLimit(1)
                .fixedSize()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// 오른쪽 칸: 화면 밖 표시, 일, 시간
    private func body(_ item: StatusLine.Line, now: Date) -> some View {
        HStack(spacing: 6) {
            if let note = item.note {
                Label(note, systemImage: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .fixedSize()
            }
            Text(attributed(item.segment, now: now))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(_ segment: StatusLine.Segment, now: Date) -> AttributedString {
        var text = AttributedString(segment.body(now: now))
        switch segment.tone {
        case .normal:
            text.foregroundColor = .primary
        case .muted:
            text.foregroundColor = .secondary
        case .attention:
            // 승인 대기: 노랑 형광펜
            text.foregroundColor = Palette.ink  // 어두운 모드에서도 흰 글자가 되지 않게
            text.backgroundColor = Palette.attention
        case .error:
            text.foregroundColor = .red
        }
        if let time = segment.time(now: now) {
            var suffix = AttributedString(" (\(time))")
            suffix.foregroundColor = .secondary
            text += suffix
        }
        return text
    }
}

/// 글자가 다음에 바뀌는 때에만 다시 그리는 TimelineView 일정 (M6(1), 설계서 §8.3).
/// `.periodic(by: 1)`은 바뀔 글자가 없어도 1초마다 창 전체를 다시 배치합니다.
struct NextChangeSchedule: TimelineSchedule {
    /// 그 시각 다음에 글자가 바뀌는 때 (없으면 nil: 다시 그리지 않음)
    let next: (Date) -> Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var upcoming: Date? = startDate
        return AnyIterator {
            guard let date = upcoming else { return nil }
            // 경계 바로 뒤에 그려야 정수로 내린 초가 새 값이 됩니다
            upcoming = next(date).map { max($0.addingTimeInterval(0.05), date.addingTimeInterval(0.5)) }
            return date
        }
    }
}

extension NextChangeSchedule {
    /// `live`일 때만 `step`초마다 (창이 안 보이면 멈춤)
    static func every(_ step: TimeInterval, live: Bool) -> NextChangeSchedule {
        NextChangeSchedule { live ? $0.addingTimeInterval(step) : nil }
    }
}

/// 시계 글자("12초째", "3분 전")를 다시 그려도 되는지: 창이 화면에 보일 때만 (M6(1)).
/// SwiftUI는 닫히거나 가려진 창의 TimelineView도 계속 돌려 창 전체를 다시 배치합니다.
private struct LiveClockKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var liveClock: Bool {
        get { self[LiveClockKey.self] }
        set { self[LiveClockKey.self] = newValue }
    }
}
