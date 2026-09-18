import SwiftUI
import AppKit

extension NetworkDiscovery {
    enum MenuBarVisualState {
        case synchronise
        case desynchronise
        case nonConnecte
    }

    var menuBarVisualState: MenuBarVisualState {
        // An active BACKUP can keep playing without its peer. The label still
        // describes the link; the menu retains the separate recovery details.
        if !isConnected || (!isMasterRuntime && linkLost) {
            return .nonConnecte
        }
        return menuBarSyncBlockReason == nil ? .synchronise : .desynchronise
    }

    // Current readiness is authoritative. Historical detection/transfer errors
    // must not override a freshly verified BACKUP, unlike an active safety fault.
    var menuBarSyncBlockReason: String? {
        if !isConnected || (!isMasterRuntime && linkLost) { return "Liaison non connectée" }
        if workspaceTransferInProgress { return "Transfert du projet en cours" }
        if liveMirrorReloading { return "Application du miroir en cours" }
        if failoverActive || failoverTakeoverLatched { return "Secours BACKUP actif" }
        if masterReturning || returnInProgress { return "Retour sur le MASTER en cours" }
        if !qlabOSCConnected { return "QLab OSC non connecté" }
        if !liveMirrorSynchronized { return liveMirrorStatus }
        if isMasterRuntime { return lastError ?? workspaceTransferError }
        if !heartbeatAlive { return "Heartbeat MASTER absent" }
        if backupOutputTestActive { return "Test de sortie BACKUP en cours" }
        if !backupAudioControlReady || !backupAudioIsolationConfirmed
            || !hotStandbyOutputIsolationConfirmed || !hotStandbyExecutionArmed {
            return backupAudioControlError ?? "Isolation ou contrôle audio BACKUP non prêts"
        }
        if !playheadSyncReady { return "Tête de lecture non synchronisée" }
        if !failoverReady { return failoverBlockedReason ?? "BACKUP non prêt à basculer" }
        return nil
    }

    var menuBarStatusText: String {
        switch menuBarVisualState {
        case .synchronise: return "Synchro OK"
        case .desynchronise: return "Désynchronisé"
        case .nonConnecte: return "Non connecté"
        }
    }

    var menuBarStatusColor: Color { Color(nsColor: menuBarStatusNSColor) }

    var menuBarStatusNSColor: NSColor {
        // Fixed bright colors remain readable on the fixed black background.
        switch menuBarVisualState {
        case .synchronise: return NSColor(srgbRed: 0.25, green: 0.90, blue: 0.43, alpha: 1)
        case .desynchronise: return NSColor(srgbRed: 1, green: 0.65, blue: 0.22, alpha: 1)
        case .nonConnecte: return NSColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 1)
        }
    }
}

struct MenuBarStatusBadge: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 15, height: 15)

            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1.1)
                .frame(width: 15, height: 15)

            Circle()
                .fill(color.opacity(0.28))
                .frame(width: 9, height: 9)

            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
        }
        .frame(width: 15, height: 15)
    }
}

struct MenuBarStatusLabel: View {
    @EnvironmentObject var networkDiscovery: NetworkDiscovery

    var body: some View {
        Image(nsImage: MenuBarLabelRenderer.image(
            text: networkDiscovery.menuBarStatusText,
            color: networkDiscovery.menuBarStatusNSColor))
            .renderingMode(.original)
            .accessibilityLabel(networkDiscovery.menuBarStatusText)
            .help("QLab Fallback — " + (networkDiscovery.menuBarSyncBlockReason ?? networkDiscovery.menuBarStatusText))
    }
}

struct MenuBarStatusMenuContent: View {
    @EnvironmentObject var networkDiscovery: NetworkDiscovery

    private var manualResyncAvailabilityText: String {
        if networkDiscovery.liveMirrorManualResyncRunning {
            return "Resynchronisation en cours"
        }
        if !networkDiscovery.isBackupRuntime {
            return "Disponible lorsque cette machine est activée en BACKUP"
        }
        if !networkDiscovery.isConnected {
            return "MASTER non connecté"
        }
        if !networkDiscovery.qlabOSCConnected {
            return "QLab OSC non connecté"
        }
        if !networkDiscovery.workspaceTransferReady {
            return "Fallback initial non prêt"
        }
        if networkDiscovery.failoverActive || networkDiscovery.failoverTakeoverLatched {
            return "Indisponible pendant le FAILOVER"
        }
        if networkDiscovery.returnInProgress || networkDiscovery.masterReturning {
            return "Indisponible pendant le retour MASTER"
        }
        if networkDiscovery.backupOutputTestActive {
            return "Indisponible pendant le test de sortie BACKUP"
        }
        if networkDiscovery.backupOutputMode != "ISOLATED"
            || !networkDiscovery.backupAudioIsolationConfirmed
            || !networkDiscovery.hotStandbyOutputIsolationConfirmed {
            return "Isolation audio BACKUP non confirmée"
        }
        return "Relance le Live Mirror sans réactiver le son du BACKUP"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MenuBarStatusBadge(
                    color: networkDiscovery.menuBarStatusColor
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text("QLab Fallback")
                        .font(.headline)

                    Text(networkDiscovery.menuBarStatusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(networkDiscovery.menuBarStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black, in: RoundedRectangle(cornerRadius: 5))
                }
            }

            Divider()

            StatusRow(
                title: "QLab",
                value: networkDiscovery.localQLabAvailable ? "Connecté" : "Non détecté"
            )

            StatusRow(
                title: "Liaison",
                value: networkDiscovery.isConnected ? "Connectée" : "En attente"
            )

            StatusRow(
                title: "Workspace",
                value: networkDiscovery.connectedWorkspace ?? "Non détecté"
            )

            Divider()
            if networkDiscovery.failoverActive {
                Text("Secours actif — le BACKUP assure la lecture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let reason = networkDiscovery.menuBarSyncBlockReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(networkDiscovery.liveMirrorStatus)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if !networkDiscovery.isMasterRuntime {
                Button {
                    networkDiscovery.requestLiveMirrorResynchronization()
                } label: {
                    Label(
                        networkDiscovery.liveMirrorManualResyncRunning
                            ? "Relance en cours…"
                            : "Relancer la synchronisation",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!networkDiscovery.canRequestLiveMirrorResynchronization)
                .help(manualResyncAvailabilityText)

                if !networkDiscovery.canRequestLiveMirrorResynchronization {
                    Text(manualResyncAvailabilityText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = networkDiscovery.liveMirrorManualResyncError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if networkDiscovery.isBrowsing {
                Text("Synchronisation automatique")
                Text("Le transfert peut se préparer pendant la lecture ; le rechargement QLab attend un moment sûr.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !networkDiscovery.recoveryStatus.isEmpty {
                Text(networkDiscovery.recoveryStatus).font(.caption)
                if networkDiscovery.failoverActive {
                    Button("Reprendre le son sur le MASTER") { networkDiscovery.requestMasterReturn() }
                        .disabled(!networkDiscovery.masterReturnReady || networkDiscovery.returnInProgress)
                }
            }

            Button("Afficher QLab Fallback") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Quitter QLab Fallback") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 12))
    }
}
