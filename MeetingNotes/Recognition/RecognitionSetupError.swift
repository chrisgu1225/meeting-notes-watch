import Foundation

enum RecognitionSetupError: LocalizedError {
    case speechPermissionDenied
    case localeUnsupported(String)
    case onDeviceUnavailable(String)
    case serverDisabled
    case modelInstallFailed(String)
    case noAudioFormat
    case recognizerFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "iPhone 还没有语音识别权限。打开「记要点」，允许语音识别后再开始。"
        case .localeUnsupported(let identifier):
            "这台 iPhone 没有 \(identifier) 的识别模型。"
        case .onDeviceUnavailable(let identifier):
            "\(identifier) 现在不能在设备上识别。没有打开「允许苹果服务器识别」，所以这场不会开始。"
        case .serverDisabled:
            "设备端识别不可用，而且没有允许把声音缓冲发给苹果。"
        case .modelInstallFailed(let message):
            "离线语音模型没有装好：\(message)"
        case .noAudioFormat:
            "识别器没有可用的音频格式。"
        case .recognizerFailed(let message):
            message
        }
    }
}
