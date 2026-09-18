import Foundation

@main
struct RegressionTests {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1
    }
    static func rejects(_ label: String, _ block: () throws -> Void) {
        do { try block(); fatalError("Expected rejection: " + label) }
        catch { checks += 1 }
    }
    static func bundle(_ packets: [Data]) -> Data {
        var data = Data([35, 98, 117, 110, 100, 108, 101, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        for p in packets {
            var count = UInt32(p.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(p)
        }
        return data
    }
    static func main() throws {
        expect(QLabOSCClient.authenticationAccepted(status: "ok", data: "ok:view|edit|control"), "Actual QLab 5.5 full permissions accepted")
        expect(QLabOSCClient.authenticationAccepted(status: "ok", data: "ok"), "Legacy success accepted")
        for data: String? in ["badpass", "ok:view", "ok:view|control", "ok:edit|control", "", nil] {
            expect(!QLabOSCClient.authenticationAccepted(status: "ok", data: data), "Bad passcode/missing permission never reports authenticated")
        }
        expect(!QLabOSCClient.authenticationAccepted(status: "denied", data: "ok"), "Denied status never authenticates")
        expect(QLabWorkspaceIdentity.matches(localName: "Qlab Backup", masterName: "QLAB BACKUP.qlab5", connected: true, localID: "id", validatedID: nil), "Workspace name extension/case normalized")
        expect(!QLabWorkspaceIdentity.matches(localName: "A", masterName: "A", connected: false, localID: "id", validatedID: "id"), "Disconnected identity never ready")
        expect(!QLabWorkspaceIdentity.matches(localName: "A", masterName: "A", connected: true, localID: "other", validatedID: "id"), "Same name cannot bypass different manifest UUID")
        expect(QLabWorkspaceIdentity.matches(localName: "A", masterName: "A.qlab5", connected: true, localID: "id", validatedID: "id"), "Validated manifest UUID survives display suffix")
        // Different wall clock settings and boot times have no effect on age.
        for remoteBase in [10.0, 999999.0] {
            var clock = MirrorEventClock()
            expect(clock.age(of: remoteBase, now: 400) == nil, "No clock sample is never ready")
            expect(clock.calibrate(sent: 400, received: 400.02, remote: remoteBase), "Fast probe accepted")
            expect(clock.age(of: remoteBase + 0.1, now: 400.12)! < 0.021, "Fresh GO accepted across boot offsets")
            expect(clock.age(of: remoteBase + 0.1, now: 403)! > 2, "Queued stale GO still rejected")
            expect(clock.age(of: remoteBase + 100, now: 400.12) == nil, "Future invalid monotonic timestamp rejected")
            expect(clock.age(of: .nan, now: 400.12) == nil, "NaN rejected")
            expect(clock.age(of: remoteBase + 11, now: 411) == nil, "Old calibration rejected")
            expect(!clock.calibrate(sent: 400, received: 401, remote: remoteBase), "Slow probe not trusted")
        }
        let ready = MirrorGoReadiness()
        expect(ready.refusal == nil, "Ready and muted BACKUP may execute GO")
        for change: (inout MirrorGoReadiness) -> Void in [
            { $0.enabled = false }, { $0.oscConnected = false }, { $0.workspaceMatches = false },
            { $0.contentReady = false }, { $0.initialTransfer = true }, { $0.reloading = true },
            { $0.missedGo = true }, { $0.takeover = true }, { $0.outputIsolationDeclared = false },
            { $0.armed = false }, { $0.audioIsolationVerified = false }
        ] {
            var blocked = ready; change(&blocked)
            expect(blocked.refusal != nil, "Every unsafe/unready state rejects GO explicitly")
        }
        var outputTest = ready; outputTest.audioIsolationVerified = false; outputTest.outputTest = true
        expect(outputTest.refusal == nil, "Explicit existing output-test mode preserved")
        outputTest.takeover = true
        expect(outputTest.refusal != nil, "Output test never overrides failover latch")
        func status(_ connected: Bool, _ synced: Bool = false, _ ready: Bool = false, _ transferring: Bool = false, _ error: String? = nil) -> String {
            MirrorTransferDisplay.status(master: true, connected: connected, synchronized: synced, ready: ready,
                transferring: transferring, error: error, transferStatus: "Vérification des targets")
        }
        expect(status(false) == "En attente d’un BACKUP…", "Disconnected PRIMARY waits for BACKUP")
        expect(status(true).contains("BACKUP connecté"), "Connected PRIMARY never claims no BACKUP")
        expect(status(true, false, true).contains("copie validée"), "Validated transfer distinguished from full mirror sync")
        expect(status(true, true) == "Synchronisé", "Actual synchronized state displayed")
        expect(status(true, false, false, true) == "Vérification des targets", "Actual transfer phase displayed")
        expect(status(true, false, false, false, "-1700") == "Validation du fallback échouée", "Failed relink stays visible after transfer stops")
        let uid = "CAKE-UNIQUE-ID"
        let full = QLabOSCClient.encodeOSCMessage(address: "/qlab/event/workspace/go", arguments: [.string("1.5"), .string("CAKE - I Will Survive.flac"), .string(uid), .string("Audio")])
        let single = QLabOSCClient.encodeOSCMessage(address: "/qlab/event/workspace/go/uniqueID", arguments: [.string(uid)])
        for packet in [full, single, bundle([single]), bundle([bundle([full])])] {
            let decoded = QLabOSCClient.decodeOSCPacket(packet)
            expect(decoded.count == 1, "One event for each valid OSC packet")
            expect(QLabOSCClient.goCueID(decoded[0]) == uid, "Uses cue ID, not number or filename")
        }
        let playhead = QLabOSCClient.encodeOSCMessage(address: "/qlab/event/workspace/playhead", arguments: [.string("2"), .string("Azizam"), .string("NEXT-CUE"), .string("Audio")])
        let batch = QLabOSCClient.decodeOSCPacket(bundle([playhead, single]))
        expect(batch.count == 2 && QLabOSCClient.goCueID(batch[0]) == nil && QLabOSCClient.goCueID(batch[1]) == uid, "Playhead + GO bundle preserves exact launched cue")
        expect(QLabOSCClient.decodeOSCPacket(bundle([single]).dropLast()).isEmpty, "Truncated bundle rejected atomically")
        expect(QLabOSCClient.decodeOSCPacket(Data(full.prefix(12))).isEmpty, "Truncated message rejected")
        for arguments: [QLabOSCClient.OSCValue] in [[], [.string("")], [.string("none")], [.string("*")], [.string("a/b")]] {
            expect(QLabOSCClient.goCueID(.init(address: "/qlab/event/workspace/go/uniqueID", arguments: arguments)) == nil, "Invalid cue ID rejected")
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("qlab53-regression-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("PRIMARY Project"), cache = tmp.appendingPathComponent("objects")
        let external = tmp.appendingPathComponent("Outside é"), other = tmp.appendingPathComponent("Other")
        for dir in [root, cache, external, other] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("workspace fixture".utf8).write(to: root.appendingPathComponent("Show.qlab5"))
        let cake = external.appendingPathComponent("CAKE - I Will Survive.flac")
        let sameName = other.appendingPathComponent(cake.lastPathComponent)
        let internalMedia = root.appendingPathComponent("Azizam é.wav")
        try Data("cake audio".utf8).write(to: cake)
        try Data("different cake".utf8).write(to: sameName)
        try Data("internal audio".utf8).write(to: internalMedia)
        let raw = "cue-1\t\(cake.path)\ncue-1.5\t\(cake.path)\nother-cue\t\(sameName.path)\nazizam\t\(internalMedia.path)\n"
        let capture = try MirrorMedia.capture(root: root, cache: cache, rawTargets: raw)
        expect(capture.targets.count == 4, "All referenced cues included")
        expect(capture.targets["cue-1"] == capture.targets["cue-1.5"], "Two Cake cues map to same bytes")
        expect(capture.targets["cue-1"] != capture.targets["other-cue"], "Same filename does not confuse different media")
        expect(capture.files.count == 4, "External shared media copied exactly once")
        expect(capture.targets["azizam"] == "Azizam é.wav", "Internal paths preserved with Unicode")
        let empty = try MirrorMedia.capture(root: root, cache: cache, rawTargets: "")
        expect(empty.targets.isEmpty, "Intentionally unassigned cues need no fabricated target")
        rejects("Missing external file must block success") {
            _ = try MirrorMedia.capture(root: root, cache: cache, rawTargets: "missing\t\(external.path)/missing.flac\n")
        }
        let m = MirrorManifest(session: UUID().uuidString, revision: 1, workspaceID: "workspace", workspacePath: "Show.qlab5", mediaTargets: capture.targets, files: capture.files)
        let stage = tmp.appendingPathComponent("Archive Project")
        try MirrorFiles.materialize(m, cache: cache, destination: stage)
        try JSONEncoder.sorted.encode(m).write(to: stage.appendingPathComponent(MirrorMedia.manifestName))
        let archive = try WorkspaceTransferSupport.makeArchive(sourceDirectory: stage)
        defer { try? fm.removeItem(at: archive) }
        let extraction = tmp.appendingPathComponent("BACKUP other account")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extraction.path]
        try process.run(); process.waitUntilExit()
        expect(process.terminationStatus == 0, "Actual archive extraction succeeds")
        let workspace = WorkspaceTransferSupport.findWorkspace(in: extraction, preferredName: "Show")!
        let (received, receivedRoot) = try WorkspaceTransferSupport.receivedManifest(workspaceURL: workspace, extractionRoot: extraction)
        expect(received == m, "Manifest preserved across archive transfer")
        for id in ["cue-1", "cue-1.5"] {
            let target = try MirrorFiles.safeURL(received.mediaTargets[id]!, under: receivedRoot)
            expect(try Data(contentsOf: target) == Data("cake audio".utf8), "Cake target points at received bytes for \(id)")
            expect(!target.path.hasPrefix(root.path), "Relink does not use PRIMARY path")
        }
        try Data("corruption".utf8).write(to: receivedRoot.appendingPathComponent(received.mediaTargets["cue-1"]!))
        rejects("Corrupt extracted media must block readiness") { try MirrorMedia.verify(received, root: receivedRoot) }
        // Incremental initial copy: exercise actual ZIP and independent BACKUP cache.
        let backupCache = tmp.appendingPathComponent("BACKUP cache")
        let existing = tmp.appendingPathComponent("Existing backup")
        try fm.createDirectory(at: backupCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try fm.copyItem(at: cake, to: existing.appendingPathComponent("renamed cake.flac"))
        try fm.copyItem(at: internalMedia, to: existing.appendingPathComponent("Azizam é.wav"))
        let available = try WorkspaceTransferSupport.availableMedia(in: existing, cache: backupCache)
        expect(available.count == 2, "Existing BACKUP files hashed even when renamed")
        let incremental = try WorkspaceTransferSupport.portableArchive(manifest: m, cache: cache,
            projectName: "Incremental", availableMedia: available)
        defer { try? fm.removeItem(at: incremental) }
        let delta = tmp.appendingPathComponent("Delta")
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", incremental.path, delta.path]
        try unzip.run(); unzip.waitUntilExit()
        expect(unzip.terminationStatus == 0, "Incremental ZIP extracts")
        let deltaRoot = delta.appendingPathComponent("Incremental")
        expect(fm.fileExists(atPath: deltaRoot.appendingPathComponent(m.workspacePath).path), "Workspace always transferred fresh")
        expect(!fm.fileExists(atPath: deltaRoot.appendingPathComponent(m.mediaTargets["cue-1"]!).path), "Identical Cake omitted from network archive")
        expect(fm.fileExists(atPath: deltaRoot.appendingPathComponent(m.mediaTargets["other-cue"]!).path), "Different Cake with same filename is transferred")
        // Local source can change after inventory: immutable cached bytes still correct.
        try Data("changed local file".utf8).write(to: existing.appendingPathComponent("renamed cake.flac"))
        try WorkspaceTransferSupport.restoreAvailableMedia(m, root: deltaRoot, cache: backupCache)
        try MirrorMedia.verify(m, root: deltaRoot)
        expect(true, "Full assembled project verified against PRIMARY after local reuse")
        let cakeHash = m.files.first { $0.path == m.mediaTargets["cue-1"]! }!.sha256
        let restored = deltaRoot.appendingPathComponent(m.mediaTargets["cue-1"]!)
        try Data("change target".utf8).write(to: restored)
        expect(try MirrorFiles.hashFile(backupCache.appendingPathComponent(cakeHash)) == cakeHash, "Restored file is independent of cache, no mutable hard link")
        try fm.removeItem(at: restored)
        try Data("corrupt cache".utf8).write(to: backupCache.appendingPathComponent(cakeHash))
        rejects("Corrupt reuse cache blocks readiness") { try WorkspaceTransferSupport.restoreAvailableMedia(m, root: deltaRoot, cache: backupCache) }
        try fm.removeItem(at: backupCache.appendingPathComponent(cakeHash))
        rejects("Missing reuse cache blocks readiness") { try WorkspaceTransferSupport.restoreAvailableMedia(m, root: deltaRoot, cache: backupCache) }
        let changedInventory = try WorkspaceTransferSupport.availableMedia(in: existing, cache: backupCache)
        expect(!changedInventory.contains(cakeHash), "Changed media no longer advertised on next retry")
        try fm.removeItem(at: deltaRoot.appendingPathComponent(m.workspacePath))
        rejects("Missing workspace must never be recovered from old cache") { try WorkspaceTransferSupport.restoreAvailableMedia(m, root: deltaRoot, cache: backupCache) }
        let recoveryCue = RecoveryCue(id: "cue", type: "Wait", elapsed: 12, paused: false, duration: 300, mediaHash: nil)
        let recovery = RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [recoveryCue])
        try recovery.validate(); expect(true, "Valid playback recovery snapshot")
        let later = RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [.init(id: "cue", type: "Wait", elapsed: 12.5, paused: false, duration: 300, mediaHash: nil)])
        expect(recovery.matches(later, age: 0.5), "Running position compensates transit time")
        expect(!recovery.matches(later, age: 3), "Large drift refuses return readiness")
        let paused = RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [.init(id: "cue", type: "Wait", elapsed: 12, paused: true, duration: 300, mediaHash: nil)])
        expect(paused.matches(paused, age: 2), "Paused position never advances with transit time")
        expect(!recovery.matches(paused, age: 0), "Pause mismatch refuses handoff")
        rejects("Unsupported active script never replayed") {
            try RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [.init(id: "cue", type: "Script", elapsed: 0, paused: false, duration: 1, mediaHash: nil)]).validate()
        }
        rejects("Audio recovery requires media identity") {
            try RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [.init(id: "cue", type: "Audio", elapsed: 0, paused: false, duration: 100, mediaHash: nil)]).validate()
        }
        rejects("Duplicate recovery cue refused") { try RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [recoveryCue, recoveryCue]).validate() }
        rejects("Ended position never restarts at beginning") {
            try RecoverySnapshot(workspaceID: "workspace", playheadID: "next", cues: [.init(id: "cue", type: "Wait", elapsed: 300, paused: false, duration: 300, mediaHash: nil)]).validate()
        }
        print("PASS: \(checks) GO/OSC/clock/media/archive regression checks")
    }
}
