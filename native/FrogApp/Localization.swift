import Foundation

enum FrogResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}

enum L10n {
    static var language: String { "en" }
    static var locale: Locale { Locale(identifier: language) }
    /// Frog's interface is English only, so the strings table is looked up once.
    private static let table = FrogResources.bundle.path(forResource: language, ofType: "lproj").flatMap { Bundle(path: $0) }
    static func text(_ key: String) -> String {
        table?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}
