import SwiftUI

/// The separate AppKit window must observe live state itself; a prebuilt view
/// tree captures values and cannot rely on redraws of the main window.
struct AdvancedSettingsHost<Content: View>: View {
    @ObservedObject var manager: NetworkDiscovery
    @Binding var role: Role
    @AppStorage("QLabFallback.Language") private var language = "system"
    @ViewBuilder var content: () -> Content
    var body: some View {
        let _ = role
        content()
            .environmentObject(manager)
            .environment(\.locale, Locale(identifier: L10n.languageCode(language)))
            .preferredColorScheme(.dark)
    }
}
