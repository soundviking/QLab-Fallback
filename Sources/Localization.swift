import SwiftUI

// String Catalog is compiled into standard Apple .lproj resources by the build.
enum L10n {
    static let supported = ["fr", "en", "de", "es"]
    static func languageCode(_ selection: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if supported.contains(selection) { return selection }
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }
    static func text(_ key: String, selection: String? = nil, resourceBundle: Bundle = .main) -> String {
        let normalized = key
        let code = languageCode(selection ?? UserDefaults.standard.string(forKey: "QLabFallback.Language") ?? "system")
        let bundle = resourceBundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        return bundle.localizedString(forKey: normalized, value: normalized, table: "Localizable")
    }
}

struct AppText: View {
    let value: String
    @AppStorage("QLabFallback.Language") private var language = "system"
    init(_ value: String) { self.value = value }
    var body: some View { Text(verbatim: L10n.text(value, selection: language)) }
}

struct AppLabel: View {
    let value: String
    let systemImage: String
    @AppStorage("QLabFallback.Language") private var language = "system"
    init(_ value: String, systemImage: String) { self.value = value; self.systemImage = systemImage }
    var body: some View { Label(L10n.text(value, selection: language), systemImage: systemImage) }
}

struct LanguageScope<Content: View>: View {
    @AppStorage("QLabFallback.Language") private var language = "system"
    @ViewBuilder var content: () -> Content
    var body: some View { content().environment(\.locale, Locale(identifier: L10n.languageCode(language))) }
}

struct LanguageSettings: View {
    @AppStorage("QLabFallback.Language") private var language = "system"
    var body: some View {
        Form {
            Picker(selection: $language) {
                AppText("Système").tag("system")
                Text("Français").tag("fr")
                Text("English").tag("en")
                Text("Deutsch").tag("de")
                Text("Español").tag("es")
            } label: { AppText("Langue") }
        }.padding(24).frame(width: 350)
    }
}

extension Notification.Name {
    static let qlabShowHelp = Notification.Name("QLabFallback.ShowHelp")
}
