import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var controller: PhoneController
    let sessionID: UUID

    @State private var title = ""
    @State private var transcript = ""
    @State private var confirmDelete = false
    @State private var confirmExportDelete = false
    @State private var pendingExport: ExportKind?
    @State private var presentedExport: PresentedFile?
    @State private var exportError: String?
    @State private var loaded = false

    private var session: MeetingSession? {
        controller.store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        Group {
            if let session {
                form(session)
            } else {
                ContentUnavailableView("这篇已经不在手机上", systemImage: "doc")
            }
        }
        .navigationTitle("文字稿")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: session?.transcript) { _, _ in
            guard let session, controller.live?.id == session.id else { return }
            transcript = session.transcript
        }
        .confirmationDialog("从 App 里删除这篇文字稿？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                controller.deleteSession(id: sessionID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导出到文件夹里的 txt 不会一起删。")
        }
        .confirmationDialog("导出后从 App 里删除？", isPresented: $confirmExportDelete, titleVisibility: .visible) {
            Button("导出并删除", role: .destructive) {
                if let pendingExport { run(pendingExport) }
            }
            Button("取消", role: .cancel) { pendingExport = nil }
        } message: {
            Text("文件夹或分享出去的 txt 会留下。App 里的这一篇会删掉。")
        }
        .alert("导出没有完成", isPresented: exportErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(item: $presentedExport, onDismiss: cleanupPresentedFile) { item in
            switch item.kind {
            case .saveAs:
                ExportPicker(fileURL: item.url) { completed in
                    finishPresented(item, completed: completed)
                }
            case .share:
                ShareSheet(url: item.url) { completed in
                    finishPresented(item, completed: completed)
                }
            case .folder:
                EmptyView()
            }
        }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    @ViewBuilder
    private func form(_ session: MeetingSession) -> some View {
        List {
            Section {
                TextField("标题", text: $title)
                    .onSubmit(saveEdits)
                Text("\(AdelaideClock.formatDisplay(session.startedAt)) · \(session.durationLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(session.language.displayName) · \(placement(session.recognition)) · \(engineName(session.engine))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if session.droppedAudioChunks > 0 {
                    Text("丢掉了 \(session.droppedAudioChunks) 段声音（没有存成文件）")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !session.note.isEmpty {
                    Text(session.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("文字") {
                TextEditor(text: $transcript)
                    .frame(minHeight: 240)
                    .font(.body)
                    .disabled(controller.live?.id == session.id)
            }
            Section {
                Button("导出到已选文件夹") { ask(.folder) }
                    .disabled(controller.settings.folderDisplayName == nil)
                Button("另存为…") { ask(.saveAs) }
                Button("分享") { ask(.share) }
            } footer: {
                if let name = controller.settings.folderDisplayName {
                    Text("固定文件夹：\(name)。Google Drive 要先安装，并在「文件」里看得到。")
                } else {
                    Text("还没选固定文件夹。用「另存为」可以选 iCloud Drive 或 Google Drive。")
                }
            }
            Section {
                Button("删除这篇", role: .destructive) { confirmDelete = true }
                    .disabled(controller.live?.id == session.id)
            }
        }
        .onChange(of: title) { _, _ in saveEdits() }
        .onChange(of: transcript) { _, _ in saveEdits() }
    }

    private func load() {
        guard !loaded, let session else { return }
        title = session.title
        transcript = session.transcript
        loaded = true
    }

    private func saveEdits() {
        guard var session, controller.live?.id != session.id else { return }
        session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        session.transcript = transcript
        controller.updateSession(session)
    }

    private func ask(_ kind: ExportKind) {
        saveEdits()
        guard session != nil else { return }
        if controller.settings.deleteAfterExport {
            pendingExport = kind
            confirmExportDelete = true
        } else {
            run(kind)
        }
    }

    private func run(_ kind: ExportKind) {
        pendingExport = nil
        guard let session else { return }
        do {
            switch kind {
            case .folder:
                _ = try controller.exportToSavedFolder(session)
                controller.didExport(session)
            case .saveAs:
                presentedExport = PresentedFile(kind: .saveAs, url: try controller.makeShareFile(session))
            case .share:
                presentedExport = PresentedFile(kind: .share, url: try controller.makeShareFile(session))
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func finishPresented(_ item: PresentedFile, completed: Bool) {
        if completed, let session { controller.didExport(session) }
        ExportCoordinator.removeTemporary(item.url)
        presentedExport = nil
    }

    private func cleanupPresentedFile() {
        guard let presentedExport else { return }
        ExportCoordinator.removeTemporary(presentedExport.url)
    }

    private func placement(_ raw: String) -> String {
        switch raw {
        case RecognitionPlacementID.onDevice: "设备端"
        case RecognitionPlacementID.appleServer: "苹果服务器"
        default: raw
        }
    }

    private func engineName(_ raw: String) -> String {
        switch raw {
        case EngineID.dictationTranscriber: "自定义词听写"
        case EngineID.speechTranscriber: "长会议模型"
        case EngineID.sfSpeechOnDevice: "经典识别"
        case EngineID.sfSpeechServer: "经典识别（服务器）"
        default: raw
        }
    }
}

private enum ExportKind {
    case folder
    case saveAs
    case share
}

private struct PresentedFile: Identifiable {
    let id = UUID()
    let kind: ExportKind
    let url: URL
}
