import Foundation

@MainActor
final class LiveMirrorEngine {
    // Live Mirror still travels over the control JSON channel. Larger bounded chunks
    // reduce framing/Base64 overhead while staying well below NetworkDiscovery's 8 MiB frame cap.
    private static let mirrorChunkBytes = 512 * 1024
    private static let mirrorEncodedMaxBytes = 720 * 1024

    struct Context {
        var master = false
        var connected = false
        var session = ""
        var workspaceID = ""
        var root: String?
        var canReload = false
        var initialTransfer = false
    }
    var context: () -> Context = { Context() }
    var qlab: (String, [String]) async throws -> String = MirrorQLab.run
    var workspaceSignature: (String) async throws -> String = { path in
        try await Task.detached(priority: .utility) { try MirrorWorkspaceSignature.capture(path) }.value
    }
    private var appliedSignature: String?
    private var offeredSignature: String?
    var verificationAttempts = 60
    var cacheOverride: URL?
    var revisionsOverride: URL?
    var send: ([String: Any]) async throws -> Void = { _ in }
    var changed: (Bool, String) -> Void = { _, _ in }
    var verifyPlayhead: () async throws -> Void = {}
    var reloadFailed: () -> Void = {}
    var prepareReload: () -> Void = {}
    var reconnected: (String) -> Void = { _ in }
    var readyAfterReload: () -> Bool = { false }
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var receivingTask: Task<Void, Never>?
    private var inbox = [[String: Any]]()
    private var offered: MirrorManifest?
    private var incoming: MirrorManifest?
    private var applied: MirrorManifest?
    private var acknowledged: String?
    private var advertisedDigest: String?
    private var lastOffer = Date.distantPast
    private var highestRevision = 0
    private var masterConfirmed = false
    private var locallyVerified = false
    private var lastRemote = Date.distantPast
    private var nextRevision = 1
    private var lastFiles = [MirrorFile]()
    private var lastWorkspacePath = ""
    private var session = ""
    private var seeded = false
    private var lastTargets = [String: String]()
    private var partial: FileHandle?
    private var partialURL: URL?
    private var partialHash: String?
    private var partialOffset: Int64 = 0
    private var cache: URL?
    private var applying = false
    // A received revision may be fully materialized on disk while QLab keeps playing.
    // Only the final workspace close/open remains gated by MirrorQLab.idle.
    private var preparedDigest: String?
    private var fileWait: (hash: String, digest: String, continuation: CheckedContinuation<Void, Error>)?
    private var fileWaitTimeout: Task<Void, Never>?

    private(set) var synchronized = false

    var contentReady: Bool {
        guard let applied else { return false }
        return locallyVerified && masterConfirmed && advertisedDigest == applied.digest && !applying
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    func stop() {
        finishFileWait(CancellationError())
        generation = UUID(); task?.cancel(); task = nil
        receivingTask?.cancel(); receivingTask = nil; inbox.removeAll()
        clearPartial(); offered = nil; incoming = nil; applied = nil; highestRevision = 0; masterConfirmed = false
        acknowledged = nil; advertisedDigest = nil; lastFiles = []; session = ""; seeded = false; lastTargets = [:]
        appliedSignature = nil; offeredSignature = nil
        applying = false; preparedDigest = nil; setState(false, "Live Mirror arrêté")
    }

    /// Relance manuelle de la négociation côté BACKUP sans toucher directement à l'audio.
    /// Si une cue joue ou est en pause, la révision reste en attente et sera réappliquée
    /// automatiquement dès que MirrorQLab.idle autorisera le rechargement.
    func requestResynchronization() async throws {
        let c = context()
        let token = generation
        guard !c.master, c.connected, !c.session.isEmpty, !c.workspaceID.isEmpty else {
            throw MirrorFailure.invalid("Relance disponible uniquement sur un BACKUP connecté")
        }
        guard !c.initialTransfer else {
            throw MirrorFailure.invalid("Transfert initial en cours")
        }
        adoptSession(c.session)

        guard let manifest = incoming ?? applied else {
            setState(false, "Live Mirror : aucune version reçue à relancer")
            throw MirrorFailure.invalid("Aucune version Live Mirror disponible")
        }

        // Invalide uniquement l'acquittement logique. Les objets déjà reçus restent en cache,
        // ce qui évite de retransférer inutilement les médias inchangés.
        masterConfirmed = false
        locallyVerified = false
        appliedSignature = nil
        if incoming?.digest != manifest.digest { incoming = manifest }
        if applied?.digest == manifest.digest { applied = nil }
        preparedDigest = nil

        var nack = message("MIRROR_NACK", manifest: manifest)
        nack["reason"] = "Resynchronisation manuelle demandée par l’opérateur"
        try await send(nack)
        try valid(token, c.session)
        setState(false, "Live Mirror : relance manuelle demandée")

        // Tente immédiatement la reprise. Si QLab joue ou est en pause, commit() conservera
        // la révision et les ticks suivants réessaieront sans interrompre le spectacle.
        await tick()
    }
    private func setState(_ ok: Bool, _ message: String) { synchronized = ok; changed(ok, message) }
    private func clearPartial() {
        try? partial?.close(); partial = nil
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil; partialHash = nil; partialOffset = 0
    }
    private func objectRoot() throws -> URL {
        if let cacheOverride { return cacheOverride }
        if let cache { return cache }
        let root = try MirrorFiles.cacheRoot(); cache = root; return root
    }
    private func message(_ type: String, manifest: MirrorManifest) -> [String: Any] {
        ["type": type, "session": manifest.session, "revision": manifest.revision, "digest": manifest.digest]
    }
    private func matches(_ obj: [String: Any], _ m: MirrorManifest) -> Bool {
        obj["session"] as? String == m.session && obj["revision"] as? Int == m.revision && obj["digest"] as? String == m.digest
    }
    private func valid(_ token: UUID, _ expectedSession: String) throws {
        guard token == generation, !Task.isCancelled, context().connected, context().session == expectedSession else { throw CancellationError() }
    }
    private func adoptSession(_ newSession: String) {
        guard session != newSession else { return }
        session = newSession; offered = nil; incoming = nil; applied = nil; acknowledged = nil
        appliedSignature = nil; offeredSignature = nil
        advertisedDigest = nil; highestRevision = 0; masterConfirmed = false; locallyVerified = false
        lastFiles = []; lastTargets = [:]; lastWorkspacePath = ""; nextRevision = 1; seeded = false; clearPartial(); preparedDigest = nil
        setState(false, "Live Mirror : négociation Build5")
    }
    func tick() async {
        let c = context(), token = generation
        guard c.connected, !c.workspaceID.isEmpty, !c.session.isEmpty else {
            setState(false, "Live Mirror : connexion QLab/MASTER attendue"); return
        }
        adoptSession(c.session)
        guard !c.initialTransfer else { setState(false, "Live Mirror : transfert initial en cours"); return }
        do {
            if c.master {
                guard let rootPath = c.root else { throw MirrorFailure.invalid("Dossier MASTER inconnu") }
                // Save captures all cue properties, including those absent from OSC snapshots.
                let workspace = try await qlab(MirrorQLab.locate, [c.workspaceID])
                try valid(token, c.session)
                let root = URL(fileURLWithPath: rootPath).standardizedFileURL
                guard workspace.hasPrefix(root.path + "/") else { throw MirrorFailure.invalid("Workspace hors du dossier projet") }
                let targetsRaw = try await qlab(MirrorQLab.targets, [c.workspaceID])
                let store = try objectRoot()
                let capture = try await Task.detached(priority: .utility) {
                    try MirrorMedia.capture(root: root, cache: store, rawTargets: targetsRaw)
                }.value
                var files = capture.files
                let targets = capture.targets
                try valid(token, c.session)
                let checkedPath = try await qlab(MirrorQLab.check, [c.workspaceID])
                guard checkedPath == workspace else { throw MirrorFailure.invalid("Workspace changé pendant la capture") }
                try valid(token, c.session)
                let relative = String(workspace.dropFirst(root.path.count + 1))
                guard let workspaceFile = files.first(where: { $0.path == relative }) else { throw MirrorFailure.invalid("Workspace absent de la capture") }
                let signature = try await workspaceSignature(store.appendingPathComponent(workspaceFile.sha256).path)
                try valid(token, c.session)
                // Controller/playhead saves must not trigger another workspace reload.
                // Keep the exact previously offered immutable object when cue content is unchanged.
                if signature == offeredSignature, relative == lastWorkspacePath,
                   let previous = lastFiles.first(where: { $0.path == relative }) {
                    files = files.map { $0.path == relative ? previous : $0 }
                }
                if files != lastFiles || targets != lastTargets || relative != lastWorkspacePath || offered == nil {
                    let m = MirrorManifest(session: c.session, revision: nextRevision, workspaceID: c.workspaceID, workspacePath: relative, mediaTargets: targets, files: files)
                    try MirrorFiles.validate(m); nextRevision += 1; offered = m; lastFiles = files; lastWorkspacePath = relative; lastTargets = targets
                    acknowledged = nil; lastOffer = .distantPast; offeredSignature = signature
                    setState(false, "Live Mirror : version \(m.revision) en attente d’application")
                }
                if let m = offered {
                    if acknowledged != m.digest, Date().timeIntervalSince(lastOffer) >= 6 {
                        var obj = message("MIRROR_OFFER", manifest: m)
                        let data = try JSONEncoder.sorted.encode(m)
                        guard data.count < 7 * 1024 * 1024 else { throw MirrorFailure.invalid("Manifest trop volumineux") }
                        obj["manifest"] = try JSONSerialization.jsonObject(with: data)
                        try await send(obj); lastOffer = Date()
                    }
                    var status = message("MIRROR_STATUS", manifest: m)
                    status["acknowledged"] = acknowledged == m.digest
                    try await send(status)
                    setState(acknowledged == m.digest && Date().timeIntervalSince(lastRemote) < 15,
                             acknowledged == m.digest ? "Live Mirror : version \(m.revision) appliquée et acquittée" : "Live Mirror : version \(m.revision) non acquittée")
                }
            } else {
                if let m = applied {
                    try await verifyAppliedWorkspace(m)
                }
                if Date().timeIntervalSince(lastRemote) > 15 { setState(false, "Live Mirror : confirmation MASTER expirée") }
                if let m = incoming, !applying { try await commit(m, token: token) }
            }
        } catch is CancellationError { return }
        catch {
            locallyVerified = false; masterConfirmed = false
            setState(false, "Live Mirror : " + error.localizedDescription)
            if !c.master, let m = applied {
                var nack = message("MIRROR_NACK", manifest: m); nack["reason"] = error.localizedDescription
                try? await send(nack)
            }
        }
    }
    func enqueue(_ obj: [String: Any]) {
        if obj["type"] as? String == "MIRROR_FILE_OK", context().master,
           obj["session"] as? String == context().session,
           let wait = fileWait, obj["hash"] as? String == wait.hash,
           obj["digest"] as? String == wait.digest {
            finishFileWait(nil)
            return
        }
        guard inbox.count < 256 else { setState(false, "Live Mirror : file réseau saturée"); return }
        inbox.append(obj)
        guard receivingTask == nil else { return }
        receivingTask = Task { [weak self] in
            guard let self else { return }
            while !self.inbox.isEmpty, !Task.isCancelled {
                let object = self.inbox.removeFirst()
                do { try await self.receive(object) }
                catch {
                    self.locallyVerified = false; self.masterConfirmed = false
                    if self.context().master { self.acknowledged = nil }
                    self.setState(false, "Live Mirror : " + error.localizedDescription)
                    if !self.context().master, let m = self.applied {
                        var nack = self.message("MIRROR_NACK", manifest: m)
                        nack["reason"] = error.localizedDescription
                        try? await self.send(nack)
                    }
                }
            }
            self.receivingTask = nil
        }
    }
    private func receive(_ obj: [String: Any]) async throws {
        let c = context(), token = generation
        guard c.connected, obj["session"] as? String == c.session, let type = obj["type"] as? String else { return }
        adoptSession(c.session)
        if c.master {
            guard let m = offered, matches(obj, m) else { return }
            switch type {
            case "MIRROR_ACK":
                lastRemote = Date(); acknowledged = m.digest
                // Tick re-scans MASTER before reporting OK.
            case "MIRROR_NEED":
                guard let hashes = obj["hashes"] as? [String], hashes.count <= m.files.count else { throw MirrorFailure.invalid("Demande média invalide") }
                let allowed = Set(m.files.map(\.sha256)), cache = try objectRoot()
                for hash in Set(hashes).sorted() {
                    guard allowed.contains(hash), MirrorFiles.validHash(hash) else { throw MirrorFailure.invalid("Objet média inconnu") }
                    let h = try FileHandle(forReadingFrom: cache.appendingPathComponent(hash)); defer { try? h.close() }
                    var offset: Int64 = 0
                    while let block = try h.read(upToCount: Self.mirrorChunkBytes), !block.isEmpty {
                        try valid(token, c.session)
                        guard offered?.digest == m.digest else { return }
                        var chunk = message("MIRROR_CHUNK", manifest: m)
                        chunk["hash"] = hash; chunk["offset"] = offset; chunk["data"] = block.base64EncodedString()
                        try await send(chunk); offset += Int64(block.count)
                    }
                    try await sendFileEndAndWait(m, hash: hash)
                }
                try await send(message("MIRROR_COMMIT", manifest: m))
            case "MIRROR_NACK":
                acknowledged = nil; setState(false, obj["reason"] as? String ?? "Application BACKUP différée")
            default: break
            }
            return
        }
        switch type {
        case "MIRROR_STATUS":
            guard let revision = obj["revision"] as? Int, revision >= highestRevision else { return }
            highestRevision = revision
            lastRemote = Date(); advertisedDigest = obj["digest"] as? String
            let ok = locallyVerified && applied.map { matches(obj, $0) } == true && obj["acknowledged"] as? Bool == true
            masterConfirmed = ok
            if let m = applied, locallyVerified, matches(obj, m), readyAfterReload() {
                try await send(message("MIRROR_ACK", manifest: m))
            }
            setState(ok, ok ? "Live Mirror : dernière version appliquée et acquittée" : "Live Mirror : version MASTER non appliquée/acquittée")
        case "MIRROR_OFFER":
            guard let raw = obj["manifest"], JSONSerialization.isValidJSONObject(raw) else { throw MirrorFailure.invalid("Manifest absent") }
            let m = try JSONDecoder().decode(MirrorManifest.self, from: JSONSerialization.data(withJSONObject: raw))
            try MirrorFiles.validate(m)
            guard matches(obj, m), m.session == c.session, m.workspaceID == c.workspaceID else { throw MirrorFailure.invalid("Identité workspace/session incompatible : refaire le transfert initial") }
            guard m.revision >= highestRevision else { return }
            if m.revision == highestRevision, let advertisedDigest, advertisedDigest != m.digest {
                throw MirrorFailure.invalid("Révision identique avec contenu différent")
            }
            highestRevision = m.revision; advertisedDigest = m.digest
            if applied != m { masterConfirmed = false }
            lastRemote = Date()
            if let old = incoming, m.revision < old.revision { return }
            if let old = applied, m.revision < old.revision { return }
            if applied == m {
                // Idempotent ACK after verifying this version is still the open document.
                try await verifyAppliedWorkspace(m)
                try valid(token, c.session)
                guard readyAfterReload() else { throw MirrorFailure.invalid("Isolation/QLab BACKUP non vérifiés") }
                locallyVerified = true
                try await send(message("MIRROR_ACK", manifest: m)); return
            }
            if incoming?.digest != m.digest { clearPartial(); incoming = m; preparedDigest = nil }
            setState(false, "Live Mirror : réception version \(m.revision)")
            if !seeded, let root = c.root {
                let cache = try objectRoot()
                _ = try await Task.detached(priority: .utility) {
                    try MirrorFiles.capture(root: URL(fileURLWithPath: root), cache: cache)
                }.value
                try valid(token, c.session); seeded = true
            }
            let cache = try objectRoot()
            let missing = await Task.detached(priority: .utility) {
                var result = Set<String>()
                for f in m.files {
                    if (try? MirrorFiles.hashFile(cache.appendingPathComponent(f.sha256))) != f.sha256 { result.insert(f.sha256) }
                }
                return result.sorted()
            }.value
            try valid(token, c.session)
            var need = message("MIRROR_NEED", manifest: m); need["hashes"] = missing
            try await send(need)
        case "MIRROR_CHUNK":
            guard let m = incoming, matches(obj, m), let hash = obj["hash"] as? String,
                  let file = m.files.first(where: { $0.sha256 == hash }), let offset = obj["offset"] as? Int64,
                  let encoded = obj["data"] as? String, encoded.count <= Self.mirrorEncodedMaxBytes,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= Self.mirrorChunkBytes else { throw MirrorFailure.invalid("Bloc média invalide") }
            if offset == 0 {
                clearPartial(); let url = try objectRoot().appendingPathComponent("partial-" + UUID().uuidString)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                partialURL = url; partialHash = hash; partial = try FileHandle(forWritingTo: url)
            }
            guard partialHash == hash, partialOffset == offset, offset <= file.size - Int64(data.count), let partial else { throw MirrorFailure.invalid("Bloc média hors séquence") }
            try partial.write(contentsOf: data); partialOffset += Int64(data.count)
        case "MIRROR_FILE_END":
            guard let m = incoming, matches(obj, m), let hash = obj["hash"] as? String,
                  let file = m.files.first(where: { $0.sha256 == hash }) else { return }
            // Empty files have no CHUNK.
            if file.size == 0, hash == MirrorFiles.hash(Data()) {
                try Data().write(to: objectRoot().appendingPathComponent(hash), options: .atomic)
                var ok = message("MIRROR_FILE_OK", manifest: m); ok["hash"] = hash
                try await send(ok); return
            }
            guard partialHash == hash, partialOffset == file.size, let url = partialURL else { throw MirrorFailure.invalid("Média incomplet") }
            try partial?.close(); partial = nil
            let actual = try await Task.detached { try MirrorFiles.hashFile(url) }.value
            try valid(token, c.session)
            guard actual == hash else { clearPartial(); throw MirrorFailure.invalid("SHA-256 média incorrect") }
            let target = try objectRoot().appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: url, to: target); clearPartial()
            var ok = message("MIRROR_FILE_OK", manifest: m); ok["hash"] = hash
            try await send(ok)
        case "MIRROR_COMMIT":
            guard let m = incoming, matches(obj, m), !applying else { return }
            try await commit(m, token: token)
        default: break
        }
    }
    private func verifyAppliedWorkspace(_ m: MirrorManifest) async throws {
        let path = try revisionDirectory(m).appendingPathComponent(m.workspacePath).path
        // saveExpected checks the exact open path before preserving any local edits.
        _ = try await qlab(MirrorQLab.saveExpected, [m.workspaceID, path])
        _ = try await qlab(MirrorQLab.verify, [m.workspaceID, path])
        let actual = try await workspaceSignature(path)
        guard let expected = appliedSignature, expected == actual else {
            throw MirrorFailure.invalid("Configuration des cues BACKUP modifiée : resynchronisation nécessaire")
        }
    }
    private func finishFileWait(_ error: Error?) {
        fileWaitTimeout?.cancel(); fileWaitTimeout = nil
        guard let wait = fileWait else { return }
        fileWait = nil
        if let error { wait.continuation.resume(throwing: error) }
        else { wait.continuation.resume() }
    }
    private func sendFileEndAndWait(_ m: MirrorManifest, hash: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileWait = (hash, m.digest, continuation)
            fileWaitTimeout = Task { [weak self] in
                let size = m.files.first(where: { $0.sha256 == hash })?.size ?? 0
                let seconds = max(30, min(600, size / (25 * 1024 * 1024) + 30))
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishFileWait(MirrorFailure.invalid("Vérification média BACKUP non confirmée : retry à la prochaine offre"))
            }
            Task { [weak self] in
                guard let self else { return }
                var end = self.message("MIRROR_FILE_END", manifest: m); end["hash"] = hash
                do { try await self.send(end) }
                catch { self.finishFileWait(error) }
            }
        }
    }
    private func revisionDirectory(_ m: MirrorManifest) throws -> URL {
        let base = revisionsOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QLab Fallback Build5", isDirectory: true)
        let root = base.appendingPathComponent(m.session, isDirectory: true)
        return root.appendingPathComponent("v\(m.revision)-\(m.digest.prefix(12))", isDirectory: true)
    }
    private func commit(_ m: MirrorManifest, token: UUID) async throws {
        guard !applying else { return }; applying = true
        var reloadStarted = false, completed = false
        defer {
            applying = false
            if reloadStarted && !completed { reloadFailed() }
        }
        let c = context()
        guard c.canReload else {
            var nack = message("MIRROR_NACK", manifest: m)
            nack["reason"] = "Resynchronisation différée : confirmer les conditions de rechargement, sortir du test/secours et attendre le BACKUP inactif"
            try await send(nack); setState(false, nack["reason"] as! String); return
        }
        let cache = try objectRoot()
        // Reception and preparation are allowed while cues are running/paused. QLab itself
        // is not touched until the final idle check below succeeds.
        for f in m.files where !FileManager.default.fileExists(atPath: cache.appendingPathComponent(f.sha256).path) { return }
        let destination = try revisionDirectory(m)
        let target = try MirrorFiles.safeURL(m.workspacePath, under: destination)
        let current = try await qlab(MirrorQLab.currentPath, [m.workspaceID])
        try valid(token, m.session)
        if current != target.path {
            if preparedDigest != m.digest {
                let staging = destination.deletingLastPathComponent().appendingPathComponent("staging-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                try await Task.detached(priority: .utility) { try MirrorFiles.materialize(m, cache: cache, destination: staging) }.value
                try valid(token, m.session)
                guard context().canReload else { throw MirrorFailure.invalid("Rechargement annulé : état BACKUP changé") }
                // Existing version directories may be open in QLab; never overwrite them.
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Never overwrite an existing revision. It can be reused only if pristine.
                    for file in m.files {
                        let existing = try MirrorFiles.safeURL(file.path, under: destination)
                        guard try MirrorFiles.hashFile(existing) == file.sha256 else {
                            throw MirrorFailure.invalid("Version existante modifiée : reprise opérateur requise")
                        }
                    }
                } else {
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
                preparedDigest = m.digest
                setState(false, "Live Mirror : version \(m.revision) prête, application QLab en attente")
            }
            // This is the only playback-sensitive gate. If a cue is active or paused,
            // MirrorQLab.idle rejects the close/open but the prepared revision is kept.
            let old = try await qlab(MirrorQLab.idle, [m.workspaceID])
            try valid(token, m.session)
            guard old == current else { throw MirrorFailure.invalid("Workspace BACKUP changé pendant la préparation") }
            reloadStarted = true
            prepareReload()
            _ = try await qlab(MirrorQLab.reload, [m.workspaceID, old, target.path])
            try valid(token, m.session)
        }
        let loaded = try await qlab(MirrorQLab.idle, [m.workspaceID])
        guard loaded == target.path else { throw MirrorFailure.invalid("QLab n’a pas ouvert la version attendue") }
        try valid(token, m.session)
        // QLab may retain absolute MASTER media paths; remap by stable cue ID.
        // Bound argv length by relinking one cue at a time.
        for (id, relative) in m.mediaTargets.sorted(by: { $0.key < $1.key }) {
            let media = try MirrorFiles.safeURL(relative, under: destination)
            _ = try await qlab(MirrorQLab.relink, [m.workspaceID, target.path, id, media.path])
            try valid(token, m.session)
        }
        reconnected(target.deletingPathExtension().lastPathComponent)
        for _ in 0..<verificationAttempts {
            try await Task.sleep(nanoseconds: 500_000_000)
            try valid(token, m.session)
            if readyAfterReload() { break }
        }
        guard readyAfterReload() else { throw MirrorFailure.invalid("Version ouverte ; isolation audio/reconnexion non confirmée, aucun ACK") }
        try await verifyPlayhead()
        _ = try await qlab(MirrorQLab.saveExpected, [m.workspaceID, target.path])
        for (id, relative) in m.mediaTargets.sorted(by: { $0.key < $1.key }) {
            let media = try MirrorFiles.safeURL(relative, under: destination)
            _ = try await qlab(MirrorQLab.verifyTargets, [m.workspaceID, target.path, id, media.path])
            try valid(token, m.session)
        }
        _ = try await qlab(MirrorQLab.verify, [m.workspaceID, target.path])
        try valid(token, m.session)
        guard incoming?.digest == m.digest else { return }
        appliedSignature = try await workspaceSignature(target.path)
        try valid(token, m.session)
        applied = m; incoming = nil; locallyVerified = true; completed = true; preparedDigest = nil
        try await send(message("MIRROR_ACK", manifest: m))
        setState(false, "Live Mirror : version \(m.revision) appliquée, confirmation MASTER attendue")
    }
}
