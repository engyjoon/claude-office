import SwiftUI

/// 받은 훅과 연출 지시를 시간순으로 보여주는 창. M3에서 사무실 화면이 생기기 전까지 동작을 확인하는 용도입니다.
struct EventLogView: View {
    static let title = "Claude Office 이벤트 로그"

    let model: AppModel
    @State private var showDirectives = false
    /// 지금 화면에 그려진 줄 (맨 아래 줄이 보이는지로 "따라가기"를 정함)
    @State private var visibleIDs: Set<AppModel.LogEntry.ID> = []

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter
    }()

    private var entries: [AppModel.LogEntry] {
        showDirectives ? model.log : model.log.filter { $0.kind != .directive }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("연출 지시도 보기", isOn: $showDirectives)
                Spacer()
                Text("\(entries.count)줄").foregroundStyle(.secondary).font(.caption)
                Button("지우기") { model.clearLog() }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.timeFormat.string(from: entry.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: icon(entry.kind))
                            .foregroundStyle(color(entry.kind))
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(entry.text)
                            .font(.system(size: 12, design: entry.kind == .directive ? .monospaced : .default))
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                    .onAppear { visibleIDs.insert(entry.id) }
                    .onDisappear { visibleIDs.remove(entry.id) }
                }
                // 맨 아래(방금까지의 마지막 줄)를 보고 있을 때만 새 줄을 따라갑니다. 위로 올려 읽는 중이면 그대로 둡니다.
                .onChange(of: entries.last?.id) { old, last in
                    guard let last else { return }
                    if old == nil || visibleIDs.contains(old!) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func icon(_ kind: AppModel.LogEntry.Kind) -> String {
        switch kind {
        case .hook: "arrow.down.circle"
        case .directive: "theatermasks"
        case .system: "gearshape"
        }
    }

    private func color(_ kind: AppModel.LogEntry.Kind) -> Color {
        switch kind {
        case .hook: .accentColor
        case .directive: .purple
        case .system: .secondary
        }
    }
}
