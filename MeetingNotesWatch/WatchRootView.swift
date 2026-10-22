import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                idle
            case .consent:
                consent
            case .preparing:
                preparing
            case .listening:
                listening
            case .stopping:
                status("正在保存", "文字传到手机上。声音已经丢掉了。")
            case .saved:
                ended(title: "已保存", detail: "文字稿在手机上。没有录音文件。", button: "好")
            case .failed(let message):
                ended(title: "没有开始", detail: message, button: "返回")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.sceneBecameActive(phase == .active)
        }
    }

    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("不留录音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("标题，可听写", text: $model.title)
                HStack {
                    languageButton(.mandarin)
                    languageButton(.australianEnglish)
                }
                Button(action: model.openConsent) {
                    Text("开始")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                Text(model.phoneReachable ? "手机已连接" : "请打开手机上的记要点")
                    .font(.caption2)
                    .foregroundStyle(model.phoneReachable ? .secondary : .orange)
            }
            .padding(.horizontal, 4)
        }
    }

    private var consent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("先说一声")
                    .font(.headline)
                Text("“\(ConsentScript.mandarin)”")
                    .font(.body.weight(.semibold))
                Text(ConsentScript.english)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("点下面才会打开麦克风。声音不写文件。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(action: model.confirmAndPrepare) {
                    Text("我已经说了")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.phoneReachable)
                Button("返回", action: model.cancelConsent)
                    .buttonStyle(.bordered)
                if !model.phoneReachable {
                    Text("手机 App 要开着，并且留在前台。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var preparing: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(model.statusLine)
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("取消", action: model.stop)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 4)
    }

    private var listening: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(elapsed(at: context.date))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                if dimmed {
                    Text("正在听")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(model.statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.transcriptTail.isEmpty ? "…" : model.transcriptTail)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("tail")
                        }
                        .onChange(of: model.transcriptTail) { _, _ in
                            proxy.scrollTo("tail", anchor: .bottom)
                        }
                    }
                    if !model.screenActive {
                        Text("屏幕灭了之后可能会停。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if model.captureInterrupted {
                        Text("被打断了。电话记不了。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if model.droppedChunks > 0 {
                        Text("丢掉 \(model.droppedChunks) 段，没存文件")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Button(action: model.stop) {
                    Text("停止")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 4)
        }
    }

    private func status(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func ended(title: String, detail: String, button: String) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button(button, action: model.dismissEndState)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 4)
        }
    }

    private func languageButton(_ language: MeetingLanguage) -> some View {
        Button(language.shortLabel) { model.language = language }
            .buttonStyle(.bordered)
            .tint(model.language == language ? .green : .gray)
            .frame(maxWidth: .infinity)
    }

    private func elapsed(at now: Date) -> String {
        guard let start = model.micStartedAt else { return "00:00" }
        let text = AdelaideClock.formatDuration(
            AdelaideClock.roundedSeconds(now.timeIntervalSince(start))
        )
        if text.hasPrefix("00:") { return String(text.dropFirst(3)) }
        return text
    }
}
