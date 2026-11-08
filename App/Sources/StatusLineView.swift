import OfficeCore
import SwiftUI

/// 사무실 바로 아래 한 줄짜리 실시간 현황 (설계서 §10.2). 신원 카드가 "누구"라면 이 줄은 "무엇을 하고 있는지"의 흐름입니다.
///
/// 내용은 OfficeCore의 `StatusLine`이 정하고(표시 수준·묶기·자르기), 여기서는 색과 경과 시간만 붙입니다.
/// 고른 사람의 흐름은 새 동작이 오른쪽이라 넘치면 앞(왼쪽)을, 사무실 줄은 새 일이 왼쪽이라 뒤(오른쪽)를 자릅니다.
struct StatusLineView: View {
    let line: StatusLine

    /// 줄 높이 (사무실 영역은 이만큼 빼고 맞춥니다)
    static let height: CGFloat = 30

    var body: some View {
        // 진행 중인 동작이 있을 때만 1초마다 경과 시간을 다시 그립니다
        TimelineView(.periodic(from: .now, by: line.hasRunning ? 1 : 60)) { context in
            HStack(spacing: 8) {
                head
                Text(attributed(now: context.date))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(line.mode == .agent ? .head : .tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(line.text(now: context.date))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var head: some View {
        switch line.mode {
        case .agent:
            HStack(spacing: 5) {
                if let colorIndex = line.colorIndex {
                    Circle().fill(Palette.team(colorIndex))
                        .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.8))
                        .frame(width: 8, height: 8)
                }
                if let head = line.head {
                    Text(head).font(.system(size: 12, weight: .bold)).lineLimit(1).fixedSize()
                }
            }
        case .office:
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let head = line.head {
                    Text(head).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
    }

    private func attributed(now: Date) -> AttributedString {
        var result = AttributedString()
        if line.truncated, line.mode == .agent { result += styled("… ", .secondary) }
        for (index, segment) in line.segments.enumerated() {
            if index > 0 { result += styled(line.separator, .secondary) }
            var text = AttributedString(segment.text)
            switch segment.tone {
            case .normal:
                text.foregroundColor = .primary
            case .muted:
                text.foregroundColor = .secondary
            case .attention:
                // 승인 대기: 노랑 형광펜
                text.foregroundColor = .primary
                text.backgroundColor = Palette.attention
            case .error:
                text.foregroundColor = .red
            }
            result += text
            if let since = segment.since, let elapsed = StatusLine.elapsed(now.timeIntervalSince(since)) {
                result += styled(" (\(elapsed))", .secondary)
            }
        }
        if line.truncated, line.mode == .office { result += styled(" …", .secondary) }
        return result
    }

    private func styled(_ string: String, _ color: Color) -> AttributedString {
        var text = AttributedString(string)
        text.foregroundColor = color
        return text
    }
}
