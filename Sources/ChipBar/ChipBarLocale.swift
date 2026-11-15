import Foundation

/// Localized dynamic text. Literal SwiftUI Text/Label keys are resolved
/// through the distributed en.lproj and zh-Hans.lproj Localizable.strings.
enum ChipBarLocale {
    static var isChinese: Bool {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
    }

    static func localized(_ text: String) -> String {
        Bundle.main.localizedString(forKey: text, value: text, table: nil)
    }

    static func choose(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    static func format(_ english: String, _ chinese: String,
                       _ arguments: CVarArg...) -> String {
        String(format: isChinese ? chinese : english, arguments: arguments)
    }
}
