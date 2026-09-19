import SwiftUI
import AppKit
import Network

struct ContentView: View {
    @State private var advancedSettingsWindowController: NSWindowController?

    @AppStorage("QLabFallback.Language") private var language = "system"
    @State private var showHelpGuide = false
    @State private var helpPage = 0

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

                    AppText("QLab Fallback")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer()
                    .frame(height: 10)

                roleSelector
                    .disabled(isActive)

                Spacer()
                    .frame(height: 12)

                workspacePanel
                    .disabled(isActive)
                if selectedRole == .backup {
                    BackupFolderView(store: networkDiscovery.backupFolder)
                        .padding(.top, 10)
                }

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
                        AppText("PRIMARY détecté")
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
                                        Text(verbatim: machine.name)
                                            .font(
                                                .system(
                                                    size: 14,
                                                    weight: .semibold
                                                )
                                            )
                                            .foregroundStyle(.white)

                                        AppText("PRIMARY QLab Fallback")
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
                        AppText("Créer le fallback de")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        AppText(
                            "« \(networkDiscovery.connectedWorkspace ?? workspaceName) » ?"
                        )
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                        AppText("Le workspace et ses médias seront copiés sur cette machine pour préparer QLab en secours.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)

                        Button {

                            showFallbackConfirmation =
                                false

                            networkDiscovery
                                .requestWorkspaceTransfer()

                        } label: {
                            AppText("Créer le fallback")
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
                        AppText(networkDiscovery.workspaceTransferStatus)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)

                        ProgressView(value: networkDiscovery.workspaceTransferProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 340)

                        AppText("\(Int(networkDiscovery.workspaceTransferProgress * 100)) %")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)


                        Button {

                            networkDiscovery
                                .cancelWorkspaceTransfer()

                        } label: {

                            AppLabel(
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

                            AppText(
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
                    AppLabel("Validation du fallback échouée : " + error, systemImage: "exclamationmark.triangle.fill")
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

                            AppText("TEST SORTIE BACKUP")
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .bold
                                    )
                                )
                                .foregroundStyle(.orange)

                            AppText(
                                L10n.format("MODE TEST ACTIF — %ld s", networkDiscovery.backupOutputTestRemainingSeconds)
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

                                AppText("Arrêter le test")
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

                                AppText("Sortie BACKUP isolée")
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

                                    AppText(
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

                            AppText(
                                "Test audio local — durée 30 secondes"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }

                        if let testError =
                            networkDiscovery.backupOutputTestError {

                            AppText(testError)
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

                                AppText("TEST SORTIE BACKUP")
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

                                    AppText(
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

                                AppText(
                                    L10n.format("Arrêt automatique dans %ld s", networkDiscovery.backupOutputTestRemainingSeconds)
                                )
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                                Button {
                                    networkDiscovery
                                        .stopBackupOutputTest()
                                } label: {

                                    AppText("Arrêter le test")
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

                                        AppText(
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

                                        AppText(
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

                                        AppText(
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

                                AppText(
                                    "Test temporaire de 30 secondes"
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                        }

                        if let testError =
                            networkDiscovery.backupOutputTestError {

                            AppText(testError)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                }

                if !networkDiscovery.recoveryStatus.isEmpty {
                    VStack(spacing: 8) {
                        AppText(networkDiscovery.recoveryStatus)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        if selectedRole == .backup && networkDiscovery.failoverActive {
                            Button("Reprendre le son sur le PRIMARY") { networkDiscovery.requestMasterReturn() }
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

                            AppLabel(
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

                            AppText(
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

                        AppText(error)
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

                            AppLabel(
                                "Réglages avancés",
                                systemImage: "gearshape"
                            )
                        }
                        .buttonStyle(.plain)


                        Button {

                            helpPage = 0
                            showHelpGuide = true

                        } label: {

                            AppLabel(
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
        .onReceive(NotificationCenter.default.publisher(for: .qlabShowHelp)) { note in
            helpPage = note.object as? Int ?? 0
            showHelpGuide = true
        }
        .environment(\.locale, Locale(identifier: L10n.languageCode(language)))
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
                    AppText("PRIMARY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    AppLabel(
                        networkDiscovery.liveMirrorSynchronized ? "Synchronisé" : "Miroir en attente",
                        systemImage: networkDiscovery.liveMirrorSynchronized ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(networkDiscovery.liveMirrorSynchronized ? .green : .orange)
                }

                AppText("BACKUP connecté")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                AppText("Workspace : \(workspaceName)")
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
                    AppText("BACKUP")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    AppLabel(
                        "En attente",
                        systemImage: "circle.dotted"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                }

                AppText(networkDiscovery.isConnected ? "PRIMARY connecté · validation en attente" : "En attente du PRIMARY")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                AppLabel(
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
                    AppText("BACKUP")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    AppLabel(
                        networkDiscovery.liveMirrorSynchronized ? "Synchronisé" : "Miroir en attente",
                        systemImage: networkDiscovery.liveMirrorSynchronized ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(networkDiscovery.liveMirrorSynchronized ? .green : .orange)
                }

                AppText("PRIMARY connecté")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                if let masterName =
                    networkDiscovery.connectedMasterName {

                    AppLabel(
                        masterName,
                        systemImage: "desktopcomputer"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                if let workspace =
                    networkDiscovery.connectedWorkspace {

                    AppText("Workspace : \(workspace)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }


                Button {
                    networkDiscovery.requestLiveMirrorResynchronization()
                } label: {
                    AppLabel(
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
                    AppText(error)
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

            AppText(title)
                .foregroundStyle(.primary)

            Spacer()

            Text(verbatim: ["Workspace PRIMARY", "Workspace local", "Machine PRIMARY", "Dossier projet PRIMARY", "Projet BACKUP"].contains(title) ? value : L10n.text(value))
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

                    AppText("QLab Fallback")
                        .font(.title2)
                        .fontWeight(.semibold)

                    AppText("Guide de démarrage")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AppText("\(helpPage + 1) / 5")
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

                        AppText(helpGuideTitle)
                            .font(.title2)
                            .fontWeight(.semibold)


                        AppText(helpGuideText)
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

                            AppText(
                                "Passcode QLab"
                            )
                            .foregroundStyle(.secondary)

                            AppText("1515")
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

                                AppLabel(
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

                    }
                    .keyboardShortcut(
                        .defaultAction
                    )

                } else {

                    Button("Commencer") {

                        onboardingCompleted = true
                        showHelpGuide = false
                        helpPage = 0


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
    }


    private var helpGuideVisual: some View { TutorialDiagram(page: helpPage) }

    private var helpGuideTitle: String {

        switch helpPage {

        case 0:
            return "Deux Macs, un seul spectacle"

        case 1:
            return "Préparer QLab"

        case 2:
            return "Choisir PRIMARY et BACKUP"

        case 3:
            return "Tout doit être vert"

        default:
            return "Le BACKUP prend la main"
        }
    }


    private var helpGuideText: String { L10n.text("help.body.\(helpPage)") }

    private var advancedSettingsView: some View {

        VStack(spacing: 0) {

            // En-tête fixe du contenu. La fermeture est assurée par le vrai
            // bouton de fenêtre macOS dans la barre de titre native.
            HStack(spacing: 12) {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    AppText("Réglages avancés")
                        .font(.title2)
                        .fontWeight(.semibold)

                    AppText(
                        selectedRole == .master
                        ? "État technique du PRIMARY"
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

                    AppLabel(
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
                            AppText("Automatique — priorité Ethernet").tag("auto")
                            ForEach(networkDiscovery.networkInterfaces, id: \.name) { card in
                                AppText((card.type == .wiredEthernet ? "Ethernet" : "Wi-Fi") + " · " + card.name).tag(card.name)
                            }
                            if networkDiscovery.selectedNetworkInterface != "auto" && !networkDiscovery.networkInterfaces.contains(where: { $0.name == networkDiscovery.selectedNetworkInterface }) {
                                AppText("Indisponible · " + networkDiscovery.selectedNetworkInterface).tag(networkDiscovery.selectedNetworkInterface)
                            }
                        }
                        .disabled(networkDiscovery.networkChoiceLocked)
                        AppText(networkDiscovery.activeNetworkDescription).font(.callout)
                        AppText("Choisir avant d’activer Fallback. Une carte imposée ne bascule pas automatiquement sur le Wi-Fi.")
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
                        AppText(networkDiscovery.networkSpeedStatus).font(.callout)
                        AppText("À lancer sur le BACKUP, cues arrêtées. Mesure réseau en mémoire, sans copier ni modifier le workspace (32 Mio, 30 secondes maximum).")
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

                        AppLabel(
                            "Transfert du projet QLab",
                            systemImage:
                                "arrow.left.arrow.right.circle.fill"
                        )
                        .font(.headline)


                        if selectedRole == .master {

                            advancedStatusRow(
                                "Dossier projet PRIMARY",
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

                                    AppLabel(
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

                                AppText(error)
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
                                AppLabel(
                                    networkDiscovery.liveMirrorManualResyncRunning
                                        ? "Relance en cours…"
                                        : "Relancer la synchronisation",
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!networkDiscovery.canRequestLiveMirrorResynchronization)

                            if let error = networkDiscovery.liveMirrorManualResyncError {
                                AppText(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }


                        AppText(
                            "Le dossier projet complet est copié depuis le PRIMARY puis vérifié par SHA-256. Une copie existante n'est jamais écrasée."
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

                        AppLabel(
                            "Connexion QLab",
                            systemImage: "key.fill"
                        )
                        .font(.headline)


                        AppText(
                            "Passcode OSC commun aux workspaces utilisés avec QLab Fallback."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)


                        OSCPasscodeEditor()

                        AppText(
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

                            AppText(
                                "Authentification : "
                                + networkDiscovery
                                    .qlabAuthenticationStatus
                            )
                            .font(.caption)
                        }


                        AppText(
                            networkDiscovery
                                .qlabPasscodeStatus
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                } label: {

                    AppText("Sécurité OSC QLab")
                }
                // ====================================================
                // PRIMARY
                // ====================================================

                if selectedRole == .master {

                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "Rôle",
                                value: "PRIMARY",
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
                                "Heartbeat PRIMARY",
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

                        AppText("PRIMARY")
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

                        AppText("Synchronisation QLab")
                    }


                    GroupBox {

                        VStack(
                            alignment: .leading,
                            spacing: 10
                        ) {

                            AppLabel(
                                networkDiscovery
                                    .isConnected
                                ? "Le PRIMARY transmet actuellement les événements au BACKUP."
                                : "Le PRIMARY attend la connexion d'un BACKUP.",
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

                            AppText(
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

                        AppText("Fonctionnement")
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

                                    AppLabel(
                                        error,
                                        systemImage:
                                            "exclamationmark.triangle.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .lastError {

                                    AppLabel(
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

                            AppText("Diagnostic")
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

                            AppLabel(
                                "Test de bascule",
                                systemImage:
                                    "wrench.and.screwdriver.fill"
                            )
                            .font(.headline)

                            AppText(
                                "Ces commandes sont réservées aux tests et à la maintenance."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)


                            if networkDiscovery.failoverActive {

                                VStack(
                                    alignment: .leading,
                                    spacing: 10
                                ) {

                                    AppLabel(
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

                                            AppText(
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

                                            AppLabel(
                                                "Reprendre le son sur le PRIMARY",
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


                                    AppText(
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

                                    AppLabel(
                                        "Simuler une perte du PRIMARY",
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

                                AppText(
                                    "Déclenche la vraie chaîne de bascule audio du BACKUP."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }


                            if let error =
                                networkDiscovery
                                    .failoverActivationError {

                                AppLabel(
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

                                AppLabel(
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

                        AppText("Outils de test")
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

                        AppText("QLab et audio")
                    }


                    GroupBox {

                        VStack(spacing: 11) {

                            advancedStatusRow(
                                "PRIMARY",
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
                                "QLab PRIMARY",
                                value: networkDiscovery.heartbeatAlive && networkDiscovery.primaryQLabHealthy ? "Disponible" : "Indisponible",
                                systemImage: "app.connected.to.app.below.fill",
                                color: networkDiscovery.heartbeatAlive && networkDiscovery.primaryQLabHealthy ? .green : .orange
                            )

                            advancedStatusRow(
                                "Liaison PRIMARY",
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

                        AppText("Redondance")
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
                                "Workspace PRIMARY",
                                value:
                                    networkDiscovery
                                        .connectedWorkspace
                                    ?? "—",
                                systemImage:
                                    "doc.on.doc"
                            )

                            advancedStatusRow(
                                "Machine PRIMARY",
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

                        AppText("Informations techniques")
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

                                    AppLabel(
                                        error,
                                        systemImage:
                                            "exclamationmark.triangle.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .backupAudioControlError {

                                    AppLabel(
                                        error,
                                        systemImage:
                                            "speaker.badge.exclamationmark.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .failoverBlockedReason {

                                    AppLabel(
                                        error,
                                        systemImage:
                                            "shield.slash.fill"
                                    )
                                }

                                if let error =
                                    networkDiscovery
                                        .lastError {

                                    AppLabel(
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

                            AppText("Diagnostic")
                        }
                    }
                }


                AppText(
                    selectedRole == .master
                    ? "Le PRIMARY supervise QLab et transmet les événements au BACKUP."
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
            AdvancedSettingsHost(manager: networkDiscovery, role: $selectedRole) { advancedSettingsView }
        )

        let hostingController = NSHostingController(
            rootView: hostedView
        )

        let window = NSWindow(
            contentViewController: hostingController
        )

        window.title = L10n.text("Réglages avancés")
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
            ? "Activer le PRIMARY"
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
                if !isActive && selectedRole == .backup && !networkDiscovery.prepareBackupFolder() { return }
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
            AppLabel(
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
            Picker(
                "PRIMARY / BACKUP",
                selection: $selectedRole
            ) {
                ForEach(Role.allCases) { role in
                    AppText(role.rawValue)
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

                AppText("Workspace QLab")
                    .font(
                        .system(
                            size: 13,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.secondary)

                Spacer()

                if availableWorkspaces.count > 1 {

                    AppText(
                        L10n.format("Workspaces ouverts : %ld", availableWorkspaces.count)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }


            HStack(spacing: 12) {

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)


                if !availableWorkspaces.isEmpty {

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
                                        "Plusieurs workspaces portent ce nom. Renommez-les pour éviter toute ambiguïté."

                                } else {

                                    workspaceDetectionError = nil
                                }

                            } label: {

                                HStack {

                                    Text(verbatim: name)

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

                            Text(verbatim: workspaceName == "Non détecté" ? L10n.text(workspaceName) : workspaceName)
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

                    Text(verbatim: workspaceName == "Non détecté" ? L10n.text(workspaceName) : workspaceName)
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

                    AppLabel(
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

                AppLabel(
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

            AppText(text)
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

            AppText(statusText)
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
    case master = "PRIMARY"
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
