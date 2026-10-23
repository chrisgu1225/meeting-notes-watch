import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var controller: PhoneController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if controller.store.sessions.isEmpty && controller.live == nil && controller.preparingMessage == nil {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("记要点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
        }
        .alert("这次没开始", isPresented: errorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(controller.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setForeground(phase == .active)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { controller.lastError != nil },
            set: { if !$0 { controller.lastError = nil } }
        )
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("还没有文字稿", systemImage: "text.quote")
        } description: {
            Text("在手表上打开「记要点」，先把同意的那句话说给在场的人，再点确认。手表只把声音留在内存里传到这台手机。停了以后这里只剩文字。")
        } actions: {
            NavigationLink("识别和导出设置") {
                SettingsView()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            if let message = controller.preparingMessage {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(message)
                    }
                }
            }
            if let live = controller.live {
                Section("正在听") {
                    LiveBanner(live: live, foreground: controller.isForeground) {
                            controller.stopFromPhone()
                        }
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        NavigationLink {
                            SessionDetailView(sessionID: session.id)
                        } label: {
                            SessionRow(session: session, isLive: controller.live?.id == session.id)
                        }
                    }
                }
            }
        }
    }

    private var groups: [(title: String, sessions: [MeetingSession])] {
        let grouped = Dictionary(grouping: controller.store.sessions) {
            AdelaideClock.dayLabel(for: $0.startedAt)
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { lhs, rhs in
                let left = lhs.sessions.map(\.startedAt).max() ?? .distantPast
                let right = rhs.sessions.map(\.startedAt).max() ?? .distantPast
                return left > right
            }
    }
}

private struct SessionRow: View {
    let session: MeetingSession
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle)
                    .font(.headline)
                Spacer()
                if isLive || session.incomplete {
                    Text(isLive ? "正在听" : "未结束")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text("\(AdelaideClock.formatDisplay(session.startedAt)) · \(session.durationLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(session.transcript.isEmpty ? "没有文字" : session.transcript)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private struct LiveBanner: View {
    let live: LiveSessionState
    let foreground: Bool
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(live.status)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TimelineView(.periodic(from: live.startedAt, by: 1)) { context in
                    Text(AdelaideClock.formatDuration(
                        AdelaideClock.roundedSeconds(context.date.timeIntervalSince(live.startedAt))
                    ))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text(live.preview.isEmpty ? "等第一句…" : live.preview)
                .font(.body)
                .lineLimit(6)
                .textSelection(.enabled)
            Button("停止并保存文字") {
                onStop()
            }
            .buttonStyle(.bordered)
            Text(foreground
                 ? "屏幕会保持常亮。声音只在内存里，不会写成录音文件。"
                 : "App 不在前台，这段话不会记下来。回到这个页面才会继续。")
                .font(.footnote)
                .foregroundStyle(foreground ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 4)
    }
}
