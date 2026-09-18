import SwiftUI

/// State belongs to the hosted settings subtree, so the eye updates its own view.
struct OSCPasscodeEditor: View {
    @EnvironmentObject private var networkDiscovery: NetworkDiscovery
    @State private var draft = ""
    @State private var visible = false

    var body: some View {
        HStack {
            Group {
                if visible { TextField("4 chiffres", text: $draft) }
                else { SecureField("4 chiffres", text: $draft) }
            }
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
            }
            .help(visible ? "Masquer" : "Afficher")
            .accessibilityLabel(visible ? "Masquer le code OSC" : "Afficher le code OSC")
            Button("Copier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft, forType: .string)
            }
            Button("Enregistrer") { _ = networkDiscovery.saveQLabPasscode(draft) }
        }
        .onAppear { draft = networkDiscovery.currentQLabPasscode(); visible = false }
        .onDisappear { visible = false; draft = "" }
    }
}
