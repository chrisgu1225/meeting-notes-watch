import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: PhoneController
    @State private var newTerm = ""
    @State private var showFolderPicker = false
    @State private var folderError: String?

    var body: some View {
        Form {
            Section {
                Picker("默认识别语言", selection: language) {
                    ForEach(MeetingLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } footer: {
                Text("手表上还能临时改。普通话这条路允许句子里夹英文词，自定义词用来照顾人名和产品名。")
            }

            Section {
                Picker("识别方式", selection: route) {
                    ForEach(RecognitionRoute.allCases) { route in
                        Text(route.displayName).tag(route)
                    }
                }
                Toggle("允许苹果服务器识别", isOn: server)
            } footer: {
                Text(routeFooter)
            }

            Section {
                ForEach(controller.settings.vocabulary, id: \.self) { term in
                    Text(term)
                }
                .onDelete { controller.settings.removeTerms(at: $0) }
                HStack {
                    TextField("人名或产品名", text: $newTerm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        controller.settings.addTerm(newTerm)
                        newTerm = ""
                    }
                    .disabled(VocabularyList.sanitizeItem(newTerm).isEmpty)
                }
                Button("恢复默认词") {
                    controller.settings.restoreDefaultVocabulary()
                }
            } header: {
                Text("自定义词")
            } footer: {
                Text("最多 \(VocabularyList.maxCount) 个，每个尽量一两个词。自定义词听写和经典识别会把它们交给识别器。长会议模型不吃这些词，但导出的 txt 文件头里仍然有这份名单。")
            }

            Section {
                Toggle("导出后删除 App 里的文字稿", isOn: deleteAfter)
                if let name = controller.settings.folderDisplayName {
                    Text("已选：\(name)")
                } else {
                    Text("还没有固定文件夹")
                        .foregroundStyle(.secondary)
                }
                Button("选择文件夹") { showFolderPicker = true }
                if controller.settings.folderDisplayName != nil {
                    Button("清除文件夹", role: .destructive) {
                        controller.settings.clearFolder()
                    }
                }
            } header: {
                Text("导出")
            } footer: {
                Text("选 iCloud Drive 或 Google Drive 里的文件夹。Google Drive 要先安装，并在「文件」App 里打开。后面的助手读的是这个文件夹里的 txt，不是录音。")
            }

            Section {
                statusRows
                Button("请求语音识别权限") { controller.requestSpeechPermission() }
                Button("下载离线模型") { controller.downloadModels() }
                    .disabled(controller.live != nil || controller.preparingMessage != nil)
                if let downloadMessage = controller.downloadMessage {
                    Text(downloadMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("这台手机")
            } footer: {
                Text("这里的结果是现在查到的，不是写死的。设备端表示声音不出这台手机。模型第一次下载会连苹果。本 App 没有自己的服务器，也没有统计。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                showFolderPicker = false
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    try controller.settings.rememberFolder(url)
                } catch {
                    folderError = error.localizedDescription
                }
            } onCancel: {
                showFolderPicker = false
            }
        }
        .alert("文件夹没记住", isPresented: folderErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
        .onAppear { controller.onAppear() }
    }

    private var language: Binding<MeetingLanguage> {
        Binding(
            get: { controller.settings.language },
            set: {
                controller.settings.language = $0
                controller.languageChanged()
            }
        )
    }

    private var route: Binding<RecognitionRoute> {
        Binding(
            get: { controller.settings.route },
            set: { controller.settings.route = $0 }
        )
    }

    private var server: Binding<Bool> {
        Binding(
            get: { controller.settings.allowAppleServer },
            set: { controller.settings.allowAppleServer = $0 }
        )
    }

    private var deleteAfter: Binding<Bool> {
        Binding(
            get: { controller.settings.deleteAfterExport },
            set: { controller.settings.deleteAfterExport = $0 }
        )
    }

    private var routeFooter: String {
        switch controller.settings.route {
        case .automatic:
            "先试自定义词听写（设备端）。不行再试长会议模型（设备端，自定义词不参与识别）。再不行用经典识别，大约每 45 秒重开一段。只有打开上面的开关，而且设备端不可用时，经典识别才会把声音缓冲发给苹果。"
        case .longForm:
            "SpeechTranscriber，给会议这种长时间、人离麦克风稍远的场景用，在设备上识别。苹果这个模型不接受自定义词。"
        case .vocabulary:
            "DictationTranscriber，设备端。自定义词通过 contextual strings 交给识别器，预设是长时间听写。"
        case .classic:
            "SFSpeechRecognizer。苹果会在大约一分钟停下，所以 App 大约每 45 秒结束一段并马上开下一段。能设备端就设备端。"
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        if let status = controller.modelStatus {
            LabeledContent("语音识别权限", value: status.speechAuthorized ? "已允许" : "还没有")
            LabeledContent("长会议模型", value: status.speechTranscriberAvailable ? "这台手机支持" : "不支持")
            LabeledContent("普通话 · 长会议", value: status.longFormMandarin ?? "不支持")
            LabeledContent("英语 · 长会议", value: status.longFormEnglish ?? "不支持")
            LabeledContent("普通话 · 自定义词", value: status.dictationMandarin ?? "不支持")
            LabeledContent("英语 · 自定义词", value: status.dictationEnglish ?? "不支持")
            LabeledContent("普通话 · 经典设备端", value: status.classicMandarinOnDevice ? "可以" : "不可以")
            LabeledContent("英语 · 经典设备端", value: status.classicEnglishOnDevice ? "可以" : "不可以")
        } else {
            ProgressView("正在查询模型…")
        }
    }

    private var folderErrorPresented: Binding<Bool> {
        Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )
    }
}
