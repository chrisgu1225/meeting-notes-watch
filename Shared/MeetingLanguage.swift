import Foundation

enum MeetingLanguage: String, Codable, CaseIterable, Identifiable {
    case mandarin = "zh-CN"
    case australianEnglish = "en-AU"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Short label used on the watch.
    var shortLabel: String {
        switch self {
        case .mandarin: "中文"
        case .australianEnglish: "EN"
        }
    }

    var displayName: String {
        switch self {
        case .mandarin: "普通话（可夹英文词）"
        case .australianEnglish: "澳大利亚英语"
        }
    }
}
