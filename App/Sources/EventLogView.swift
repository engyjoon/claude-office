import SwiftUI

/// 받은 훅과 연출 지시를 시간순으로 보여주는 창. M3에서 사무실 화면이 생기기 전까지 동작을 확인하는 용도입니다.
struct EventLogView: View {
    let model: AppModel
    @State private var showDirectives = false

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
                        Text(entry.text)
                            .font(.system(size: 12, design: entry.kind == .directive ? .monospaced : .default))
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                }
                .onChange(of: entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
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
