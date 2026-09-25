import Foundation
import Observation

@Observable
final class AppLanguage {
    static let shared = AppLanguage()
    var selection = "system"
}

enum L10n {
    static var language: String {
        let choice = AppLanguage.shared.selection
        return choice == "system" ? (Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en") : choice
    }
    static var locale: Locale { Locale(identifier: language) }
    static func text(_ key: String) -> String {
        #if SWIFT_PACKAGE
        let root = Bundle.module
        #else
        let root = Bundle.main
        #endif
        guard let path = root.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
