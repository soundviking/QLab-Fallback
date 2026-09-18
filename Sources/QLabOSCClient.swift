import Foundation
import Network

final class QLabOSCClient: @unchecked Sendable {

    enum OSCValue {
        case string(String)
        case int32(Int32)
        case float(Float)
        case double(Double)
        case bool(Bool)

        var stringValue: String? {
            if case .string(let value) = self {
                return value
            }
            return nil
        }
    }

    struct OSCMessage {
        let address: String
        let arguments: [OSCValue]
    }

    var onPlayhead: (@Sendable (String) -> Void)?
    var onPlayheadEvent: (@Sendable (String) -> Void)?
    var onGo: (@Sendable (String) -> Void)?
    var onPanicAll: (@Sendable () -> Void)?
    var onConnected: (@Sendable (String) -> Void)?
    var onQLabVersionDetected: (@Sendable (String) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    // Diagnostic uniquement :
    // permet d'observer une réponse OSC sans modifier QLab.
    var onRawMessage:
        (@Sendable (String, [String]) -> Void)?

    private let queue =
        DispatchQueue(
            label: "fr.viking.qlabfallback.osc"
        )

    private let qlabHost =
        NWEndpoint.Host("127.0.0.1")

    private let qlabPort: NWEndpoint.Port
    private let replyPort: NWEndpoint.Port
    private let queueKey = DispatchSpecificKey<Bool>()
    private var session = UUID()
    private var discoveryTimer: DispatchSourceTimer?

    // Alternate ports allow real UDP regression tests without touching local QLab.
    init(port: UInt16 = 53000, replyPort: UInt16 = 53001) {
        self.qlabPort = NWEndpoint.Port(rawValue: port)!
        self.replyPort = NWEndpoint.Port(rawValue: replyPort)!
        queue.setSpecific(key: queueKey, value: true)
    }

    private var sender: NWConnection?
    private var listener: NWListener?
    private var receiverConnections: [NWConnection] = []
    private var receiverActivity: [ObjectIdentifier: TimeInterval] = [:]

    private var expectedWorkspaceName = ""
    private var workspaceID: String?
    private var currentCueListID: String?

    private var passcode: String?

    private var recoveryQueries = [String: (UUID, CheckedContinuation<Data, Error>)]()

    func recoveryQuery(_ address: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.connected, let id = self.workspaceID,
                      address.hasPrefix("/workspace/" + id + "/"),
                      self.recoveryQueries[address] == nil else {
                    continuation.resume(throwing: MirrorFailure.invalid("Requête de reprise indisponible")); return
                }
                let token = UUID()
                self.recoveryQueries[address] = (token, continuation)
                self.send(address: address)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard self.recoveryQueries[address]?.0 == token,
                          let pending = self.recoveryQueries.removeValue(forKey: address) else { return }
                    pending.1.resume(throwing: MirrorFailure.invalid("Réponse QLab de reprise absente"))
                }
            }
        }
    }

    func recoveryCommand(_ address: String, arguments: [OSCValue] = []) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            return queue.sync { self.recoveryCommand(address, arguments: arguments) }
        }
        guard connected, let id = workspaceID, address.hasPrefix("/workspace/" + id + "/") else { return false }
        send(address: address, arguments: arguments)
        return true
    }

    private var started = false
    private var connected = false

    private let goLock = NSLock()
    private var pendingGo = [(token: UUID, cue: String)]()

    private func confirmMirroredGo(_ cueID: String) {
        goLock.lock()
        let index = pendingGo.firstIndex { $0.cue == cueID }
        let pending = index.map { pendingGo.remove(at: $0) }
        goLock.unlock()
        if let pending { MirrorDiagnostics.log("GO exécuté : démarrage QLab observé cue=\(cueID) requête=\(pending.token)") }
    }

    func start(
        workspaceName: String,
        passcode: String? = nil
    ) {
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            return queue.sync { self.start(workspaceName: workspaceName, passcode: passcode) }
        }
        stop()

        expectedWorkspaceName =
            workspaceName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let cleanedPasscode =
            passcode?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        self.passcode =
            cleanedPasscode?.isEmpty == true
                ? nil
                : cleanedPasscode

        let generation = session
        MirrorDiagnostics.log("OSC démarrage session=\(generation) workspace=\(expectedWorkspaceName)")
        do {
            let listener =
                try NWListener(
                    using: .udp,
                    on: replyPort
                )

            listener.stateUpdateHandler = {
                [weak self] state in

                guard let self, self.session == generation else {
                    return
                }

                switch state {

                case .ready:
                    self.onStatus?(
                        "OSC QLab : écoute UDP 53001 active"
                    )

                    self.startSender()

                case .failed(let error):
                    self.reportError(
                        "Écoute OSC impossible : "
                        + error.localizedDescription
                    )

                case .cancelled:
                    break

                default:
                    break
                }
            }

            listener.newConnectionHandler = {
                [weak self] connection in

                guard let self, self.session == generation else {
                    return
                }

                self.expireReceivers()
                self.receiverConnections.append(connection)
                self.receiverActivity[ObjectIdentifier(connection)] = ProcessInfo.processInfo.systemUptime

                connection.stateUpdateHandler = {
                    [weak self, weak connection] state in

                    guard let self, let connection, self.session == generation,
                          self.receiverConnections.contains(where: { $0 === connection }) else { return }
                    if case .failed(let error) = state {
                        self.reportError(
                            "Réception OSC : "
                            + error.localizedDescription
                        )
                    }
                }

                connection.start(
                    queue: self.queue
                )

                self.receive(
                    on: connection
                )
            }

            self.listener = listener

            listener.start(
                queue: queue
            )

            started = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.started, self.session == generation else { return }
                self.expireReceivers()
                guard !self.connected else { return }
                if self.sender == nil { self.startSender() }
                else { self.requestWorkspaces() }
            }
            discoveryTimer = timer
            timer.resume()

        } catch {
            reportError(
                "Impossible de démarrer OSC : "
                + error.localizedDescription
            )
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.stop() } }

        if started {
            send(
                address: "/udpKeepAlive",
                arguments: [
                    .bool(false)
                ]
            )

            print(
                "OSC QLab : UDP keepalive désactivé"
            )
        }

        started = false
        connected = false
        session = UUID()
        discoveryTimer?.cancel()
        discoveryTimer = nil

        sender?.cancel()
        sender = nil

        for connection in receiverConnections {
            connection.cancel()
        }

        receiverConnections.removeAll()
        let abandonedQueries = recoveryQueries.values
        recoveryQueries.removeAll()
        for pending in abandonedQueries { pending.1.resume(throwing: MirrorFailure.invalid("Connexion QLab remplacée")) }

        receiverActivity.removeAll()

        listener?.cancel()
        listener = nil

        workspaceID = nil
        currentCueListID = nil
        goLock.lock(); pendingGo.removeAll(); goLock.unlock()
    }

    private func startSender() {
        let generation = session
        let connection =
            NWConnection(
                host: qlabHost,
                port: qlabPort,
                using: .udp
            )

        connection.stateUpdateHandler = {
            [weak self, weak connection] state in

            guard let self, let connection, self.sender === connection, self.started, self.session == generation else {
                return
            }

            switch state {

            case .ready:
                self.onStatus?(
                    "OSC QLab : connexion UDP 53000 prête"
                )

                if self.replyPort.rawValue != 53001 {
                    self.send(address: "/udpReplyPort", arguments: [.int32(Int32(self.replyPort.rawValue))])
                }
                self.requestWorkspaces()

            case .failed(let error):
                self.sender?.cancel()
                self.sender = nil
                self.connected = false
                self.reportError(
                    "Connexion OSC QLab impossible : "
                    + error.localizedDescription
                )

            case .cancelled:
                break

            default:
                break
            }
        }

        sender = connection

        connection.start(
            queue: queue
        )
    }

    // MARK: - Découverte QLab

    private func requestWorkspaces() {
        onStatus?(
            "OSC QLab : recherche du workspace"
        )

        send(
            address: "/workspaces"
        )
    }

    private func connectToWorkspace(
        id: String
    ) {
        workspaceID = id

        let address =
            "/workspace/\(id)/connect"

        if let passcode {
            send(
                address: address,
                arguments: [
                    .string(passcode)
                ]
            )
        } else {
            send(
                address: address
            )
        }
    }

    @discardableResult
    func executeHotStandbyGo(cueID: String) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.executeHotStandbyGo(cueID: cueID) } }
        guard connected, let workspaceID, sender != nil, !cueID.isEmpty else {
            MirrorDiagnostics.log("GO refusé OSC : QLab non connecté cue=\(cueID)")
            return false
        }
        // Start the actual PRIMARY cue atomically. Playhead replication is independent:
        // a PLAYHEAD for the next cue must never race a two-datagram select + GO.
        let token = UUID()
        goLock.lock(); pendingGo.append((token, cueID)); goLock.unlock()
        send(address: "/workspace/\(workspaceID)/cue_id/\(cueID)/start")
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.goLock.lock()
            let pending = self.pendingGo.firstIndex { $0.token == token }.map { self.pendingGo.remove(at: $0) }
            self.goLock.unlock()
            if pending != nil {
                MirrorDiagnostics.log("GO exécution non confirmée après 3 s cue=\(cueID) requête=\(token) (pré-attente, refus ou retour OSC absent ; aucun renvoi automatique)")
            }
        }
        MirrorDiagnostics.log("GO exécution demandée OSC cue=\(cueID) workspace=\(workspaceID)")
        return true
    }

    func executeHotStandbyPanic() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.executeHotStandbyPanic() } }
        guard
            connected,
            let workspaceID
        else {
            reportError(
                "PANIC HOT STANDBY impossible : QLab non connecté"
            )
            return
        }

        send(
            address:
                "/workspace/\(workspaceID)/panic"
        )

        onStatus?(
            "HOT STANDBY : PANIC envoyé"
        )
    }


    @discardableResult
    func setPlayhead(
        cueID: String
    ) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.setPlayhead(cueID: cueID) } }
        guard
            connected,
            let workspaceID,
            !cueID.isEmpty
        else {
            reportError(
                "Impossible de synchroniser le playhead : QLab non connecté"
            )
            return false
        }

        let address =
            "/workspace/\(workspaceID)/playheadID/\(cueID)"

        onStatus?(
            "OSC QLab : synchronisation playhead \(cueID)"
        )

        send(
            address: address
        )
        if let currentCueListID { requestInitialPlayhead(cueListID: currentCueListID) }
        return true
    }


    private func subscribeToPlayhead() {
        guard let workspaceID else {
            return
        }

        send(address: "/workspace/\(workspaceID)/eventFormat", arguments: [.string("")])
        send(address: "/workspace/\(workspaceID)/ignore/go")
        send(address: "/workspace/\(workspaceID)/listen/playhead")

        send(
            address:
                "/workspace/\(workspaceID)/listen/go/uniqueID"
        )

        send(
            address:
                "/workspace/\(workspaceID)/listen/panicAll"
        )

        // A cue/start observation confirms that QLab acted on a mirrored command.
        send(address: "/workspace/\(workspaceID)/listen/cue/start/uniqueID")
        MirrorDiagnostics.log("GO abonnement OSC uniqueID demandé workspace=\(workspaceID)")

        // On récupère également le playhead déjà présent
        // au démarrage, sans attendre un mouvement manuel.
        send(
            address:
                "/workspace/\(workspaceID)/currentCueListID"
        )
    }

    private func requestInitialPlayhead(
        cueListID: String
    ) {
        guard let workspaceID else {
            return
        }

        currentCueListID = cueListID

        send(
            address:
                "/workspace/\(workspaceID)"
                + "/cue_id/\(cueListID)"
                + "/playheadID"
        )
    }

    func requestWorkspaceBasePath() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.requestWorkspaceBasePath() } }

        guard
            let workspaceID
        else {

            print(
                "QLab basePath : workspaceID encore indisponible"
            )

            return
        }


        send(
            address:
                "/workspace/"
                + workspaceID
                + "/basePath"
        )


        print(
            "QLab : demande basePath du workspace"
        )
    }


    // MARK: - Réception UDP

    // QLab may use a new source UDP port for each reply. NWListener creates a
    // new connection per endpoint; retain only recently active receivers.
    private func expireReceivers() {
        let now = ProcessInfo.processInfo.systemUptime
        let ordered = receiverConnections.sorted {
            (receiverActivity[ObjectIdentifier($0)] ?? 0) < (receiverActivity[ObjectIdentifier($1)] ?? 0)
        }
        let overflow = Set(ordered.prefix(max(0, ordered.count - 255)).map(ObjectIdentifier.init))
        let expired = receiverConnections.filter {
            now - (receiverActivity[ObjectIdentifier($0)] ?? 0) > 5 || overflow.contains(ObjectIdentifier($0))
        }
        let ids = Set(expired.map(ObjectIdentifier.init))
        receiverConnections.removeAll { ids.contains(ObjectIdentifier($0)) }
        for c in expired { receiverActivity.removeValue(forKey: ObjectIdentifier(c)); c.cancel() }
    }

    private func receive(
        on connection: NWConnection
    ) {
        let generation = session
        connection.receiveMessage {
            [weak self] data, _, _, error in

            guard let self, self.started, self.session == generation,
                  self.receiverConnections.contains(where: { $0 === connection }) else {
                return
            }
            self.receiverActivity[ObjectIdentifier(connection)] = ProcessInfo.processInfo.systemUptime

            if let error {
                self.reportError(
                    "Erreur réception OSC : "
                    + error.localizedDescription
                )

                return
            }

            if let data, !data.isEmpty {
                let messages = Self.decodeOSCPacket(data)
                if messages.isEmpty { MirrorDiagnostics.log("OSC paquet refusé : décodage impossible (\(data.count) octets)") }
                for message in messages { self.handle(message) }
            }

            if self.started {
                self.receive(
                    on: connection
                )
            }
        }
    }

    private func handle(
        _ message: OSCMessage
    ) {
        let debugArguments =
            message.arguments.compactMap {
                value -> String? in

                switch value {
                case .string(let string):
                    return string
                case .int32(let number):
                    return String(number)
                case .float(let number):
                    return String(number)
                case .double(let number):
                    return String(number)
                case .bool(let value):
                    return String(value)
                }
            }

        print(
            "OSC reçu :",
            message.address,
            "| arguments :",
            debugArguments
        )

        if message.address.hasPrefix("/reply/"),
           let pending = recoveryQueries.removeValue(forKey: String(message.address.dropFirst(6))) {
            if let json = replyJSON(from: message), json["status"] as? String == "ok",
               let value = json["data"], let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                pending.1.resume(returning: data)
            } else { pending.1.resume(throwing: MirrorFailure.invalid("Requête de reprise refusée par QLab")) }
        }

        onRawMessage?(
            message.address,
            debugArguments
        )

        // Discovery and watchdog share /workspaces. A watchdog reply must
        // still complete discovery when a workspace opens after Fallback.
        if message.address == "/reply/workspaces" {

            guard
                let json = replyJSON(
                    from: message
                ),
                (json["status"] as? String) == "ok",
                let workspaces =
                    json["data"]
                        as? [[String: Any]]
            else {
                reportError(
                    "QLab n'a pas retourné la liste des workspaces"
                )

                return
            }

            let wanted =
                normalizeWorkspaceName(
                    expectedWorkspaceName
                )

            let matches =
                workspaces.filter {
                    item in

                    guard let name =
                        item["displayName"]
                            as? String
                    else {
                        return false
                    }

                    return normalizeWorkspaceName(
                        name
                    ) == wanted
                }

            guard !matches.isEmpty else {
                connected = false
                workspaceID = nil
                let names =
                    workspaces.compactMap {
                        $0["displayName"]
                            as? String
                    }
                    .joined(
                        separator: ", "
                    )

                reportError(
                    "Workspace QLab introuvable. "
                    + "Recherché : "
                    + expectedWorkspaceName
                    + ". Ouverts : "
                    + names
                )

                return
            }

            // VERSION QLAB DÉTECTÉE
            if let qlabVersion =
                matches.first?["version"] as? String {

                print(
                    "QLab version détectée :",
                    qlabVersion
                )

                onQLabVersionDetected?(
                    qlabVersion
                )
            }


            guard matches.count == 1 else {
                reportError(
                    "Plusieurs workspaces QLab portent le nom « "
                    + expectedWorkspaceName
                    + " ». Fermez les doublons avant d'activer QLab Fallback."
                )

                return
            }

            let match = matches[0]

            guard let id =
                match["uniqueID"]
                    as? String
            else {
                reportError(
                    "QLab n'a pas fourni l'identifiant du workspace"
                )

                return
            }

            if connected, workspaceID == id { return }
            MirrorDiagnostics.log("OSC workspace découvert id=\(id), authentification demandée")
            onStatus?(
                "OSC QLab : workspace détecté \(id)"
            )

            connectToWorkspace(
                id: id
            )

            return
        }

        // ----------------------------------------------------
        // /connect
        // ----------------------------------------------------

        if let workspaceID,
           message.address ==
            "/reply/workspace/\(workspaceID)/connect" {

            guard let json =
                replyJSON(
                    from: message
                )
            else {
                reportError(
                    "Réponse /connect QLab invalide"
                )

                return
            }

            let status =
                json["status"] as? String

            let dataString =
                json["data"] as? String

            guard Self.authenticationAccepted(status: status, data: dataString) else {

                let detail =
                    dataString
                    ?? status
                    ?? "réponse inconnue"

                reportError(
                    "Connexion au workspace QLab refusée : "
                    + detail
                )

                return
            }

            connected = true
            MirrorDiagnostics.log("OSC authentification confirmée workspace=\(workspaceID)")

            onStatus?(
                "OSC QLab : workspace connecté"
            )

            // QLab déconnecte automatiquement
            // un client UDP après 61 secondes
            // sans message.
            //
            // udpKeepAlive maintient ici
            // l'authentification OSC active
            // pendant toute la session.
            send(
                address: "/udpKeepAlive",
                arguments: [
                    .bool(true)
                ]
            )

            print(
                "OSC QLab : UDP keepalive activé"
            )

            onConnected?(
                workspaceID
            )

            subscribeToPlayhead()

            return
        }

        // ----------------------------------------------------
        // currentCueListID
        // ----------------------------------------------------

        if let workspaceID,
           message.address ==
            "/reply/workspace/\(workspaceID)/currentCueListID" {

            guard
                let json =
                    replyJSON(
                        from: message
                    ),
                (json["status"] as? String) == "ok",
                let cueListID =
                    json["data"] as? String,
                !cueListID.isEmpty
            else {
                return
            }

            requestInitialPlayhead(
                cueListID: cueListID
            )

            return
        }

        // ----------------------------------------------------
        // playheadID initial
        // ----------------------------------------------------

        if let workspaceID,
           let currentCueListID,
           message.address ==
            "/reply/workspace/\(workspaceID)"
            + "/cue_id/\(currentCueListID)"
            + "/playheadID" {

            guard
                let json =
                    replyJSON(
                        from: message
                    ),
                (json["status"] as? String) == "ok",
                let cueID =
                    json["data"] as? String,
                !cueID.isEmpty,
                cueID.lowercased() != "none"
            else {
                return
            }

            onStatus?(
                "OSC QLab : playhead initial \(cueID)"
            )

            onPlayhead?(
                cueID
            )

            return
        }

        // ----------------------------------------------------
        // Broadcast GO
        // ----------------------------------------------------

        if message.address == "/qlab/event/workspace/go/uniqueID"
            || message.address == "/qlab/event/workspace/go" {
            guard connected, let cueID = Self.goCueID(message) else {
                MirrorDiagnostics.log("GO détecté mais refusé OSC : format/connexion invalide address=\(message.address) args=\(debugArguments)")
                return
            }
            MirrorDiagnostics.log("GO détecté cue=\(cueID)")
            onGo?(cueID)
            return
        }
        if (message.address == "/qlab/event/workspace/cue/start/uniqueID" || message.address == "/qlab/event/workspace/cue/start"),
           message.arguments.count == 1, let cueID = message.arguments.first?.stringValue {
            confirmMirroredGo(cueID)
        }
        if message.address.hasPrefix("/reply/"), let json = replyJSON(from: message),
           let status = json["status"] as? String, status != "ok" {
            reportError("Refus QLab : \(message.address) — \(status) — \(json["data"] ?? "")")
        }

        // ----------------------------------------------------
        // Broadcast PANIC ALL
        // ----------------------------------------------------

        if message.address ==
            "/qlab/event/workspace/panicAll" {

            onPanicAll?()

            return
        }

        // ----------------------------------------------------
        // Broadcast playhead complet
        //
        // /qlab/event/workspace/playhead
        // number, name, uniqueID, type
        // ----------------------------------------------------

        if message.address ==
            "/qlab/event/workspace/playhead" {

            guard
                message.arguments.count >= 3,
                let cueID =
                    message.arguments[2]
                        .stringValue,
                !cueID.isEmpty
            else {
                return
            }

            onPlayhead?(cueID)
            onPlayheadEvent?(cueID)

            return
        }

        // Certaines versions / configurations peuvent aussi
        // envoyer la forme dédiée uniqueID.
        if message.address.hasSuffix(
            "/playhead/uniqueID"
        ) {
            guard
                let cueID =
                    message.arguments.first?
                        .stringValue,
                !cueID.isEmpty
            else {
                return
            }

            onPlayhead?(cueID)
            onPlayheadEvent?(cueID)
        }
    }

    static func authenticationAccepted(status: String?, data: String?) -> Bool {
        guard status == "ok", let data else { return false }
        if data == "ok" { return true } // Legacy QLab reply.
        guard data.hasPrefix("ok:") else { return false }
        let permissions = Set(data.dropFirst(3).split(separator: "|").map(String.init))
        return Set(["view", "edit", "control"]).isSubset(of: permissions)
    }

    // MARK: - JSON des réponses QLab

    private func replyJSON(
        from message: OSCMessage
    ) -> [String: Any]? {

        guard
            let jsonString =
                message.arguments.first?
                    .stringValue,
            let data =
                jsonString.data(
                    using: .utf8
                ),
            let object =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private func normalizeWorkspaceName(
        _ name: String
    ) -> String {

        var value =
            name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()

        if value.hasSuffix(
            ".qlab5"
        ) {
            value.removeLast(
                ".qlab5".count
            )
        }

        return value
    }

    private func reportError(
        _ message: String
    ) {
        connected = false
        MirrorDiagnostics.log("OSC erreur : \(message)")
        onError?(
            message
        )
    }

    // MARK: - Contrôle audio BACKUP

    func requestAudioPatchList() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.requestAudioPatchList() } }
        guard
            connected,
            let workspaceID
        else {
            reportError(
                "QLab : impossible de lire les patches audio"
            )
            return
        }

        send(
            address:
                "/workspace/\(workspaceID)"
                + "/settings/audio/patchList"
        )
    }

    func setAudioPatchMute(
        patchID: String,
        output: Int,
        muted: Bool
    ) {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.setAudioPatchMute(patchID: patchID, output: output, muted: muted) } }
        guard
            connected,
            let workspaceID,
            !patchID.isEmpty,
            output > 0
        else {
            reportError(
                "QLab : commande mute audio invalide"
            )
            return
        }

        send(
            address:
                "/workspace/\(workspaceID)"
                + "/settings/audio/patchID/"
                + patchID
                + "/mute/"
                + String(output),
            arguments: [
                .bool(muted)
            ]
        )
    }

    func requestAudioPatchMuteChannels(
        patchID: String
    ) {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.requestAudioPatchMuteChannels(patchID: patchID) } }
        guard
            connected,
            let workspaceID,
            !patchID.isEmpty
        else {
            reportError(
                "QLab : impossible de vérifier les mutes audio"
            )
            return
        }

        send(
            address:
                "/workspace/\(workspaceID)"
                + "/settings/audio/patchID/"
                + patchID
                + "/muteChannels"
        )
    }

    // MARK: - Envoi OSC

    // Utilisé uniquement pour nos diagnostics contrôlés.
    // Aucun argument = lecture uniquement.
    func sendDiagnostic(
        address: String
    ) {
        send(
            address: address
        )
    }

    func sendHealthProbe() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.sendHealthProbe() } }

        guard started else {
            return
        }

        // Le watchdog doit continuer à sonder QLab même
        // lorsqu'une réponse précédente n'est jamais revenue.
        //
        // C'est indispensable pour détecter automatiquement
        // le redémarrage de QLab après une fermeture/crash.

        send(
            address: "/workspaces"
        )
    }


    func sendDiagnosticWithBool(
        address: String,
        value: Bool
    ) {
        send(
            address: address,
            arguments: [
                .bool(value)
            ]
        )
    }

    private func send(
        address: String,
        arguments: [OSCValue] = []
    ) {
        if DispatchQueue.getSpecific(key: queueKey) == nil { return queue.sync { self.send(address: address, arguments: arguments) } }
        print(
            "OSC envoyé :",
            address
        )
        guard let sender, started else {
            return
        }

        let packet =
            Self.encodeOSCMessage(
                address: address,
                arguments: arguments
            )

        let generation = session
        sender.send(
            content: packet,
            completion:
                .contentProcessed {
                    [weak self, weak sender] error in

                    guard let self, let sender, self.sender === sender, self.started, self.session == generation else { return }
                    if let error {
                        MirrorDiagnostics.log("OSC envoi échoué address=\(address) erreur=\(error.localizedDescription)")
                        self.connected = false
                        self.reportError(
                            "Envoi OSC : "
                            + error.localizedDescription
                        )
                    }
                }
        )
    }

    // MARK: - Encodeur OSC

    static func encodeOSCMessage(
        address: String,
        arguments: [OSCValue]
    ) -> Data {

        var data =
            oscStringData(
                address
            )

        var typeTags = ","

        for argument in arguments {
            switch argument {
            case .string:
                typeTags += "s"
            case .int32:
                typeTags += "i"
            case .float:
                typeTags += "f"
            case .double:
                typeTags += "d"
            case .bool(let value):
                typeTags += value
                    ? "T"
                    : "F"
            }
        }

        data.append(
            oscStringData(
                typeTags
            )
        )

        for argument in arguments {
            switch argument {

            case .string(let value):
                data.append(
                    oscStringData(
                        value
                    )
                )

            case .int32(let value):
                var bits =
                    UInt32(
                        bitPattern: value
                    )
                    .bigEndian

                withUnsafeBytes(
                    of: &bits
                ) {
                    data.append(
                        contentsOf: $0
                    )
                }

            case .float(let value):
                var bits =
                    value.bitPattern
                        .bigEndian

                withUnsafeBytes(
                    of: &bits
                ) {
                    data.append(
                        contentsOf: $0
                    )
                }

            case .double(let value):
                var bits =
                    value.bitPattern
                        .bigEndian

                withUnsafeBytes(
                    of: &bits
                ) {
                    data.append(
                        contentsOf: $0
                    )
                }

            case .bool:
                break
            }
        }

        return data
    }

    private static func oscStringData(
        _ string: String
    ) -> Data {

        var data =
            Data(
                string.utf8
            )

        data.append(
            0
        )

        while data.count % 4 != 0 {
            data.append(
                0
            )
        }

        return data
    }

    // MARK: - Décodeur OSC

    static func goCueID(_ message: OSCMessage) -> String? {
        let value: String?
        if (message.address == "/qlab/event/workspace/go/uniqueID" || message.address == "/qlab/event/workspace/go"), message.arguments.count == 1 {
            value = message.arguments[0].stringValue
        } else if message.address == "/qlab/event/workspace/go", message.arguments.count >= 3 {
            value = message.arguments[2].stringValue
        } else { return nil }
        guard let value, !value.isEmpty, value.lowercased() != "none",
              !value.contains("/"), !value.contains("*"), !value.contains("?") else { return nil }
        return value
    }

    static func decodeOSCPacket(_ data: Data, depth: Int = 0) -> [OSCMessage] {
        guard depth < 8 else { return [] }
        if data.prefix(8) == Data([35, 98, 117, 110, 100, 108, 101, 0]) {
            guard data.count >= 16 else { return [] }
            let bytes = Array(data)
            var offset = 16, result = [OSCMessage]()
            while offset < bytes.count {
                guard let count = readUInt32(bytes, offset: &offset), count > 0,
                      Int(count) <= bytes.count - offset else { return [] }
                let child = decodeOSCPacket(Data(bytes[offset..<offset + Int(count)]), depth: depth + 1)
                guard !child.isEmpty else { return [] }
                result += child; offset += Int(count)
            }
            return result
        }
        return decodeOSCMessage(data).map { [$0] } ?? []
    }

    private static func decodeOSCMessage(
        _ data: Data
    ) -> OSCMessage? {

        let bytes =
            [UInt8](
                data
            )

        var offset = 0

        guard let address =
            readOSCString(
                bytes,
                offset: &offset
            )
        else {
            return nil
        }

        // Pour l'instant les bundles OSC ne sont pas utiles
        // pour les messages que nous demandons à QLab.
        guard address != "#bundle" else {
            return nil
        }

        guard let typeTagString =
            readOSCString(
                bytes,
                offset: &offset
            )
        else {
            return OSCMessage(
                address: address,
                arguments: []
            )
        }

        guard typeTagString.hasPrefix(
            ","
        ) else {
            return nil
        }

        var arguments: [OSCValue] = []

        for tag in typeTagString.dropFirst() {

            switch tag {

            case "s":
                guard let value =
                    readOSCString(
                        bytes,
                        offset: &offset
                    )
                else {
                    return nil
                }

                arguments.append(
                    .string(value)
                )

            case "i":
                guard
                    let raw =
                        readUInt32(
                            bytes,
                            offset: &offset
                        )
                else {
                    return nil
                }

                arguments.append(
                    .int32(
                        Int32(
                            bitPattern: raw
                        )
                    )
                )

            case "f":
                guard
                    let raw =
                        readUInt32(
                            bytes,
                            offset: &offset
                        )
                else {
                    return nil
                }

                arguments.append(
                    .float(
                        Float(
                            bitPattern: raw
                        )
                    )
                )

            case "d":
                guard
                    let raw =
                        readUInt64(
                            bytes,
                            offset: &offset
                        )
                else {
                    return nil
                }

                arguments.append(
                    .double(
                        Double(
                            bitPattern: raw
                        )
                    )
                )

            case "T":
                arguments.append(
                    .bool(true)
                )

            case "F":
                arguments.append(
                    .bool(false)
                )

            default:
                return nil
            }
        }

        return OSCMessage(
            address: address,
            arguments: arguments
        )
    }

    private static func readOSCString(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> String? {

        guard offset < bytes.count else {
            return nil
        }

        let start = offset
        var end = start

        while end < bytes.count,
              bytes[end] != 0 {
            end += 1
        }

        guard end < bytes.count else {
            return nil
        }

        let value =
            String(
                bytes: bytes[start..<end],
                encoding: .utf8
            )

        end += 1

        while end % 4 != 0 {
            end += 1
        }

        guard end <= bytes.count else {
            return nil
        }

        offset = end

        return value
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> UInt32? {

        guard offset + 4 <= bytes.count else {
            return nil
        }

        let value =
            (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])

        offset += 4

        return value
    }

    private static func readUInt64(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> UInt64? {

        guard offset + 8 <= bytes.count else {
            return nil
        }

        var value: UInt64 = 0

        for index in 0..<8 {
            value =
                (value << 8)
                | UInt64(
                    bytes[offset + index]
                )
        }

        offset += 8

        return value
    }
}
