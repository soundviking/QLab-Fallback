import SwiftUI

/// Schematic instructions, not screenshots. No timers, media or network requests.
struct TutorialDiagram: View {
    let page: Int
    private func card(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.purple)
            AppText(title).font(.headline)
            AppText(detail).font(.caption).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, minHeight: 120)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    var body: some View {
        VStack(spacing: 14) {
            AppText(page == 1 ? "Schéma QLab" : "Schéma Fallback").font(.caption).foregroundStyle(.secondary)
            if page == 1 {
                card("Workspace Settings → OSC", icon: "slider.horizontal.3", detail: "OSC: 53000 · View · Edit · Control")
                AppText("Passcode QLab")
                Text("1515").monospaced()
            } else if page == 3 {
                card("BACKUP", icon: "checkmark.shield", detail: "SHA-256 · Live Mirror · Playhead · ISOLATED")
            } else {
                HStack(spacing: 12) {
                    card("PRIMARY", icon: "desktopcomputer", detail: page == 4 ? "Indisponible" : "Spectacle principal")
                    Image(systemName: page == 4 ? "bolt.slash" : "arrow.right").accessibilityHidden(true)
                    card("BACKUP", icon: "desktopcomputer", detail: page == 4 ? "FAILOVER ACTIF" : "Sortie BACKUP isolée")
                }
            }
        }
    }
}
