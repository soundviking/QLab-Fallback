import SwiftUI
import AppKit

@main
struct QLabFallbackApp: App {
    @StateObject private var networkDiscovery = NetworkDiscovery()

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(networkDiscovery)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 620, height: 620)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarStatusMenuContent()
                .environmentObject(networkDiscovery)
        } label: {
            MenuBarStatusLabel()
                .environmentObject(networkDiscovery)
        }
        .menuBarExtraStyle(.window)
    }
}
