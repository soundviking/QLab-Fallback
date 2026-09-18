import Foundation
import Network
import AppKit

@MainActor
final class NetworkDiscovery: ObservableObject {

    @Published var networkInterfaces: [NWInterface] = []
    @Published var selectedNetworkInterface = UserDefaults.standard.string(forKey: "NetworkInterface") ?? "auto" {
        didSet { UserDefaults.standard.set(selectedNetworkInterface, forKey: "NetworkInterface") }
    }
    @Published var networkSpeedRunning = false
    @Published var networkSpeedStatus = "Test disponible sur le BACKUP, hors lecture."
    private let networkPathMonitor = NWPathMonitor()
    private var binaryTransfer: WorkspaceBinaryTransfer?
    private var binaryTransferGeneration = UUID()
    private var speedProbe: NetworkSpeedProbe?
    private var speedID: String?
    private var speedTask: Task<Void, Never>?
    var networkChoiceLocked: Bool { runtimeRole != .idle }
    var activeNetworkDescription: String {
        guard isConnected, let path = activeConnection?.currentPath else { return "Aucune liaison établie" }
        if path.usesInterfaceType(.wiredEthernet) { return "Liaison Ethernet" }
        if path.usesInterfaceType(.wifi) { return "Liaison Wi-Fi" }
        return "Liaison réseau établie"
    }
    var canTestNetworkSpeed: Bool {
        runtimeRole == .backup && isConnected && qlabOSCConnected && !networkSpeedRunning
            && !workspaceTransferInProgress && !liveMirrorReloading && !failoverActive
            && !failoverTakeoverLatched && !returnInProgress && !backupOutputTestActive
    }
    @Published var liveMirrorSynchronized = false
    @Published var liveMirrorStatus = "Live Mirror : en attente"
    @Published var liveMirrorReloadConditionsConfirmed = false
    @Published var liveMirrorReloading = false
    @Published var liveMirrorManualResyncRunning = false
    @Published var liveMirrorManualResyncError: String?
    private var liveMirrorMissedGo = false
    private var initialApplyTask: Task<Void, Never>?
    private var validatedInitialWorkspaceID: String?
    private lazy var liveMirror = makeLiveMirror()

    var canRequestLiveMirrorResynchronization: Bool {
        runtimeRole == .backup
            && isConnected
            && qlabOSCConnected
            && workspaceTransferReady
            && !workspaceTransferInProgress
            && !liveMirrorReloading
            && !liveMirrorManualResyncRunning
            && !failoverActive
            && !failoverTakeoverLatched
            && !failoverPending
            && !returnInProgress
            && !backupOutputTestActive
            && backupOutputMode == "ISOLATED"
            && backupAudioIsolationConfirmed
            && hotStandbyOutputIsolationConfirmed
    }

    private enum RuntimeRole {
        case idle
        case master
        case backup
    }

    struct RemoteMachine: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (
            lhs: RemoteMachine,
            rhs: RemoteMachine
        ) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published var discoveredMasters: [RemoteMachine] = []
    @Published var isPublishing = false
    @Published var isBrowsing = false
    @Published var isConnected = false
    @Published var connectedMasterName: String?
    @Published var connectedWorkspace: String?
    @Published var connectedSessionID: String?
    @Published var protocolVersion: Int?
    @Published var lastError: String?
    @Published var heartbeatAlive = false
    @Published var lastHeartbeatAt: Date?
    @Published private(set) var primaryQLabHealthy = false
    private var backupTestStartedReady = false
    @Published var linkLost = false
    @Published var linkLostAt: Date?

    @Published var failoverPending = false
    @Published var failoverPreparedAt: Date?
    @Published var failoverReason: String?

    @Published var localQLabAvailable = false
    @Published var localQLabWorkspace: String?
    @Published var localQLabWorkspaceMatchesMaster = false

    @Published var failoverReady = false
    @Published var failoverBlockedReason: String?

    @Published var masterPlayheadID: String?
    @Published var backupTargetPlayheadID: String?
    @Published var lastPlayheadUpdateAt: Date?
    @Published var playheadSyncReady = false
    @Published var backupPlayheadAppliedID: String?
    @Published var backupPlayheadAppliedAt: Date?
    @Published var backupPlayheadSyncError: String?

    @Published var lastMasterEventType: String?
    @Published var lastMasterEventCueID: String?
    @Published var lastMasterEventAt: Date?
    @Published var masterEventSequence: Int = 0

    @Published var lastBackupObservedEventType: String?
    @Published var lastBackupObservedEventCueID: String?
    @Published var lastBackupObservedEventAt: Date?

    @Published var lastBackupEventSequence: Int = 0
    @Published var duplicateMasterEventCount: Int = 0
    @Published var staleMasterEventCount: Int = 0
    @Published var missingMasterEventCount: Int = 0

    @Published var simulatedFailoverAction: String?
    @Published var simulatedFailoverCueID: String?
    @Published var simulatedFailoverDecisionAt: Date?
    @Published var simulatedFailoverBlockedReason: String?

    @Published var hotStandbyEnabled = true
    @Published var hotStandbyExecutionArmed = false
    @Published var hotStandbyOutputIsolationConfirmed = false

    @Published var lastMirroredAction: String?
    @Published var lastMirroredCueID: String?
    @Published var lastMirroredActionAt: Date?
    @Published var hotStandbyBlockedReason: String?

    // --------------------------------------------------------
    // TEST SORTIE BACKUP
    // --------------------------------------------------------

    @Published var backupOutputTestActive = false
    @Published var backupOutputTestStartedAt: Date?
    @Published var backupOutputTestEndsAt: Date?
    @Published var backupOutputTestRemainingSeconds: Int = 0
    @Published var backupOutputTestError: String?

    // ISOLATED / TEST / FAILOVER
    @Published var backupOutputMode: String = "ISOLATED"

    @Published var qlabOSCConnected = false
    @Published var qlabOSCWorkspaceID: String?
    @Published var qlabOSCError: String?
    @Published var qlabOSCStatus: String?

    @Published var qlabAuthenticationStatus =
        "Non vérifiée"

    @Published var qlabAuthenticationOK = false

    @Published var qlabPasscodeStatus =
        "Passcode enregistré dans le Trousseau"

    @Published var qlabVersion: String?
    @Published var qlabCompatibilityStatus =
        "Version QLab non détectée"
    @Published var qlabCompatibilityValidated = false
    @Published var qlabCompatibilityWarning = false

    @Published var backupAudioControlReady = false
    @Published var backupAudioIsolationConfirmed = false
    @Published var backupAudioPatchSummary: String?
    @Published var backupAudioControlError: String?

    @Published var failoverActive = false
    @Published var failoverActivatedAt: Date?
    @Published var failoverActivationError: String?
    @Published var failoverTakeoverLatched = false

    @Published var failoverDeactivationPending = false
    @Published var failoverDeactivationError: String?

    // ========================================================
    // TRANSFERT WORKSPACE + MÉDIAS
    // ========================================================

    @Published var masterProjectFolderPath:
        String?

    @Published var workspaceTransferInProgress =
        false

    @Published var workspaceTransferReady =
        false

    @Published var workspaceTransferProgress:
        Double = 0.0

    @Published var workspaceTransferStatus =
        "En attente"

    @Published var workspaceTransferError:
        String?

    @Published var workspaceTransferBytes:
        Int64 = 0

    @Published var workspaceTransferTotalBytes:
        Int64 = 0

    @Published var workspaceTransferDestinationPath:
        String?


    @Published var workspaceTransferSpeedBytesPerSecond:
        Double = 0

    @Published var workspaceTransferSourceBytes:
        Int64 = 0

    @Published var workspaceTransferAvailableDiskBytes:
        Int64 = 0

    @Published var workspaceTransferRequiredDiskBytes:
        Int64 = 0

    @Published var workspaceTransferMasterConfirmed =
        false


    private let serviceType = "_qlabfallback._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var activeConnection: NWConnection?
    private var discoveryGeneration = UUID()
    private var backupRetryTask: Task<Void, Never>?
    private var backupHandshakeTask: Task<Void, Never>?
    private var selectedMasterID: String?

    // Never choose an arbitrary MASTER or reconnect across a pending takeover.
    private func connectDiscoveredMasterIfNeeded() {
        guard runtimeRole == .backup, activeConnection == nil,
              !isConnected else { return }
        let candidates = discoveredMasters.filter {
            selectedMasterID == nil || $0.id == selectedMasterID
        }
        guard candidates.count == 1, let machine = candidates.first else { return }
        connect(to: machine)
    }

    private func finishBackupConnection(_ connection: NWConnection, reason: String) {
        guard runtimeRole == .backup, activeConnection === connection else { return }
        if binaryTransfer != nil { finishWorkspaceTransferWithError("Liaison perdue pendant le transfert") }
        let hadSession = connectedSessionID != nil
        activeConnection = nil // Invalidate callbacks before cancellation.
        backupHandshakeTask?.cancel()
        backupHandshakeTask = nil
        connection.cancel()
        isConnected = false
        heartbeatAlive = false
        receiveBuffer.removeAll()
        lastError = reason
        if hadSession { markLinkLost(reason: reason) }
    }


    private var masterControlReceiveBuffer =
        Data()

    private var workspaceTransferReceiveHandle:
        FileHandle?

    private var workspaceTransferReceiveURL:
        URL?

    private var workspaceTransferExpectedSHA256:
        String?

    private var workspaceTransferID:
        String?

    private var workspaceTransferProjectName =
        ""

    private var workspaceTransferCancelled =
        false

    private var workspaceTransferSendHandle:
        FileHandle?

    private var workspaceTransferArchiveURL:
        URL?

    private var workspaceTransferSentBytes:
        Int64 = 0


    private var workspaceTransferStartedAt:
        Date?


    private var workspaceTransferConfirmationTask:
        Task<Void, Never>?
    private var masterWorkspace = ""
    private var masterSessionID = UUID().uuidString
    private var receiveBuffer = Data()
    private var qlabOSCClient: QLabOSCClient?
    @Published var recoveryStatus = ""
    @Published var masterReturnReady = false
    @Published var masterReturning = false
    @Published var returnInProgress = false
    private var recoveryMonitor: Task<Void, Never>?
    private var recoveryOperation: Task<Void, Never>?
    private var recoveryOperationID = UUID()
    private var recoveryToken: String?
    private var recoveryRequest: (id: String, sent: Double)?
    private var recoveryLastReady = Date.distantPast
    private var recoveryState: RecoverySnapshot?
    private var recoveryStateAt: Double = 0
    private var recoveryMasterIsolated = false
    private var returnToken: String?
    private var completedReturnToken: String?
    private lazy var recoveryIO: RecoveryIO = {
        let io = RecoveryIO()
        io.run = self.runQLab
        io.client = { [weak self] in self?.qlabOSCClient }
        io.identity = { [weak self] in self?.qlabOSCWorkspaceID }
        return io
    }()
    private var selectionRequestSentAt: (cue: String, at: Double)?
    private var failoverAudioRequestedAt: Double?
    private var audioVerificationGeneration = UUID()
    private var audioVerificationDeadline = 0.0
    private var selectionRequestTask: Task<Void, Never>?
    private var backupObservedPlayheadID: String?
    private var lastBackupSelectionRequest: String?
    private var remoteSelectionEchoes = [String: Date]()
    private var selectionRequestIDs = [String]()
    private let makeOSCClient: () -> QLabOSCClient

    private let runQLab: (String, [String]) async throws -> String
    init(makeOSCClient: @escaping () -> QLabOSCClient = { QLabOSCClient() },
         runQLab: @escaping (String, [String]) async throws -> String = MirrorQLab.run) {
        self.makeOSCClient = makeOSCClient
        self.runQLab = runQLab
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkInterfaces = path.availableInterfaces.filter { $0.type == .wiredEthernet || $0.type == .wifi }.sorted { $0.name < $1.name }
            }
        }
        networkPathMonitor.start(queue: DispatchQueue(label: "qlab.interfaces"))
    }
    deinit { networkPathMonitor.cancel() }
    private func networkParameters() throws -> NWParameters {
        let parameters = ResponsivenessPolicy.tcpParameters()
        if selectedNetworkInterface != "auto" {
            guard let selected = networkInterfaces.first(where: { $0.name == selectedNetworkInterface }) else {
                throw MirrorFailure.invalid("Carte réseau choisie indisponible : " + selectedNetworkInterface)
            }
            parameters.requiredInterface = selected
        }
        return parameters
    }

    // ========================================================
    // WATCHDOG QLAB LOCAL
    // ========================================================

    private var qlabWatchdogTask: Task<Void, Never>?

    private let qlabWatchdogIntervalNanoseconds:
        UInt64 = ResponsivenessPolicy.qlabProbe

    private let qlabWatchdogTimeout:
        TimeInterval = ResponsivenessPolicy.qlabTimeout

    private var lastQLabOSCResponseAt: Date?

    private var qlabWatchdogLost = false

    private var qlabMonitoredWorkspace = ""

    private struct BackupAudioPatch {
        let id: String
        let name: String
        let routing: [Int]
        let baselineMuted: Set<Int>

        var controlledOutputs: [Int] {
            routing.filter {
                !baselineMuted.contains($0)
            }
        }
    }

    // ----------------------------------------------------
    // MÉMOIRE PERSISTANTE DES SORTIES AUDIO GÉRÉES
    // PAR QLAB FALLBACK
    //
    // Permet de distinguer après redémarrage :
    // - les mutes posés par QLab Fallback ;
    // - les mutes déjà présents côté opérateur.
    // ----------------------------------------------------

    private let backupAudioOwnershipDefaults: UserDefaults = {
        let current =
            UserDefaults(
                suiteName: "fr.viking.qlabfallback"
            ) ?? .standard

        let key = "ManagedAudioOutputs.v1"

        // Migration depuis l'ancien namespace utilisé
        // pendant les versions de développement.
        //
        // Ne copie l'ancienne valeur que si la nouvelle
        // installation n'en possède pas encore.
        if current.object(forKey: key) == nil,
           let legacy =
               UserDefaults(
                   suiteName: "com.s2a.qlabfallback"
               ),
           let legacyValue =
               legacy.object(forKey: key) {

            current.set(
                legacyValue,
                forKey: key
            )
        }

        return current
    }()

    private let backupAudioOwnershipKey =
        "ManagedAudioOutputs.v1"

    private func managedAudioOutputs(
        for patchID: String
    ) -> Set<Int> {

        guard
            let dictionary =
                backupAudioOwnershipDefaults.dictionary(
                    forKey: backupAudioOwnershipKey
                ),
            let raw =
                dictionary[patchID] as? [Any]
        else {
            return []
        }

        return Set(
            raw.compactMap {
                value -> Int? in

                if let number =
                    value as? NSNumber {

                    return number.intValue
                }

                return nil
            }
        )
    }

    private func saveManagedAudioOutputs(
        _ outputs: Set<Int>,
        for patchID: String
    ) {

        var dictionary =
            backupAudioOwnershipDefaults.dictionary(
                forKey: backupAudioOwnershipKey
            ) ?? [:]

        if outputs.isEmpty {

            dictionary.removeValue(
                forKey: patchID
            )

        } else {

            dictionary[patchID] =
                outputs.sorted()
        }

        backupAudioOwnershipDefaults.set(
            dictionary,
            forKey: backupAudioOwnershipKey
        )
    }

    private var backupAudioPatches:
        [BackupAudioPatch] = []

    private var backupAudioVerificationTargetMuted:
        Bool?

    private var failoverActivationPending = false

    private var backupAudioVerifiedPatchIDs:
        Set<String> = []
    private var runtimeRole: RuntimeRole = .idle
    var isMasterRuntime: Bool { runtimeRole == .master }
    var isBackupRuntime: Bool { runtimeRole == .backup }

    private var seenMasterEventIDs: Set<String> = []
    private var seenMasterEventOrder: [String] = []

    private let maxSeenMasterEvents = 1000
    private let maxMasterEventAge: TimeInterval = 2.0
    private var eventClock = MirrorEventClock()
    private var clockProbe: (id: String, sent: Double)?

    private var backupOutputTestTask: Task<Void, Never>?
    private let backupOutputTestDuration: TimeInterval = 30.0

    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatMonitorTask: Task<Void, Never>?

    private let heartbeatIntervalNanoseconds: UInt64 =
        ResponsivenessPolicy.heartbeat

    private let heartbeatMonitorIntervalNanoseconds: UInt64 =
        ResponsivenessPolicy.monitor

    private let heartbeatTimeout: TimeInterval =
        ResponsivenessPolicy.peerTimeout


    // Un transfert volumineux partage la connexion TCP
    // avec le heartbeat. On conserve 0,9 s en exploitation,
    // mais on tolère davantage pendant une copie active.
    private var effectiveHeartbeatTimeout:
        TimeInterval {

        (workspaceTransferInProgress || networkSpeedRunning)
            ? 6.0
            : heartbeatTimeout
    }

    private func sendJSON(
        _ payload: [String: Any],
        on connection: NWConnection
    ) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload
        ) else {
            return
        }

        var framedData = data
        framedData.append(0x0A)

        connection.send(
            content: framedData,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor in
                        guard self?.activeConnection === connection else { return }
                        self?.lastError = error.localizedDescription
                    }
                }
            }
        )
    }



    // ========================================================
    // TRANSFERT WORKSPACE / MÉDIAS
    // ========================================================

    var workspaceTransferSizeText: String {

        guard workspaceTransferSourceBytes > 0 else {
            return "—"
        }

        return ByteCountFormatter.string(
            fromByteCount:
                workspaceTransferSourceBytes,
            countStyle:
                .file
        )
    }


    var workspaceTransferArchiveSizeText: String {

        guard workspaceTransferTotalBytes > 0 else {
            return "—"
        }

        return ByteCountFormatter.string(
            fromByteCount:
                workspaceTransferTotalBytes,
            countStyle:
                .file
        )
    }


    var workspaceTransferSpeedText: String {

        guard workspaceTransferSpeedBytesPerSecond > 0 else {
            return "—"
        }

        let value =
            ByteCountFormatter.string(
                fromByteCount:
                    Int64(
                        workspaceTransferSpeedBytesPerSecond
                    ),
                countStyle:
                    .file
            )

        return value + "/s"
    }


    var workspaceTransferAvailableDiskText: String {

        guard workspaceTransferAvailableDiskBytes > 0 else {
            return "—"
        }

        return ByteCountFormatter.string(
            fromByteCount:
                workspaceTransferAvailableDiskBytes,
            countStyle:
                .file
        )
    }


    func openWorkspaceTransferDestination() {

        guard
            let path =
                workspaceTransferDestinationPath
        else {
            return
        }


        NSWorkspace.shared
            .activateFileViewerSelecting(
                [
                    URL(
                        fileURLWithPath:
                            path
                    )
                ]
            )
    }


    private func handleWorkspaceBasePathOSC(
        address: String,
        arguments: [String]
    ) {

        guard address.contains(
            "/basePath"
        ) else {
            return
        }


        print(
            "QLab basePath : réponse reçue :",
            address,
            "|",
            arguments
        )


        guard
            let raw =
                arguments.first,
            let data =
                raw.data(
                    using: .utf8
                ),
            let json =
                try?
                JSONSerialization
                    .jsonObject(
                        with: data
                    )
                    as? [String: Any]
        else {

            print(
                "QLab basePath : réponse JSON illisible"
            )

            return
        }


        let status =
            json["status"]
                as? String
            ?? ""


        guard status == "ok" else {

            print(
                "QLab basePath : QLab a refusé la demande —",
                status,
                json
            )

            return
        }


        guard
            let rawPath =
                json["data"]
                    as? String
        else {

            print(
                "QLab basePath : champ data absent ou non textuel —",
                json
            )

            return
        }


        let trimmed =
            rawPath
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )


        guard !trimmed.isEmpty else {

            print(
                "QLab basePath : workspace non enregistré ou chemin vide"
            )

            if runtimeRole == .master {

                masterProjectFolderPath =
                    nil
            }

            return
        }


        let path =
            WorkspaceTransferSupport
                .normalizedPath(
                    from:
                        trimmed
                )


        guard runtimeRole == .master else {

            print(
                "QLab basePath : réponse reçue sur BACKUP — ignorée pour la source"
            )

            return
        }


        masterProjectFolderPath =
            path


        print(
            "========================================"
        )

        print(
            "MASTER : DOSSIER PROJET QLAB DÉTECTÉ"
        )

        print(
            path
        )

        print(
            "========================================"
        )
    }


    func requestWorkspaceTransfer() {

        guard !workspaceTransferInProgress else {

            workspaceTransferError =
                "Un transfert est déjà en cours"

            workspaceTransferStatus =
                "Transfert déjà en cours"

            return
        }


        guard runtimeRole == .backup else {

            workspaceTransferError =
                "La création du fallback doit être lancée depuis le BACKUP"

            return
        }


        guard
            isConnected,
            let connection =
                activeConnection
        else {

            workspaceTransferError =
                "BACKUP non connecté au MASTER"

            return
        }


        workspaceTransferCancelled =
            false

        workspaceTransferReady =
            false
        validatedInitialWorkspaceID = nil
        liveMirrorReloadConditionsConfirmed = false

        workspaceTransferMasterConfirmed =
            false

        workspaceTransferInProgress =
            true

        workspaceTransferProgress =
            0

        workspaceTransferBytes =
            0

        workspaceTransferTotalBytes =
            0

        workspaceTransferSourceBytes =
            0

        workspaceTransferSpeedBytesPerSecond =
            0

        workspaceTransferAvailableDiskBytes =
            0

        workspaceTransferRequiredDiskBytes =
            0

        workspaceTransferMasterConfirmed =
            false

        workspaceTransferStartedAt =
            Date()

        workspaceTransferDestinationPath =
            nil

        workspaceTransferError =
            nil

        workspaceTransferStatus =
            "Demande du projet au MASTER…"


        workspaceTransferStatus = "Vérification des médias déjà présents…"
        let requestGeneration = UUID().uuidString
        workspaceTransferID = requestGeneration
        let session = connectedSessionID ?? ""
        let name = connectedWorkspace ?? ""
        Task { [weak self] in
            let hashes = await Task.detached(priority: .userInitiated) {
                do {
                    let root = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Documents/QLab Fallback")
                    return try WorkspaceTransferSupport.availableMedia(in: root, cache: MirrorFiles.cacheRoot())
                } catch {
                    MirrorDiagnostics.log("TRANSFERT inventaire local indisponible, copie complète : \(error.localizedDescription)")
                    return Set<String>()
                }
            }.value
            guard let self, self.workspaceTransferID == requestGeneration,
                  !self.workspaceTransferCancelled, self.activeConnection === connection else { return }
            self.workspaceTransferStatus = "Demande du projet au MASTER…"
            MirrorDiagnostics.log("TRANSFERT inventaire : \(hashes.count) fichiers locaux vérifiés")
            self.sendJSON(["type": "TRANSFER_REQUEST", "sessionID": session, "workspace": name,
                "binaryTransferVersion": 1, "availableMediaSHA256": hashes.sorted()], on: connection)
        }

    }


    func cancelWorkspaceTransfer() {
        stopBinaryTransfer()

        workspaceTransferCancelled =
            true

        workspaceTransferInProgress =
            false

        workspaceTransferStatus =
            "Transfert annulé"


        workspaceTransferReceiveHandle?
            .closeFile()

        workspaceTransferReceiveHandle =
            nil


        if let url =
            workspaceTransferReceiveURL {

            try?
                FileManager.default
                    .removeItem(
                        at: url
                    )
        }


        workspaceTransferReceiveURL =
            nil


        if runtimeRole == .backup,
           let connection =
            activeConnection {

            sendJSON(
                [
                    "type":
                        "TRANSFER_CANCEL",
                    "transferID":
                        workspaceTransferID
                        ?? ""
                ],
                on: connection
            )
        }
    }


    private func receiveBackupMessages(
        on connection: NWConnection
    ) {

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) {
            [weak self]
            data,
            _,
            isComplete,
            error in


            Task { @MainActor in

                guard let self, self.activeConnection === connection else {
                    return
                }


                if let error {
                    if self.binaryTransfer != nil { self.finishWorkspaceTransferWithError("Liaison de contrôle interrompue : " + error.localizedDescription) }
                    print(
                        "MASTER réception contrôle :",
                        error.localizedDescription
                    )

                    return
                }


                if let data,
                   !data.isEmpty {

                    self
                        .masterControlReceiveBuffer
                        .append(
                            data
                        )


                    guard self.masterControlReceiveBuffer.count <= 8 * 1024 * 1024 else {
                        self.lastError = "Trame MASTER/BACKUP trop volumineuse"
                        connection.cancel(); return
                    }
                    while let newline =
                        self
                            .masterControlReceiveBuffer
                            .firstIndex(
                                of: 0x0A
                            ) {

                        let line =
                            Data(
                                self
                                    .masterControlReceiveBuffer[
                                        ..<newline
                                    ]
                            )


                        self
                            .masterControlReceiveBuffer
                            .removeSubrange(
                                ...newline
                            )


                        guard
                            !line.isEmpty,
                            let object =
                                try?
                                JSONSerialization
                                    .jsonObject(
                                        with: line
                                    )
                                    as?
                                    [String: Any],
                            let type =
                                object["type"]
                                    as? String
                        else {
                            continue
                        }


                        if type.hasPrefix("SPEED_") {
                            self.handleSpeedFrame(object, on: connection)
                            continue
                        }
                        if type.hasPrefix("RECOVERY_") {
                            self.handleRecovery(object, on: connection)
                            continue
                        }
                        if type.hasPrefix("MIRROR_") {
                            self.liveMirror.enqueue(object)
                            continue
                        }

                        switch type {

                        case "BACKUP_SELECTION":
                            self.receiveBackupSelection(object, on: connection)

                        case "EVENT_CLOCK_REQUEST":
                            guard object["sessionID"] as? String == self.masterSessionID,
                                  let probe = object["probeID"] as? String else { continue }
                            self.sendJSON(["type": "EVENT_CLOCK_REPLY", "sessionID": self.masterSessionID,
                                "probeID": probe, "monotonicTime": ProcessInfo.processInfo.systemUptime], on: connection)

                        case "TRANSFER_REQUEST":

                            if self.workspaceTransferInProgress {

                                self.sendJSON(
                                    [
                                        "type":
                                            "TRANSFER_REJECT",
                                        "message":
                                            "Le MASTER traite déjà un transfert"
                                    ],
                                    on:
                                        connection
                                )

                            } else {

                                self.startMasterWorkspaceTransfer(on: connection,
                                    binary: object["binaryTransferVersion"] as? Int == 1, availableMedia: Set((object["availableMediaSHA256"] as? [String] ?? [])
                                        .prefix(8192).filter(MirrorFiles.validHash)))
                            }


                        case "TRANSFER_CANCEL":

                            self.workspaceTransferConfirmationTask?
                                .cancel()

                            self.workspaceTransferConfirmationTask =
                                nil

                            self.workspaceTransferCancelled =
                                true

                            self.workspaceTransferInProgress =
                                false

                            self.workspaceTransferStatus =
                                "Transfert annulé par le BACKUP"

                            self.cleanupMasterWorkspaceTransfer(
                                removeStatus:
                                    false
                            )


                        case "TRANSFER_REJECT":

                            self.workspaceTransferConfirmationTask?
                                .cancel()

                            self.workspaceTransferConfirmationTask =
                                nil

                            self.workspaceTransferCancelled =
                                true

                            self.workspaceTransferReady =
                                false

                            self.workspaceTransferInProgress =
                                false

                            self.workspaceTransferError =
                                object["message"]
                                    as? String
                                ?? "Transfert refusé par le BACKUP"

                            self.workspaceTransferStatus =
                                "BACKUP non prêt pour le transfert"

                            self.cleanupMasterWorkspaceTransfer(
                                removeStatus:
                                    false
                            )


                        case "TRANSFER_APPLY_FAILED":
                            guard object["transferID"] as? String == self.workspaceTransferID,
                                  object["sessionID"] as? String == self.masterSessionID else { continue }
                            self.workspaceTransferMasterConfirmed = false
                            self.finishWorkspaceTransferWithError(object["message"] as? String ?? "Validation QLab BACKUP échouée")

                        case "TRANSFER_COMPLETE":
                            guard object["transferID"] as? String == self.workspaceTransferID,
                                  object["applied"] as? Bool == true else { continue }


                            self.workspaceTransferConfirmationTask?
                                .cancel()

                            self.workspaceTransferConfirmationTask =
                                nil

                            self.workspaceTransferMasterConfirmed =
                                true

                            self.workspaceTransferReady =
                                true

                            self.workspaceTransferInProgress =
                                false

                            self.workspaceTransferProgress =
                                1

                            self.workspaceTransferStatus =
                                "Fallback confirmé par le BACKUP"

                            self.workspaceTransferError =
                                nil


                            print(
                                "MASTER : fallback confirmé par le BACKUP"
                            )


                        default:
                            break
                        }
                    }
                }


                guard !isComplete else {
                    if self.binaryTransfer != nil { self.finishWorkspaceTransferWithError("Liaison de contrôle fermée pendant le transfert") }
                    return
                }


                self.receiveBackupMessages(
                    on: connection
                )
            }
        }
    }


    private func startMasterWorkspaceTransfer(
        on connection: NWConnection, binary: Bool = false, availableMedia: Set<String> = []
    ) {

        guard runtimeRole == .master else {
            return
        }


        guard
            let sourcePath =
                masterProjectFolderPath,
            !sourcePath.isEmpty
        else {

            sendJSON(
                [
                    "type":
                        "TRANSFER_ERROR",
                    "message":
                        "Dossier projet QLab MASTER non détecté"
                ],
                on: connection
            )

            return
        }


        let sourceURL =
            URL(
                fileURLWithPath:
                    sourcePath
            )


        var sourceIsDirectory:
            ObjCBool = false


        guard
            FileManager.default
                .fileExists(
                    atPath:
                        sourceURL.path,
                    isDirectory:
                        &sourceIsDirectory
                ),
            sourceIsDirectory.boolValue
        else {

            let message =
                "Le dossier projet QLab MASTER n'existe plus"


            workspaceTransferInProgress =
                false

            workspaceTransferReady =
                false

            workspaceTransferError =
                message

            workspaceTransferStatus =
                "Dossier source introuvable"


            sendJSON(
                [
                    "type":
                        "TRANSFER_ERROR",
                    "message":
                        message
                ],
                on:
                    connection
            )


            return
        }


        let projectName =
            sourceURL
                .lastPathComponent


        let transferID =
            UUID().uuidString


        workspaceTransferID =
            transferID

        workspaceTransferCancelled =
            false

        workspaceTransferReady =
            false

        workspaceTransferInProgress =
            true

        workspaceTransferProgress =
            0

        workspaceTransferBytes =
            0

        workspaceTransferTotalBytes =
            0

        workspaceTransferError =
            nil

        workspaceTransferStatus =
            "Préparation du projet…"


        let workspaceID = qlabOSCWorkspaceID ?? ""
        Task.detached(priority: .userInitiated) {
            [weak self] in


            do {

                let sourceSize =
                    try WorkspaceTransferSupport
                        .directorySize(
                            of:
                                sourceURL
                        )


                let archive =
                    try await WorkspaceTransferSupport.makePortableArchive(
                        sourceDirectory: sourceURL, workspaceID: workspaceID, availableMedia: availableMedia)


                let attributes =
                    try FileManager.default
                        .attributesOfItem(
                            atPath:
                                archive.path
                        )


                let size =
                    (
                        attributes[.size]
                        as? NSNumber
                    )?.int64Value
                    ?? 0


                let hash =
                    try WorkspaceTransferSupport
                        .sha256(
                            of: archive
                        )


                Task { @MainActor in

                    guard let self else {
                        return
                    }


                    guard
                        !self.workspaceTransferCancelled,
                        self.workspaceTransferID == transferID, self.activeConnection === connection
                    else {

                        try?
                            FileManager.default
                                .removeItem(
                                    at: archive
                                )

                        return
                    }


                    self.workspaceTransferArchiveURL =
                        archive

                    self.workspaceTransferTotalBytes =
                        size

                    self.workspaceTransferSourceBytes =
                        sourceSize

                    self.workspaceTransferSentBytes =
                        0

                    self.workspaceTransferStartedAt =
                        Date()

                    self.workspaceTransferStatus =
                        "Envoi vers le BACKUP…"


                    if binary {
                        self.startBinaryWorkspaceSend(archive: archive, size: size, sourceSize: sourceSize,
                            hash: hash, projectName: projectName, transferID: transferID, connection: connection)
                        return
                    }

                    do {

                        self.workspaceTransferSendHandle =
                            try FileHandle(
                                forReadingFrom:
                                    archive
                            )

                    } catch {

                        self.finishWorkspaceTransferWithError(
                            "Lecture archive impossible : "
                            + error.localizedDescription
                        )

                        return
                    }


                    self.sendJSONWithCompletion(
                        [
                            "type":
                                "TRANSFER_START",
                            "transferID":
                                transferID,
                            "workspace":
                                self.masterWorkspace,
                            "projectName":
                                projectName,
                            "size":
                                size,
                            "sourceSize":
                                sourceSize,
                            "sha256":
                                hash
                        ],
                        on: connection
                    ) {
                        error in


                        Task { @MainActor in

                            if let error {

                                self
                                    .finishWorkspaceTransferWithError(
                                        error.localizedDescription
                                    )

                                return
                            }


                            self.sendNextWorkspaceTransferChunk(
                                on: connection,
                                transferID:
                                    transferID
                            )
                        }
                    }
                }


            } catch {

                Task { @MainActor in

                    guard let self else {
                        return
                    }


                    self.finishWorkspaceTransferWithError(
                        error.localizedDescription
                    )


                    self.sendJSON(
                        [
                            "type":
                                "TRANSFER_ERROR",
                            "message":
                                error.localizedDescription
                        ],
                        on: connection
                    )
                }
            }
        }
    }


    private func sendNextWorkspaceTransferChunk(
        on connection: NWConnection,
        transferID: String
    ) {

        guard
            !workspaceTransferCancelled, workspaceTransferID == transferID,
            activeConnection === connection
        else {

            cleanupMasterWorkspaceTransfer()

            return
        }


        guard
            let handle =
                workspaceTransferSendHandle
        else {

            finishWorkspaceTransferWithError(
                "Flux archive MASTER indisponible"
            )

            return
        }


        do {

            // 64 Ko :
            // suffisamment rapide en réseau local,
            // tout en laissant respirer heartbeat et UI.
            let chunk =
                try handle.read(
                    upToCount:
                        64 * 1024
                ) ?? Data()


            guard !chunk.isEmpty else {

                handle.closeFile()

                workspaceTransferSendHandle =
                    nil


                sendJSONWithCompletion(
                    [
                        "type":
                            "TRANSFER_END",
                        "transferID":
                            transferID
                    ],
                    on: connection
                ) {
                    [weak self] error in


                    Task { @MainActor in

                        guard let self else {
                            return
                        }


                        guard self.workspaceTransferID == transferID, self.activeConnection === connection else { return }
                        if let error {

                            self.finishWorkspaceTransferWithError(
                                error.localizedDescription
                            )

                        } else {

                            self.workspaceTransferProgress =
                                1

                            self.workspaceTransferStatus =
                                "Projet envoyé — vérification du BACKUP…"


                            self.startWorkspaceTransferConfirmationTimeout()
                        }


                        self.cleanupMasterWorkspaceTransfer(
                            removeStatus:
                                false
                        )
                    }
                }

                return
            }


            let payload: [String: Any] = [
                "type":
                    "TRANSFER_CHUNK",
                "transferID":
                    transferID,
                "data":
                    chunk
                        .base64EncodedString()
            ]


            sendJSONWithCompletion(
                payload,
                on: connection
            ) {
                [weak self]
                error in


                Task { @MainActor in

                    guard let self else {
                        return
                    }


                    guard self.workspaceTransferID == transferID, self.activeConnection === connection else { return }
                    if let error {

                        self.finishWorkspaceTransferWithError(
                            error.localizedDescription
                        )

                        return
                    }


                    self.workspaceTransferSentBytes +=
                        Int64(
                            chunk.count
                        )


                    self.workspaceTransferBytes =
                        self.workspaceTransferSentBytes


                    if let started =
                        self.workspaceTransferStartedAt {

                        let elapsed =
                            Date()
                                .timeIntervalSince(
                                    started
                                )


                        if elapsed > 0.20 {

                            self.workspaceTransferSpeedBytesPerSecond =
                                Double(
                                    self.workspaceTransferSentBytes
                                )
                                / elapsed
                        }
                    }


                    if self.workspaceTransferTotalBytes
                        > 0 {

                        self.workspaceTransferProgress =
                            min(
                                0.99,
                                Double(
                                    self.workspaceTransferSentBytes
                                )
                                /
                                Double(
                                    self.workspaceTransferTotalBytes
                                )
                            )
                    }


                    self.sendNextWorkspaceTransferChunk(
                        on: connection,
                        transferID:
                            transferID
                    )
                }
            }


        } catch {

            finishWorkspaceTransferWithError(
                error.localizedDescription
            )
        }
    }


    private func startWorkspaceTransferConfirmationTimeout() {

        workspaceTransferConfirmationTask?
            .cancel()


        workspaceTransferConfirmationTask =
            Task { [weak self] in

                try? await Task.sleep(
                    nanoseconds:
                        120_000_000_000
                )


                guard !Task.isCancelled else {
                    return
                }


                guard let self else {
                    return
                }


                guard
                    self.workspaceTransferInProgress,
                    !self.workspaceTransferMasterConfirmed
                else {
                    return
                }


                self.workspaceTransferInProgress =
                    false

                self.workspaceTransferReady =
                    false

                self.workspaceTransferError =
                    "Le BACKUP n'a pas confirmé l'installation dans le délai prévu"

                self.workspaceTransferStatus =
                    "Confirmation BACKUP absente"


                print(
                    "MASTER : timeout confirmation transfert BACKUP"
                )
            }
    }


    private func sendJSONWithCompletion(
        _ payload: [String: Any],
        on connection: NWConnection,
        completion:
            @escaping (Error?) -> Void
    ) {

        guard
            let data =
                try?
                JSONSerialization
                    .data(
                        withJSONObject:
                            payload
                    )
        else {

            completion(
                NSError(
                    domain:
                        "QLabFallback.Transfer",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Encodage transfert impossible"
                    ]
                )
            )

            return
        }


        var framed =
            data

        framed.append(
            0x0A
        )


        connection.send(
            content: framed,
            completion:
                .contentProcessed {
                    error in

                    completion(
                        error
                    )
                }
        )
    }


    private func handleWorkspaceTransferMessage(
        _ object: [String: Any]
    ) {

        guard runtimeRole == .backup else {
            return
        }


        guard
            let type =
                object["type"]
                    as? String
        else {
            return
        }


        switch type {

        case "TRANSFER_START":

            guard
                let transferID =
                    object["transferID"]
                        as? String,
                let projectName =
                    object["projectName"]
                        as? String,
                let hash =
                    object["sha256"]
                        as? String
            else {

                finishWorkspaceTransferWithError(
                    "Métadonnées du projet invalides"
                )

                return
            }


            let size =
                (
                    object["size"]
                    as? NSNumber
                )?.int64Value
                ?? 0


            let sourceSize =
                (
                    object["sourceSize"]
                    as? NSNumber
                )?.int64Value
                ?? size


            guard UUID(uuidString: transferID) != nil, MirrorFiles.validHash(hash),
                  size > 0, sourceSize >= 0, size < Int64.max / 4, sourceSize < Int64.max / 4 else {
                finishWorkspaceTransferWithError("Métadonnées du projet invalides")
                return
            }
            stopBinaryTransfer()

            let documentsURL =
                FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Documents",
                        isDirectory:
                            true
                    )


            let availableDisk =
                WorkspaceTransferSupport
                    .availableDiskSpace(
                        at:
                            documentsURL
                    )


            // Pendant l'installation, le BACKUP doit
            // temporairement contenir l'archive ET le
            // dossier extrait. On ajoute 512 Mo de marge.
            let safetyMargin:
                Int64 =
                    512 * 1024 * 1024


            let requiredDisk =
                size
                + sourceSize
                + safetyMargin


            workspaceTransferAvailableDiskBytes =
                availableDisk

            workspaceTransferRequiredDiskBytes =
                requiredDisk

            workspaceTransferSourceBytes =
                sourceSize


            if availableDisk > 0,
               availableDisk < requiredDisk {

                let requiredText =
                    ByteCountFormatter.string(
                        fromByteCount:
                            requiredDisk,
                        countStyle:
                            .file
                    )


                let availableText =
                    ByteCountFormatter.string(
                        fromByteCount:
                            availableDisk,
                        countStyle:
                            .file
                    )


                let message =
                    "Espace disque insuffisant : "
                    + requiredText
                    + " nécessaires, "
                    + availableText
                    + " disponibles"


                finishWorkspaceTransferWithError(
                    message
                )


                if let connection =
                    activeConnection {

                    sendJSON(
                        [
                            "type":
                                "TRANSFER_REJECT",
                            "transferID":
                                transferID,
                            "message":
                                message
                        ],
                        on:
                            connection
                    )
                }


                return
            }


            workspaceTransferID =
                transferID

            workspaceTransferProjectName =
                projectName

            workspaceTransferExpectedSHA256 =
                hash

            workspaceTransferTotalBytes =
                size

            workspaceTransferBytes =
                0

            workspaceTransferSpeedBytesPerSecond =
                0

            workspaceTransferStartedAt =
                Date()

            workspaceTransferProgress =
                0

            workspaceTransferReady =
                false

            workspaceTransferInProgress =
                true

            workspaceTransferError =
                nil

            workspaceTransferStatus =
                "Réception du projet…"


            let receiveURL =
                FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent(
                        "QLab-Fallback-Receive-"
                        + transferID
                        + ".zip"
                    )


            try?
                FileManager.default
                    .removeItem(
                        at: receiveURL
                    )


            FileManager.default
                .createFile(
                    atPath:
                        receiveURL.path,
                    contents: nil
                )


            do {

                workspaceTransferReceiveHandle =
                    try FileHandle(
                        forWritingTo:
                            receiveURL
                    )

                workspaceTransferReceiveURL =
                    receiveURL

            } catch {

                finishWorkspaceTransferWithError(
                    "Création fichier BACKUP impossible : "
                    + error.localizedDescription
                )
            }


            if object["transport"] as? String == "binary-v1", workspaceTransferReceiveURL != nil {
                workspaceTransferReceiveHandle?.closeFile(); workspaceTransferReceiveHandle = nil
                startBinaryWorkspaceReceive(object)
            }

        case "TRANSFER_CHUNK":

            guard
                workspaceTransferInProgress,
                let transferID =
                    object["transferID"]
                        as? String,
                transferID ==
                    workspaceTransferID,
                let encoded =
                    object["data"]
                        as? String,
                let chunk =
                    Data(
                        base64Encoded:
                            encoded
                    ),
                let handle =
                    workspaceTransferReceiveHandle
            else {
                return
            }


            do {

                try handle.write(
                    contentsOf:
                        chunk
                )


                workspaceTransferBytes +=
                    Int64(
                        chunk.count
                    )


                if let started =
                    workspaceTransferStartedAt {

                    let elapsed =
                        Date()
                            .timeIntervalSince(
                                started
                            )


                    if elapsed > 0.20 {

                        workspaceTransferSpeedBytesPerSecond =
                            Double(
                                workspaceTransferBytes
                            )
                            / elapsed
                    }
                }


                if workspaceTransferTotalBytes
                    > 0 {

                    workspaceTransferProgress =
                        min(
                            0.99,
                            Double(
                                workspaceTransferBytes
                            )
                            /
                            Double(
                                workspaceTransferTotalBytes
                            )
                        )
                }


                workspaceTransferStatus =
                    "Copie du workspace et des médias…"


            } catch {

                finishWorkspaceTransferWithError(
                    error.localizedDescription
                )
            }


        case "TRANSFER_END":
            guard binaryTransfer == nil, workspaceTransferInProgress, object["transferID"] as? String == workspaceTransferID else { return }

            workspaceTransferReceiveHandle?
                .closeFile()

            workspaceTransferReceiveHandle =
                nil


            guard
                workspaceTransferTotalBytes <= 0
                ||
                workspaceTransferBytes
                    == workspaceTransferTotalBytes
            else {

                finishWorkspaceTransferWithError(
                    "Transfert incomplet : "
                    + String(
                        workspaceTransferBytes
                    )
                    + " octets reçus sur "
                    + String(
                        workspaceTransferTotalBytes
                    )
                )

                return
            }


            workspaceTransferStatus =
                "Vérification SHA-256…"

            verifyAndInstallWorkspaceTransfer()


        case "TRANSFER_ERROR":
            if let id = object["transferID"] as? String, id != workspaceTransferID { return }
            finishWorkspaceTransferWithError(
                object["message"]
                    as? String
                ?? "Erreur de transfert MASTER"
            )


        default:
            break
        }
    }


    private func verifyAndInstallWorkspaceTransfer() {

        guard
            let archive =
                workspaceTransferReceiveURL,
            let expectedHash =
                workspaceTransferExpectedSHA256
        else {

            finishWorkspaceTransferWithError(
                "Archive BACKUP introuvable"
            )

            return
        }


        let projectName =
            workspaceTransferProjectName

        let preferredWorkspace =
            connectedWorkspace
        let installingID = workspaceTransferID
        let installingConnection = activeConnection


        DispatchQueue.global(
            qos: .userInitiated
        ).async {
            [weak self] in


            do {

                let actualHash =
                    try WorkspaceTransferSupport
                        .sha256(
                            of: archive
                        )


                guard
                    actualHash
                        .caseInsensitiveCompare(
                            expectedHash
                        )
                        == .orderedSame
                else {

                    throw NSError(
                        domain:
                            "QLabFallback.Transfer",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Vérification SHA-256 échouée : la copie reçue n'est pas identique au MASTER"
                        ]
                    )
                }


                let destination =
                    try WorkspaceTransferSupport
                        .extractArchive(
                            archive,
                            projectName:
                                projectName
                        )


                guard
                    let workspaceURL =
                        WorkspaceTransferSupport
                            .findWorkspace(
                                in:
                                    destination,
                                preferredName:
                                    preferredWorkspace
                            )
                else {

                    throw WorkspaceTransferSupport
                        .TransferError
                        .workspaceNotFound
                }


                let (mediaManifest, mediaRoot) = try WorkspaceTransferSupport.receivedManifest(
                    workspaceURL: workspaceURL, extractionRoot: destination)

                try?
                    FileManager.default
                        .removeItem(
                            at: archive
                        )


                Task { @MainActor in

                    guard let self else {
                        return
                    }


                    guard !self.workspaceTransferCancelled, self.workspaceTransferID == installingID,
                          self.activeConnection === installingConnection else { return }
                    self.workspaceTransferProgress = 1
                    self.workspaceTransferReady = false
                    self.workspaceTransferStatus = "Copie vérifiée ; validation QLab en cours"
                    self.workspaceTransferError = nil
                    self.workspaceTransferReceiveURL = nil
                    self.workspaceTransferExpectedSHA256 = nil
                    self.workspaceTransferDestinationPath = destination.path
                    self.confirmInitialWorkspaceApplication(workspaceURL: workspaceURL, manifest: mediaManifest, mediaRoot: mediaRoot)


                    print(
                        "BACKUP : projet installé :",
                        destination.path
                    )



                }


            } catch {

                Task { @MainActor in

                    self?
                        .finishWorkspaceTransferWithError(
                            error.localizedDescription
                        )
                }
            }
        }
    }


    private func finishWorkspaceTransferWithError(
        _ message: String
    ) {
        stopBinaryTransfer()
        workspaceTransferConfirmationTask?
            .cancel()

        workspaceTransferConfirmationTask =
            nil


        workspaceTransferInProgress =
            false

        workspaceTransferReady =
            false

        workspaceTransferError =
            message

        workspaceTransferStatus =
            "Échec du transfert"

        MirrorDiagnostics.log("TRANSFERT refusé : " + message)
        if runtimeRole == .backup, let connection = activeConnection, let transferID = workspaceTransferID {
            sendJSON(["type": "TRANSFER_APPLY_FAILED", "sessionID": connectedSessionID ?? "",
                      "transferID": transferID, "message": message], on: connection)
        }


        workspaceTransferReceiveHandle?
            .closeFile()

        workspaceTransferReceiveHandle =
            nil


        if let receiveURL =
            workspaceTransferReceiveURL {

            try?
                FileManager.default
                    .removeItem(
                        at:
                            receiveURL
                    )
        }

        workspaceTransferReceiveURL =
            nil


        workspaceTransferSendHandle?
            .closeFile()

        workspaceTransferSendHandle =
            nil


        print(
            "TRANSFERT WORKSPACE :",
            message
        )
    }


    private func cleanupMasterWorkspaceTransfer(
        removeStatus: Bool = true
    ) {
        stopBinaryTransfer()

        workspaceTransferSendHandle?
            .closeFile()

        workspaceTransferSendHandle =
            nil


        if let archive =
            workspaceTransferArchiveURL {

            try?
                FileManager.default
                    .removeItem(
                        at: archive
                    )
        }


        workspaceTransferArchiveURL =
            nil

        workspaceTransferSentBytes =
            0


        if removeStatus {

            workspaceTransferInProgress =
                false
        }
    }


    private func requestBackupAudioConfiguration() {

        guard runtimeRole == .backup else {
            return
        }

        guard qlabOSCConnected else {
            return
        }

        backupAudioControlReady = false
        backupAudioIsolationConfirmed = false
        backupAudioControlError = nil
        backupAudioPatchSummary = nil
        backupAudioPatches.removeAll()
        backupAudioVerifiedPatchIDs.removeAll()
        backupAudioVerificationTargetMuted = nil

        qlabOSCClient?.requestAudioPatchList()

        print(
            "AUDIO BACKUP : lecture des patches QLab"
        )
    }

    private func setBackupAudioMuted(
        _ muted: Bool,
        reason: String
    ) {

        guard runtimeRole == .backup else {
            return
        }

        guard qlabOSCConnected else {
            backupAudioControlError =
                "QLab BACKUP non connecté"
            return
        }

        guard !backupAudioPatches.isEmpty else {
            backupAudioControlError =
                "Configuration audio BACKUP non disponible"
            return
        }

        guard let client = qlabOSCClient else {
            backupAudioControlError =
                "Client OSC BACKUP indisponible"
            return
        }

        backupAudioControlError = nil
        backupAudioVerificationTargetMuted = muted
        backupAudioVerifiedPatchIDs.removeAll()
        let verification = UUID()
        audioVerificationGeneration = verification
        audioVerificationDeadline = ProcessInfo.processInfo.systemUptime + 1.0

        // Avant de muter, mémoriser précisément
        // les sorties que QLab Fallback prend en charge.
        //
        // La mémoire est écrite AVANT la commande OSC :
        // même en cas de fermeture brutale juste après le mute,
        // le prochain lancement saura récupérer ces sorties.

        if muted {

            for patch in backupAudioPatches {

                saveManagedAudioOutputs(
                    Set(
                        patch.controlledOutputs
                    ),
                    for: patch.id
                )
            }
        }

        var commandCount = 0

        for patch in backupAudioPatches {

            for output in patch.controlledOutputs {

                client.setAudioPatchMute(
                    patchID: patch.id,
                    output: output,
                    muted: muted
                )

                commandCount += 1
            }
        }

        guard commandCount > 0 else {
            backupAudioControlError =
                "Aucune sortie audio BACKUP active à contrôler"
            return
        }

        if muted {
            backupAudioIsolationConfirmed = false
        }

        print(
            "AUDIO BACKUP :",
            muted ? "MUTE demandé" : "UNMUTE demandé",
            "—",
            reason
        )

        Task { [weak self, weak client] in
            for _ in 0..<22 {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, let client, self.qlabOSCClient === client,
                      self.runtimeRole == .backup, self.audioVerificationGeneration == verification,
                      self.backupAudioVerificationTargetMuted == muted else { return }
                for patch in self.backupAudioPatches {
                    client.requestAudioPatchMuteChannels(patchID: patch.id)
                }
            }
            guard let self, self.audioVerificationGeneration == verification,
                  self.backupAudioVerificationTargetMuted == muted else { return }
            self.backupAudioControlError = "Confirmation audio QLab absente après une seconde"
            if self.failoverActivationPending {
                self.failoverActivationError = self.backupAudioControlError
                self.failoverActivationPending = false
            }
        }
    }


    private func handleBackupAudioOSC(
        address: String,
        arguments: [String]
    ) {

        guard runtimeRole == .backup else {
            return
        }

        guard let rawJSON = arguments.first else {
            return
        }

        guard
            let data = rawJSON.data(
                using: .utf8
            ),
            let json =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
            (json["status"] as? String) == "ok"
        else {
            return
        }

        // ----------------------------------------------------
        // PATCH LIST
        // ----------------------------------------------------

        if address.contains(
            "/settings/audio/patchList"
        ) {

            guard
                let rawPatches =
                    json["data"]
                        as? [[String: Any]]
            else {
                backupAudioControlError =
                    "QLab n'a retourné aucun patch audio"
                return
            }

            var patches:
                [BackupAudioPatch] = []

            for item in rawPatches {

                guard
                    let id =
                        item["uniqueID"]
                            as? String,
                    !id.isEmpty
                else {
                    continue
                }

                let name =
                    item["name"]
                        as? String
                    ?? "Patch audio"

                let routing =
                    (item["routing"] as? [Any])?
                        .compactMap {
                            value -> Int? in

                            if let number =
                                value as? NSNumber {

                                return number.intValue
                            }

                            return nil
                        }
                    ?? []

                let muted =
                    Set(
                        (item["muteChannels"] as? [Any])?
                            .compactMap {
                                value -> Int? in

                                if let number =
                                    value as? NSNumber {

                                    return number.intValue
                                }

                                return nil
                            }
                        ?? []
                    )

                // QLab retire les sorties mutées de "routing".
                //
                // Une sortie déjà mutée n'est récupérée ici que si
                // QLab Fallback sait qu'il l'avait lui-même prise
                // en charge lors d'une exécution précédente.
                //
                // Un mute posé manuellement par l'opérateur reste
                // donc protégé et ne devient pas contrôlable.

                let managed =
                    managedAudioOutputs(
                        for: id
                    )

                let recoverableMuted =
                    muted.intersection(
                        managed
                    )

                let effectiveRouting =
                    Array(
                        Set(routing)
                            .union(
                                recoverableMuted
                            )
                    )
                    .sorted()

                let baselineMuted =
                    muted.subtracting(
                        managed
                    )

                guard !effectiveRouting.isEmpty else {
                    continue
                }

                patches.append(
                    BackupAudioPatch(
                        id: id,
                        name: name,
                        routing: effectiveRouting,
                        baselineMuted: baselineMuted
                    )
                )
            }

            guard !patches.isEmpty else {
                backupAudioControlError =
                    "Aucun patch audio routé détecté dans QLab"
                return
            }

            let controllable =
                patches.reduce(0) {
                    result,
                    patch in

                    result
                    + patch.controlledOutputs.count
                }

            guard controllable > 0 else {
                backupAudioControlError =
                    "Toutes les sorties QLab sont déjà mutées"
                return
            }

            backupAudioPatches = patches

            backupAudioPatchSummary =
                patches.map {
                    patch in

                    let outputs =
                        patch.controlledOutputs
                            .map(String.init)
                            .joined(
                                separator: ","
                            )

                    return
                        patch.name
                        + " ["
                        + outputs
                        + "]"
                }
                .joined(
                    separator: " | "
                )

            backupAudioControlReady = true
            backupAudioControlError = nil

            print(
                "AUDIO BACKUP : patches détectés :",
                backupAudioPatchSummary ?? ""
            )

            // Sécurité fondamentale :
            // le BACKUP devient silencieux immédiatement.
            setBackupAudioMuted(
                true,
                reason: "initialisation BACKUP"
            )

            return
        }

        // ----------------------------------------------------
        // VÉRIFICATION muteChannels
        // ----------------------------------------------------

        guard address.contains(
            "/muteChannels"
        ) else {
            return
        }

        guard let targetMuted =
            backupAudioVerificationTargetMuted
        else {
            return
        }

        guard let patch =
            backupAudioPatches.first(
                where: {
                    address.contains(
                        "/patchID/"
                        + $0.id
                        + "/muteChannels"
                    )
                }
            )
        else {
            return
        }

        let actualMuted =
            Set(
                (json["data"] as? [Any])?
                    .compactMap {
                        value -> Int? in

                        if let number =
                            value as? NSNumber {
                            return number.intValue
                        }

                        return nil
                    }
                ?? []
            )

        let controlled =
            Set(
                patch.controlledOutputs
            )

        let patchIsCorrect: Bool

        if targetMuted {

            patchIsCorrect =
                controlled.isSubset(
                    of: actualMuted
                )

        } else {

            patchIsCorrect =
                controlled
                    .intersection(
                        actualMuted
                    )
                    .isEmpty
        }

        guard patchIsCorrect else {
            // QLab may still be applying the command at the first readback.
            // Keep querying; never declare success before every patch confirms.
            if ProcessInfo.processInfo.systemUptime < audioVerificationDeadline { return }

            backupAudioControlError =
                targetMuted
                ? "Échec de l'isolation audio BACKUP"
                : "Échec de l'ouverture audio BACKUP"

            if !targetMuted
                && failoverActivationPending {

                failoverActivationPending = false

                failoverActivationError =
                    "QLab n'a pas confirmé l'ouverture audio BACKUP"

                print(
                    "FAILOVER AUDIO NON CONFIRMÉ"
                )
            }

            if targetMuted {
                backupAudioIsolationConfirmed = false
                hotStandbyOutputIsolationConfirmed = false
                hotStandbyExecutionArmed = false
            }

            print(
                "AUDIO BACKUP : vérification ÉCHEC :",
                patch.name
            )

            return
        }

        backupAudioVerifiedPatchIDs.insert(
            patch.id
        )

        let expectedIDs =
            Set(
                backupAudioPatches.map {
                    $0.id
                }
            )

        guard
            backupAudioVerifiedPatchIDs
                == expectedIDs
        else {
            return
        }

        backupAudioControlError = nil

        if targetMuted {

            backupAudioIsolationConfirmed = true

            // Une fois l'isolation réellement confirmée
            // par QLab, le moteur HOT STANDBY peut être armé.
            hotStandbyOutputIsolationConfirmed = true
            hotStandbyExecutionArmed = true


            if failoverDeactivationPending {

                let wasManualSimulation =
                    failoverReason
                    == "SIMULATION MANUELLE PERTE MASTER"


                failoverDeactivationPending = false
                failoverDeactivationError = nil

                failoverActive = false
                failoverActivatedAt = nil

                failoverActivationPending = false
                failoverActivationError = nil

                failoverTakeoverLatched = false
        failoverDeactivationPending = false
        failoverDeactivationError = nil

                backupOutputMode =
                    "ISOLATED"


                // Dans une simulation locale,
                // la perte de liaison avait elle-même
                // été simulée. On remet donc cet état
                // artificiel à zéro.
                if wasManualSimulation {

                    linkLost = false
                    linkLostAt = nil
                    heartbeatAlive = false
                }


                cancelPendingFailover()


                print(
                    "========================================"
                )

                print(
                    "FAILOVER DÉSACTIVÉ — BACKUP RÉ-ISOLÉ"
                )

                print(
                    "========================================"
                )

            } else if !backupOutputTestActive
                && backupOutputMode != "FAILOVER" {

                backupOutputMode =
                    "ISOLATED"
            }


            print(
                "AUDIO BACKUP : ISOLATION CONFIRMÉE"
            )

            print(
                "HOT STANDBY : ARMÉ"
            )

        } else {

            backupAudioIsolationConfirmed = false

            if failoverActivationPending {

                failoverActivationPending = false
                failoverActive = true
                failoverActivatedAt = Date()
                if let began = failoverAudioRequestedAt {
                    MirrorDiagnostics.log("LATENCE détection → confirmation audio ms=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))")
                    failoverAudioRequestedAt = nil
                }
                failoverActivationError = nil

                backupOutputMode = "FAILOVER"

                // Le BACKUP est maintenant audible.
                hotStandbyOutputIsolationConfirmed = false

                print(
                    "========================================"
                )
                print(
                    "FAILOVER ACTIF — SORTIES BACKUP OUVERTES"
                )
                print(
                    "========================================"
                )

            } else {

                // L'ouverture audio vient d'être confirmée.
            // QLab Fallback ne considère donc plus ces sorties
            // comme étant maintenues mutées par lui.

            for patch in backupAudioPatches {

                saveManagedAudioOutputs(
                    [],
                    for: patch.id
                )
            }

            print(
                    "AUDIO BACKUP : SORTIE OUVERTE CONFIRMÉE"
                )
            }
        }

        backupAudioVerificationTargetMuted = nil
        backupAudioVerifiedPatchIDs.removeAll()
    }


    func startBackupOutputTest() {
        backupOutputTestError = nil

        guard runtimeRole == .backup else {
            backupOutputTestError =
                "Le test de sortie est disponible uniquement en mode BACKUP"
            return
        }

        guard qlabOSCConnected else {
            backupOutputTestError =
                "QLab BACKUP n'est pas connecté"
            return
        }

        // La connexion OSC active confirme déjà que
        // QLab local est ouvert, joignable et authentifié.

        guard backupAudioControlReady else {
            backupOutputTestError =
                backupAudioControlError
                ?? "Sorties audio BACKUP non préparées"
            return
        }

        guard !backupOutputTestActive, !linkLost, !failoverPending,
              !failoverActive, !failoverTakeoverLatched, !failoverActivationPending,
              !returnInProgress, !workspaceTransferInProgress, !liveMirrorReloading else {
            backupOutputTestError = "Test indisponible pendant une transition ou une perte PRIMARY"
            return
        }
        refreshLocalQLabState()
        backupTestStartedReady = failoverReady
        backupOutputTestTask?.cancel()

        // Ouvre réellement les sorties QLab BACKUP.
        setBackupAudioMuted(
            false,
            reason: "test manuel 30 secondes"
        )

        let now = Date()
        let endDate =
            now.addingTimeInterval(
                backupOutputTestDuration
            )

        backupOutputTestActive = true
        backupOutputTestStartedAt = now
        backupOutputTestEndsAt = endDate
        backupOutputTestRemainingSeconds =
            Int(backupOutputTestDuration)

        backupOutputMode = "TEST"

        print(
            "MODE TEST SORTIE BACKUP ACTIF —",
            Int(backupOutputTestDuration),
            "secondes"
        )

        backupOutputTestTask =
            Task { [weak self] in

                while !Task.isCancelled {

                    guard let self else {
                        return
                    }

                    guard
                        self.backupOutputTestActive,
                        let endsAt =
                            self.backupOutputTestEndsAt
                    else {
                        return
                    }

                    let remaining =
                        endsAt.timeIntervalSinceNow

                    if remaining <= 0 {
                        self.stopBackupOutputTest()
                        return
                    }

                    self.backupOutputTestRemainingSeconds =
                        max(
                            0,
                            Int(remaining.rounded(.up))
                        )

                    do {
                        try await Task.sleep(
                            nanoseconds:
                                250_000_000
                        )
                    } catch {
                        return
                    }
                }
            }
    }

    func stopBackupOutputTest() {
        backupOutputTestTask?.cancel()
        backupOutputTestTask = nil

        let wasActive = backupOutputTestActive
        // Resolve loss while the test eligibility is still available.
        if wasActive && linkLost {
            activateRealFailover(reason: "Perte PRIMARY pendant test audio")
            // Even if readiness was lost, never automatically cut an audible backup.
            // This latch does not claim that audio or the mirror is verified.
            failoverTakeoverLatched = true
            if !failoverActive { backupOutputMode = "FAILOVER" }
        }
        backupTestStartedReady = false
        backupOutputTestActive = false
        backupOutputTestStartedAt = nil
        backupOutputTestEndsAt = nil
        backupOutputTestRemainingSeconds = 0

        if failoverTakeoverLatched
            || failoverActive
            || failoverActivationPending
            || (linkLost && failoverReady) {

            if failoverActive {
                backupOutputMode = "FAILOVER"
            }

            // Une prise de relais ne doit jamais
            // être remutée automatiquement.
            setBackupAudioMuted(
                false,
                reason: "prise de relais BACKUP"
            )

        } else {

            backupOutputMode = "ISOLATED"

            // Retour réel au silence BACKUP.
            if runtimeRole == .backup
                && backupAudioControlReady {

                setBackupAudioMuted(
                    true,
                    reason: "fin du test"
                )
            }
        }

        if wasActive {
            print(
                "MODE TEST SORTIE BACKUP ARRÊTÉ"
            )
        }
    }


    private func mirrorHotStandbyEvent(
        eventType: String,
        cueID: String?
    ) {
        defer {
            if let reason = hotStandbyBlockedReason {
                MirrorDiagnostics.log("\(eventType) refusé : \(reason) cue=\(cueID ?? "") ready=\(workspaceTransferReady) isolated=\(backupAudioIsolationConfirmed) armed=\(hotStandbyExecutionArmed) reload=\(liveMirrorReloading) failover=\(failoverTakeoverLatched)")
            }
        }
        if liveMirrorReloading && eventType == "GO" {
            liveMirrorMissedGo = true
            hotStandbyBlockedReason = "GO reçu pendant rechargement : revalidation BACKUP requise"
            return
        }
        lastMirroredAction = nil
        lastMirroredCueID = nil
        lastMirroredActionAt = nil
        hotStandbyBlockedReason = nil

        guard runtimeRole == .backup else {
            return
        }

        refreshLocalQLabState()
        let readiness = MirrorGoReadiness(
            enabled: hotStandbyEnabled, oscConnected: qlabOSCConnected,
            workspaceMatches: localQLabWorkspaceMatchesMaster,
            contentReady: workspaceTransferReady || liveMirror.contentReady,
            initialTransfer: workspaceTransferInProgress, reloading: liveMirrorReloading,
            missedGo: liveMirrorMissedGo,
            takeover: failoverTakeoverLatched || failoverActive || failoverActivationPending,
            outputIsolationDeclared: hotStandbyOutputIsolationConfirmed,
            armed: hotStandbyExecutionArmed,
            audioIsolationVerified: backupAudioIsolationConfirmed, outputTest: backupOutputTestActive)
        if let reason = readiness.refusal { hotStandbyBlockedReason = reason; return }

        guard let client = qlabOSCClient else {
            hotStandbyBlockedReason =
                "Client OSC BACKUP indisponible"
            return
        }

        switch eventType {

        case "GO":
            guard let cueID, !cueID.isEmpty else {
                hotStandbyBlockedReason =
                    "Cue ID GO manquant"
                return
            }

            guard client.executeHotStandbyGo(cueID: cueID) else {
                hotStandbyBlockedReason = "Client OSC non prêt au moment du GO"; return
            }

            lastMirroredAction =
                "GO"

            lastMirroredCueID =
                cueID

            lastMirroredActionAt =
                Date()

            print(
                "HOT STANDBY : GO transmis au moteur QLab (attente observation) :",
                cueID
            )

        case "PANIC_ALL":
            client.executeHotStandbyPanic()

            lastMirroredAction =
                "PANIC_ALL"

            lastMirroredCueID =
                nil

            lastMirroredActionAt =
                Date()

            print(
                "HOT STANDBY : PANIC miroir exécuté"
            )

        default:
            break
        }
    }


    private func evaluateFailoverEvent(
        eventType: String,
        cueID: String?
    ) {
        simulatedFailoverAction = nil
        simulatedFailoverCueID = nil
        simulatedFailoverDecisionAt = Date()
        simulatedFailoverBlockedReason = nil

        guard runtimeRole == .backup else {
            simulatedFailoverBlockedReason =
                "Machine non configurée en BACKUP"
            return
        }

        guard linkLost else {
            simulatedFailoverBlockedReason =
                "MASTER toujours joignable"
            return
        }

        guard !heartbeatAlive else {
            simulatedFailoverBlockedReason =
                "Heartbeat MASTER encore actif"
            return
        }

        guard liveMirror.contentReady && !liveMirrorReloading && !liveMirrorMissedGo else {
            failoverReady = false
            failoverBlockedReason = liveMirrorReloading ? "Application du miroir en cours" :
                (liveMirrorMissedGo ? "GO manqué pendant le rechargement : resynchronisation requise" : liveMirrorStatus)
            return
        }

        guard failoverPending else {
            simulatedFailoverBlockedReason =
                "Bascule non préparée"
            return
        }

        guard failoverReady else {
            simulatedFailoverBlockedReason =
                failoverBlockedReason
                ?? "BACKUP non prêt"
            return
        }

        guard localQLabAvailable else {
            simulatedFailoverBlockedReason =
                "QLab BACKUP indisponible"
            return
        }

        guard localQLabWorkspaceMatchesMaster else {
            simulatedFailoverBlockedReason =
                "Workspace BACKUP incorrect"
            return
        }

        guard playheadSyncReady else {
            simulatedFailoverBlockedReason =
                "Playhead non synchronisé"
            return
        }

        switch eventType {

        case "GO":
            guard let cueID, !cueID.isEmpty else {
                simulatedFailoverBlockedReason =
                    "Cue ID GO manquant"
                return
            }

            simulatedFailoverAction =
                "WOULD_EXECUTE_GO"

            simulatedFailoverCueID =
                cueID

            print(
                "SIMULATION BASCULE : GO autorisé sur cue",
                cueID
            )

        case "PANIC_ALL":
            simulatedFailoverAction =
                "WOULD_EXECUTE_PANIC_ALL"

            print(
                "SIMULATION BASCULE : PANIC_ALL autorisé"
            )

        default:
            simulatedFailoverBlockedReason =
                "Type d'événement non autorisé"
        }
    }


    private func rememberMasterEventID(
        _ eventID: String
    ) {
        seenMasterEventIDs.insert(eventID)
        seenMasterEventOrder.append(eventID)

        while seenMasterEventOrder.count >
                maxSeenMasterEvents {

            let oldest =
                seenMasterEventOrder.removeFirst()

            seenMasterEventIDs.remove(
                oldest
            )
        }
    }


    private func requestEventClock(on connection: NWConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if let probe = clockProbe, now - probe.sent < 2 { return }
        let id = UUID().uuidString
        clockProbe = (id, now)
        sendJSON(["type": "EVENT_CLOCK_REQUEST", "sessionID": connectedSessionID ?? "", "probeID": id], on: connection)
    }

    private func sendMasterEvent(
        type: String,
        cueID: String? = nil
    ) {
        if networkSpeedRunning { cancelNetworkSpeedTest() }
        guard runtimeRole == .master, !masterReturning else {
            return
        }

        masterEventSequence += 1

        lastMasterEventType = type
        lastMasterEventCueID = cueID
        lastMasterEventAt = Date()

        guard
            let connection = activeConnection,
            isConnected
        else {
            MirrorDiagnostics.log("\(type) refusé envoi : BACKUP non connecté cue=\(cueID ?? "")")
            print(
                "ÉVÉNEMENT MASTER observé sans BACKUP :",
                type,
                cueID ?? ""
            )
            return
        }

        var payload: [String: Any] = [
            "type": "MASTER_EVENT",
            "protocolVersion": 1,
            "sessionID": masterSessionID,
            "eventID": UUID().uuidString,
            "sequence": masterEventSequence,
            "eventType": type,
            "monotonicTime": ProcessInfo.processInfo.systemUptime,
            "timestamp":
                Date().timeIntervalSince1970
        ]

        if let cueID {
            payload["cueID"] = cueID
        }

        let eventID = payload["eventID"] as? String ?? ""
        sendJSONWithCompletion(payload, on: connection) { error in
            MirrorDiagnostics.log("\(type) \(error == nil ? "envoyé TCP" : "envoi TCP échoué") event=\(eventID) cue=\(cueID ?? "") \(error?.localizedDescription ?? "")")
        }

        print(
            "ÉVÉNEMENT MASTER transmis :",
            type,
            cueID ?? ""
        )
    }


    private func applyBackupPlayhead(
        cueID: String
    ) {
        guard runtimeRole == .backup else {
            return
        }

        guard !cueID.isEmpty else {
            return
        }

        guard let client = qlabOSCClient else {
            backupPlayheadSyncError =
                "Client OSC QLab BACKUP indisponible"
            return
        }

        remoteSelectionEchoes[cueID] = Date()
        guard qlabOSCConnected, client.setPlayhead(cueID: cueID) else {
            playheadSyncReady = false
            backupPlayheadSyncError = "QLab BACKUP déconnecté : playhead non appliqué"
            return
        }
        // Confirmation comes from QLab's playhead response/event, not send success.
        backupPlayheadSyncError = nil
        print("PLAYHEAD demandé au QLab BACKUP :", cueID)
    }


    func sendPlayheadUpdate(
        cueID: String
    ) {
        guard runtimeRole == .master else {
            return
        }

        guard !cueID.isEmpty else {
            return
        }

        if masterReturning { masterPlayheadID = cueID; return }
        let changed =
            masterPlayheadID != cueID

        masterPlayheadID = cueID
        lastPlayheadUpdateAt = Date()

        if changed {
            print(
                "PLAYHEAD QLab détecté :",
                cueID
            )
        }

        guard
            let connection = activeConnection,
            isConnected
        else {
            return
        }

        let payload: [String: Any] = [
            "type": "PLAYHEAD",
            "protocolVersion": 1,
            "sessionID": masterSessionID,
            "cueID": cueID,
            "timestamp":
                Date().timeIntervalSince1970
        ]

        sendJSON(
            payload,
            on: connection
        )

        print(
            "PLAYHEAD transmis au BACKUP :",
            cueID
        )
    }


    private func queueBackupSelection(_ cueID: String) {
        remoteSelectionEchoes = remoteSelectionEchoes.filter { Date().timeIntervalSince($0.value) < 2 }
        if remoteSelectionEchoes.removeValue(forKey: cueID) != nil { return }
        selectionRequestTask?.cancel()
        guard !cueID.isEmpty, cueID != backupTargetPlayheadID else { return }
        selectionRequestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ResponsivenessPolicy.selectionCoalescing)
            guard let self, !Task.isCancelled, self.backupObservedPlayheadID == cueID,
                  cueID != self.backupTargetPlayheadID, self.isConnected,
                  self.qlabOSCConnected, self.workspaceTransferReady,
                  !self.workspaceTransferInProgress, !self.liveMirrorReloading,
                  !self.failoverTakeoverLatched, !self.failoverActive,
                  let session = self.connectedSessionID, let connection = self.activeConnection,
                  let workspaceID = self.qlabOSCWorkspaceID,
                  let base = self.backupTargetPlayheadID else { return }
            self.lastBackupSelectionRequest = UUID().uuidString
            self.selectionRequestSentAt = (cueID, ProcessInfo.processInfo.systemUptime)
            self.playheadSyncReady = false
            self.sendJSON(["type": "BACKUP_SELECTION", "sessionID": session,
                "workspaceID": workspaceID, "cueID": cueID, "baseCueID": base,
                "requestID": self.lastBackupSelectionRequest!], on: connection)
            MirrorDiagnostics.log("SÉLECTION BACKUP → MASTER demandée cue=\(cueID)")
        }
    }

    private func receiveBackupSelection(_ object: [String: Any], on connection: NWConnection) {
        guard runtimeRole == .master, !masterReturning, activeConnection === connection,
              isConnected, qlabOSCConnected, workspaceTransferReady,
              !workspaceTransferInProgress,
              object["sessionID"] as? String == masterSessionID,
              object["workspaceID"] as? String == qlabOSCWorkspaceID,
              let cue = object["cueID"] as? String, !cue.isEmpty,
              let request = object["requestID"] as? String, UUID(uuidString: request) != nil,
              !selectionRequestIDs.contains(request) else { return }
        selectionRequestIDs.append(request)
        if selectionRequestIDs.count > 256 { selectionRequestIDs.removeFirst() }
        guard object["baseCueID"] as? String == masterPlayheadID else {
            if let current = masterPlayheadID { sendPlayheadUpdate(cueID: current) }
            MirrorDiagnostics.log("SÉLECTION BACKUP refusée : le MASTER a changé entre-temps")
            return
        }
        guard qlabOSCClient?.setPlayhead(cueID: cue) == true else { return }
        // Broadcast only when QLab confirms the new playhead. Never trigger GO.
        MirrorDiagnostics.log("SÉLECTION BACKUP → MASTER application OSC cue=\(cue)")
    }

    private func startHeartbeat(
        on connection: NWConnection,
        sessionID: String
    ) {
        liveMirror.start()
        startRecoveryMonitor()
        heartbeatTask?.cancel()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                guard
                    self.activeConnection === connection,
                    self.isConnected
                else {
                    return
                }

                let payload: [String: Any] = [
                    "type": "HEARTBEAT",
                    "protocolVersion": 1,
                    "sessionID": sessionID,
                    "timestamp":
                        Date().timeIntervalSince1970,

                    // Un MASTER dont QLab ne répond plus
                    // n'est PAS considéré comme sain,
                    // même si QLab Fallback tourne encore.
                    "qlabAlive":
                        self.qlabOSCConnected
                ]

                self.sendJSON(
                    payload,
                    on: connection
                )

                do {
                    try await Task.sleep(
                        nanoseconds:
                            self.heartbeatIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    func refreshLocalQLabState() {
        let previousReady = failoverReady, previousReason = failoverBlockedReason
        defer {
            if runtimeRole == .backup && (previousReady != failoverReady || previousReason != failoverBlockedReason) {
                MirrorDiagnostics.log("BASCULE prête=\(failoverReady) raison=\(failoverBlockedReason ?? "aucune")")
            }
        }

        // ====================================================
        // IMPORTANT
        //
        // On ne doit PAS utiliser le workspace QLab au premier
        // plan : l'opérateur peut avoir plusieurs workspaces
        // ouverts.
        //
        // La référence locale est désormais exclusivement le
        // workspace réellement sélectionné et monitoré par
        // QLab Fallback.
        // ====================================================

        let monitoredWorkspace =
            qlabMonitoredWorkspace
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )


        let localAvailable =
            qlabOSCConnected
            && !monitoredWorkspace.isEmpty


        localQLabAvailable =
            localAvailable

        localQLabWorkspace =
            localAvailable
            ? monitoredWorkspace
            : nil


        guard
            let expectedWorkspace =
                connectedWorkspace?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
            !expectedWorkspace.isEmpty
        else {

            localQLabWorkspaceMatchesMaster =
                false

            failoverReady =
                false

            failoverBlockedReason =
                "Workspace MASTER inconnu"

            return
        }


        guard localAvailable else {

            localQLabWorkspaceMatchesMaster =
                false

            failoverReady =
                false

            failoverBlockedReason =
                "QLab BACKUP inaccessible ou workspace sélectionné non connecté"

            return
        }


        let matches =
            QLabWorkspaceIdentity.matches(localName: monitoredWorkspace, masterName: expectedWorkspace,
                connected: qlabOSCConnected, localID: qlabOSCWorkspaceID,
                validatedID: validatedInitialWorkspaceID)


        localQLabWorkspaceMatchesMaster =
            matches


        guard matches else {

            failoverReady =
                false

            failoverBlockedReason =
                "Workspace BACKUP différent du MASTER"

            return
        }


        guard liveMirror.contentReady && !liveMirrorReloading && !liveMirrorMissedGo else {
            failoverReady = false
            failoverBlockedReason = liveMirrorReloading ? "Application du miroir en cours" :
                (liveMirrorMissedGo ? "GO manqué pendant le rechargement : resynchronisation requise" : liveMirrorStatus)
            return
        }

        guard backupAudioControlReady,
              (backupAudioIsolationConfirmed || (backupOutputTestActive && backupTestStartedReady)),
              hotStandbyOutputIsolationConfirmed, hotStandbyExecutionArmed,
              (!backupOutputTestActive || backupTestStartedReady), !workspaceTransferInProgress,
              !failoverActive, !failoverTakeoverLatched else {
            failoverReady = false
            failoverBlockedReason = "Contrôle audio/isolation HOT STANDBY non prêts ou opération en cours"
            return
        }


        guard
            playheadSyncReady,
            backupTargetPlayheadID != nil
        else {

            failoverReady =
                false

            failoverBlockedReason =
                "Playhead MASTER non synchronisé"

            return
        }


        guard qlabOSCConnected else {

            failoverReady =
                false

            failoverBlockedReason =
                "QLab BACKUP non connecté en OSC"

            return
        }


        failoverReady =
            true

        failoverBlockedReason =
            nil


        print(
            "BACKUP prêt pour bascule — workspace sélectionné :",
            monitoredWorkspace
        )
    }


    func simulateMasterLossForTest() {

        guard runtimeRole == .backup else {
            failoverActivationError =
                "Simulation disponible uniquement en mode BACKUP"
            return
        }

        guard !failoverActive else {
            failoverActivationError =
                "Le BACKUP est déjà en FAILOVER"
            return
        }

        guard !failoverActivationPending else {
            return
        }

        guard qlabOSCConnected else {
            failoverActivationError =
                "QLab BACKUP non connecté"
            return
        }

        guard backupAudioControlReady else {
            failoverActivationError =
                backupAudioControlError
                ?? "Contrôle audio BACKUP non prêt"
            return
        }

        guard backupAudioIsolationConfirmed else {
            failoverActivationError =
                "Sorties BACKUP non isolées"
            return
        }

        guard hotStandbyExecutionArmed else {
            failoverActivationError =
                "HOT STANDBY non armé"
            return
        }

        guard hotStandbyOutputIsolationConfirmed else {
            failoverActivationError =
                "Isolation HOT STANDBY non confirmée"
            return
        }

        // Etat réseau simulé.
        heartbeatAlive = false
        linkLost = true
        linkLostAt = Date()

        failoverPending = true
        failoverPreparedAt = Date()
        failoverReason =
            "SIMULATION MANUELLE PERTE MASTER"

        failoverTakeoverLatched = true
        failoverActivationPending = true
        failoverActivationError = nil

        print(
            "========================================"
        )
        print(
            "SIMULATION : PERTE MASTER"
        )
        print(
            "Déclenchement du vrai UNMUTE BACKUP"
        )
        print(
            "========================================"
        )

        setBackupAudioMuted(
            false,
            reason: "simulation perte MASTER"
        )
    }


    func deactivateFailoverManually() { requestMasterReturn() }


    private func activateRealFailover(
        reason: String
    ) {

        guard runtimeRole == .backup else {
            return
        }

        guard !failoverActive else {
            return
        }

        guard !failoverActivationPending else {
            return
        }

        refreshLocalQLabState()

        guard failoverReady else {
            failoverActivationError =
                failoverBlockedReason
                ?? "BACKUP non prêt pour la bascule"

            print(
                "FAILOVER AUDIO BLOQUÉ :",
                failoverActivationError ?? ""
            )

            return
        }

        guard qlabOSCConnected else {
            failoverActivationError =
                "QLab BACKUP non connecté"
            return
        }

        guard backupAudioControlReady else {
            failoverActivationError =
                backupAudioControlError
                ?? "Contrôle audio BACKUP indisponible"
            return
        }

        guard backupAudioIsolationConfirmed || (backupOutputTestActive && backupTestStartedReady) else {
            failoverActivationError =
                "Isolation audio BACKUP non confirmée"
            return
        }

        guard hotStandbyOutputIsolationConfirmed else {
            failoverActivationError =
                "HOT STANDBY non isolé"
            return
        }

        guard hotStandbyExecutionArmed else {
            failoverActivationError =
                "HOT STANDBY non armé"
            return
        }

        // Si un test audio était en cours au moment
        // de la panne MASTER, on arrête seulement
        // son compte à rebours.
        //
        // Surtout : aucun remute.
        if backupOutputTestActive {

            backupOutputTestTask?.cancel()
            backupOutputTestTask = nil

            backupOutputTestActive = false
            backupOutputTestStartedAt = nil
            backupOutputTestEndsAt = nil
            backupOutputTestRemainingSeconds = 0
        }

        failoverTakeoverLatched = true
        failoverActivationPending = true
        failoverActivationError = nil

        print(
            "FAILOVER AUDIO DEMANDÉ :",
            reason
        )

        failoverAudioRequestedAt = ProcessInfo.processInfo.systemUptime
        MirrorDiagnostics.log("LATENCE bascule détectée : " + reason)
        // La sortie est réellement ouverte.
        // failoverActive ne passera à true
        // qu'après confirmation muteChannels.
        setBackupAudioMuted(
            false,
            reason: "perte MASTER"
        )
    }


    private func markLinkLost(
        reason: String
    ) {

        if workspaceTransferInProgress {

            workspaceTransferConfirmationTask?
                .cancel()

            workspaceTransferConfirmationTask =
                nil

            workspaceTransferInProgress =
                false

            workspaceTransferReady =
                false

            workspaceTransferError =
                "Transfert interrompu par la perte du MASTER"

            workspaceTransferStatus =
                "Transfert interrompu"
        }

        heartbeatAlive = false

        if !linkLost {
            linkLost = true
            linkLostAt = Date()

            print(
                "PERTE MASTER détectée :",
                reason
            )
        }

        prepareFailover(
            reason: reason
        )
    }

    private func markLinkRestored() {
        let wasLost = linkLost

        linkLost = false
        linkLostAt = nil
        heartbeatAlive = true

        // Une fois la prise de relais demandée
        // ou confirmée, le retour du MASTER
        // ne provoque jamais un remute automatique.
        if failoverTakeoverLatched
            || failoverActive
            || failoverActivationPending {

            if wasLost {
                print(
                    "MASTER revenu — BACKUP reste en prise de relais"
                )
            }

            return
        }

        cancelPendingFailover()

        if !backupOutputTestActive {
            backupOutputMode = "ISOLATED"
        }

        if wasLost {
            print(
                "Liaison MASTER rétablie"
            )
        }
    }

    private func prepareFailover(
        reason: String
    ) {

        if failoverPending {

            if !failoverActive
                && !failoverActivationPending {

                activateRealFailover(
                    reason: reason
                )
            }

            return
        }

        failoverPending = true
        failoverPreparedAt = Date()
        failoverReason = reason

        print(
            "BASCULE BACKUP préparée :",
            reason
        )

        refreshLocalQLabState()

        guard failoverReady else {

            print(
                "BASCULE BLOQUÉE :",
                failoverBlockedReason
                    ?? "raison inconnue"
            )

            return
        }

        activateRealFailover(
            reason: reason
        )
    }

    private func cancelPendingFailover() {
        failoverPending = false
        failoverPreparedAt = nil
        failoverReason = nil

        refreshLocalQLabState()
    }


    private func receivePrimaryHeartbeat(qlabHealthy: Bool) {
        lastHeartbeatAt = Date()
        primaryQLabHealthy = qlabHealthy
        if qlabHealthy {
            markLinkRestored()
        } else {
            markLinkLost(reason: "QLab du PRIMARY ne répond plus")
            // Transport is alive; show availability is a separate fact.
            heartbeatAlive = true
        }
    }

    private func startHeartbeatMonitor() {
        startRecoveryMonitor()
        heartbeatMonitorTask?.cancel()

        heartbeatMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                do {
                    try await Task.sleep(
                        nanoseconds:
                            self.heartbeatMonitorIntervalNanoseconds
                    )
                } catch {
                    return
                }

                guard self.isConnected else {
                    self.heartbeatAlive = false

                    // Si un MASTER avait déjà été authentifié,
                    // la disparition de la connexion est une
                    // vraie perte de transport.
                    //
                    // Pendant une simple recherche de MASTER,
                    // connectedSessionID est nil : aucune bascule.
                    if self.runtimeRole == .backup,
                       self.connectedSessionID != nil {

                        self.markLinkLost(
                            reason:
                                "Connexion MASTER interrompue"
                        )
                    }

                    continue
                }

                guard let lastHeartbeatAt =
                    self.lastHeartbeatAt
                else {
                    self.heartbeatAlive = false
                    continue
                }

                let alive =
                    Date().timeIntervalSince(
                        lastHeartbeatAt
                    ) <= self.effectiveHeartbeatTimeout

                if alive {
                    self.heartbeatAlive = true

                    if self.primaryQLabHealthy && self.linkLost {
                        self.markLinkRestored()
                    }
                } else {
                    self.markLinkLost(
                        reason:
                            "Heartbeat absent depuis plus de "
                            + String(self.effectiveHeartbeatTimeout)
                            + " seconde(s)"
                    )
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil

        heartbeatAlive = false
        primaryQLabHealthy = false
        lastHeartbeatAt = nil
        linkLost = false
        linkLostAt = nil

        cancelPendingFailover()

        localQLabAvailable = false
        localQLabWorkspace = nil
        localQLabWorkspaceMatchesMaster = false

        masterPlayheadID = nil
        backupTargetPlayheadID = nil
        lastPlayheadUpdateAt = nil
        playheadSyncReady = false

        backupPlayheadAppliedID = nil
        backupPlayheadAppliedAt = nil
        backupPlayheadSyncError = nil

        lastMasterEventType = nil
        lastMasterEventCueID = nil
        lastMasterEventAt = nil
        masterEventSequence = 0

        lastBackupObservedEventType = nil
        lastBackupObservedEventCueID = nil
        lastBackupObservedEventAt = nil

        lastBackupEventSequence = 0
        duplicateMasterEventCount = 0
        staleMasterEventCount = 0
        missingMasterEventCount = 0

        seenMasterEventIDs.removeAll()
        seenMasterEventOrder.removeAll()

        simulatedFailoverAction = nil
        simulatedFailoverCueID = nil
        simulatedFailoverDecisionAt = nil
        simulatedFailoverBlockedReason = nil

        lastMirroredAction = nil
        lastMirroredCueID = nil
        lastMirroredActionAt = nil
        hotStandbyBlockedReason = nil

        // L'armement ne survit jamais à un stop/restart.
        hotStandbyExecutionArmed = false
        hotStandbyOutputIsolationConfirmed = false
    }


    func getQLabWorkspaceName() -> String? {
        let script = """
        tell application "QLab"
            tell front workspace
                return name
            end tell
        end tell
        """

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/osascript"
        )
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading
                .readDataToEndOfFile()

            guard process.terminationStatus == 0,
                let result = String(
                    data: data,
                    encoding: .utf8
                )
            else {
                return nil
            }

            let cleaned = result
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            print("QLab workspace détecté :", cleaned)

            return cleaned.isEmpty ? nil : cleaned

        } catch {
            return nil
        }
    }

    private func registerQLabOSCResponse() {

        lastQLabOSCResponseAt = Date()


        guard qlabWatchdogLost else {
            return
        }


        print(
            "WATCHDOG QLAB : QLab répond à nouveau"
        )


        // On vient de retrouver QLab après une vraie perte.
        // Le client OSC doit être complètement reconnecté et
        // réauthentifié : une ancienne session QLab n'est pas
        // considérée comme encore valide après un redémarrage.
        qlabWatchdogLost = false

        qlabOSCStatus =
            "QLab détecté — reconnexion OSC"

        let workspace =
            qlabMonitoredWorkspace


        guard
            runtimeRole != .idle,
            !workspace.isEmpty
        else {
            return
        }


        let recoveringClient = qlabOSCClient
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15
        ) { [weak self] in

            guard let self else {
                return
            }

            guard self.runtimeRole != .idle, self.qlabOSCClient === recoveringClient else {
                return
            }

            self.startQLabOSCMonitoring(
                workspace: workspace
            )
        }
    }


    private func markLocalQLabLost() {

        guard !qlabWatchdogLost else {
            return
        }


        qlabWatchdogLost = true

        qlabOSCConnected = false
        qlabOSCWorkspaceID = nil

        qlabAuthenticationOK = false
        qlabAuthenticationStatus =
            "QLab inaccessible"

        qlabOSCStatus =
            "QLab ne répond plus"

        qlabOSCError =
            "Aucune réponse OSC de QLab depuis plus de "
            + String(qlabWatchdogTimeout)
            + " secondes"


        qlabVersion = nil

        qlabCompatibilityStatus =
            "QLab inaccessible"

        qlabCompatibilityValidated = false
        qlabCompatibilityWarning = true


        localQLabAvailable = false
        localQLabWorkspace = nil
        localQLabWorkspaceMatchesMaster = false

        failoverReady = false


        // Un playhead affiché alors que QLab local est mort
        // serait un état périmé et trompeur.
        if runtimeRole == .master {

            masterPlayheadID = nil
            lastPlayheadUpdateAt = nil
        }


        if runtimeRole == .backup {

            failoverBlockedReason =
                "QLab BACKUP ne répond plus"

            backupAudioControlReady = false
            backupAudioIsolationConfirmed = false

            backupAudioControlError =
                "QLab BACKUP ne répond plus"

            hotStandbyExecutionArmed = false
            hotStandbyOutputIsolationConfirmed = false

            hotStandbyBlockedReason =
                "QLab BACKUP ne répond plus"
        }


        print(
            "========================================"
        )

        print(
            "WATCHDOG QLAB : PERTE DE QLAB LOCAL"
        )

        print(
            "Rôle :",
            runtimeRole == .master
                ? "MASTER"
                : runtimeRole == .backup
                    ? "BACKUP"
                    : "IDLE"
        )

        print(
            "========================================"
        )
    }


    private func startQLabWatchdog(
        client: QLabOSCClient
    ) {

        qlabWatchdogTask?.cancel()

        lastQLabOSCResponseAt = Date()
        qlabWatchdogLost = false


        qlabWatchdogTask =
            Task { [weak self, weak client] in

                while !Task.isCancelled {

                    guard
                        let self,
                        let client
                    else {
                        return
                    }


                    do {

                        try await Task.sleep(
                            nanoseconds:
                                self.qlabWatchdogIntervalNanoseconds
                        )

                    } catch {

                        return
                    }


                    guard self.runtimeRole != .idle else {
                        return
                    }


                    guard self.qlabOSCClient === client else {
                        return
                    }


                    // Le probe est volontairement envoyé même
                    // lorsque qlabOSCConnected est déjà false :
                    // c'est ce qui permet de détecter le retour
                    // de QLab automatiquement.
                    client.sendHealthProbe()


                    guard let lastResponse =
                        self.lastQLabOSCResponseAt
                    else {

                        self.markLocalQLabLost()

                        continue
                    }


                    let silence =
                        Date().timeIntervalSince(
                            lastResponse
                        )


                    if silence >
                        self.qlabWatchdogTimeout {

                        self.markLocalQLabLost()
                    }
                }
            }
    }


    private func stopQLabWatchdog() {

        qlabWatchdogTask?.cancel()
        qlabWatchdogTask = nil

        lastQLabOSCResponseAt = nil
        qlabWatchdogLost = false
    }


    // ========================================================
    // PASSCODE OSC QLAB
    // ========================================================

    private let defaultQLabPasscode =
        "1515"

    // Lu une seule fois depuis le Trousseau par lancement.
    // Toutes les reconnexions QLab utilisent ensuite ce cache.
    private var cachedQLabPasscode: String?


    func currentQLabPasscode() -> String {

        // IMPORTANT :
        // aucune nouvelle lecture du Trousseau
        // tant que l'application reste ouverte.
        if let cachedQLabPasscode {
            return cachedQLabPasscode
        }


        let resolvedPasscode: String


        if let saved =
            KeychainStore.readPasscode(),
           saved.count == 4,
           saved.allSatisfy({ $0.isNumber }) {

            // Migration unique de l'ancien code
            // utilisé pendant le développement.
            if saved == "7429" {

                _ = KeychainStore.savePasscode(
                    "1515"
                )

                resolvedPasscode = "1515"

                qlabPasscodeStatus =
                    "Passcode migré vers 1515 dans le Trousseau"

            } else {

                resolvedPasscode = saved
            }

        } else {

            _ = KeychainStore.savePasscode(
                defaultQLabPasscode
            )

            resolvedPasscode =
                defaultQLabPasscode
        }


        cachedQLabPasscode =
            resolvedPasscode

        return resolvedPasscode
    }


    @discardableResult
    func saveQLabPasscode(
        _ rawValue: String
    ) -> Bool {

        let value =
            rawValue.filter {
                $0.isNumber
            }


        guard value.count == 4 else {

            qlabPasscodeStatus =
                "Le passcode QLab doit contenir exactement 4 chiffres"

            return false
        }


        guard
            KeychainStore.savePasscode(
                value
            )
        else {

            qlabPasscodeStatus =
                "Impossible d'enregistrer le passcode dans le Trousseau"

            return false
        }


        cachedQLabPasscode =
            value

        qlabPasscodeStatus =
            "Passcode enregistré dans le Trousseau"

        qlabAuthenticationOK = false
        qlabAuthenticationStatus =
            "À vérifier"


        // Si Fallback est déjà actif,
        // on reconnecte immédiatement QLab
        // avec le nouveau passcode.
        if runtimeRole != .idle,
           !qlabMonitoredWorkspace.isEmpty {

            startQLabOSCMonitoring(
                workspace:
                    qlabMonitoredWorkspace
            )
        }


        return true
    }


    private func handleQLabAuthenticationReply(
        address: String,
        arguments: [String]
    ) {

        guard
            address.hasPrefix(
                "/reply/workspace/"
            ),
            address.hasSuffix(
                "/connect"
            ),
            let raw = arguments.first,
            let data = raw.data(
                using: .utf8
            ),
            let object =
                try? JSONSerialization
                    .jsonObject(
                        with: data
                    ) as? [String: Any]
        else {
            return
        }


        let status =
            object["status"] as? String
            ?? ""


        // IMPORTANT :
        //
        // Un status "ok" ne doit jamais mettre
        // l'interface en erreur.
        //
        // Le succès définitif est confirmé par
        // QLabOSCClient.onConnected.
        if QLabOSCClient.authenticationAccepted(status: status, data: object["data"] as? String) {

            print(
                "QLab : authentification OSC confirmée — demande basePath"
            )


            qlabOSCClient?
                .requestWorkspaceBasePath()


            DispatchQueue.main
                .asyncAfter(
                    deadline:
                        .now() + 0.35
                ) {
                    [weak self] in

                    guard let self else {
                        return
                    }


                    guard
                        self.runtimeRole
                            == .master,
                        self.masterProjectFolderPath
                            == nil
                    else {
                        return
                    }


                    print(
                        "QLab basePath : relance après authentification"
                    )


                    self.qlabOSCClient?
                        .requestWorkspaceBasePath()
                }


            return
        }


        qlabAuthenticationOK = false

        qlabAuthenticationStatus =
            "Refusée"

        qlabOSCConnected = false

        qlabOSCError =
            "Vérifie le passcode OSC 1515 et les permissions View / Edit / Control dans QLab"

        qlabOSCStatus =
            "Authentification QLab refusée"
    }


    private func evaluateQLabCompatibility(
        version: String
    ) {

        qlabVersion = version
        qlabCompatibilityValidated = false
        qlabCompatibilityWarning = false


        let parts =
            version.split(separator: ".")

        guard
            let majorText = parts.first,
            let major = Int(majorText)
        else {

            qlabCompatibilityStatus =
                "Version QLab illisible"

            qlabCompatibilityWarning = true

            return
        }


        if version == "5.5.5" {

            qlabCompatibilityStatus =
                "Validée avec QLab Fallback"

            qlabCompatibilityValidated = true

            return
        }


        if major == 5 {

            qlabCompatibilityStatus =
                "Compatible attendue — test réel conseillé"

            qlabCompatibilityWarning = false

            return
        }


        qlabCompatibilityStatus =
            "Version non validée"

        qlabCompatibilityWarning = true
    }


    private func startQLabOSCMonitoring(
        workspace: String
    ) {

        stopQLabWatchdog()

        qlabMonitoredWorkspace = workspace

        qlabOSCClient?.stop()

        qlabOSCConnected = false
        qlabOSCWorkspaceID = nil
        qlabOSCError = nil

        qlabAuthenticationOK = false
        qlabAuthenticationStatus =
            "Connexion en cours"
        qlabVersion = nil
        qlabCompatibilityStatus =
            "Version QLab non détectée"
        qlabCompatibilityValidated = false
        qlabCompatibilityWarning = false
        qlabOSCStatus =
            "Initialisation OSC QLab"

        backupAudioControlReady = false
        backupAudioIsolationConfirmed = false
        backupAudioPatchSummary = nil
        backupAudioControlError = nil
        backupAudioPatches.removeAll()
        backupAudioVerifiedPatchIDs.removeAll()
        backupAudioVerificationTargetMuted = nil

        let client = makeOSCClient()

        client.onStatus = {
            [weak self, weak client] status in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }
                self.qlabOSCStatus =
                    status
            }
        }

        client.onError = {
            [weak self, weak client] error in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }
                self.qlabOSCConnected =
                    false

                self.qlabAuthenticationOK = false
                self.qlabAuthenticationStatus = error
                self.backupAudioIsolationConfirmed = false
                self.hotStandbyOutputIsolationConfirmed = false
                self.hotStandbyExecutionArmed = false
                self.playheadSyncReady = false
                self.refreshLocalQLabState()
                self.qlabOSCError =
                    error

                self.qlabOSCStatus =
                    "Erreur OSC QLab"

                print(
                    "OSC QLab :",
                    error
                )
            }
        }

        client.onQLabVersionDetected = {
            [weak self, weak client] version in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }


                self.evaluateQLabCompatibility(
                    version: version
                )

                print(
                    "Compatibilité QLab :",
                    self.qlabCompatibilityStatus
                )
            }
        }


        client.onConnected = {
            [weak self, weak client] workspaceID in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }
                if self.masterReturning { self.recoveryMasterIsolated = false; self.masterReturnReady = false }

                self.qlabOSCConnected =
                    true

                self.qlabOSCWorkspaceID =
                    workspaceID

                self.qlabOSCError =
                    nil

                self.qlabOSCStatus =
                    "QLab connecté en OSC"

                // Le callback onConnected n'arrive qu'après
                // une connexion workspace QLab acceptée.
                // Il devient donc la source de vérité pour
                // le statut d'authentification.
                self.qlabAuthenticationOK =
                    true

                self.qlabAuthenticationStatus =
                    "OK — View / Edit / Control"
                self.refreshLocalQLabState()

                print(
                    "QLab OSC connecté :",
                    workspaceID
                )

                do {

                    self.lastQLabOSCResponseAt =
                        Date()

                    self.qlabWatchdogLost =
                        false

                    self.startQLabWatchdog(
                        client: client
                    )

                    // Le workspace sélectionné fournit son
                    // dossier projet directement via OSC.
                    client.requestWorkspaceBasePath()


                    if self.runtimeRole == .master {

                        DispatchQueue.main
                            .asyncAfter(
                                deadline:
                                    .now() + 1.0
                            ) {
                                [weak self, weak client] in

                                guard let self, let client, self.qlabOSCClient === client else {
                                    return
                                }


                                guard
                                    self.runtimeRole
                                        == .master,
                                    self.masterProjectFolderPath
                                        == nil
                                else {
                                    return
                                }


                                print(
                                    "QLab basePath : relance de sécurité"
                                )


                                self.qlabOSCClient?
                                    .requestWorkspaceBasePath()
                            }
                    }


                    if self.runtimeRole == .backup {

                        self.requestBackupAudioConfiguration()
                        if let cueID = self.backupTargetPlayheadID {
                            self.applyBackupPlayhead(cueID: cueID)
                        }
                    }
                }
            }
        }

        client.onRawMessage = {
            [weak self, weak client] address,
            arguments in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }


                // Toute réponse OSC réelle de QLab prouve
                // que le moteur local est vivant.
                self.registerQLabOSCResponse()

                self.handleQLabAuthenticationReply(
                    address: address,
                    arguments: arguments
                )

                self.handleWorkspaceBasePathOSC(
                    address: address,
                    arguments: arguments
                )

                self.handleBackupAudioOSC(
                    address: address,
                    arguments: arguments
                )
            }
        }

        client.onPlayhead = {
            [weak self, weak client] cueID in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }

                if self.runtimeRole == .backup { self.backupObservedPlayheadID = cueID }
                if self.runtimeRole == .backup, self.backupTargetPlayheadID == cueID {
                    if let pending = self.selectionRequestSentAt, pending.cue == cueID {
                        MirrorDiagnostics.log("LATENCE sélection BACKUP aller-retour confirmée ms=\(Int((ProcessInfo.processInfo.systemUptime - pending.at) * 1000)) cue=\(cueID)")
                        self.selectionRequestSentAt = nil
                    }
                    self.backupPlayheadAppliedID = cueID
                    self.backupPlayheadAppliedAt = Date()
                    self.playheadSyncReady = self.qlabOSCConnected
                    self.backupPlayheadSyncError = nil
                    return
                }
                guard self.runtimeRole == .master else {
                    return
                }

                self.sendPlayheadUpdate(
                    cueID: cueID
                )
            }
        }

        client.onPlayheadEvent = { [weak self, weak client] cueID in
            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client,
                      self.runtimeRole == .backup else { return }
                self.backupObservedPlayheadID = cueID
                self.queueBackupSelection(cueID)
            }
        }

        client.onGo = {
            [weak self, weak client] cueID in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }

                self.sendMasterEvent(
                    type: "GO",
                    cueID: cueID
                )
            }
        }

        client.onPanicAll = {
            [weak self, weak client] in

            Task { @MainActor in
                guard let self, let client, self.qlabOSCClient === client else { return }

                self.sendMasterEvent(
                    type: "PANIC_ALL"
                )
            }
        }

        qlabOSCClient = client

        client.start(
            workspaceName: workspace,
            passcode:
                currentQLabPasscode()
        )
    }


    func startMaster(workspace: String) {
        stop()
        runtimeRole = .master
        masterWorkspace = workspace

        startQLabOSCMonitoring(
            workspace: workspace
        )

        do {
            let listener = try NWListener(using: try networkParameters())

            let machineName =
                Host.current().localizedName ?? "Mac"

            listener.service = NWListener.Service(
                name: "\(machineName) | \(workspace)",
                type: serviceType
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isPublishing = true
                        self?.lastError = nil

                    case .failed(let error):
                        self?.isPublishing = false
                        self?.lastError =
                            error.localizedDescription

                    case .cancelled:
                        self?.isPublishing = false

                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = {
                [weak self] connection in

                Task { @MainActor in
                    self?.acceptMasterConnection(
                        connection
                    )
                }
            }

            listener.start(
                queue: .global(
                    qos: .userInitiated
                )
            )

            self.listener = listener

        } catch {
            lastError = error.localizedDescription
        }
    }

    func startBackupSearch(
        workspace preferredWorkspace: String? = nil
    ) {

        stop()

        runtimeRole = .backup


        // Discovery does not require a local QLab workspace. In particular,
        // do not run synchronous AppleScript before starting the browser.
        if let workspace = preferredWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty, workspace != "Non détecté" {
            startQLabOSCMonitoring(workspace: workspace)
        }

        // Capture the search lifetime: stopped browsers may still deliver callbacks.
        let generation = discoveryGeneration
        let parameters: NWParameters
        do { parameters = try networkParameters() }
        catch { lastError = error.localizedDescription; return }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.runtimeRole == .backup,
                      self.discoveryGeneration == generation else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                case .waiting(let error), .failed(let error):
                    self.isBrowsing = false
                    self.lastError = "Découverte MASTER : " + error.localizedDescription
                case .cancelled:
                    self.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.runtimeRole == .backup,
                      self.discoveryGeneration == generation else { return }
                var machines: [String: RemoteMachine] = [:]
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    // Service identity is independent of its interface/address.
                    let id = "\(name)|\(type)|\(domain)"
                    let interfaces = result.interfaces.sorted {
                        let a = $0.type == .wiredEthernet ? 0 : 1, b = $1.type == .wiredEthernet ? 0 : 1
                        return a == b ? $0.name < $1.name : a < b
                    }
                    let preferred = self.selectedNetworkInterface == "auto" ? interfaces.first : interfaces.first(where: { $0.name == self.selectedNetworkInterface })
                    guard let preferred else { continue }
                    let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: preferred)
                    if let existing = machines[id], case let .service(_, _, _, old) = existing.endpoint,
                       old?.type == .wiredEthernet && preferred.type != .wiredEthernet { continue }
                    machines[id] = RemoteMachine(id: id, name: name, endpoint: endpoint)
                }
                self.discoveredMasters = machines.values.sorted { $0.id < $1.id }
                self.connectDiscoveredMasterIfNeeded()
            }
        }
        browser.start(queue: .main)
        backupRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self, self.discoveryGeneration == generation,
                      self.runtimeRole == .backup else { return }
                self.connectDiscoveredMasterIfNeeded()
            }
        }
    }

    func connect(to machine: RemoteMachine) {
        guard runtimeRole == .backup else { return }
        // Ignore repeated clicks/results for an attempt already in progress.
        if selectedMasterID == machine.id, activeConnection != nil { return }
        let previous = activeConnection
        activeConnection = nil
        previous?.cancel()
        backupHandshakeTask?.cancel()
        selectedMasterID = machine.id
        receiveBuffer.removeAll()
        connectedSessionID = nil
        connectedWorkspace = nil
        protocolVersion = nil
        heartbeatAlive = false
        primaryQLabHealthy = false
        lastHeartbeatAt = nil
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        let parameters: NWParameters
        do { parameters = try networkParameters() }
        catch { lastError = error.localizedDescription; return }
        let connection = NWConnection(to: machine.endpoint, using: parameters)
        activeConnection = connection
        connectedMasterName = machine.name
        isConnected = false
        lastError = nil
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.runtimeRole == .backup,
                      self.activeConnection === connection else { return }
                switch state {
                case .ready:
                    self.sendHello(on: connection)
                case .waiting(let error):
                    self.lastError = "Connexion MASTER en attente : " + error.localizedDescription
                case .failed(let error):
                    self.finishBackupConnection(connection, reason: error.localizedDescription)
                case .cancelled:
                    self.finishBackupConnection(connection, reason: "Connexion MASTER annulée")
                default: break
                }
            }
        }
        backupHandshakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            guard let self, self.activeConnection === connection, !self.isConnected else { return }
            self.finishBackupConnection(connection, reason: "MASTER : délai TCP/WELCOME dépassé (10 s)")
        }
        connection.start(queue: .main)
    }

    private func sendHello(
        on connection: NWConnection
    ) {
        let data = Data(
            "HELLO\n".utf8
        )

        connection.send(
            content: data,
            completion: .contentProcessed {
                [weak self] error in

                if let error {
                    Task { @MainActor in
                        self?.finishBackupConnection(connection, reason: error.localizedDescription)
                    }
                    return
                }

                Task { @MainActor in
                    self?.receiveWelcome(
                        on: connection
                    )
                }
            }
        )
    }

    private func receiveWelcome(
        on connection: NWConnection
    ) {
        guard runtimeRole == .backup, activeConnection === connection else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in

            Task { @MainActor in
                guard let self, self.runtimeRole == .backup,
                      self.activeConnection === connection else {
                    return
                }

                if let error {
                    self.finishBackupConnection(connection, reason: "Erreur TCP MASTER : " + error.localizedDescription)
                    return
                }

                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)

                    guard self.receiveBuffer.count <= 8 * 1024 * 1024 else {
                        self.lastError = "Trame MASTER/BACKUP trop volumineuse"
                        self.finishBackupConnection(connection, reason: "Trame MASTER/BACKUP trop volumineuse")
                        return
                    }
                    while let newlineIndex =
                        self.receiveBuffer.firstIndex(of: 0x0A) {

                        let lineData = Data(
                            self.receiveBuffer[
                                ..<newlineIndex
                            ]
                        )

                        self.receiveBuffer.removeSubrange(
                            ...newlineIndex
                        )

                        guard !lineData.isEmpty else {
                            continue
                        }

                        guard
                            let object =
                                try? JSONSerialization.jsonObject(
                                    with: lineData
                                ) as? [String: Any],
                            let type =
                                object["type"] as? String
                        else {
                            continue
                        }

                        if type.hasPrefix(
                            "TRANSFER_"
                        ) {

                            self.handleWorkspaceTransferMessage(
                                object
                            )

                            continue
                        }


                        if type.hasPrefix("SPEED_") {
                            self.handleSpeedFrame(object, on: connection)
                            continue
                        }
                        if type.hasPrefix("RECOVERY_") {
                            self.handleRecovery(object, on: connection)
                            continue
                        }
                        if type.hasPrefix("MIRROR_") {
                            self.liveMirror.enqueue(object)
                            continue
                        }

                        switch type {

                        case "WELCOME":
                            guard !self.isConnected,
                                  object["protocolVersion"] as? Int == 1,
                                  let session = object["sessionID"] as? String, !session.isEmpty,
                                  object["machineName"] is String,
                                  object["workspace"] is String else {
                                self.finishBackupConnection(connection, reason: "WELCOME invalide ou incompatible")
                                return
                            }
                            self.backupHandshakeTask?.cancel()
                            self.backupHandshakeTask = nil
                            self.liveMirror.stop()
                            self.liveMirror.start()
                            self.connectedMasterName =
                                object["machineName"] as? String

                            self.connectedWorkspace =
                                object["workspace"] as? String

                            self.connectedSessionID =
                                object["sessionID"] as? String

                            self.protocolVersion =
                                object["protocolVersion"] as? Int

                            self.lastHeartbeatAt = nil
                            self.heartbeatAlive = false
                            self.linkLost = false
                            self.linkLostAt = nil

                            if !self.failoverTakeoverLatched && !self.failoverActive {
                                self.masterPlayheadID = nil
                                self.backupTargetPlayheadID = nil
                                self.lastPlayheadUpdateAt = nil
                                self.playheadSyncReady = false
                            }

                            self.eventClock = MirrorEventClock()
                            self.clockProbe = nil
                            self.requestEventClock(on: connection)
                            self.seenMasterEventIDs.removeAll()
                            self.seenMasterEventOrder.removeAll()
                            self.lastBackupEventSequence = 0
                            self.duplicateMasterEventCount = 0
                            self.staleMasterEventCount = 0
                            self.missingMasterEventCount = 0

                            self.simulatedFailoverAction = nil
                            self.simulatedFailoverCueID = nil
                            self.simulatedFailoverDecisionAt = nil
                            self.simulatedFailoverBlockedReason = nil

                            self.cancelPendingFailover()

                            self.isConnected = true
                            self.lastError = nil

                            self.startHeartbeatMonitor()

                            self.refreshLocalQLabState()

                        case "EVENT_CLOCK_REPLY":
                            guard object["sessionID"] as? String == self.connectedSessionID,
                                  let probe = self.clockProbe,
                                  object["probeID"] as? String == probe.id,
                                  let remote = object["monotonicTime"] as? Double else { continue }
                            self.clockProbe = nil
                            if !self.eventClock.calibrate(sent: probe.sent, received: ProcessInfo.processInfo.systemUptime, remote: remote) {
                                MirrorDiagnostics.log("GO horloge : sonde trop lente, nouvelle mesure au prochain heartbeat")
                            }

                        case "HEARTBEAT":
                            guard
                                let heartbeatSessionID =
                                    object["sessionID"] as? String,
                                heartbeatSessionID ==
                                    self.connectedSessionID
                            else {
                                continue
                            }


                            // --------------------------------
                            // ÉTAT QLAB DU MASTER
                            // --------------------------------
                            //
                            // Compatibilité avec une ancienne
                            // build : champ absent = true.
                            let masterQLabAlive =
                                object["qlabAlive"] as? Bool
                                ?? true


                            self.receivePrimaryHeartbeat(qlabHealthy: masterQLabAlive)
                            self.requestEventClock(on: connection)

                        case "MASTER_EVENT":
                            MirrorDiagnostics.log("\(object["eventType"] as? String ?? "EVENT") reçu TCP event=\(object["eventID"] as? String ?? "?") seq=\(object["sequence"] ?? "?") cue=\(object["cueID"] as? String ?? "")")
                            guard
                                let eventSessionID =
                                    object["sessionID"] as? String,
                                eventSessionID ==
                                    self.connectedSessionID,
                                let eventID =
                                    object["eventID"] as? String,
                                let sequence =
                                    object["sequence"] as? Int,
                                let eventType =
                                    object["eventType"] as? String,
                                let remoteTime = object["monotonicTime"] as? Double
                            else {
                                MirrorDiagnostics.log("GO/événement refusé : session ou trame incompatible (Build5.3-test requis sur les deux Mac)")
                                continue
                            }

                            // --------------------------------
                            // DÉDUPLICATION
                            // --------------------------------

                            if self.seenMasterEventIDs.contains(
                                eventID
                            ) {
                                self.duplicateMasterEventCount += 1
                                MirrorDiagnostics.log("\(eventType) refusé : eventID déjà reçu \(eventID)")

                                print(
                                    "ÉVÉNEMENT DUPLIQUÉ ignoré :",
                                    eventType,
                                    eventID
                                )

                                continue
                            }

                            // --------------------------------
                            // ÉVÉNEMENT TROP ANCIEN
                            // --------------------------------

                            guard let age = self.eventClock.age(of: remoteTime, now: ProcessInfo.processInfo.systemUptime) else {
                                MirrorDiagnostics.log("\(eventType) refusé : mesure du délai indisponible/périmée event=\(eventID)")
                                self.rememberMasterEventID(eventID)
                                self.requestEventClock(on: connection)
                                continue
                            }

                            if age >
                                self.maxMasterEventAge {

                                self.staleMasterEventCount += 1
                                MirrorDiagnostics.log("\(eventType) refusé : retard=\(age)s event=\(eventID)")

                                print(
                                    "ÉVÉNEMENT PÉRIMÉ ignoré :",
                                    eventType,
                                    "âge :",
                                    age
                                )

                                self.rememberMasterEventID(
                                    eventID
                                )

                                continue
                            }

                            // --------------------------------
                            // SÉQUENCE
                            // --------------------------------

                            if self.lastBackupEventSequence > 0 {

                                if sequence <=
                                    self.lastBackupEventSequence {

                                    self.duplicateMasterEventCount += 1
                                    MirrorDiagnostics.log("\(eventType) refusé : séquence déjà traitée seq=\(sequence) event=\(eventID)")

                                    self.rememberMasterEventID(
                                        eventID
                                    )

                                    print(
                                        "ÉVÉNEMENT HORS SÉQUENCE ignoré :",
                                        sequence
                                    )

                                    continue
                                }

                                let expected =
                                    self.lastBackupEventSequence + 1

                                if sequence > expected {

                                    let missing =
                                        sequence - expected

                                    self.missingMasterEventCount +=
                                        missing

                                    print(
                                        "ATTENTION :",
                                        missing,
                                        "événement(s) MASTER manquant(s)"
                                    )
                                }
                            }

                            self.lastBackupEventSequence =
                                sequence

                            self.rememberMasterEventID(
                                eventID
                            )

                            let cueID =
                                object["cueID"] as? String

                            self.lastBackupObservedEventType =
                                eventType

                            self.lastBackupObservedEventCueID =
                                cueID

                            self.lastBackupObservedEventAt =
                                Date()

                            print(
                                "ÉVÉNEMENT MASTER VALIDÉ sur BACKUP :",
                                "#\(sequence)",
                                eventType,
                                cueID ?? ""
                            )

                            self.mirrorHotStandbyEvent(
                                eventType: eventType,
                                cueID: cueID
                            )

                            self.evaluateFailoverEvent(
                                eventType: eventType,
                                cueID: cueID
                            )

                            if let reason =
                                self.simulatedFailoverBlockedReason {

                                print(
                                    "SIMULATION BASCULE BLOQUÉE :",
                                    reason
                                )
                            }


                        case "PLAYHEAD":
                            guard !self.failoverActive, !self.failoverTakeoverLatched else { continue }
                            guard
                                let playheadSessionID =
                                    object["sessionID"] as? String,
                                playheadSessionID ==
                                    self.connectedSessionID,
                                let cueID =
                                    object["cueID"] as? String,
                                !cueID.isEmpty
                            else {
                                continue
                            }

                            if self.backupTargetPlayheadID != cueID || self.backupObservedPlayheadID != cueID {
                                self.backupTargetPlayheadID = cueID
                                self.masterPlayheadID = cueID
                                self.lastPlayheadUpdateAt = Date()
                                self.playheadSyncReady = false

                                print(
                                    "PLAYHEAD reçu :",
                                    cueID
                                )

                                self.applyBackupPlayhead(
                                    cueID: cueID
                                )
                            }

                            if self.failoverPending {
                                self.refreshLocalQLabState()
                            }

                        default:
                            break
                        }
                    }
                }

                if isComplete {
                    self.finishBackupConnection(connection, reason: "Connexion TCP MASTER fermée")
                    return
                }

                self.receiveWelcome(
                    on: connection
                )
            }
        }
    }

    private func acceptMasterConnection(
        _ connection: NWConnection
    ) {
        activeConnection?.cancel()
        activeConnection = connection

        let workspace = masterWorkspace
        let sessionID = masterSessionID

        connection.stateUpdateHandler = {
            [weak self] state in

            Task { @MainActor in
                guard self?.activeConnection === connection else { return }
                switch state {
                case .ready:
                    self?.receiveHello(
                        on: connection,
                        workspace: workspace,
                        sessionID: sessionID
                    )

                case .failed(let error):
                    self?.isConnected = false
                    self?.lastError =
                        error.localizedDescription

                case .cancelled:
                    self?.isConnected = false

                default:
                    break
                }
            }
        }

        connection.start(
            queue: .global(
                qos: .userInitiated
            )
        )
    }

    private func receiveHello(
        on connection: NWConnection,
        workspace: String,
        sessionID: String
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1024
        ) { [weak self] data, _, _, error in

            if let error {
                Task { @MainActor in
                guard self?.activeConnection === connection else { return }
                    self?.lastError =
                        error.localizedDescription
                }
                return
            }

            guard
                let data,
                let message = String(
                    data: data,
                    encoding: .utf8
                )
            else {
                return
            }

            if message.contains("HELLO") {
                let machineName =
                    Host.current().localizedName ?? "Mac"

                let payload: [String: Any] = [
                    "type": "WELCOME",
                    "protocolVersion": 1,
                    "machineName": machineName,
                    "workspace": workspace,
                    "sessionID": sessionID
                ]

                print("WELCOME envoyé avec workspace :", workspace)

                Task { @MainActor in
                guard self?.activeConnection === connection else { return }
                    self?.sendJSON(
                        payload,
                        on: connection
                    )
                }

                Task { @MainActor in
                guard self?.activeConnection === connection else { return }
                    self?.isConnected = true
                    self?.lastError = nil

                    self?.startHeartbeat(
                        on: connection,
                        sessionID: sessionID
                    )

                    self?.receiveBackupMessages(
                        on: connection
                    )

                    if let cueID =
                        self?.masterPlayheadID {

                        self?.sendPlayheadUpdate(
                            cueID: cueID
                        )
                    }
                }
            }
        }
    }

    func stop() {
        stopBinaryTransfer()
        cancelNetworkSpeedTest()
        discoveryGeneration = UUID()
        backupRetryTask?.cancel(); backupRetryTask = nil
        backupHandshakeTask?.cancel(); backupHandshakeTask = nil
        selectedMasterID = nil
        initialApplyTask?.cancel(); initialApplyTask = nil
        recoveryMonitor?.cancel(); recoveryMonitor = nil
        recoveryOperation?.cancel(); recoveryOperation = nil; recoveryOperationID = UUID()
        recoveryRequest = nil; recoveryToken = nil; returnToken = nil; completedReturnToken = nil
        recoveryState = nil; masterReturning = false; masterReturnReady = false; returnInProgress = false
        recoveryMasterIsolated = false
        recoveryStatus = ""
        selectionRequestTask?.cancel(); selectionRequestTask = nil
        selectionRequestSentAt = nil; failoverAudioRequestedAt = nil
        audioVerificationGeneration = UUID()
        backupObservedPlayheadID = nil; lastBackupSelectionRequest = nil
        remoteSelectionEchoes.removeAll(); selectionRequestIDs.removeAll()
        validatedInitialWorkspaceID = nil
        liveMirrorReloadConditionsConfirmed = false
        liveMirror.stop()
        liveMirrorReloading = false
        liveMirrorMissedGo = false
        liveMirrorReloadConditionsConfirmed = false

        workspaceTransferConfirmationTask?
            .cancel()

        workspaceTransferConfirmationTask =
            nil


        workspaceTransferCancelled =
            true

        workspaceTransferReceiveHandle?
            .closeFile()

        workspaceTransferReceiveHandle =
            nil

        workspaceTransferSendHandle?
            .closeFile()

        workspaceTransferSendHandle =
            nil

        if let archive =
            workspaceTransferArchiveURL {

            try?
                FileManager.default
                    .removeItem(
                        at: archive
                    )
        }

        workspaceTransferArchiveURL =
            nil

        masterControlReceiveBuffer
            .removeAll(
                keepingCapacity:
                    false
            )

        stopBackupOutputTest()

        backupOutputMode = "ISOLATED"
        backupOutputTestError = nil

        failoverActive = false
        failoverActivatedAt = nil
        failoverActivationError = nil
        failoverTakeoverLatched = false
        failoverActivationPending = false

        runtimeRole = .idle

        stopHeartbeat()
        stopQLabWatchdog()

        qlabOSCClient?.stop()
        qlabOSCClient = nil

        qlabOSCConnected = false
        qlabOSCWorkspaceID = nil
        qlabOSCError = nil
        qlabOSCStatus = nil
        qlabVersion = nil
        qlabCompatibilityStatus =
            "Version QLab non détectée"
        qlabCompatibilityValidated = false
        qlabCompatibilityWarning = false

        receiveBuffer.removeAll(
            keepingCapacity: false
        )

        activeConnection?.cancel()
        activeConnection = nil

        listener?.cancel()
        listener = nil

        browser?.cancel()
        browser = nil

        isPublishing = false
        isBrowsing = false
        isConnected = false
        connectedMasterName = nil
        connectedWorkspace = nil
        connectedSessionID = nil
        protocolVersion = nil
        discoveredMasters = []
    }
}


extension NetworkDiscovery {
    func requestLiveMirrorResynchronization() {
        guard canRequestLiveMirrorResynchronization else {
            liveMirrorManualResyncError = "Relance indisponible : vérifier la connexion, l’isolation audio et l’état du BACKUP."
            return
        }

        liveMirrorManualResyncRunning = true
        liveMirrorManualResyncError = nil
        liveMirrorSynchronized = false
        liveMirrorStatus = "Live Mirror : relance manuelle en cours"

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.liveMirror.requestResynchronization()
                self.liveMirrorManualResyncRunning = false
            } catch is CancellationError {
                self.liveMirrorManualResyncRunning = false
            } catch {
                self.liveMirrorManualResyncRunning = false
                self.liveMirrorManualResyncError = error.localizedDescription
                self.liveMirrorStatus = "Live Mirror : relance refusée — \(error.localizedDescription)"
            }
        }
    }

    private func makeLiveMirror() -> LiveMirrorEngine {
        let engine = LiveMirrorEngine()
        engine.qlab = runQLab
        engine.context = { [weak self] in
            guard let self else { return .init() }
            return .init(master: self.runtimeRole == .master,
                         connected: self.isConnected && !self.masterReturning && !self.failoverTakeoverLatched && !self.failoverActive,
                         session: self.runtimeRole == .master ? self.masterSessionID : (self.connectedSessionID ?? ""),
                         workspaceID: self.qlabOSCWorkspaceID ?? "",
                         root: self.runtimeRole == .master ? self.masterProjectFolderPath : self.workspaceTransferDestinationPath,
                         canReload: self.runtimeRole == .backup && self.liveMirrorReloadConditionsConfirmed && self.workspaceTransferReady
                            && !self.failoverActive && !self.failoverTakeoverLatched && !self.failoverPending
                            && !self.backupOutputTestActive && self.backupOutputMode == "ISOLATED"
                            && self.backupAudioIsolationConfirmed && self.hotStandbyOutputIsolationConfirmed,
                         initialTransfer: self.workspaceTransferInProgress)
        }
        engine.changed = { [weak self] ok, status in
            guard let self else { return }
            if self.liveMirrorStatus != status || self.liveMirrorSynchronized != ok {
                MirrorDiagnostics.log("MIROIR rôle=\(self.runtimeRole) synchronisé=\(ok) état=\(status)")
            }
            self.liveMirrorSynchronized = ok
            self.liveMirrorStatus = status
            if self.runtimeRole == .backup { self.refreshLocalQLabState() }
        }
        engine.send = { [weak self] payload in
            guard let self, let connection = self.activeConnection, self.isConnected else {
                throw MirrorFailure.invalid("Liaison MASTER/BACKUP fermée")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.sendJSONWithCompletion(payload, on: connection) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        engine.prepareReload = { [weak self] in
            self?.liveMirrorReloading = true
            self?.playheadSyncReady = false
            self?.backupAudioIsolationConfirmed = false
        }
        engine.reloadFailed = { [weak self] in
            guard let self, self.runtimeRole == .backup else { return }
            self.startQLabOSCMonitoring(workspace: self.qlabMonitoredWorkspace)
        }
        engine.verifyPlayhead = { [weak self] in
            guard let self, let workspaceID = self.qlabOSCWorkspaceID else {
                throw MirrorFailure.invalid("QLab BACKUP déconnecté pendant restauration du playhead")
            }
            guard let target = self.backupTargetPlayheadID else { return }
            let result = try await self.runQLab(MirrorQLab.restorePlayhead, [workspaceID, target])
            guard self.backupTargetPlayheadID == target, result == target, !self.liveMirrorMissedGo else {
                throw MirrorFailure.invalid("Playhead/GO changé pendant rechargement : revalidation requise")
            }
            self.backupPlayheadAppliedID = target
            self.backupPlayheadAppliedAt = Date()
            self.playheadSyncReady = true
            self.backupPlayheadSyncError = nil
        }
        engine.reconnected = { [weak self] name in
            self?.startQLabOSCMonitoring(workspace: name)
        }
        engine.readyAfterReload = { [weak self] in
            guard let self else { return false }
            let ready = self.qlabOSCConnected && self.backupAudioIsolationConfirmed
                && self.backupAudioControlReady && !self.liveMirrorMissedGo
                && !self.failoverActive && !self.backupOutputTestActive
            if ready { self.liveMirrorReloading = false }
            return ready
        }
        return engine
    }

    private func confirmInitialWorkspaceApplication(workspaceURL: URL, manifest: MirrorManifest, mediaRoot: URL) {
        initialApplyTask?.cancel()
        let transferID = workspaceTransferID
        let connection = activeConnection
        initialApplyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receivedRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/QLab Fallback").path
                _ = try await self.runQLab(MirrorQLab.openReceived, [manifest.workspaceID, workspaceURL.path, receivedRoot])
                MirrorDiagnostics.log("TRANSFERT workspace ouvert et chemin vérifié : \(workspaceURL.path)")
            } catch {
                guard !Task.isCancelled, self.workspaceTransferID == transferID else { return }
                self.finishWorkspaceTransferWithError("Ouverture QLab refusée : " + error.localizedDescription)
                return
            }
            guard !Task.isCancelled, self.workspaceTransferID == transferID,
                  self.activeConnection === connection else { return }
            self.startQLabOSCMonitoring(workspace: workspaceURL.deletingPathExtension().lastPathComponent)
            for attempt in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, self.workspaceTransferID == transferID,
                      self.activeConnection === connection else { return }
                if attempt % 10 == 0 {
                    if self.qlabOSCConnected, !self.backupAudioIsolationConfirmed {
                        if !self.backupAudioControlReady { self.requestBackupAudioConfiguration() }
                        else {
                            for patch in self.backupAudioPatches {
                                self.qlabOSCClient?.requestAudioPatchMuteChannels(patchID: patch.id)
                            }
                        }
                    }
                    MirrorDiagnostics.log("TRANSFERT validation en attente osc=\(self.qlabOSCConnected) workspace=\(self.qlabOSCWorkspaceID ?? "absent") audio=\(self.backupAudioControlReady) isolation=\(self.backupAudioIsolationConfirmed) erreur=\(self.qlabOSCError ?? self.backupAudioControlError ?? "aucune")")
                }
                guard let id = self.qlabOSCWorkspaceID, self.qlabOSCConnected,
                      self.backupAudioIsolationConfirmed, self.backupAudioControlReady else { continue }
                do {
                    let opened = try await self.runQLab(MirrorQLab.idle, [id])
                    guard URL(fileURLWithPath: opened).resolvingSymlinksInPath().standardizedFileURL == workspaceURL.resolvingSymlinksInPath().standardizedFileURL else { throw MirrorFailure.invalid("QLab a ouvert un autre workspace") }
                    guard id == manifest.workspaceID else { throw MirrorFailure.invalid("Identifiant workspace reçu incorrect") }
                    for (cueID, relative) in manifest.mediaTargets.sorted(by: { $0.key < $1.key }) {
                        guard !Task.isCancelled, self.workspaceTransferID == transferID,
                              self.activeConnection === connection else { return }
                        let media = try MirrorFiles.safeURL(relative, under: mediaRoot)
                        _ = try await self.runQLab(MirrorQLab.relink, [id, workspaceURL.path, cueID, media.path])
                        MirrorDiagnostics.log("MEDIA relink vérifié cue=\(cueID) target=\(media.path)")
                    }
                    _ = try await self.runQLab(MirrorQLab.saveExpected, [id, workspaceURL.path])
                    for (cueID, relative) in manifest.mediaTargets.sorted(by: { $0.key < $1.key }) {
                        guard !Task.isCancelled, self.workspaceTransferID == transferID,
                              self.activeConnection === connection else { return }
                        let media = try MirrorFiles.safeURL(relative, under: mediaRoot)
                        _ = try await self.runQLab(MirrorQLab.verifyTargets, [id, workspaceURL.path, cueID, media.path])
                        MirrorDiagnostics.log("MEDIA target après sauvegarde vérifié cue=\(cueID) target=\(media.path)")
                    }
                    _ = try await self.runQLab(MirrorQLab.verify, [id, workspaceURL.path])
                    guard !Task.isCancelled, self.workspaceTransferID == transferID,
                          self.activeConnection === connection, let connection else { return }
                    guard self.qlabOSCConnected, self.qlabOSCWorkspaceID == id,
                          self.backupAudioIsolationConfirmed, self.backupAudioControlReady,
                          !self.failoverActive, !self.backupOutputTestActive else {
                        throw MirrorFailure.invalid("État QLab/isolation changé pendant le relink : validation refusée")
                    }
                    self.validatedInitialWorkspaceID = id
                    self.workspaceTransferReady = true
                    // Automatic synchronization explicitly requested by the operator.
                    // Runtime guards still require idle cues and confirmed isolation.
                    self.liveMirrorReloadConditionsConfirmed = true
                    self.refreshLocalQLabState()
                    MirrorDiagnostics.log("WORKSPACE validé id=\(id) correspondance=\(self.localQLabWorkspaceMatchesMaster)")
                    self.workspaceTransferInProgress = false
                    self.workspaceTransferStatus = "Projet validé : médias reliés et isolation audio vérifiée"
                    MirrorDiagnostics.log("TRANSFERT validé : \(manifest.mediaTargets.count) targets sauvegardés, isolation confirmée")
                    self.sendJSON(["type": "TRANSFER_COMPLETE", "transferID": transferID ?? "",
                                   "applied": true, "destination": workspaceURL.path], on: connection)
                    self.liveMirror.start()
                    return
                } catch {
                    MirrorDiagnostics.log("MEDIA application refusée : \(error.localizedDescription)")
                    self.finishWorkspaceTransferWithError(error.localizedDescription)
                    return
                }
            }
            self.finishWorkspaceTransferWithError("Copie reçue, validation QLab incomplète : OSC=\(self.qlabOSCConnected), audio=\(self.backupAudioControlReady), isolation=\(self.backupAudioIsolationConfirmed). \(self.qlabOSCError ?? self.backupAudioControlError ?? "Délai de validation dépassé")")
        }
    }
}

extension NetworkDiscovery {
    private func recoverySend(_ type: String, _ fields: [String: Any] = [:]) {
        guard let connection = activeConnection, isConnected else { return }
        var payload = fields
        payload["type"] = type
        payload["sessionID"] = runtimeRole == .master ? masterSessionID : connectedSessionID
        payload["workspaceID"] = qlabOSCWorkspaceID
        payload["takeoverID"] = recoveryToken
        sendJSON(payload, on: connection)
    }
    private func startRecoveryMonitor() {
        guard recoveryMonitor == nil else { return }
        recoveryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.runtimeRole == .backup, self.failoverActive || self.failoverTakeoverLatched {
                    if self.recoveryToken == nil { self.recoveryToken = UUID().uuidString }
                    if self.returnInProgress, let returnID = self.returnToken {
                        self.recoverySend(self.backupAudioIsolationConfirmed ? "RECOVERY_RETURN_MUTED" : "RECOVERY_RETURN_PREPARE", ["returnID": returnID])
                    } else { self.recoverySend("RECOVERY_OFFER") }
                }
                if self.runtimeRole == .master, self.masterReturning, !self.returnInProgress,
                   self.recoveryOperation == nil, self.isConnected, self.qlabOSCConnected, self.recoveryMasterIsolated {
                    if let pending = self.recoveryRequest,
                       ProcessInfo.processInfo.systemUptime - pending.sent > 3 { self.recoveryRequest = nil }
                    if self.recoveryRequest == nil {
                        let request = UUID().uuidString
                        self.recoveryRequest = (request, ProcessInfo.processInfo.systemUptime)
                        self.recoverySend("RECOVERY_REQUEST", ["requestID": request])
                    }
                }
                if Date().timeIntervalSince(self.recoveryLastReady) > 3 { self.masterReturnReady = false }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    private func recoveryPayload(_ state: RecoverySnapshot) throws -> String {
        try JSONEncoder().encode(state).base64EncodedString()
    }
    private func decodeRecovery(_ object: [String: Any]) throws -> RecoverySnapshot {
        guard let encoded = object["state"] as? String, encoded.count < 131072,
              let data = Data(base64Encoded: encoded) else { throw MirrorFailure.invalid("État de retour absent") }
        let result = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        try result.validate(); return result
    }
    private func configureRecoveryCheck(_ connection: NWConnection, token: String) {
        let client = qlabOSCClient
        recoveryIO.check = { [weak self, weak connection, weak client] in
            guard let self, let connection, let client,
                  self.activeConnection === connection, self.qlabOSCClient === client,
                  self.recoveryToken == token, self.isConnected, self.qlabOSCConnected,
                  !Task.isCancelled else { throw CancellationError() }
        }
    }
    private func handleRecovery(_ object: [String: Any], on connection: NWConnection) {
        let expectedSession = runtimeRole == .master ? masterSessionID : connectedSessionID
        guard activeConnection === connection, isConnected,
              object["sessionID"] as? String == expectedSession,
              let remoteID = object["workspaceID"] as? String,
              let token = object["takeoverID"] as? String, UUID(uuidString: token) != nil,
              let type = object["type"] as? String else { return }
        // During QLab startup, wait for a local identity rather than switching another workspace.
        guard qlabOSCWorkspaceID == remoteID else { return }
        if type == "RECOVERY_OFFER", runtimeRole == .master {
            if recoveryToken == token, let done = completedReturnToken {
                recoverySend("RECOVERY_RETURN_DONE", ["returnID": done]); return
            }
            if recoveryToken != token {
                recoveryOperation?.cancel()
                recoveryRequest = nil; recoveryState = nil; masterReturnReady = false; recoveryMasterIsolated = false
                returnToken = nil; completedReturnToken = nil; returnInProgress = false
            }
            recoveryToken = token; masterReturning = true
            recoveryStatus = masterReturnReady ? "MASTER aligné en silence — reprise manuelle disponible" : "Retour MASTER : mise à jour silencieuse en cours"
            startRecoveryMonitor()
            if !recoveryMasterIsolated && recoveryOperation == nil {
                configureRecoveryCheck(connection, token: token)
                let operationID = UUID(); recoveryOperationID = operationID
                recoveryOperation = Task { [weak self] in
                    guard let self else { return }
                    defer { if self.recoveryOperationID == operationID { self.recoveryOperation = nil } }
                    do {
                        try await self.recoveryIO.isolate()
                        self.recoveryMasterIsolated = true
                        MirrorDiagnostics.log("RETOUR MASTER : isolation confirmée avant réception de l'état BACKUP")
                    } catch {
                        self.masterReturnReady = false; self.recoveryStatus = error.localizedDescription
                        self.recoverySend("RECOVERY_ERROR", ["message": error.localizedDescription])
                    }
                }
            }
            return
        }
        guard token == recoveryToken else { return }
        if type == "RECOVERY_READY", runtimeRole == .backup, failoverActive || failoverTakeoverLatched {
            masterReturnReady = true; recoveryLastReady = Date()
            recoveryStatus = "MASTER aligné en silence — le BACKUP garde le son"
            return
        }
        if type == "RECOVERY_ERROR" {
            masterReturnReady = false
            if runtimeRole == .backup && !backupAudioIsolationConfirmed {
                if let pending = returnToken { recoverySend("RECOVERY_RETURN_CANCEL", ["returnID": pending]) }
                returnInProgress = false; returnToken = nil
            }
            recoveryStatus = object["message"] as? String ?? "Retour MASTER non confirmé"
            MirrorDiagnostics.log("RETOUR refusé : " + recoveryStatus)
            return
        }
        if type == "RECOVERY_RETURN_CANCEL", runtimeRole == .master,
           completedReturnToken == nil, object["returnID"] as? String == returnToken {
            returnInProgress = false; returnToken = nil; masterReturnReady = false
            recoveryRequest = nil
            return
        }
        if type == "RECOVERY_RETURN_DONE", runtimeRole == .backup,
           object["returnID"] as? String == returnToken, returnInProgress {
            failoverActive = false; failoverTakeoverLatched = false; failoverActivationPending = false
            failoverPending = false; failoverReason = nil; backupOutputMode = "ISOLATED"
            failoverActivationError = nil; failoverDeactivationError = nil
            failoverDeactivationPending = false
            returnInProgress = false; masterReturnReady = false
            recoveryStatus = "Son repris sur le MASTER — BACKUP isolé"
            recoveryToken = nil; returnToken = nil
            liveMirror.start(); refreshLocalQLabState()
            return
        }
        guard recoveryOperation == nil else { return }
        configureRecoveryCheck(connection, token: token)
        let operationID = UUID(); recoveryOperationID = operationID
        recoveryOperation = Task { [weak self] in
            guard let self else { return }
            defer { if self.recoveryOperationID == operationID { self.recoveryOperation = nil } }
            do {
                switch type {
                case "RECOVERY_REQUEST":
                    guard self.runtimeRole == .backup, self.failoverActive || self.failoverTakeoverLatched,
                          let request = object["requestID"] as? String else { return }
                    let state = try await self.recoveryIO.snapshot()
                    self.recoverySend("RECOVERY_STATE", ["requestID": request, "state": try self.recoveryPayload(state)])
                case "RECOVERY_STATE":
                    guard self.runtimeRole == .master, self.masterReturning,
                          let pending = self.recoveryRequest, object["requestID"] as? String == pending.id else { return }
                    self.recoveryRequest = nil
                    let age = (ProcessInfo.processInfo.systemUptime - pending.sent) / 2
                    guard age < 1 else { throw MirrorFailure.invalid("Retour MASTER : liaison trop lente pour confirmer la lecture") }
                    let state = try self.decodeRecovery(object)
                    self.masterReturnReady = false
                    let began = ProcessInfo.processInfo.systemUptime
                    try await self.recoveryIO.isolate()
                    try await self.recoveryIO.restore(state, age: age + ProcessInfo.processInfo.systemUptime - began)
                    self.recoveryState = try await self.recoveryIO.snapshot()
                    self.recoveryStateAt = ProcessInfo.processInfo.systemUptime
                    self.masterReturnReady = true; self.recoveryLastReady = Date()
                    self.recoveryStatus = "MASTER aligné en silence — reprise manuelle disponible"
                    self.recoverySend("RECOVERY_READY")
                case "RECOVERY_RETURN_PREPARE":
                    guard self.runtimeRole == .master, self.masterReturning,
                          let returnID = object["returnID"] as? String, UUID(uuidString: returnID) != nil,
                          (self.returnToken == returnID && self.returnInProgress) ||
                          (self.masterReturnReady && Date().timeIntervalSince(self.recoveryLastReady) < 3) else {
                        throw MirrorFailure.invalid("Le MASTER n'est pas encore prêt à reprendre")
                    }
                    try await self.recoveryIO.isolate()
                    let state = try await self.recoveryIO.snapshot()
                    self.returnToken = returnID; self.returnInProgress = true
                    self.recoverySend("RECOVERY_RETURN_PREPARED", ["returnID": returnID, "state": try self.recoveryPayload(state)])
                case "RECOVERY_RETURN_PREPARED":
                    guard self.runtimeRole == .backup, self.returnInProgress,
                          object["returnID"] as? String == self.returnToken else { return }
                    let master = try self.decodeRecovery(object)
                    let local = try await self.recoveryIO.snapshot()
                    guard master.matches(local, age: 0, tolerance: 1) else {
                        throw MirrorFailure.invalid("Le BACKUP a changé : attendre un nouvel alignement du MASTER")
                    }
                    self.setBackupAudioMuted(true, reason: "reprise manuelle MASTER")
                    for _ in 0..<40 {
                        try await Task.sleep(nanoseconds: 100_000_000); try self.recoveryIO.check()
                        if self.backupAudioIsolationConfirmed { break }
                    }
                    guard self.backupAudioIsolationConfirmed else { throw MirrorFailure.invalid("BACKUP non isolé : son MASTER maintenu coupé") }
                    self.recoverySend("RECOVERY_RETURN_MUTED", ["returnID": self.returnToken ?? ""])
                case "RECOVERY_RETURN_MUTED":
                    guard self.runtimeRole == .master, let returnID = object["returnID"] as? String,
                          returnID == self.returnToken else { return }
                    if self.completedReturnToken != returnID {
                        guard self.returnInProgress, self.masterReturning else { return }
                        try await self.recoveryIO.release()
                        self.completedReturnToken = returnID
                    }
                    self.recoverySend("RECOVERY_RETURN_DONE", ["returnID": returnID])
                    self.returnInProgress = false; self.masterReturning = false; self.masterReturnReady = false
                    self.recoveryStatus = "MASTER actif — reprise sonore confirmée"
                    if let cue = self.masterPlayheadID { self.sendPlayheadUpdate(cueID: cue) }
                default: break
                }
            } catch {
                self.masterReturnReady = false
                self.recoveryStatus = error.localizedDescription
                if self.runtimeRole == .backup && !self.backupAudioIsolationConfirmed {
                    if let pending = self.returnToken { self.recoverySend("RECOVERY_RETURN_CANCEL", ["returnID": pending]) }
                    self.returnInProgress = false; self.returnToken = nil
                }
                self.recoverySend("RECOVERY_ERROR", ["message": error.localizedDescription])
                MirrorDiagnostics.log("RETOUR refusé : \(error.localizedDescription)")
            }
        }
    }
    func requestMasterReturn() {
        guard runtimeRole == .backup, failoverActive || failoverTakeoverLatched,
              masterReturnReady, isConnected, heartbeatAlive, !returnInProgress,
              Date().timeIntervalSince(recoveryLastReady) < 3 else {
            failoverDeactivationError = "Attendre le MASTER aligné en silence avant de reprendre le son"
            return
        }
        returnToken = UUID().uuidString; returnInProgress = true
        recoveryStatus = "Reprise manuelle : vérification du MASTER avant ré-isolation du BACKUP"
        recoverySend("RECOVERY_RETURN_PREPARE", ["returnID": returnToken!])
    }
}

extension NetworkDiscovery {
    private func speedSend(_ type: String, id: String, extra: [String: Any] = [:]) {
        guard let connection = activeConnection, isConnected else { return }
        var frame = extra
        frame["type"] = type; frame["id"] = id
        frame["sessionID"] = runtimeRole == .master ? masterSessionID : connectedSessionID
        sendJSON(frame, on: connection)
    }
    func cancelNetworkSpeedTest() {
        if let id = speedID { speedSend("SPEED_CANCEL", id: id) }
        finishSpeedTest("Test de débit arrêté")
    }
    private func finishSpeedTest(_ message: String) {
        speedID = nil; networkSpeedRunning = false
        speedTask?.cancel(); speedTask = nil
        speedProbe?.cancel(); speedProbe = nil
        networkSpeedStatus = message
    }
    private func speedDeadline(id: String) {
        speedTask = Task { [weak self] in
            for _ in 0..<150 {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, self.speedID == id else { return }
                if !self.isConnected || self.workspaceTransferInProgress || self.liveMirrorReloading
                    || self.failoverActive || self.failoverTakeoverLatched || self.masterReturning {
                    self.cancelNetworkSpeedTest(); return
                }
            }
            guard let self, self.speedID == id else { return }
            self.speedSend("SPEED_CANCEL", id: id)
            self.finishSpeedTest("Test non disponible : vérifier que les deux Mac utilisent la Build5.13 ou une version compatible.")
        }
    }
    func startNetworkSpeedTest() {
        guard canTestNetworkSpeed else { return }
        let id = UUID().uuidString
        speedID = id; networkSpeedRunning = true; networkSpeedStatus = "Vérification avant le test…"
        speedDeadline(id: id)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let workspace = self.qlabOSCWorkspaceID else { throw MirrorFailure.invalid("QLab non connecté") }
                _ = try await self.runQLab(MirrorQLab.idle, [workspace])
                guard self.speedID == id, self.isConnected else { return }
                self.networkSpeedStatus = "Connexion au test du MASTER…"
                self.speedSend("SPEED_REQUEST", id: id)
            } catch {
                guard self.speedID == id else { return }
                self.finishSpeedTest("Test impossible : " + error.localizedDescription)
            }
        }
    }
    private func handleSpeedFrame(_ frame: [String: Any], on connection: NWConnection) {
        guard activeConnection === connection, isConnected,
              frame["sessionID"] as? String == (runtimeRole == .master ? masterSessionID : connectedSessionID),
              let id = frame["id"] as? String, UUID(uuidString: id) != nil,
              let type = frame["type"] as? String else { return }
        if type == "SPEED_REQUEST", runtimeRole == .master {
            guard !networkSpeedRunning, !workspaceTransferInProgress, !liveMirrorReloading,
                  !masterReturning, !returnInProgress, qlabOSCConnected else {
                speedSend("SPEED_ERROR", id: id, extra: ["message": "MASTER occupé : attendre la fin de l’opération en cours"]); return
            }
            speedID = id; networkSpeedRunning = true; networkSpeedStatus = "Test demandé par le BACKUP…"
            speedDeadline(id: id)
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let workspace = self.qlabOSCWorkspaceID else { throw MirrorFailure.invalid("QLab non connecté") }
                    _ = try await self.runQLab(MirrorQLab.idle, [workspace])
                    guard self.speedID == id, self.activeConnection === connection else { return }
                    let probe = NetworkSpeedProbe(token: id) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.speedID == id else { return }
                            if case .failure(let error) = result {
                                self.speedSend("SPEED_ERROR", id: id, extra: ["message": error.localizedDescription])
                                self.finishSpeedTest(error.localizedDescription)
                            }
                        }
                    }
                    self.speedProbe = probe
                    probe.serve(parameters: try self.networkParameters()) { [weak self] port in
                        Task { @MainActor in
                            guard let self, self.speedID == id else { return }
                            self.networkSpeedStatus = "Test réseau MASTER → BACKUP (32 Mio)…"
                            self.speedSend("SPEED_READY", id: id, extra: ["port": Int(port)])
                        }
                    }
                } catch {
                    guard self.speedID == id else { return }
                    self.speedSend("SPEED_ERROR", id: id, extra: ["message": error.localizedDescription])
                    self.finishSpeedTest(error.localizedDescription)
                }
            }
            return
        }
        guard speedID == id else { return }
        if type == "SPEED_CANCEL" { finishSpeedTest("Test de débit arrêté"); return }
        if type == "SPEED_ERROR" { finishSpeedTest(frame["message"] as? String ?? "Test refusé"); return }
        if type == "SPEED_RESULT", runtimeRole == .master,
           let value = frame["mbps"] as? Double, value.isFinite, value > 0,
           let route = frame["route"] as? String, route.count < 160 {
            finishSpeedTest(String(format: "Débit réseau : %.1f Mo/s — %@", value, route)); return
        }
        if type == "SPEED_READY", runtimeRole == .backup, speedProbe == nil {
            guard let port = frame["port"] as? Int, (1...65535).contains(port),
                  case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint else {
                speedSend("SPEED_CANCEL", id: id); finishSpeedTest("Adresse du MASTER indisponible pour le test"); return
            }
            do {
                let probe = NetworkSpeedProbe(token: id) { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.speedID == id else { return }
                        switch result {
                        case .success(let measurement):
                            self.speedSend("SPEED_RESULT", id: id, extra: ["mbps": measurement.megabytesPerSecond, "route": measurement.route])
                            let text = String(format: "Débit réseau : %.1f Mo/s — %@", measurement.megabytesPerSecond, measurement.route)
                            MirrorDiagnostics.log("TEST DÉBIT : " + text)
                            self.finishSpeedTest(text)
                        case .failure(let error):
                            self.speedSend("SPEED_CANCEL", id: id); self.finishSpeedTest(error.localizedDescription)
                        }
                    }
                }
                speedProbe = probe; networkSpeedStatus = "Mesure MASTER → BACKUP (32 Mio)…"
                probe.receive(host: host, port: UInt16(port), parameters: try networkParameters())
            } catch {
                speedSend("SPEED_CANCEL", id: id); finishSpeedTest(error.localizedDescription)
            }
        }
    }
}

extension NetworkDiscovery {
    private func stopBinaryTransfer() {
        binaryTransferGeneration = UUID()
        let transfer = binaryTransfer; binaryTransfer = nil; transfer?.cancel()
    }
    private func binaryParameters(on connection: NWConnection) throws -> NWParameters {
        let parameters = try networkParameters()
        if selectedNetworkInterface == "auto", let path = connection.currentPath,
           let interface = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) && $0.type == .wiredEthernet }) {
            parameters.requiredInterface = interface
        }
        return parameters
    }
    private func binaryProgress(_ result: WorkspaceBinaryTransfer.Measurement) {
        workspaceTransferBytes = result.bytes
        workspaceTransferSpeedBytesPerSecond = result.bytesPerSecond
        workspaceTransferProgress = min(0.99, Double(result.bytes) / Double(max(1, workspaceTransferTotalBytes)))
    }
    private func startBinaryWorkspaceSend(archive: URL, size: Int64, sourceSize: Int64,
        hash: String, projectName: String, transferID: String, connection: NWConnection) {
        stopBinaryTransfer()
        let generation = binaryTransferGeneration
        let token = UUID().uuidString
        let transfer = WorkspaceBinaryTransfer(token: token, size: size, progress: { [weak self] progress in
            Task { @MainActor in
                guard let self, self.binaryTransferGeneration == generation else { return }
                self.binaryProgress(progress)
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.binaryTransferGeneration == generation,
                      self.workspaceTransferID == transferID, self.activeConnection === connection else { return }
                switch result {
                case .success(let measurement):
                    self.binaryProgress(measurement)
                    self.workspaceTransferProgress = 1
                    self.workspaceTransferStatus = "Projet envoyé — vérification du BACKUP…"
                    MirrorDiagnostics.log("TRANSFERT BINAIRE envoyé : \(measurement.bytes) octets, \(measurement.bytesPerSecond / 1_000_000) Mo/s")
                    if !self.workspaceTransferReady { self.startWorkspaceTransferConfirmationTimeout() }
                    self.cleanupMasterWorkspaceTransfer(removeStatus: false)
                case .failure(let error):
                    self.finishWorkspaceTransferWithError(error.localizedDescription)
                    self.sendJSON(["type": "TRANSFER_ERROR", "transferID": transferID,
                                   "message": error.localizedDescription], on: connection)
                    self.cleanupMasterWorkspaceTransfer(removeStatus: false)
                }
            }
        })
        binaryTransfer = transfer
        do {
            transfer.serve(file: archive, parameters: try binaryParameters(on: connection)) { [weak self] port in
                Task { @MainActor in
                    guard let self, self.binaryTransferGeneration == generation,
                          self.activeConnection === connection else { return }
                    self.sendJSONWithCompletion(["type": "TRANSFER_START", "transferID": transferID,
                        "workspace": self.masterWorkspace, "projectName": projectName,
                        "size": size, "sourceSize": sourceSize, "sha256": hash,
                        "transport": "binary-v1", "port": Int(port), "token": token], on: connection) { error in
                        if let error {
                            Task { @MainActor in
                                guard self.binaryTransferGeneration == generation else { return }
                                self.finishWorkspaceTransferWithError(error.localizedDescription)
                            }
                        }
                    }
                }
            }
        } catch { finishWorkspaceTransferWithError(error.localizedDescription) }
    }
    private func startBinaryWorkspaceReceive(_ metadata: [String: Any]) {
        guard let connection = activeConnection, let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = endpoint,
              let port = metadata["port"] as? Int, port > 0, port <= 65535,
              let token = metadata["token"] as? String, UUID(uuidString: token) != nil,
              let url = workspaceTransferReceiveURL, let transferID = workspaceTransferID else {
            finishWorkspaceTransferWithError("Connexion binaire du projet invalide"); return
        }
        let generation = binaryTransferGeneration
        let transfer = WorkspaceBinaryTransfer(token: token, size: workspaceTransferTotalBytes, progress: { [weak self] progress in
            Task { @MainActor in
                guard let self, self.binaryTransferGeneration == generation else { return }
                self.binaryProgress(progress)
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.binaryTransferGeneration == generation,
                      self.workspaceTransferID == transferID, self.activeConnection === connection else { return }
                switch result {
                case .success(let measurement):
                    self.binaryProgress(measurement)
                    MirrorDiagnostics.log("TRANSFERT BINAIRE reçu et écrit : \(measurement.bytes) octets, \(measurement.bytesPerSecond / 1_000_000) Mo/s")
                    self.stopBinaryTransfer()
                    self.handleWorkspaceTransferMessage(["type": "TRANSFER_END", "transferID": transferID])
                case .failure(let error): self.finishWorkspaceTransferWithError(error.localizedDescription)
                }
            }
        })
        binaryTransfer = transfer
        do { transfer.receive(file: url, host: host, port: UInt16(port), parameters: try binaryParameters(on: connection)) }
        catch { finishWorkspaceTransferWithError(error.localizedDescription) }
    }
}
