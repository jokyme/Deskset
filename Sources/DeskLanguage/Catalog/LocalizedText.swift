import Foundation

/// A short text in the two languages Desk documents and messages are written in: English and Simplified Chinese.
public struct LocalizedText: Sendable, Hashable, CustomStringConvertible {
    public var en: String
    public var zh: String

    public init(en: String, zh: String) {
        self.en = en
        self.zh = zh
    }

    public init(_ en: String, _ zh: String) {
        self.init(en: en, zh: zh)
    }

    public func text(in language: DiagnosticLanguage) -> String {
        switch language {
        case .english: return en
        case .simplifiedChinese: return zh
        }
    }

    /// True when both languages have text.
    public var isComplete: Bool {
        !en.trimmingCharacters(in: .whitespaces).isEmpty && !zh.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var description: String { "\(en) / \(zh)" }
}
