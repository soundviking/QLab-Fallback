import SwiftUI
import AppKit
import Network

struct ContentView: View {
    @State private var advancedSettingsWindowController: NSWindowController?

    @State private var showHelpGuide = false
    @State private var helpPage = 0
    @State private var helpAnimationPulse = false

    @State private var helpAnimationTask:
        Task<Void, Never>?

    @AppStorage(
        "QLabFallback.OnboardingCompleted.v1"
    )
    private var onboardingCompleted = false

    @EnvironmentObject private var qlabDiscovery: QLabDiscoveryService
    @State private var availableWorkspaces: [String] = []
    @State private var workspaceDetectionError: String?


    @EnvironmentObject private var networkDiscovery: NetworkDiscovery

    @State private var selectedRole: Role = .master
    @State private var workspaceName = "Non détecté"
    @State private var syncState: SyncState = .ready
    @State private var isActive = false
    @State private var masterDetected = false
    @State private var showFallbackConfirmation = false
    @State private var fallbackProgress = 0.0
    private var fallbackPreparing: Bool { networkDiscovery.workspaceTransferInProgress }
    private var fallbackReady: Bool { networkDiscovery.workspaceTransferReady }
    private var masterReady: Bool { networkDiscovery.isConnected }

    private let backgroundColor = Color(
        red: 10 / 255,
        green: 11 / 255,
        blue: 15 / 255
    )

    private let panelColor = Color(
        red: 24 / 255,
        green: 26 / 255,
        blue: 31 / 255
    )

    private let inactiveColor = Color(
        red: 27 / 255,
        green: 29 / 255,
        blue: 35 / 255
    )

    private let purple = Color(
        red: 93 / 255,
        green: 75 / 255,
        blue: 190 / 255
    )

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {

                    VStack(spacing: 8) {
                    FallbackLogo()
                        .frame(width: 58, height: 58)

                    Text("QLab Fallback")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer()
                    .frame(height: 10)

                roleSelector

                Spacer()
                    .frame(height: 12)

                workspacePanel

                Spacer()
                    .frame(height: 10)

                if !networkDiscovery.workspaceTransferReady && (selectedRole == .backup || !masterReady) {
                    statusView
                        .onChange(
                            of: networkDiscovery.isConnected
                        ) { _, connected in
                            if connected
                                && selectedRole == .backup {
                                masterDetected = true

                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.2
                                ) {
                                    showFallbackConfirmation = true
                                }
                            }
                        }
                }

                if selectedRole == .backup
                    && isActive
                    && !networkDiscovery.discoveredMasters.isEmpty
                    && !showFallbackConfirmation
                    && !networkDiscovery.workspaceTransferInProgress
                    && !networkDiscovery.workspaceTransferReady {

                    Spacer()
                        .frame(height: 9)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("MASTER détecté")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        ForEach(
                            networkDiscovery.discoveredMasters
                        ) { machine in

                            Button {
                                masterDetected = true
                                networkDiscovery.connect(
                                    to: machine
                                )
                            } label: {
                                HStack {
                                    Image(
                                        systemName: "desktopcomputer"
                                    )
                                    .foregroundStyle(.secondary)

                                    VStack(
                                        alignment: .leading,
                                        spacing: 2
                                    ) {
                                        Text(machine.name)
                                            .font(
                                                .system(
                                                    size: 14,
                                                    weight: .semibold
                                                )
                                            )
                                            .foregroundStyle(.white)

                                        Text("MASTER QLab Fallback")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(
                                        systemName: "chevron.right"
                                    )
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .frame(maxWidth: 470, minHeight: 50)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 10
                                    )
                                    .fill(panelColor)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if selectedRole == .backup && showFallbackConfirmation {
                    Spacer()
                        .frame(height: 9)

                    VStack(spacing: 14) {
                        Text("Créer le fallback de")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(
                            "« \(networkDiscovery.connectedWorkspace ?? workspaceName) » ?"
                        )
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                        Text("Le workspace et ses médias seront copiés sur cette machine pour préparer QLab en secours.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)

                        Button {

                            showFallbackConfirmation =
                                false

                            fallbackProgress =
                                0

                            networkDiscovery
                                .requestWorkspaceTransfer()

                        } label: {
                            Text("Créer le fallback")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: 220, minHeight: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(purple)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedRole == .backup && networkDiscovery.workspaceTransferInProgress {
                    Spacer()
                        .frame(height: 9)

                    VStack(spacing: 12) {
                        Text(networkDiscovery.workspaceTransferStatus)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)

                        ProgressView(value: networkDiscovery.workspaceTransferProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 340)

                        Text("\(Int(networkDiscovery.workspaceTransferProgress * 100)) %")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)


                        Button {

                            networkDiscovery
                                .cancelWorkspaceTransfer()

                        } label: {

                            Label(
                                "Annuler le transfert",
                                systemImage:
                                    "xmark.circle"
                            )
                            .font(
                                .system(
                                    size: 11,
                                    weight: .medium
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)


                        if let transferError =
                            networkDiscovery
                                .workspaceTransferError {

                            Text(
                                transferError
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 390)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            progressLine(
                                "Copie du workspace",
                                done: networkDiscovery.workspaceTransferProgress >= 1.0
                            )

                            progressLine(
                                "Copie des médias",
                                done: networkDiscovery.workspaceTransferProgress >= 1.0
                            )

                            progressLine(
                                "Vérification des fichiers",
                                done: networkDiscovery.workspaceTransferProgress >= 1.0
                            )

                            progressLine(
                                "Préparation de QLab",
                                done: networkDiscovery.workspaceTransferReady
                            )

                            progressLine(
                                "Synchronisation initiale",
                                done: networkDiscovery.workspaceTransferReady
                            )
                        }
                    }
                }

                if let error = networkDiscovery.workspaceTransferError {
                    Label("Validation du fallback échouée : " + error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: 400)
                }

                if selectedRole == .master && masterReady {

                    Spacer()
                        .frame(height: 9)

                    masterReadyCard
                }


                if selectedRole == .backup
                    && isActive
                    && !networkDiscovery.workspaceTransferReady {

                    Spacer()
                        .frame(height: 9)

                    VStack(spacing: 12) {

                        backupWaitingCard

                        Spacer()
                            .frame(height: 5)

                        Divider()
                            .frame(maxWidth: 340)
                            .opacity(0.25)

                        Spacer()
                            .frame(height: 3)

                        if networkDiscovery.backupOutputTestActive {

                            Text("TEST SORTIE BACKUP")
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .bold
                                    )
                                )
                                .foregroundStyle(.orange)

                            Text(
                                "MODE TEST ACTIF — \(networkDiscovery.backupOutputTestRemainingSeconds) s"
                            )
                            .font(
                                .system(
                                    size: 13,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.orange)

                            Button {
                                networkDiscovery
                                    .stopBackupOutputTest()
                            } label: {

                                Text("Arrêter le test")
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(.white)
                                    .frame(
                                        width: 230,
                                        height: 40
                                    )
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: 7
                                        )
                                        .fill(
                                            Color.red.opacity(
                                                0.85
                                            )
                                        )
                                    )
                            }
                            .buttonStyle(.plain)

                        } else {

                            HStack(spacing: 8) {

                                Circle()
                                    .fill(Color.secondary)
                                    .frame(
                                        width: 8,
                                        height: 8
                                    )

                                Text("Sortie BACKUP isolée")
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: .medium
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                networkDiscovery
                                    .startBackupOutputTest()
                            } label: {

                                HStack(spacing: 8) {

                                    Image(
                                        systemName:
                                            "speaker.wave.2.fill"
                                    )

                                    Text(
                                        "Tester la sortie BACKUP"
                                    )
                                }
                                .font(
                                    .system(
                                        size: 13,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.white)
                                .frame(
                                    width: 240,
                                    height: 40
                                )
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 7
                                    )
                                    .fill(
                                        Color.orange.opacity(
                                            0.85
                                        )
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                !networkDiscovery
                                    .qlabOSCConnected
                            )
                            .opacity(
                                networkDiscovery
                                    .qlabOSCConnected
                                ? 1.0
                                : 0.45
                            )

                            Text(
                                "Test audio local — durée 30 secondes"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }

                        if let testError =
                            networkDiscovery.backupOutputTestError {

                            Text(testError)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                }


                if selectedRole == .backup && networkDiscovery.workspaceTransferReady {
                    Spacer()
                        .frame(height: 9)

                    VStack(spacing: 12) {

                        backupReadyCard

                        Spacer()
                            .frame(height: 8)

                        Divider()
                            .frame(maxWidth: 360)
                            .opacity(0.25)

                        Spacer()
                            .frame(height: 4)

                        // ------------------------------------
                        // ÉTAT SORTIE BACKUP
                        // ------------------------------------

                        if networkDiscovery.backupOutputTestActive {

                            VStack(spacing: 8) {

                                Text("TEST SORTIE BACKUP")
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(.orange)

                                HStack(spacing: 8) {

                                    Circle()
                                        .fill(Color.orange)
                                        .frame(
                                            width: 9,
                                            height: 9
                                        )

                                    Text(
                                        "MODE TEST ACTIF"
                                    )
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(.orange)
                                }

                                Text(
                                    "Arrêt automatique dans \(networkDiscovery.backupOutputTestRemainingSeconds) s"
                                )
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                                Button {
                                    networkDiscovery
                                        .stopBackupOutputTest()
                                } label: {

                                    Text("Arrêter le test")
                                        .font(
                                            .system(
                                                size: 13,
                                                weight: .semibold
                                            )
                                        )
                                        .foregroundStyle(.white)
                                        .frame(
                                            width: 220,
                                            height: 38
                                        )
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: 7
                                            )
                                            .fill(
                                                Color.red.opacity(
                                                    0.85
                                                )
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                        } else {

                            VStack(spacing: 8) {

                                HStack(spacing: 8) {

                                    Circle()
                                        .fill(
                                            networkDiscovery.backupOutputMode
                                                == "FAILOVER"
                                                ? Color.red
                                                : Color.secondary
                                        )
                                        .frame(
                                            width: 9,
                                            height: 9
                                        )

                                    if networkDiscovery.backupOutputMode
                                        == "FAILOVER" {

                                        Text(
                                            "SORTIE BACKUP — FAILOVER"
                                        )
                                        .font(
                                            .system(
                                                size: 12,
                                                weight: .semibold
                                            )
                                        )
                                        .foregroundStyle(.red)

                                    } else {

                                        Text(
                                            "Sortie BACKUP isolée"
                                        )
                                        .font(
                                            .system(
                                                size: 12,
                                                weight: .medium
                                            )
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                }

                                Button {
                                    networkDiscovery
                                        .startBackupOutputTest()
                                } label: {

                                    HStack(spacing: 8) {

                                        Image(
                                            systemName:
                                                "speaker.wave.2.fill"
                                        )

                                        Text(
                                            "Tester la sortie BACKUP"
                                        )
                                    }
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(.white)
                                    .frame(
                                        width: 240,
                                        height: 40
                                    )
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: 7
                                        )
                                        .fill(
                                            Color.orange.opacity(
                                                0.85
                                            )
                                        )
                                    )
                                }
                                .buttonStyle(.plain)

                                Text(
                                    "Test temporaire de 30 secondes"
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                        }

                        if let testError =
                            networkDiscovery.backupOutputTestError {

                            Text(testError)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                }

                if !networkDiscovery.recoveryStatus.isEmpty {
                    VStack(spacing: 8) {
                        Text(networkDiscovery.recoveryStatus)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        if selectedRole == .backup && networkDiscovery.failoverActive {
                            Button("Reprendre le son sur le MASTER") { networkDiscovery.requestMasterReturn() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!networkDiscovery.masterReturnReady || networkDiscovery.returnInProgress)
                        }
                    }
                    .padding(.horizontal)
                }

                if selectedRole == .backup
                    && isActive
                    && networkDiscovery.qlabOSCConnected {

                    Spacer()
                        .frame(height: 12)

                    if networkDiscovery.failoverActive {

                        VStack(spacing: 6) {

                            Label(
                                "FAILOVER ACTIF",
                                systemImage:
                                    "bolt.shield.fill"
                            )
                            .font(
                                .system(
                                    size: 13,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Color.red.opacity(0.10),
                                in: Capsule()
                            )

                            Text(
                                "Le BACKUP assure désormais la sortie audio"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }

                    } else {
                        EmptyView()
                    }

                    if let error =
                        networkDiscovery
                            .failoverActivationError {

                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                }



                Spacer()
                    .frame(height: 10)

                    HStack(spacing: 18) {

                        Button {

                            openAdvancedSettingsWindow()

                        } label: {

                            Label(
                                "Réglages avancés",
                                systemImage: "gearshape"
                            )
                        }
                        .buttonStyle(.plain)


                        Button {

                            helpPage = 0
                            helpAnimationPulse = false
                            showHelpGuide = true

                        } label: {

                            Label(
                                "Aide",
                                systemImage:
                                    "questionmark.circle"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .font(
                        .system(
                            size: 12,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(
            edge: .bottom,
            spacing: 0
        ) {
            VStack(spacing: 0) {

                Divider()
                    .opacity(0.22)

                mainActionButton
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }

        .animation(
            .easeInOut(duration: 0.18),
            value: isActive
        )
        .animation(
            .easeInOut(duration: 0.18),
            value: selectedRole
        )
        .animation(
            .easeInOut(duration: 0.18),
            value:
                networkDiscovery.backupAudioIsolationConfirmed
        )
        .animation(
            .easeInOut(duration: 0.18),
            value:
                networkDiscovery.failoverActive
        )
        .sheet(
            isPresented: $showHelpGuide
        ) {
            helpGuideView
        }

        .onChange(of: networkDiscovery.localQLabWorkspace) { _, name in
            if let name, !name.isEmpty, networkDiscovery.qlabOSCConnected { workspaceName = name }
        }
        .onReceive(qlabDiscovery.$workspaces) { _ in Task { @MainActor in applyDiscoveredWorkspaces() } }
        .onReceive(qlabDiscovery.$error) { _ in Task { @MainActor in applyDiscoveredWorkspaces() } }
        .onAppear {
            applyDiscoveredWorkspaces()
            if !onboardingCompleted {

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.35
                ) {

                    showHelpGuide = true
                }
            }
        }

        .frame(
            minWidth: 520,
            idealWidth: 620,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: 620,
            maxHeight: .infinity
        )
    }


    private var masterReadyCard: some View {
        HStack(
            alignment: .top,
            spacing: 12
        ) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                HStack(spacing: 8) {
                    Text("MASTER")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Label(
                        networkDiscovery.liveMirrorSynchronized ? "Synchronisé" : "Miroir en attente",
                        systemImage: networkDiscovery.liveMirrorSynchronized ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(networkDiscovery.liveMirrorSynchronized ? .green : .orange)
                }

                Text("BACKUP connecté")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Workspace : \(workspaceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .stroke(
                Color.green.opacity(0.24),
                lineWidth: 1
            )
        }
    }


    private var backupWaitingCard: some View {
        HStack(
            alignment: .top,
            spacing: 12
        ) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                HStack(spacing: 8) {
                    Text("BACKUP")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Label(
                        "En attente",
                        systemImage: "circle.dotted"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                }

                Text(networkDiscovery.isConnected ? "MASTER connecté · validation en attente" : "En attente du MASTER")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Label(
                    networkDiscovery.qlabOSCConnected
                        ? "QLab BACKUP connecté"
                        : "Connexion à QLab BACKUP…",
                    systemImage:
                        networkDiscovery.qlabOSCConnected
                        ? "checkmark.circle.fill"
                        : "circle.dotted"
                )
                .font(.caption)
                .foregroundStyle(
                    networkDiscovery.qlabOSCConnected
                        ? Color.green
                        : Color.orange
                )
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .stroke(
                Color.orange.opacity(0.24),
                lineWidth: 1
            )
        }
    }


    private var backupReadyCard: some View {
        HStack(
            alignment: .top,
            spacing: 12
        ) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 36, height: 36)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                HStack(spacing: 8) {
                    Text("BACKUP")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Label(
                        networkDiscovery.liveMirrorSynchronized ? "Synchronisé" : "Miroir en attente",
                        systemImage: networkDiscovery.liveMirrorSynchronized ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(networkDiscovery.liveMirrorSynchronized ? .green : .orange)
                }

                Text("MASTER connecté")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                if let masterName =
                    networkDiscovery.connectedMasterName {

                    Label(
                        masterName,
                        systemImage: "desktopcomputer"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                if let workspace =
                    networkDiscovery.connectedWorkspace {

                    Text("Workspace : \(workspace)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }


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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!networkDiscovery.canRequestLiveMirrorResynchronization)
                .help("Relance le Live Mirror sans réactiver le son du BACKUP. Si une cue joue ou est en pause, l’application attendra le prochain moment sûr.")

                if let error = networkDiscovery.liveMirrorManualResyncError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .stroke(
                Color.green.opacity(0.24),
                lineWidth: 1
            )
        }
    }


    private func advancedStatusRow(
        _ title: String,
        value: String,
        systemImage: String,
        color: Color = .secondary
    ) -> some View {

        HStack(spacing: 10) {

            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(color)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.system(size: 12))
    }


    private var helpGuideView: some View {

        VStack(spacing: 0) {

            HStack {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text("QLab Fallback")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Guide de démarrage")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(helpPage + 1) / 5")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)


            Divider()


            ScrollView {

                VStack(spacing: 22) {

                    helpGuideVisual
                        .frame(
                            maxWidth: .infinity
                        )
                        .padding(.top, 8)


                    VStack(spacing: 10) {

                        Text(helpGuideTitle)
                            .font(.title2)
                            .fontWeight(.semibold)


                        Text(helpGuideText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 560)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .lineSpacing(3)
                    }


                    if helpPage == 1 {

                        HStack(spacing: 10) {

                            Text(
                                "Passcode QLab"
                            )
                            .foregroundStyle(.secondary)

                            Text("1515")
                                .font(
                                    .system(
                                        .body,
                                        design: .monospaced
                                    )
                                )
                                .fontWeight(.bold)


                            Button {

                                NSPasteboard
                                    .general
                                    .clearContents()

                                NSPasteboard
                                    .general
                                    .setString(
                                        networkDiscovery
                                            .currentQLabPasscode(),
                                        forType:
                                            .string
                                    )

                            } label: {

                                Label(
                                    "Copier",
                                    systemImage:
                                        "doc.on.doc"
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(
                                cornerRadius: 10
                            )
                            .fill(
                                Color.primary
                                    .opacity(0.06)
                            )
                        )
                    }
                }
                .padding(
                    EdgeInsets(
                        top: 18,
                        leading: 30,
                        bottom: 22,
                        trailing: 30
                    )
                )
            }


            Divider()


            HStack {

                if helpPage > 0 {

                    Button("Précédent") {

                        withAnimation(
                            .easeInOut(
                                duration: 0.22
                            )
                        ) {
                            helpPage -= 1
                        }

                        restartHelpAnimation()
                    }
                }


                Spacer()


                if helpPage < 4 {

                    Button("Suivant") {

                        withAnimation(
                            .easeInOut(
                                duration: 0.22
                            )
                        ) {
                            helpPage += 1
                        }

                        restartHelpAnimation()
                    }
                    .keyboardShortcut(
                        .defaultAction
                    )

                } else {

                    Button("Commencer") {

                        onboardingCompleted = true
                        showHelpGuide = false
                        helpPage = 0

                        helpAnimationTask?
                            .cancel()

                        helpAnimationTask =
                            nil

                        helpAnimationPulse =
                            false
                    }
                    .keyboardShortcut(
                        .defaultAction
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(
            width: 660,
            height: 610
        )
        .onAppear {
            restartHelpAnimation()
        }
    }


    private func restartHelpAnimation() {

        helpAnimationTask?
            .cancel()

        helpAnimationTask =
            nil


        helpAnimationPulse =
            false


        helpAnimationTask =
            Task { @MainActor in

                // Petite pause pour laisser la page apparaître.
                try? await Task.sleep(
                    nanoseconds:
                        600_000_000
                )


                guard !Task.isCancelled else {
                    return
                }


                while !Task.isCancelled {

                    withAnimation(
                        .easeInOut(
                            duration: 1.15
                        )
                    ) {

                        helpAnimationPulse
                            .toggle()
                    }


                    // L'utilisateur a environ trois secondes
                    // pour lire chaque état avant la suite.
                    try? await Task.sleep(
                        nanoseconds:
                            3_000_000_000
                    )
                }
            }
    }



    @ViewBuilder
    private var helpGuideVisual: some View {

        switch helpPage {

        // ----------------------------------------------------
        // PAGE 1 — PRINCIPE MASTER / BACKUP
        // ----------------------------------------------------

        case 0:

            helpScreenshotShell(
                title:
                    "QLab Fallback"
            ) {

                HStack(
                    spacing: 22
                ) {

                    helpComputerCard(
                        title:
                            "MASTER",
                        subtitle:
                            "Spectacle principal",
                        icon:
                            "play.fill",
                        color:
                            .green
                    )


                    ZStack {

                        Capsule()
                            .fill(
                                purple.opacity(
                                    0.16
                                )
                            )
                            .frame(
                                width: 88,
                                height: 5
                            )


                        Image(
                            systemName:
                                "arrow.right"
                        )
                        .font(
                            .system(
                                size: 20,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(
                            purple
                        )
                        .offset(
                            x:
                                helpAnimationPulse
                                ? 22
                                : -22
                        )
                    }
                    .frame(
                        width: 92,
                        height: 48
                    )


                    helpComputerCard(
                        title:
                            "BACKUP",
                        subtitle:
                            "Secours prêt",
                        icon:
                            "shield.fill",
                        color:
                            helpAnimationPulse
                            ? .green
                            : .orange
                    )
                }
                .padding(
                    .vertical,
                    16
                )
            }


        // ----------------------------------------------------
        // PAGE 2 — RÉGLAGES OSC QLAB
        // ----------------------------------------------------

        case 1:

            helpScreenshotShell(
                title:
                    "QLab • Workspace Settings"
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 12
                ) {

                    HStack {

                        Label(
                            "OSC Access",
                            systemImage:
                                "network"
                        )
                        .font(
                            .system(
                                size: 13,
                                weight: .semibold
                            )
                        )


                        Spacer()


                        Text(
                            "Port 53000"
                        )
                        .font(
                            .system(
                                size: 11,
                                design:
                                    .monospaced
                            )
                        )
                        .foregroundStyle(
                            .secondary
                        )
                    }


                    HStack(
                        spacing: 12
                    ) {

                        VStack(
                            alignment: .leading,
                            spacing: 5
                        ) {

                            Text(
                                "Passcode"
                            )
                            .font(
                                .caption
                            )
                            .foregroundStyle(
                                .secondary
                            )


                            Text(
                                "1515"
                            )
                            .font(
                                .system(
                                    size: 17,
                                    weight: .bold,
                                    design:
                                        .monospaced
                                )
                            )
                        }
                        .padding(
                            10
                        )
                        .frame(
                            width: 115,
                            alignment:
                                .leading
                        )
                        .background(
                            RoundedRectangle(
                                cornerRadius: 9
                            )
                            .fill(
                                Color.white
                                    .opacity(0.05)
                            )
                        )


                        HStack(
                            spacing: 14
                        ) {

                            helpPermissionBadge(
                                "View"
                            )

                            helpPermissionBadge(
                                "Edit"
                            )

                            helpPermissionBadge(
                                "Control"
                            )
                        }
                        .padding(
                            10
                        )
                        .background(
                            RoundedRectangle(
                                cornerRadius: 9
                            )
                            .fill(
                                Color.green
                                    .opacity(
                                        helpAnimationPulse
                                        ? 0.16
                                        : 0.06
                                    )
                            )
                        )
                        .overlay {

                            RoundedRectangle(
                                cornerRadius: 9
                            )
                            .stroke(
                                Color.green
                                    .opacity(
                                        helpAnimationPulse
                                        ? 0.85
                                        : 0.20
                                    ),
                                lineWidth: 1.5
                            )
                        }
                    }


                    helpAnimatedPointer(
                        x:
                            helpAnimationPulse
                            ? 116
                            : 64,
                        y:
                            4
                    )
                }
                .padding(
                    16
                )
            }


        // ----------------------------------------------------
        // PAGE 3 — CHOIX RÔLE / DÉTECTION / CRÉATION
        // ----------------------------------------------------

        case 2:

            helpScreenshotShell(
                title:
                    "QLab Fallback"
            ) {

                VStack(
                    spacing: 14
                ) {

                    HStack(
                        spacing: 3
                    ) {

                        helpSegment(
                            "MASTER",
                            selected:
                                !helpAnimationPulse
                        )

                        helpSegment(
                            "BACKUP",
                            selected:
                                helpAnimationPulse
                        )
                    }


                    HStack {

                        Image(
                            systemName:
                                "doc.badge.gearshape"
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Text(
                            helpAnimationPulse
                            ? "Qlab Backup"
                            : "Workspace QLab"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .medium
                            )
                        )


                        Spacer()


                        Text(
                            helpAnimationPulse
                            ? "Détecté"
                            : "Détecter"
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(
                            helpAnimationPulse
                            ? .green
                            : .secondary
                        )
                    }
                    .padding(
                        .horizontal,
                        13
                    )
                    .frame(
                        height: 42
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: 10
                        )
                        .fill(
                            Color.white
                                .opacity(0.05)
                        )
                    )


                    HStack {

                        Spacer()


                        Text(
                            "Créer le fallback"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold
                            )
                        )
                        .padding(
                            .horizontal,
                            20
                        )
                        .frame(
                            height: 36
                        )
                        .background(
                            RoundedRectangle(
                                cornerRadius: 8
                            )
                            .fill(
                                purple
                                    .opacity(
                                        helpAnimationPulse
                                        ? 1.0
                                        : 0.62
                                    )
                            )
                        )
                        .overlay {

                            RoundedRectangle(
                                cornerRadius: 8
                            )
                            .stroke(
                                Color.white
                                    .opacity(
                                        helpAnimationPulse
                                        ? 0.30
                                        : 0.06
                                    ),
                                lineWidth: 1
                            )
                        }


                        Spacer()
                    }
                }
                .padding(
                    16
                )
                .overlay(
                    alignment:
                        .bottomTrailing
                ) {

                    helpAnimatedPointer(
                        x:
                            helpAnimationPulse
                            ? -150
                            : -225,
                        y:
                            -22
                    )
                }
            }


        // ----------------------------------------------------
        // PAGE 4 — TRANSFERT RÉEL
        // ----------------------------------------------------

        case 3:

            helpScreenshotShell(
                title:
                    "Création du fallback"
            ) {

                VStack(
                    spacing: 14
                ) {

                    HStack {

                        Label(
                            helpAnimationPulse
                            ? "Vérification SHA-256…"
                            : "Copie du workspace et des médias…",
                            systemImage:
                                helpAnimationPulse
                                ? "checkmark.shield"
                                : "arrow.left.arrow.right"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold
                            )
                        )


                        Spacer()


                        Text(
                            helpAnimationPulse
                            ? "100 %"
                            : "42 %"
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .bold,
                                design:
                                    .monospaced
                            )
                        )
                    }


                    GeometryReader {
                        geometry in

                        ZStack(
                            alignment:
                                .leading
                        ) {

                            Capsule()
                                .fill(
                                    Color.white
                                        .opacity(0.08)
                                )


                            Capsule()
                                .fill(
                                    helpAnimationPulse
                                    ? Color.green
                                    : purple
                                )
                                .frame(
                                    width:
                                        geometry.size.width
                                        * (
                                            helpAnimationPulse
                                            ? 1.0
                                            : 0.42
                                        )
                                )
                        }
                    }
                    .frame(
                        height: 8
                    )


                    HStack(
                        spacing: 20
                    ) {

                        helpMetric(
                            "Projet",
                            value:
                                "1,24 Go"
                        )

                        helpMetric(
                            "Vitesse",
                            value:
                                "82 Mo/s"
                        )

                        helpMetric(
                            "Espace",
                            value:
                                "118 Go"
                        )
                    }


                    HStack(
                        spacing: 7
                    ) {

                        Image(
                            systemName:
                                helpAnimationPulse
                                ? "checkmark.circle.fill"
                                : "clock"
                        )
                        .foregroundStyle(
                            helpAnimationPulse
                            ? .green
                            : .orange
                        )


                        Text(
                            helpAnimationPulse
                            ? "Fallback vérifié et prêt"
                            : "Transfert sécurisé en cours"
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .medium
                            )
                        )
                    }
                }
                .padding(
                    16
                )
            }


        // ----------------------------------------------------
        // PAGE 5 — VOYANT SYSTÈME / EXPLOITATION
        // ----------------------------------------------------

        default:

            helpScreenshotShell(
                title:
                    "Barre de menus macOS"
            ) {

                VStack(
                    spacing: 16
                ) {

                    HStack(
                        spacing: 17
                    ) {

                        Image(
                            systemName:
                                "speaker.wave.2.fill"
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Image(
                            systemName:
                                "wifi"
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        ZStack {

                            Circle()
                                .fill(
                                    (
                                        helpAnimationPulse
                                        ? Color.green
                                        : Color.orange
                                    )
                                    .opacity(0.30)
                                )
                                .frame(
                                    width: 30,
                                    height: 30
                                )


                            Circle()
                                .stroke(
                                    helpAnimationPulse
                                    ? Color.green
                                    : Color.orange,
                                    lineWidth: 1.6
                                )
                                .frame(
                                    width: 30,
                                    height: 30
                                )


                            Image(
                                systemName:
                                    helpAnimationPulse
                                    ? "checkmark.circle.fill"
                                    : "circle.dotted"
                            )
                            .foregroundStyle(
                                helpAnimationPulse
                                ? .green
                                : .orange
                            )
                        }
                        .shadow(
                            color:
                                (
                                    helpAnimationPulse
                                    ? Color.green
                                    : Color.orange
                                )
                                .opacity(0.60),
                            radius: 7
                        )


                        Image(
                            systemName:
                                "battery.75percent"
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Text(
                            "16:59"
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .medium
                            )
                        )
                    }


                    HStack(
                        spacing: 8
                    ) {

                        Circle()
                            .fill(
                                helpAnimationPulse
                                ? Color.green
                                : Color.orange
                            )
                            .frame(
                                width: 8,
                                height: 8
                            )


                        Text(
                            helpAnimationPulse
                            ? "BACKUP connecté • système prêt"
                            : "En attente du BACKUP"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(
                            helpAnimationPulse
                            ? .green
                            : .orange
                        )
                    }


                    Text(
                        "Un coup d’œil à la barre de menus suffit pour contrôler l’état de la redondance."
                    )
                    .font(
                        .system(
                            size: 11
                        )
                    )
                    .foregroundStyle(
                        .secondary
                    )
                    .multilineTextAlignment(
                        .center
                    )
                }
                .padding(
                    18
                )
            }
        }
    }


    // ========================================================
    // COMPOSANTS DES MINI-CAPTURES
    // ========================================================

    private func helpScreenshotShell<Content: View>(
        title: String,
        @ViewBuilder content:
            () -> Content
    ) -> some View {

        VStack(
            spacing: 0
        ) {

            HStack(
                spacing: 7
            ) {

                Circle()
                    .fill(
                        Color.red.opacity(0.85)
                    )
                    .frame(
                        width: 9,
                        height: 9
                    )

                Circle()
                    .fill(
                        Color.orange.opacity(0.85)
                    )
                    .frame(
                        width: 9,
                        height: 9
                    )

                Circle()
                    .fill(
                        Color.green.opacity(0.85)
                    )
                    .frame(
                        width: 9,
                        height: 9
                    )


                Spacer()


                Text(
                    title
                )
                .font(
                    .system(
                        size: 10,
                        weight: .medium
                    )
                )
                .foregroundStyle(
                    .secondary
                )


                Spacer()


                Color.clear
                    .frame(
                        width: 41,
                        height: 1
                    )
            }
            .padding(
                .horizontal,
                12
            )
            .frame(
                height: 30
            )
            .background(
                Color.white
                    .opacity(0.035)
            )


            Divider()
                .opacity(0.25)


            content()
                .frame(
                    maxWidth: .infinity,
                    minHeight: 150
                )
                .background(
                    Color.black
                        .opacity(0.18)
                )
        }
        .frame(
            width: 520
        )
        .background(
            .thinMaterial,
            in:
                RoundedRectangle(
                    cornerRadius: 15,
                    style: .continuous
                )
        )
        .overlay {

            RoundedRectangle(
                cornerRadius: 15,
                style: .continuous
            )
            .stroke(
                Color.white
                    .opacity(0.09),
                lineWidth: 1
            )
        }
        .shadow(
            color:
                Color.black.opacity(0.30),
            radius: 18,
            y: 8
        )
    }


    private func helpComputerCard(
        title: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {

        VStack(
            spacing: 8
        ) {

            ZStack {

                RoundedRectangle(
                    cornerRadius: 12
                )
                .fill(
                    color.opacity(0.13)
                )
                .frame(
                    width: 72,
                    height: 55
                )


                Image(
                    systemName:
                        icon
                )
                .font(
                    .system(
                        size: 24,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    color
                )
            }


            Text(title)
                .font(
                    .system(
                        size: 12,
                        weight: .bold
                    )
                )


            Text(subtitle)
                .font(
                    .system(
                        size: 10
                    )
                )
                .foregroundStyle(
                    .secondary
                )
        }
        .frame(
            width: 135
        )
    }


    private func helpPermissionBadge(
        _ title: String
    ) -> some View {

        HStack(
            spacing: 5
        ) {

            Image(
                systemName:
                    "checkmark.circle.fill"
            )
            .foregroundStyle(
                .green
            )


            Text(title)
                .font(
                    .system(
                        size: 11,
                        weight: .medium
                    )
                )
        }
    }


    private func helpSegment(
        _ title: String,
        selected: Bool
    ) -> some View {

        Text(title)
            .font(
                .system(
                    size: 11,
                    weight: .semibold
                )
            )
            .foregroundStyle(
                selected
                ? Color.white
                : Color.secondary
            )
            .frame(
                width: 96,
                height: 30
            )
            .background(
                RoundedRectangle(
                    cornerRadius: 7
                )
                .fill(
                    selected
                    ? purple
                    : Color.white
                        .opacity(0.05)
                )
            )
    }


    private func helpMetric(
        _ title: String,
        value: String
    ) -> some View {

        VStack(
            spacing: 3
        ) {

            Text(title)
                .font(
                    .system(
                        size: 10
                    )
                )
                .foregroundStyle(
                    .secondary
                )


            Text(value)
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
        }
    }


    private func helpAnimatedPointer(
        x: CGFloat,
        y: CGFloat
    ) -> some View {

        Image(
            systemName:
                "cursorarrow.rays"
        )
        .font(
            .system(
                size: 22,
                weight: .semibold
            )
        )
        .foregroundStyle(
            .white
        )
        .shadow(
            color:
                purple.opacity(0.9),
            radius:
                helpAnimationPulse
                ? 10
                : 3
        )
        .offset(
            x: x,
            y: y
        )
    }


    private var helpGuideTitle: String {

        switch helpPage {

        case 0:
            return "Deux Macs, un seul spectacle"

        case 1:
            return "Préparer QLab"

        case 2:
            return "Choisir MASTER et BACKUP"

        case 3:
            return "Tout doit être vert"

        default:
            return "Le BACKUP prend la main"
        }
    }


    private var helpGuideText: String {

        switch helpPage {

        case 0:

            return """
            Le MASTER exécute le spectacle.

            Build5 transfère les changements du projet. Leur application attend que le BACKUP soit inactif et isolé. Le statut Synchronisé exige une version appliquée et acquittée ; la reprise automatique dépend aussi du playhead et de l’isolation audio.
            """


        case 1:

            return """
            Sur le MASTER, ouvre le workspace QLab à sécuriser.

            Active OSC sur le port 53000, utilise le passcode 1515 et autorise View, Edit et Control.

            QLab Fallback détecte automatiquement le dossier projet. Pour copier les médias, ceux-ci doivent se trouver dans le dossier projet du spectacle.
            """


        case 2:

            return """
            Sur le Mac principal, sélectionne MASTER. Sur le Mac de secours, sélectionne BACKUP.

            Le BACKUP découvre automatiquement le MASTER sur le réseau local.

            Clique « Créer le fallback » : l'application contrôle d'abord l'espace disque disponible, puis le workspace et ses médias sont transférés et vérifiés par empreinte SHA-256. La copie reçue est ensuite ouverte automatiquement dans QLab.
            """


        case 3:

            return """
            Avant le spectacle, contrôle cette liste.

            QLab, le réseau, le heartbeat et le playhead doivent être synchronisés.

            Sur le BACKUP, les sorties doivent rester ISOLATED et le HOT STANDBY doit être ARMÉ.
            """


        default:

            return """
            Si le MASTER disparaît, le BACKUP passe en FAILOVER et ouvre ses sorties audio.

            Le retour du MASTER ne referme jamais automatiquement les sorties du BACKUP.

            Après stabilisation, utilise « Reprendre le son sur le MASTER » dans les Réglages avancés.
            """
        }
    }


    private var advancedSettingsView: some View {

        VStack(spacing: 0) {

            // En-tête fixe du contenu. La fermeture est assurée par le vrai
            // bouton de fenêtre macOS dans la barre de titre native.
            HStack(spacing: 12) {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text("Réglages avancés")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(
                        selectedRole == .master
                        ? "État technique du MASTER"
                        : "Tests, diagnostic et état technique du BACKUP"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    helpPage = 0
                    closeAdvancedSettingsWindow()

                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + 0.15
                    ) {
                        showHelpGuide = true
                    }

                } label: {

                    Label(
                        "Aide",
                        systemImage:
                            "questionmark.circle"
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial)

            Divider()

            ScrollViewReader { proxy in

                ScrollView {

                    VStack(
                        alignment: .leading,
                        spacing: 18
                    ) {

                        Color.clear
                            .frame(height: 0)
                            .id("advancedTop")

                GroupBox("Réseau et débit") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Connexion", selection: $networkDiscovery.selectedNetworkInterface) {
                            Text("Automatique — priorité Ethernet").tag("auto")
                            ForEach(networkDiscovery.networkInterfaces, id: \.name) { card in
                                Text((card.type == .wiredEthernet ? "Ethernet" : "Wi-Fi") + " · " + card.name).tag(card.name)
                            }
                            if networkDiscovery.selectedNetworkInterface != "auto" && !networkDiscovery.networkInterfaces.contains(where: { $0.name == networkDiscovery.selectedNetworkInterface }) {
                                Text("Indisponible · " + networkDiscovery.selectedNetworkInterface).tag(networkDiscovery.selectedNetworkInterface)
                            }
                        }
                        .disabled(networkDiscovery.networkChoiceLocked)
                        Text(networkDiscovery.activeNetworkDescription).font(.callout)
                        Text("Choisir avant d’activer Fallback. Une carte imposée ne bascule pas automatiquement sur le Wi-Fi.")
                            .font(.caption).foregroundStyle(.secondary)
                        if networkDiscovery.networkSpeedRunning {
                            HStack {
                                ProgressView().controlSize(.small)
                                Button("Arrêter le test") { networkDiscovery.cancelNetworkSpeedTest() }
                            }
                        } else {
                            Button("Tester le débit entre les deux Mac") { networkDiscovery.startNetworkSpeedTest() }
                                .disabled(!networkDiscovery.canTestNetworkSpeed)
                        }
                        Text(networkDiscovery.networkSpeedStatus).font(.callout)
                        Text("À lancer sur le BACKUP, cues arrêtées. Mesure réseau en mémoire, sans copier ni modifier le workspace (32 Mio, 30 secondes maximum).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox {

                    VStack(
                        alignment: .leading,
                        spacing: 11
                    ) {

                        Label(
                            "Transfert du projet QLab",
                            systemImage:
                                "arrow.left.arrow.right.circle.fill"
                        )
                        .font(.headline)


                        if selectedRole == .master {

                            advancedStatusRow(
                                "Dossier projet MASTER",
                                value:
                                    networkDiscovery
                                        .masterProjectFolderPath
                                    ?? "En attente de QLab",
                                systemImage:
                                    "folder",
                                color:
                                    networkDiscovery
                                        .masterProjectFolderPath
                                    != nil
                                    ? .green
                                    : .orange
                            )

                        } else {

                            advancedStatusRow(
                                "État du transfert",
                                value:
                                    networkDiscovery
                                        .workspaceTransferStatus,
                                systemImage:
                                    "externaldrive.badge.icloud",
                                color:
                                    networkDiscovery
                                        .workspaceTransferReady
                                    ? .green
                                    : (
                                        networkDiscovery
                                            .workspaceTransferError
                                        != nil
                                        ? .red
                                        : .orange
                                    )
                            )


                            if networkDiscovery
                                .workspaceTransferInProgress {

                                ProgressView(
                                    value:
                                        networkDiscovery
                                            .workspaceTransferProgress
                                )
                            }



                            if networkDiscovery
                                .workspaceTransferSourceBytes
                                > 0 {

                                advancedStatusRow(
                                    "Taille du projet",
                                    value:
                                        networkDiscovery
                                            .workspaceTransferSizeText,
                                    systemImage:
                                        "externaldrive",
                                    color:
                                        .secondary
                                )
                            }


                            if networkDiscovery
                                .workspaceTransferTotalBytes
                                > 0 {

                                advancedStatusRow(
                                    "Archive de transfert",
                                    value:
                                        networkDiscovery
                                            .workspaceTransferArchiveSizeText,
                                    systemImage:
                                        "archivebox",
                                    color:
                                        .secondary
                                )
                            }


                            if networkDiscovery
                                .workspaceTransferSpeedBytesPerSecond
                                > 0 {

                                advancedStatusRow(
                                    "Vitesse moyenne",
                                    value:
                                        networkDiscovery
                                            .workspaceTransferSpeedText,
                                    systemImage:
                                        "speedometer",
                                    color:
                                        .secondary
                                )
                            }


                            if networkDiscovery
                                .workspaceTransferAvailableDiskBytes
                                > 0 {

                                advancedStatusRow(
                                    "Espace disponible",
                                    value:
                                        networkDiscovery
                                            .workspaceTransferAvailableDiskText,
                                    systemImage:
                                        "internaldrive",
                                    color:
                                        .secondary
                                )
                            }


                            if let destination =
                                networkDiscovery
                                    .workspaceTransferDestinationPath {

                                advancedStatusRow(
                                    "Projet BACKUP",
                                    value:
                                        destination,
                                    systemImage:
                                        "folder.badge.checkmark",
                                    color:
                                        .green
                                )


                                Button {

                                    networkDiscovery
                                        .openWorkspaceTransferDestination()

                                } label: {

                                    Label(
                                        "Afficher le projet dans le Finder",
                                        systemImage:
                                            "folder"
                                    )
                                }
                                .buttonStyle(.bordered)
                            }


                            if let error =
                                networkDiscovery
                                    .workspaceTransferError {

                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            }

                            Divider()

                            advancedStatusRow(
                                "Live Mirror",
                                value: networkDiscovery.liveMirrorStatus,
                                systemImage: networkDiscovery.liveMirrorSynchronized
                                    ? "checkmark.circle.fill"
                                    : "arrow.triangle.2.circlepath",
                                color: networkDiscovery.liveMirrorSynchronized ? .green : .orange
                            )

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
                            .buttonStyle(.borderedProminent)
                            .disabled(!networkDiscovery.canRequestLiveMirrorResynchronization)

                            if let error = networkDiscovery.liveMirrorManualResyncError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }


                        Text(
                            "Le dossier projet complet est copié depuis le MASTER puis vérifié par SHA-256. Une copie existante n'est jamais écrasée."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                    }
                }


                GroupBox {

                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {

                        Label(
                            "Connexion QLab",
                            systemImage: "key.fill"
                        )
                        .font(.headline)


                        Text(
                            "Passcode OSC commun aux workspaces utilisés avec QLab Fallback."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)


                        OSCPasscodeEditor()

                        Text(
                            "QLab accepte un passcode OSC de 4 chiffres. Valeur recommandée pour Fallback : 1515."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)


                        HStack(spacing: 8) {

                            Image(
                                systemName:
                                    networkDiscovery
                                        .qlabAuthenticationOK
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                networkDiscovery
                                    .qlabAuthenticationOK
                                ? .green
                                : .secondary
                            )

                            Text(
                                "Authentification : "
                                + networkDiscovery
                                    .qlabAuthenticationStatus
                            )
                            .font(.caption)
                        }


                        Text(
                            networkDiscovery
                                .qlabPasscodeStatus
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                } label: {

                    Text("Sécurité OSC QLab")
                }
                // ====================================================
                // MASTER
                // ====================================================

                if selectedRole == .master {

                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "Rôle",
                                value: "MASTER",
                                systemImage:
                                    "desktopcomputer"
                            )

                            Divider()

                            advancedStatusRow(
                                "Version QLab",
                                value:
                                    networkDiscovery
                                        .qlabVersion
                                        .map { "QLab " + $0 }
                                    ?? "Non détectée",
                                systemImage:
                                    "number.circle"
                            )

                            advancedStatusRow(
                                "Compatibilité",
                                value:
                                    networkDiscovery
                                        .qlabCompatibilityStatus,
                                systemImage:
                                    networkDiscovery
                                        .qlabCompatibilityWarning
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill",
                                color:
                                    networkDiscovery
                                        .qlabCompatibilityWarning
                                    ? .orange
                                    : .green
                            )

                            advancedStatusRow(
                                "QLab OSC",
                                value:
                                    networkDiscovery
                                        .qlabOSCConnected
                                    ? "Connecté"
                                    : "Déconnecté",
                                systemImage:
                                    "dot.radiowaves.left.and.right",
                                color:
                                    networkDiscovery
                                        .qlabOSCConnected
                                    ? .green
                                    : .orange
                            )

                            advancedStatusRow(
                                "Publication réseau",
                                value:
                                    networkDiscovery
                                        .isPublishing
                                    ? "Active"
                                    : "Inactive",
                                systemImage:
                                    "antenna.radiowaves.left.and.right",
                                color:
                                    networkDiscovery
                                        .isPublishing
                                    ? .green
                                    : .orange
                            )

                            advancedStatusRow(
                                "BACKUP",
                                value:
                                    networkDiscovery
                                        .isConnected
                                    ? "Connecté"
                                    : "En attente",
                                systemImage:
                                    "laptopcomputer",
                                color:
                                    networkDiscovery
                                        .isConnected
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Heartbeat MASTER",
                                value:
                                    networkDiscovery
                                        .isConnected
                                    ? "Émis"
                                    : "En attente du BACKUP",
                                systemImage:
                                    "heart.fill",
                                color:
                                    networkDiscovery
                                        .isConnected
                                    ? .green
                                    : .secondary
                            )
                        }
                        .padding(4)

                    } label: {

                        Text("MASTER")
                    }


                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "Workspace",
                                value:
                                    workspaceName,
                                systemImage:
                                    "doc.fill"
                            )

                            advancedStatusRow(
                                "Playhead QLab",
                                value:
                                    networkDiscovery
                                        .masterPlayheadID
                                        .map {
                                            String(
                                                $0.prefix(8)
                                            )
                                        }
                                    ?? "—",
                                systemImage:
                                    "location.fill",
                                color:
                                    networkDiscovery
                                        .masterPlayheadID != nil
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Dernier événement",
                                value:
                                    networkDiscovery
                                        .lastMasterEventType
                                    ?? "—",
                                systemImage:
                                    "bolt.fill",
                                color:
                                    networkDiscovery
                                        .lastMasterEventType != nil
                                    ? .green
                                    : .secondary
                            )

                            if let cueID =
                                networkDiscovery
                                    .lastMasterEventCueID {

                                advancedStatusRow(
                                    "Cue du dernier événement",
                                    value:
                                        String(
                                            cueID.prefix(8)
                                        ),
                                    systemImage:
                                        "play.square"
                                )
                            }

                            advancedStatusRow(
                                "Séquence événements",
                                value:
                                    String(
                                        networkDiscovery
                                            .masterEventSequence
                                    ),
                                systemImage:
                                    "number"
                            )
                        }
                        .padding(4)

                    } label: {

                        Text("Synchronisation QLab")
                    }


                    GroupBox {

                        VStack(
                            alignment: .leading,
                            spacing: 10
                        ) {

                            Label(
                                networkDiscovery
                                    .isConnected
                                ? "Le MASTER transmet actuellement les événements au BACKUP."
                                : "Le MASTER attend la connexion d'un BACKUP.",
                                systemImage:
                                    networkDiscovery
                                        .isConnected
                                    ? "checkmark.circle.fill"
                                    : "clock"
                            )
                            .foregroundStyle(
                                networkDiscovery
                                    .isConnected
                                ? Color.green
                                : Color.secondary
                            )

                            Text(
                                "Le contrôle audio, l'isolation des sorties et le HOT STANDBY sont gérés uniquement sur la machine BACKUP."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(4)

                    } label: {

                        Text("Fonctionnement")
                    }


                    if networkDiscovery.qlabOSCError != nil
                        || networkDiscovery.lastError != nil {

                        GroupBox {

                            VStack(
                                alignment: .leading,
                                spacing: 8
                            ) {

                                if let error =
                                    networkDiscovery
                                        .qlabOSCError {

                                    Label(
                                        error,
                                        systemImage:
                                            "exclamationmark.triangle.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .lastError {

                                    Label(
                                        error,
                                        systemImage:
                                            "network.slash"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(4)

                        } label: {

                            Text("Diagnostic")
                        }
                    }


                // ====================================================
                // BACKUP
                // ====================================================

                } else {

                    GroupBox {

                        VStack(
                            alignment: .leading,
                            spacing: 12
                        ) {

                            Label(
                                "Test de bascule",
                                systemImage:
                                    "wrench.and.screwdriver.fill"
                            )
                            .font(.headline)

                            Text(
                                "Ces commandes sont réservées aux tests et à la maintenance."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)


                            if networkDiscovery.failoverActive {

                                VStack(
                                    alignment: .leading,
                                    spacing: 10
                                ) {

                                    Label(
                                        "FAILOVER ACTIF",
                                        systemImage:
                                            "bolt.shield.fill"
                                    )
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(.red)


                                    if networkDiscovery
                                        .failoverDeactivationPending {

                                        HStack(spacing: 8) {

                                            ProgressView()
                                                .controlSize(.small)

                                            Text(
                                                "Ré-isolation du BACKUP en cours…"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }

                                    } else {

                                        Button {

                                            networkDiscovery
                                                .deactivateFailoverManually()

                                        } label: {

                                            Label(
                                                "Reprendre le son sur le MASTER",
                                                systemImage:
                                                    "speaker.slash.fill"
                                            )
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: 34
                                            )
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.orange)
                                    }


                                    Text(
                                        "Le FAILOVER ne sera désactivé qu'après confirmation réelle du MUTE par QLab."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)

                            } else {

                                Button {

                                    networkDiscovery
                                        .simulateMasterLossForTest()

                                } label: {

                                    Label(
                                        "Simuler une perte du MASTER",
                                        systemImage:
                                            "exclamationmark.arrow.triangle.2.circlepath"
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 34
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(
                                    !isActive
                                    || !networkDiscovery
                                        .qlabOSCConnected
                                    || !networkDiscovery
                                        .backupAudioIsolationConfirmed
                                )

                                Text(
                                    "Déclenche la vraie chaîne de bascule audio du BACKUP."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }


                            if let error =
                                networkDiscovery
                                    .failoverActivationError {

                                Label(
                                    error,
                                    systemImage:
                                        "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }


                            if let error =
                                networkDiscovery
                                    .failoverDeactivationError {

                                Label(
                                    error,
                                    systemImage:
                                        "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(4)

                    } label: {

                        Text("Outils de test")
                    }


                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "Rôle",
                                value: "BACKUP",
                                systemImage:
                                    "desktopcomputer"
                            )

                            Divider()

                            advancedStatusRow(
                                "Version QLab",
                                value:
                                    networkDiscovery
                                        .qlabVersion
                                        .map { "QLab " + $0 }
                                    ?? "Non détectée",
                                systemImage:
                                    "number.circle"
                            )

                            advancedStatusRow(
                                "Compatibilité",
                                value:
                                    networkDiscovery
                                        .qlabCompatibilityStatus,
                                systemImage:
                                    networkDiscovery
                                        .qlabCompatibilityWarning
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill",
                                color:
                                    networkDiscovery
                                        .qlabCompatibilityWarning
                                    ? .orange
                                    : .green
                            )

                            advancedStatusRow(
                                "QLab OSC",
                                value:
                                    networkDiscovery
                                        .qlabOSCConnected
                                    ? "Connecté"
                                    : "Déconnecté",
                                systemImage:
                                    "dot.radiowaves.left.and.right",
                                color:
                                    networkDiscovery
                                        .qlabOSCConnected
                                    ? .green
                                    : .orange
                            )

                            advancedStatusRow(
                                "Contrôle audio",
                                value:
                                    networkDiscovery
                                        .backupAudioControlReady
                                    ? "Prêt"
                                    : "Non prêt",
                                systemImage:
                                    "speaker.wave.2",
                                color:
                                    networkDiscovery
                                        .backupAudioControlReady
                                    ? .green
                                    : .orange
                            )

                            advancedStatusRow(
                                "Isolation BACKUP",
                                value:
                                    networkDiscovery
                                        .backupAudioIsolationConfirmed
                                    ? "Confirmée"
                                    : "Non confirmée",
                                systemImage:
                                    "speaker.slash.fill",
                                color:
                                    networkDiscovery
                                        .backupAudioIsolationConfirmed
                                    ? .green
                                    : .orange
                            )

                            advancedStatusRow(
                                "HOT STANDBY",
                                value:
                                    networkDiscovery
                                        .hotStandbyExecutionArmed
                                    ? "Armé"
                                    : "Désarmé",
                                systemImage:
                                    "shield.checkered",
                                color:
                                    networkDiscovery
                                        .hotStandbyExecutionArmed
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Mode sortie",
                                value:
                                    networkDiscovery
                                        .backupOutputMode,
                                systemImage:
                                    "waveform"
                            )
                        }
                        .padding(4)

                    } label: {

                        Text("QLab et audio")
                    }


                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "MASTER",
                                value:
                                    networkDiscovery
                                        .isConnected
                                    ? "Connecté"
                                    : "Non connecté",
                                systemImage:
                                    "network",
                                color:
                                    networkDiscovery
                                        .isConnected
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Heartbeat",
                                value:
                                    networkDiscovery
                                        .heartbeatAlive
                                    ? "Actif"
                                    : "Absent",
                                systemImage:
                                    "heart.fill",
                                color:
                                    networkDiscovery
                                        .heartbeatAlive
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Liaison MASTER",
                                value:
                                    networkDiscovery
                                        .linkLost
                                    ? "PERDUE"
                                    : "Normale",
                                systemImage:
                                    networkDiscovery
                                        .linkLost
                                    ? "wifi.exclamationmark"
                                    : "wifi",
                                color:
                                    networkDiscovery
                                        .linkLost
                                    ? .red
                                    : .green
                            )

                            advancedStatusRow(
                                "BACKUP prêt à basculer",
                                value:
                                    networkDiscovery
                                        .failoverReady
                                    ? "Oui"
                                    : "Non",
                                systemImage:
                                    "bolt.horizontal.circle",
                                color:
                                    networkDiscovery
                                        .failoverReady
                                    ? .green
                                    : .secondary
                            )

                            advancedStatusRow(
                                "Playhead synchronisé",
                                value:
                                    networkDiscovery
                                        .playheadSyncReady
                                    ? "Oui"
                                    : "Non",
                                systemImage:
                                    "location.fill",
                                color:
                                    networkDiscovery
                                        .playheadSyncReady
                                    ? .green
                                    : .secondary
                            )
                        }
                        .padding(4)

                    } label: {

                        Text("Redondance")
                    }


                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "Workspace local",
                                value:
                                    networkDiscovery
                                        .localQLabWorkspace
                                    ?? workspaceName,
                                systemImage:
                                    "doc.fill"
                            )

                            advancedStatusRow(
                                "Workspace MASTER",
                                value:
                                    networkDiscovery
                                        .connectedWorkspace
                                    ?? "—",
                                systemImage:
                                    "doc.on.doc"
                            )

                            advancedStatusRow(
                                "Machine MASTER",
                                value:
                                    networkDiscovery
                                        .connectedMasterName
                                    ?? "—",
                                systemImage:
                                    "desktopcomputer"
                            )

                            advancedStatusRow(
                                "Session",
                                value:
                                    networkDiscovery
                                        .connectedSessionID
                                        .map {
                                            String(
                                                $0.prefix(8)
                                            )
                                        }
                                    ?? "—",
                                systemImage:
                                    "number"
                            )

                            if let summary =
                                networkDiscovery
                                    .backupAudioPatchSummary {

                                advancedStatusRow(
                                    "Patch audio",
                                    value: summary,
                                    systemImage:
                                        "slider.horizontal.3"
                                )
                            }
                        }
                        .padding(4)

                    } label: {

                        Text("Informations techniques")
                    }


                    if networkDiscovery.qlabOSCError != nil
                        || networkDiscovery
                            .backupAudioControlError != nil
                        || networkDiscovery
                            .failoverBlockedReason != nil
                        || networkDiscovery.lastError != nil {

                        GroupBox {

                            VStack(
                                alignment: .leading,
                                spacing: 8
                            ) {

                                if let error =
                                    networkDiscovery
                                        .qlabOSCError {

                                    Label(
                                        error,
                                        systemImage:
                                            "exclamationmark.triangle.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .backupAudioControlError {

                                    Label(
                                        error,
                                        systemImage:
                                            "speaker.badge.exclamationmark.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .failoverBlockedReason {

                                    Label(
                                        error,
                                        systemImage:
                                            "shield.slash.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .lastError {

                                    Label(
                                        error,
                                        systemImage:
                                            "network.slash"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(4)

                        } label: {

                            Text("Diagnostic")
                        }
                    }
                }


                Text(
                    selectedRole == .master
                    ? "Le MASTER supervise QLab et transmet les événements au BACKUP."
                    : "Ces informations sont destinées aux tests et au diagnostic. En exploitation normale, l'écran principal suffit."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                    }
                    .padding(20)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(
                            "advancedTop",
                            anchor: .top
                        )
                    }
                }
            }
        }
        .frame(
            minWidth: 500,
            maxWidth: .infinity,
            minHeight: 460,
            maxHeight: .infinity
        )
    }

    private func openAdvancedSettingsWindow() {

        if let controller = advancedSettingsWindowController,
           let window = controller.window,
           window.isVisible {

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostedView = AnyView(
            advancedSettingsView
                .environmentObject(networkDiscovery)
                .preferredColorScheme(.dark)
        )

        let hostingController = NSHostingController(
            rootView: hostedView
        )

        let window = NSWindow(
            contentViewController: hostingController
        )

        window.title = "Réglages avancés"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(
            width: 520,
            height: 500
        )
        window.setContentSize(
            NSSize(
                width: 680,
                height: 740
            )
        )
        window.setFrameAutosaveName(
            "QLabFallback.AdvancedSettingsWindow"
        )
        window.center()

        let controller = NSWindowController(
            window: window
        )

        advancedSettingsWindowController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }


    private func closeAdvancedSettingsWindow() {

        advancedSettingsWindowController?
            .window?
            .performClose(nil)

        advancedSettingsWindowController = nil
    }


    private var mainActionTitle: String {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return "Détecter un workspace"
        }

        if isActive {
            return "Arrêter"
        }

        return selectedRole == .master
            ? "Activer le MASTER"
            : "Activer le BACKUP"
    }

    private var mainActionIcon: String {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return "magnifyingglass"
        }

        return isActive
            ? "stop.fill"
            : "play.fill"
    }

    private var mainActionTint: Color {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return .gray
        }

        if isActive {
            return .red
        }

        return purple
    }

    private var mainActionButton: some View {
        Button {
            if selectedRole == .master && workspaceName == "Non détecté" {
                detectWorkspace()
                return
            }

            if selectedRole == .backup && isActive && masterDetected {
                networkDiscovery.stop()
                masterDetected = false
                isActive = false
                syncState = .ready
            } else {
                isActive.toggle()

                if isActive {
                    syncState = .syncing

                    if selectedRole == .backup {
                        masterDetected = false
                        networkDiscovery.startBackupSearch(workspace: workspaceName)
                    } else {

                        networkDiscovery.startMaster(workspace: workspaceName)
                    }
                } else {
                    networkDiscovery.stop()
                    masterDetected = false



                    showFallbackConfirmation = false
                    syncState = .ready
                }
            }
        } label: {
            Label(
                mainActionTitle,
                systemImage: mainActionIcon
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .semibold))
            .frame(
                minWidth: 220,
                idealWidth: 250,
                maxWidth: 300,
                minHeight: 40
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(mainActionTint)
    }


    private var roleSelector: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {
            Text("Rôle de cette machine")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Picker(
                "Rôle de cette machine",
                selection: $selectedRole
            ) {
                ForEach(Role.allCases) { role in
                    Text(role.rawValue)
                        .tag(role)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: 440)
    }


    private var workspacePanel: some View {

        VStack(
            alignment: .leading,
            spacing: 9
        ) {

            HStack {

                Text("Workspace QLab")
                    .font(
                        .system(
                            size: 13,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.secondary)

                Spacer()

                if availableWorkspaces.count > 1 {

                    Text(
                        "\(availableWorkspaces.count) ouverts"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }


            HStack(spacing: 12) {

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)


                if availableWorkspaces.count > 1 {

                    Menu {

                        ForEach(
                            Array(
                                availableWorkspaces.enumerated()
                            ),
                            id: \.offset
                        ) { _, name in

                            Button {

                                workspaceName = name

                                let duplicateCount =
                                    availableWorkspaces
                                        .filter {
                                            $0 == name
                                        }
                                        .count

                                if duplicateCount > 1 {

                                    workspaceDetectionError =
                                        "Plusieurs workspaces QLab portent le nom « \(name) ». Renomme-les pour éviter toute ambiguïté."

                                } else {

                                    workspaceDetectionError = nil
                                }

                            } label: {

                                HStack {

                                    Text(name)

                                    if workspaceName == name {

                                        Image(
                                            systemName:
                                                "checkmark"
                                        )
                                    }
                                }
                            }
                        }

                    } label: {

                        HStack(spacing: 7) {

                            Text(workspaceName)
                                .font(
                                    .system(
                                        size: 15,
                                        weight: .semibold
                                    )
                                )

                            Image(
                                systemName:
                                    "chevron.up.chevron.down"
                            )
                            .font(
                                .system(
                                    size: 10,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(isActive)

                } else {

                    Text(workspaceName)
                        .font(
                            .system(
                                size: 15,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }


                Spacer()


                Button {

                    detectWorkspace()

                } label: {

                    Label(
                        availableWorkspaces.isEmpty
                            ? "Détecter"
                            : "Actualiser",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isActive)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(
                .regularMaterial,
                in: RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
            )
            .overlay {

                RoundedRectangle(
                    cornerRadius: 14,
                    style: .continuous
                )
                .stroke(
                    Color.white.opacity(0.07),
                    lineWidth: 1
                )
            }


            if let error = workspaceDetectionError {

                Label(
                    error,
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
        .frame(maxWidth: 440)
    }


    private func detectWorkspace() {
        Task { await qlabDiscovery.refresh(); applyDiscoveredWorkspaces() }
    }

    private func applyDiscoveredWorkspaces() {
        availableWorkspaces = qlabDiscovery.workspaces
        workspaceDetectionError = qlabDiscovery.error
        if workspaceName == "Non détecté", let first = availableWorkspaces.first, !isActive {
            workspaceName = first
        }
        if availableWorkspaces.filter({ $0 == workspaceName }).count > 1 {
            workspaceDetectionError = "Plusieurs workspaces portent ce nom. Renommez-les pour éviter toute ambiguïté."
        } else if workspaceName != "Non détecté" && !availableWorkspaces.contains(workspaceName) {
            workspaceDetectionError = "Le workspace sélectionné est fermé."
        }
    }

    private func progressLine(
        _ text: String,
        done: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(
                systemName:
                    done
                    ? "checkmark.circle.fill"
                    : "circle"
            )
            .foregroundStyle(
                done
                ? Color.green
                : Color.secondary
            )

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return "Workspace non détecté"
        }

        if !isActive {
            return "Prêt"
        }

        return MirrorTransferDisplay.status(
            master: selectedRole == .master,
            connected: networkDiscovery.isConnected,
            synchronized: networkDiscovery.liveMirrorSynchronized,
            ready: networkDiscovery.workspaceTransferReady,
            transferring: networkDiscovery.workspaceTransferInProgress,
            error: networkDiscovery.workspaceTransferError,
            transferStatus: networkDiscovery.workspaceTransferStatus)
    }

    private var statusIconName: String {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return "questionmark.circle.fill"
        }

        switch syncState {
        case .ready:
            return isActive
                ? "circle.fill"
                : "checkmark.circle.fill"

        case .syncing:
            return "circle.dotted"

        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusDisplayColor: Color {
        if selectedRole == .master && workspaceName == "Non détecté" {
            return .orange
        }

        if isActive && !networkDiscovery.liveMirrorSynchronized { return .orange }
        return syncState.color
    }

    private var statusView: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusDisplayColor)

            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    Color.white.opacity(0.06),
                    lineWidth: 1
                )
        }
    }

}


struct FallbackLogo: View {

    var body: some View {
        Image(
            nsImage:
                NSImage(
                    contentsOfFile:
                        Bundle.main.path(
                            forResource: "QLabFallbackLogo",
                            ofType: "png"
                        ) ?? ""
                ) ?? NSImage()
        )
        .resizable()
        .scaledToFit()
    }
}


enum Role: String, CaseIterable, Identifiable {
    case master = "MASTER"
    case backup = "BACKUP"

    var id: String { rawValue }
}


enum SyncState {
    case ready
    case syncing
    case error

    var title: String {
        switch self {
        case .ready:
            return "Synchronisé"
        case .syncing:
            return "Synchronisation…"
        case .error:
            return "Fallback indisponible"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            return .green
        case .syncing:
            return .orange
        case .error:
            return .red
        }
    }
}
