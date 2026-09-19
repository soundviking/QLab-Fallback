import SwiftUI
import AppKit

@main
struct QLabFallbackApp: App {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("QLabFallback.Language") private var language = "system"
    @StateObject private var networkDiscovery = NetworkDiscovery()
    @StateObject private var qlabDiscovery = QLabDiscoveryService()

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    private func showHelp(_ page: Int) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .qlabShowHelp, object: page)
        }
    }

    var body: some Scene {
        Window("QLab Fallback", id: "main") {
            ContentView()
                .environmentObject(networkDiscovery)
                .environmentObject(qlabDiscovery)
                .task { qlabDiscovery.start() }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 620, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button(L10n.text("Guide de démarrage")) { showHelp(0) }
                Button(L10n.text("Tutoriel QLab")) { showHelp(1) }
                Button(L10n.text("Tutoriel Fallback")) { showHelp(2) }
                Divider()
                Link(L10n.text("Documentation QLab"), destination: URL(string: "https://qlab.app/docs/v5/")!)
            }
        }
        Settings { LanguageSettings() }


        MenuBarExtra {
            LanguageScope { MenuBarStatusMenuContent().environmentObject(networkDiscovery) }
        } label: {
            MenuBarStatusLabel()
                .environmentObject(networkDiscovery)
        }
        .menuBarExtraStyle(.window)
    }
}
