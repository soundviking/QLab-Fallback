import SwiftUI

struct BackupFolderView: View {
    @ObservedObject var store: BackupFolderStore
    @EnvironmentObject private var networkDiscovery: NetworkDiscovery
    var body: some View {
        GroupBox("Dossier BACKUP") {
            VStack(alignment: .leading, spacing: 8) {
                Button(store.url.path) { NSWorkspace.shared.open(store.url) }
                    .buttonStyle(.link)
                    .help("Afficher dans le Finder")
                Button("Changer d’emplacement…") { networkDiscovery.chooseBackupFolder() }
                    .disabled(!networkDiscovery.canChangeBackupFolder)
                if !networkDiscovery.canChangeBackupFolder {
                    AppText("Arrêtez BACKUP avant de changer de dossier.").font(.caption)
                }
                if let error = store.error { AppText(error).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
