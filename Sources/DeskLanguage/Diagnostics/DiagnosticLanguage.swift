import Foundation

/// The languages messages and catalog documentation are written in. Other system languages fall back to English.
public enum DiagnosticLanguage: String, Sendable, Hashable, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}
