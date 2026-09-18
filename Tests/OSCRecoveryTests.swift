import Foundation
import Network

final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String]()
    func add(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
    func count(_ s: String) -> Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 == s }.count }
}

// Real UDP traffic on test-only loopback ports. The installed QLab is never targeted.
final class FakeQLab: @unchecked Sendable {
    let queue = DispatchQueue(label: "qlab.test.server")
    let listener: NWListener
    let replies: NWConnection
    var connections = [NWConnection]()
    var present = false
    var rejectAuth = false
    var ignore = 0
    var silent = false
    var muteDelay = 0.0
    var rejectMute = false
    var muted = Set<Int>()
    var history = [String]()
    var playhead = "CUE-ID"
    init(port: UInt16, replyPort: UInt16) throws {
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        replies = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: replyPort)!, using: .udp)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }; self.connections.append(c)
            c.start(queue: self.queue); self.receive(c)
        }
        replies.start(queue: queue)
        listener.start(queue: queue)
    }
    func configure(present: Bool, reject: Bool = false, ignore: Int = 0) {
        queue.sync { self.present = present; rejectAuth = reject; self.ignore = ignore }
    }
    func configureMute(delay: Double = 0, reject: Bool = false, clear: Bool = false) {
        queue.sync { muteDelay = delay; rejectMute = reject; if clear { muted.removeAll() } }
    }
    func silence(_ value: Bool) { queue.sync { silent = value } }
    func select(_ cue: String) {
        queue.sync { playhead = cue }
        emit("/qlab/event/workspace/playhead/uniqueID", [.string(cue)])
    }
    func setManualMute(_ output: Int) { queue.sync { _ = muted.insert(output) } }
    func hasMute(_ output: Int) -> Bool { queue.sync { muted.contains(output) } }
    func isMuted() -> Bool { queue.sync { muted == Set([1, 2]) } }
    func count(_ address: String) -> Int { queue.sync { history.filter { $0 == address }.count } }
    func emit(_ address: String, _ args: [QLabOSCClient.OSCValue]) {
        replies.send(content: QLabOSCClient.encodeOSCMessage(address: address, arguments: args), completion: .contentProcessed { _ in })
    }
    func reply(_ address: String, _ data: Any, status: String = "ok") {
        let bytes = try! JSONSerialization.data(withJSONObject: ["status": status, "data": data])
        emit("/reply" + address, [.string(String(decoding: bytes, as: UTF8.self))])
    }
    func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                for m in QLabOSCClient.decodeOSCPacket(data) {
                    self.history.append(m.address)
                    if self.silent { continue }
                    if m.address == "/workspaces" {
                        if self.ignore > 0 { self.ignore -= 1; continue }
                        self.reply(m.address, self.present ? [["displayName": "Fixture", "uniqueID": "TEST-ID", "version": "5.5"]] : [])
                    } else if m.address.hasSuffix("/connect") {
                        self.reply(m.address, self.rejectAuth ? "badpass" : "ok:view|edit|control", status: "ok")
                    } else if m.address.hasSuffix("/currentCueListID") {
                        self.reply(m.address, "LIST-ID")
                    } else if m.address.contains("/playheadID/") {
                        self.playhead = String(m.address.split(separator: "/").last!)
                        self.emit("/qlab/event/workspace/playhead/uniqueID", [.string(self.playhead)])
                    } else if m.address.hasSuffix("/playheadID") {
                        self.reply(m.address, self.playhead)
                    } else if m.address.hasSuffix("/basePath") {
                        self.reply(m.address, "/private/tmp/Fixture")
                    } else if m.address.hasSuffix("/patchList") {
                        self.reply(m.address, [["uniqueID": "PATCH-ID", "name": "Test", "routing": [1, 2], "muteChannels": Array(self.muted)]])
                    } else if m.address.contains("/mute/") {
                        let n = Int(m.address.split(separator: "/").last!)!
                        if !self.rejectMute {
                            let requestedMute: Bool
                            if case .bool(true)? = m.arguments.first { requestedMute = true } else { requestedMute = false }
                            self.queue.asyncAfter(deadline: .now() + self.muteDelay) {
                                if requestedMute { self.muted.insert(n) } else { self.muted.remove(n) }
                            }
                        }
                    } else if m.address.hasSuffix("/muteChannels") {
                        self.reply(m.address, Array(self.muted))
                    } else if m.address.hasSuffix("/start") {
                        self.emit("/qlab/event/workspace/cue/start/uniqueID", [.string("CAKE-ID")])
                    }
                }
            }
            self.receive(c)
        }
    }
    func stop() { queue.sync { listener.cancel(); replies.cancel(); connections.forEach { $0.cancel() } } }
}

@MainActor final class PlaybackFixture {
    var active = false
    var paused = false
    var elapsed = 10.0
    var stamp = ProcessInfo.processInfo.systemUptime
    var playhead = "CUE-ID"
    var failSnapshot = false
    var restores = 0
    func value() -> Double { elapsed + ((active && !paused) ? ProcessInfo.processInfo.systemUptime - stamp : 0) }
    func run(_ script: String, _ args: [String]) throws -> String? {
        if script == MirrorQLab.idle && active { throw MirrorFailure.invalid("Cues actives : test refusé") }
        if script == RecoveryQLab.snapshot {
            if failSnapshot { throw MirrorFailure.invalid("Unsupported active fixture") }
            return playhead + ((active || args.count > 1) ? "\nWAIT-ID\tWait\t\(value())\t\(paused)\t300.0\t" : "")
        }
        if script == RecoveryQLab.restoreCue {
            active = true; elapsed = Double(args[2])!; stamp = ProcessInfo.processInfo.systemUptime
            paused = args[3] == "true"; restores += 1; return args[1]
        }
        if script == RecoveryQLab.stopCue { active = false; return "" }
        if script == MirrorQLab.restorePlayhead { playhead = args[1]; return args[1] }
        return nil
    }
}

@main struct OSCRecoveryTests {
    static var checks = 0
    static func expect(_ v: Bool, _ name: String) { precondition(v, name); checks += 1; print("PASS: " + name) }
    static func waitFor(_ name: String, seconds: Double = 6, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { expect(true, name); return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError("TIMEOUT: " + name)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let results = ProbeResults()
        let client = QLabOSCClient(port: 55300, replyPort: 55301)
        client.onConnected = { _ in results.add("connected") }
        client.onError = { s in results.add(s.contains("canceled") ? "cancel-error" : "error") }
        client.onGo = { cue in results.add("go:" + cue) }
        client.start(workspaceName: "Fixture", passcode: "1515")
        // Start server after the first discovery datagram was sent to an absent QLab.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let server = try FakeQLab(port: 55300, replyPort: 55301)
        defer { client.stop(); server.stop() }
        server.configure(present: false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        expect(results.count("connected") == 0, "Missing workspace never becomes ready")
        server.configure(present: true, ignore: 1)
        client.sendHealthProbe()
        await waitFor("Late QLab/workspace + lost discovery packet recover automatically") { results.count("connected") == 1 }
        for _ in 0..<4 { client.sendHealthProbe() }
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(results.count("connected") == 1, "Health probes do not repeatedly reauthenticate an active session")
        server.emit("/qlab/event/workspace/go/uniqueID", [.string("CAKE-ID")])
        await waitFor("MASTER GO event decoded with cue identity") { results.count("go:CAKE-ID") == 1 }
        expect(client.executeHotStandbyGo(cueID: "CAKE-ID"), "BACKUP GO accepted only when connected")
        await waitFor("BACKUP emits exact cue/start without moving playhead") { server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == 1 }
        server.configure(present: false)
        client.sendHealthProbe()
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(!client.executeHotStandbyGo(cueID: "CAKE-ID"), "Closed workspace rejects GO")
        server.configure(present: true, reject: true)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        expect(results.count("connected") == 1, "Bad authentication does not connect")
        server.configure(present: true)
        await waitFor("Authentication recovers without restarting Fallback") { results.count("connected") == 2 }
        for i in 0..<8 {
            client.start(workspaceName: "Fixture", passcode: "1515")
            client.sendHealthProbe()
            await waitFor("OSC restart and simultaneous watchdog #\(i + 1)") { results.count("connected") >= i + 3 }
        }
        expect(results.count("cancel-error") == 0, "Cancelled old connection never reports an error into a new session")
        client.onRawMessage = { address, _ in if address == "/test/churn" { results.add("churn") } }
        var ephemeral = [NWConnection]()
        for _ in 0..<40 {
            let c = NWConnection(host: "127.0.0.1", port: 55301, using: .udp)
            c.stateUpdateHandler = { [weak c] state in
                if case .ready = state {
                    c?.send(content: QLabOSCClient.encodeOSCMessage(address: "/test/churn", arguments: []), completion: .contentProcessed { _ in })
                }
            }
            c.start(queue: .global()); ephemeral.append(c)
        }
        await waitFor("40 changing QLab source ports are received") { results.count("churn") == 40 }
        let churnReceivers = client.testReceiverCount()
        print("Receiver count after 40-port burst: \(churnReceivers)")
        expect(churnReceivers >= 40, "Regression fixture reproduces per-port UDP connections")
        try await Task.sleep(nanoseconds: 6_200_000_000)
        expect(client.testReceiverCount() < 4, "Idle UDP receivers are released instead of accumulating")
        ephemeral.forEach { $0.cancel() }
        client.stop()
        expect(!client.executeHotStandbyGo(cueID: "CAKE-ID"), "Stopped client rejects GO")
        try await Task.sleep(nanoseconds: 300_000_000)
        // Exercise the real manager callbacks, including an intentionally delayed old error.
        var openedPath = "", activeFixtureCue = false, reloadCount = 0
        let backupPlayback = PlaybackFixture(), masterPlayback = PlaybackFixture()
        let manager = NetworkDiscovery(makeOSCClient: { QLabOSCClient(port: 55300, replyPort: 55301) }, runQLab: { script, args in
            if let recovery = try backupPlayback.run(script, args) { return recovery }
            if script == MirrorQLab.openReceived { openedPath = args[1] }
            if script == MirrorQLab.idle && activeFixtureCue { throw MirrorFailure.invalid("Resynchronisation différée : cues BACKUP actives") }
            if script == MirrorQLab.reload { openedPath = args[2]; reloadCount += 1 }
            if script == MirrorQLab.restorePlayhead { return args[1] }
            if script == MirrorQLab.verify && args[1] != openedPath { throw MirrorFailure.invalid("Wrong open fixture") }
            return openedPath
        })
        server.configureMute(delay: 0.2)
        manager.testStartBackupOSC()
        await waitFor("Manager authenticates and verifies both mute outputs") { manager.qlabOSCConnected && manager.backupAudioIsolationConfirmed }
        expect(manager.localQLabWorkspaceMatchesMaster, "Cold BACKUP identity refreshed after OSC authentication, extension normalized")
        expect(manager.backupAudioControlError == nil, "Delayed mute application is retried and confirmed without false error")
        server.configureMute()
        let old = manager.testCurrentClient()
        manager.testStartBackupOSC()
        old?.onError?("injected late cancellation from previous session")
        old?.onConnected?("WRONG-OLD-ID")
        await waitFor("Manager reconnects and isolates after reload despite old callbacks") { manager.qlabOSCConnected && manager.backupAudioIsolationConfirmed && manager.qlabOSCWorkspaceID == "TEST-ID" }
        expect(manager.qlabOSCError == nil, "Stale error cannot poison current manager readiness")
        let masterServer = try FakeQLab(port: 55320, replyPort: 55321)
        masterServer.configure(present: true)
        defer { masterServer.stop() }
        let master = NetworkDiscovery(makeOSCClient: { QLabOSCClient(port: 55320, replyPort: 55321) },
            runQLab: { script, args in try masterPlayback.run(script, args) ?? "" })
        master.testStartMasterOSC()
        await waitFor("Second simulated QLab MASTER connects") { master.qlabOSCConnected }
        let tcp = try NWListener(using: ResponsivenessPolicy.tcpParameters(), on: 55310)
        tcp.newConnectionHandler = { c in
            c.start(queue: .global())
            Task { @MainActor in master.testAttachMaster(c); results.add("tcp-master") }
        }
        tcp.start(queue: .global())
        let backupConnection = NWConnection(host: "127.0.0.1", port: 55310, using: ResponsivenessPolicy.tcpParameters())
        backupConnection.stateUpdateHandler = { state in
            if case .ready = state { results.add("tcp-backup") }
        }
        backupConnection.start(queue: .global())
        await waitFor("Actual TCP test link ready") { results.count("tcp-master") == 1 && results.count("tcp-backup") == 1 }
        manager.testAttachBackup(backupConnection)
        let beforeGo = server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start")
        manager.testInvalidateCachedMatch()
        master.testSendGo()
        await waitFor("MASTER serialization → TCP → BACKUP readiness → OSC cue/start") { server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == beforeGo + 1 }
        func frame(_ id: String, _ seq: Int, age: Double = 0, session: String = "TEST-SESSION") -> [String: Any] {
            ["type": "MASTER_EVENT", "sessionID": session, "eventID": id, "sequence": seq,
             "eventType": "GO", "cueID": "CAKE-ID", "monotonicTime": ProcessInfo.processInfo.systemUptime - age]
        }
        expect(manager.localQLabWorkspaceMatchesMaster, "GO recomputes stale cached workspace match")
        let repeated = frame("duplicate-test", 2)
        master.testFrame(repeated); master.testFrame(repeated)
        await waitFor("Repeated event is executed once") { manager.duplicateMasterEventCount == 1 }
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == beforeGo + 2, "TCP duplicate produces exactly one OSC start")
        master.testFrame(frame("wrong-session", 3, session: "OTHER"))
        master.testFrame(frame("stale", 3, age: 4))
        await waitFor("Old event rejected before OSC") { manager.staleMasterEventCount == 1 }
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == beforeGo + 2, "Wrong session and stale GO never execute")
        manager.workspaceTransferInProgress = true
        master.testFrame(frame("copy-running", 3))
        await waitFor("GO during initial copy refused") { manager.hotStandbyBlockedReason != nil }
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == beforeGo + 2, "Unvalidated copy never executes GO")
        manager.workspaceTransferInProgress = false
        manager.testValidateIdentity("DIFFERENT-WORKSPACE-ID")
        manager.hotStandbyBlockedReason = nil
        master.testFrame(frame("wrong-id", 4))
        await waitFor("Different UUID is refused even with same workspace name") { manager.hotStandbyBlockedReason == "Workspace BACKUP différent du MASTER" }
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == beforeGo + 2, "Identity protection remains effective")
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("qlab57-readiness-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appendingPathComponent("source"), cache = fixtureRoot.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Exercise production TRANSFER_START negotiation, raw receive and SHA guard.
        // Deliberately wrong hash prevents extraction or any QLab workspace change.
        let binaryArchive = fixtureRoot.appendingPathComponent("raw-test.bin")
        let binarySize = 32 * 1024 * 1024 + 17
        try Data(repeating: 0x7B, count: binarySize).write(to: binaryArchive)
        master.testBinaryArchive(binaryArchive, size: Int64(binarySize), hash: String(repeating: "0", count: 64))
        await waitFor("Binary control negotiation reaches receiver SHA-256 verification", seconds: 15) {
            manager.workspaceTransferError?.contains("SHA-256") == true
        }
        await waitFor("Receiver hash failure reaches MASTER", seconds: 5) {
            master.workspaceTransferError?.contains("SHA-256") == true
        }
        expect(manager.workspaceTransferBytes == Int64(binarySize), "Real manager binary transfer writes complete announced archive")
        expect(!manager.workspaceTransferReady && !master.workspaceTransferReady, "Corrupt archive never reports applied or ready")
        expect(manager.heartbeatAlive && !manager.failoverActive, "Control heartbeat continues during binary file transfer")
        manager.workspaceTransferError = nil; master.workspaceTransferError = nil
        master.workspaceTransferReady = true // restore fixture state after the intentionally corrupt transfer
        let workspace = source.appendingPathComponent("Fixture.qlab5")
        try Data("isolated workspace fixture".utf8).write(to: workspace)
        let files = try MirrorFiles.capture(root: source, cache: cache)
        let manifest = MirrorManifest(session: UUID().uuidString, revision: 1, workspaceID: "TEST-ID", workspacePath: "Fixture.qlab5", mediaTargets: [:], files: files)
        expect(!manager.testMirrorCanReload(), "Mirror reload disabled before initial validation")
        manager.testApplyInitial(backupConnection, workspace: workspace, manifest: manifest, mediaRoot: source)
        await waitFor("Production initial-apply pipeline validates fixture") { manager.workspaceTransferReady && !manager.workspaceTransferInProgress }
        expect(manager.testMirrorCanReload(), "Initial validation automatically enables isolated synchronization")
        let mirror = manager.testConfigureMirror(session: manifest.session, root: source.path, cache: cache, revisions: fixtureRoot.appendingPathComponent("revisions"), playhead: "CUE-ID")
        var mirrorFrames = [[String: Any]]()
        mirror.send = { mirrorFrames.append($0) }
        await mirror.tick()
        var offer: [String: Any] = ["type": "MIRROR_OFFER", "session": manifest.session, "revision": 1, "digest": manifest.digest,
            "manifest": try JSONSerialization.jsonObject(with: JSONEncoder.sorted.encode(manifest))]
        mirror.enqueue(offer)
        await waitFor("Manager mirror negotiates cached objects") { mirrorFrames.contains { $0["type"] as? String == "MIRROR_NEED" } }
        activeFixtureCue = true
        offer["type"] = "MIRROR_COMMIT"; mirror.enqueue(offer)
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(reloadCount == 0 && !manager.failoverReady, "Active cue blocks reload and failover readiness")
        activeFixtureCue = false
        await mirror.tick()
        await waitFor("Production reload callbacks authenticate, isolate, restore playhead and ACK") { mirrorFrames.contains { $0["type"] as? String == "MIRROR_ACK" } }
        expect(reloadCount == 1 && !manager.failoverReady, "Local ACK alone cannot make failover ready")
        offer["type"] = "MIRROR_STATUS"; offer["acknowledged"] = true; mirror.enqueue(offer)
        await waitFor("Ready before MASTER failure after matching confirmation") { manager.failoverReady }
        expect(!manager.failoverPending && manager.backupAudioIsolationConfirmed, "Standby readiness never unmutes audio")
        manager.backupOutputTestActive = true; manager.refreshLocalQLabState()
        expect(!manager.failoverReady, "Output test blocks failover readiness")
        manager.backupOutputTestActive = false; manager.refreshLocalQLabState()
        expect(manager.failoverReady, "Readiness recovers when output test ends")
        offer["acknowledged"] = false; mirror.enqueue(offer)
        await waitFor("Withdrawal of MASTER confirmation blocks a healthy isolated BACKUP") { !manager.failoverReady }
        offer["acknowledged"] = true; mirror.enqueue(offer)
        await waitFor("Matching MASTER confirmation restores readiness") { manager.failoverReady }
        // Selection is remote control only, never a GO.
        master.testMatchSession(manifest.session)
        manager.testValidateIdentity("TEST-ID")
        master.sendPlayheadUpdate(cueID: "CUE-ID")
        await waitFor("Initial MASTER selection reaches BACKUP") { manager.backupTargetPlayheadID == "CUE-ID" && manager.playheadSyncReady }
        let goCount = server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start")
        let remoteSelectionBegan = ProcessInfo.processInfo.systemUptime
        server.select("REMOTE-CUE")
        await waitFor("BACKUP selection remotely moves MASTER") { master.masterPlayheadID == "REMOTE-CUE" }
        await waitFor("MASTER confirms remote selection to BACKUP") { manager.backupTargetPlayheadID == "REMOTE-CUE" && manager.playheadSyncReady }
        let remoteSelectionTime = ProcessInfo.processInfo.systemUptime - remoteSelectionBegan
        print("MEASURE: BACKUP selection round trip \(Int(remoteSelectionTime * 1000)) ms on loopback")
        expect(remoteSelectionTime < 0.15, "BACKUP remote selection has no 150 ms hold")
        let selectedCount = masterServer.count("/workspace/TEST-ID/playheadID/REMOTE-CUE")
        try await Task.sleep(nanoseconds: 500_000_000)
        expect(selectedCount == 1 && masterServer.count("/workspace/TEST-ID/playheadID/REMOTE-CUE") == 1, "Remote confirmation produces no selection echo loop")
        server.select("CUE-ID")
        await waitFor("Rapid BACKUP return to previous selection works") { master.masterPlayheadID == "CUE-ID" }
        masterServer.select("MASTER-CUE")
        await waitFor("MASTER user selection still moves BACKUP") { manager.backupTargetPlayheadID == "MASTER-CUE" }
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == goCount, "Bidirectional selection never executes GO")
        backupPlayback.active = true
        manager.startNetworkSpeedTest()
        await waitFor("Speed test refuses active BACKUP cues") { !manager.networkSpeedRunning && manager.networkSpeedStatus.contains("Test impossible") }
        backupPlayback.active = false
        masterPlayback.active = true
        manager.startNetworkSpeedTest()
        await waitFor("Speed test refuses active MASTER cues") { !manager.networkSpeedRunning && manager.networkSpeedStatus.contains("Cues actives") }
        masterPlayback.active = false
        manager.startNetworkSpeedTest()
        await waitFor("RAM-only network speed test completes through control protocol", seconds: 12) {
            !manager.networkSpeedRunning && manager.networkSpeedStatus.contains("Débit réseau")
        }
        await waitFor("Measured throughput reported on MASTER", seconds: 3) { !master.networkSpeedRunning && master.networkSpeedStatus.contains("Débit réseau") }
        print("MEASURE: " + manager.networkSpeedStatus)
        expect(manager.heartbeatAlive && !manager.failoverActive, "Benchmark preserves control link and does not trigger takeover")
        expect(server.count("/workspace/TEST-ID/cue_id/CAKE-ID/start") == goCount, "Network benchmark never starts a cue")
        manager.startNetworkSpeedTest(); manager.cancelNetworkSpeedTest()
        try await Task.sleep(nanoseconds: 250_000_000)
        expect(!manager.networkSpeedRunning && !master.networkSpeedRunning, "Cancelled benchmark cannot revive from late preparation")
        manager.selectedNetworkInterface = "missing-adapter-test"
        do { _ = try manager.testNetworkParameters(); fatalError("Missing interface must not fall back") }
        catch { expect(true, "Unavailable selected adapter refuses fallback to another interface") }
        manager.selectedNetworkInterface = "auto"
        expect(try manager.testNetworkParameters().requiredInterface == nil, "Automatic interface selection leaves listener available")
        if let card = manager.networkInterfaces.first {
            manager.selectedNetworkInterface = card.name
            expect(try manager.testNetworkParameters().requiredInterface?.name == card.name, "Explicit adapter is required by transport parameters")
            manager.selectedNetworkInterface = "auto"
        }
        masterServer.setManualMute(2)
        let beforeInvalid = masterServer.count("/workspace/TEST-ID/playheadID/INVALID-CUE")
        manager.testFrame(["type": "BACKUP_SELECTION", "sessionID": "OTHER", "workspaceID": "TEST-ID", "cueID": "INVALID-CUE", "baseCueID": "MASTER-CUE", "requestID": UUID().uuidString])
        manager.testFrame(["type": "BACKUP_SELECTION", "sessionID": manifest.session, "workspaceID": "TEST-ID", "cueID": "INVALID-CUE", "baseCueID": "STALE", "requestID": UUID().uuidString])
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(masterServer.count("/workspace/TEST-ID/playheadID/INVALID-CUE") == beforeInvalid, "Foreign session and conflicting stale BACKUP selection are refused")
        backupPlayback.active = true; backupPlayback.stamp = ProcessInfo.processInfo.systemUptime
        backupPlayback.playhead = "BACKUP-ACTIVE-CUE"
        manager.testRecoveryMonitoring(); master.testRecoveryMonitoring()
        masterServer.silence(true)
        try await Task.sleep(nanoseconds: 350_000_000)
        expect(!manager.failoverActive && master.qlabOSCConnected, "350 ms QLab response gap does not trigger takeover")
        masterServer.silence(false)
        try await Task.sleep(nanoseconds: 400_000_000)
        let lossBegan = ProcessInfo.processInfo.systemUptime
        masterServer.silence(true)
        await waitFor("QLab watchdog and heartbeat trigger real simulated audio takeover", seconds: 3) { manager.failoverActive }
        let detectionTime = ProcessInfo.processInfo.systemUptime - lossBegan
        print("MEASURE: QLab silence to confirmed BACKUP output \(Int(detectionTime * 1000)) ms on loopback")
        expect(detectionTime < 1.7, "QLab loss to confirmed output is below former 2–3 seconds")
        masterServer.silence(false)
        expect(manager.failoverTakeoverLatched, "Takeover is latched")
        await waitFor("Returning MASTER restores active playback silently", seconds: 12) { master.masterReturnReady && manager.masterReturnReady }
        expect(masterServer.isMuted() && !server.isMuted(), "BACKUP remains audible while returned MASTER stays muted")
        expect(masterPlayback.active && abs(masterPlayback.value() - backupPlayback.value()) < 1, "Running cue position restored within verification tolerance")
        expect(masterPlayback.playhead == "BACKUP-ACTIVE-CUE", "Returned MASTER follows authoritative BACKUP playhead")
        manager.testDisconnect(); master.testDisconnect()
        let reconnected = NWConnection(host: "127.0.0.1", port: 55310, using: ResponsivenessPolicy.tcpParameters())
        reconnected.start(queue: .global())
        await waitFor("TCP peer reconnects after takeover") { results.count("tcp-master") == 2 }
        manager.testReconnectBackup(reconnected)
        master.testFrame(["type": "WELCOME", "protocolVersion": 1, "sessionID": "TEST-SESSION", "machineName": "Returned MASTER", "workspace": "Fixture"])
        await waitFor("WELCOME reconnect preserves BACKUP authority", seconds: 8) { manager.isConnected && manager.connectedSessionID == "TEST-SESSION" && manager.failoverTakeoverLatched }
        expect(manager.failoverActive && !server.isMuted(), "Reconnected MASTER never automatically takes BACKUP sound")
        await waitFor("Silent return recovers after a new TCP session", seconds: 12) { master.masterReturnReady && manager.masterReturnReady }
        backupPlayback.playhead = "BACKUP-NEXT-CUE"
        await waitFor("BACKUP selection remains authoritative after MASTER returns", seconds: 8) { masterPlayback.playhead == "BACKUP-NEXT-CUE" && manager.masterReturnReady }
        backupPlayback.failSnapshot = true
        await waitFor("Unsupported live state disables manual return", seconds: 8) { !manager.masterReturnReady }
        expect(!server.isMuted(), "Invalid recovery leaves the active BACKUP audible")
        backupPlayback.failSnapshot = false
        await waitFor("Recovery retries after transient failure", seconds: 8) { manager.masterReturnReady && master.masterReturnReady }
        backupPlayback.elapsed = backupPlayback.value(); backupPlayback.paused = true
        await waitFor("Paused BACKUP state reaches silent MASTER", seconds: 8) { masterPlayback.paused && master.masterReturnReady }
        backupPlayback.paused = false; backupPlayback.stamp = ProcessInfo.processInfo.systemUptime
        await waitFor("Resumed BACKUP state reaches silent MASTER", seconds: 8) { !masterPlayback.paused && master.masterReturnReady }
        backupPlayback.playhead = "CHANGED-JUST-BEFORE-HANDOFF"
        manager.requestMasterReturn()
        await waitFor("Changed BACKUP cancels handoff without muting active output", seconds: 8) { !manager.returnInProgress && manager.failoverActive }
        expect(!server.isMuted(), "Rejected handoff keeps BACKUP audible")
        await waitFor("Cancelled handoff resumes silent alignment", seconds: 8) { masterPlayback.playhead == backupPlayback.playhead && manager.masterReturnReady && !master.returnInProgress }
        manager.requestMasterReturn()
        await waitFor("Manual return completes coordinated audio handoff", seconds: 12) { !manager.failoverActive && !master.masterReturning && manager.backupAudioIsolationConfirmed }
        expect(!masterServer.isMuted() && server.isMuted(), "MASTER only unmutes after BACKUP mute verification")
        expect(masterServer.hasMute(2) && !masterServer.hasMute(1), "Manual MASTER mute is preserved by handoff")
        expect(masterPlayback.restores > 0, "Recovery restores playback, not just selection")
        // A freshly verified BACKUP must not be orange due to earlier discovery failures.
        manager.liveMirrorSynchronized = true; manager.failoverReady = true
        manager.heartbeatAlive = true; manager.playheadSyncReady = true
        manager.backupAudioControlReady = true; manager.backupAudioIsolationConfirmed = true
        manager.hotStandbyOutputIsolationConfirmed = true; manager.hotStandbyExecutionArmed = true
        manager.lastError = "Ancienne détection QLab impossible"
        manager.workspaceTransferError = "Ancien transfert non confirmé"
        manager.failoverActivationError = "Ancienne tentative refusée"
        expect(manager.menuBarStatusText == "Synchro OK", "Verified BACKUP ignores historical errors after recovery")
        manager.heartbeatAlive = false
        expect(manager.menuBarStatusText == "Désynchronisé", "Missing BACKUP heartbeat remains orange")
        manager.heartbeatAlive = true; manager.backupAudioIsolationConfirmed = false
        expect(manager.menuBarStatusText == "Désynchronisé", "Loss of isolation remains orange even with cached ready")
        manager.backupAudioIsolationConfirmed = true; manager.failoverReady = false
        expect(manager.menuBarStatusText == "Désynchronisé", "BACKUP not ready remains orange")
        manager.failoverReady = true; manager.liveMirrorSynchronized = false
        expect(manager.menuBarStatusText == "Désynchronisé", "Unconfirmed revision remains orange")
        manager.liveMirrorSynchronized = true; manager.isConnected = false
        expect(manager.menuBarStatusText == "Non connecté", "Disconnected BACKUP is red")
        manager.isConnected = true; manager.lastError = nil; manager.workspaceTransferError = nil
        manager.failoverActivationError = nil
        master.liveMirrorSynchronized = true
        master.failoverBlockedReason = "Workspace MASTER inconnu" // stale BACKUP-only diagnostic
        master.heartbeatAlive = false // MASTER sends heartbeats; it does not receive them.
        expect(master.menuBarStatusText == "Synchro OK", "Synchronized MASTER ignores BACKUP-only status after return")
        master.lastError = "Current network error"
        expect(master.menuBarStatusText == "Désynchronisé", "Real MASTER error remains visible")
        master.lastError = nil; master.masterReturning = true
        expect(master.menuBarStatusText != "Synchro OK", "Silent returning MASTER is not reported active OK")
        master.masterReturning = false
        master.stop()

        manager.failoverActive = false; manager.failoverTakeoverLatched = false
        offer["revision"] = 2; offer["acknowledged"] = false; mirror.enqueue(offer)
        await waitFor("New unacknowledged revision blocks readiness") { !manager.failoverReady }
        mirror.stop()
        manager.testDisconnect(); master.testDisconnect(); tcp.cancel()
        manager.stop()
        server.configureMute(reject: true, clear: true)
        let refusedAudio = NetworkDiscovery(makeOSCClient: { QLabOSCClient(port: 55300, replyPort: 55301) }, runQLab: { _, _ in "" })
        refusedAudio.testStartBackupOSC()
        await waitFor("Unconfirmed audio command reports failure", seconds: 4) { refusedAudio.backupAudioControlError != nil }
        expect(!refusedAudio.backupAudioIsolationConfirmed && !refusedAudio.failoverActive, "Missing mute confirmation never becomes ready or active")
        refusedAudio.stop()
        let heartbeatProbe = NetworkDiscovery()
        heartbeatProbe.testHeartbeatMonitor()
        try await Task.sleep(nanoseconds: 350_000_000)
        expect(!heartbeatProbe.linkLost, "Brief heartbeat gap is tolerated")
        await waitFor("Missing peer heartbeat is detected below 1.2 seconds", seconds: 0.85) { heartbeatProbe.linkLost }
        heartbeatProbe.stop()
        heartbeatProbe.testHeartbeatMonitor(age: 2, transferring: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(!heartbeatProbe.linkLost, "Transfer retains six-second heartbeat allowance")
        heartbeatProbe.stop()
        print("PASS: \(checks) OSC recovery and manager integration checks")
    }
}
