import Foundation
import Network

final class RealResults: @unchecked Sendable {
    let lock = NSLock()
    var messages = ""
    var peers = [NWConnection]()
    func accept(_ c: NWConnection) { lock.lock(); peers.append(c); lock.unlock(); c.start(queue: .global()); receive(c) }
    func close() { lock.lock(); defer { lock.unlock() }; peers.forEach { $0.cancel() }; peers.removeAll() }
    func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.add(String(decoding: data, as: UTF8.self)) }
            if !done, error == nil { self.receive(c) }
        }
    }
    func add(_ value: String) { lock.lock(); messages += value; lock.unlock() }
    func count(_ value: String) -> Int { lock.lock(); defer { lock.unlock() }; return messages.components(separatedBy: value).count - 1 }
    func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return messages.contains(value) }
}

@main struct RealQLabTests {
    @MainActor static func waitFor(_ name: String, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(12)
        while Date() < end {
            if condition() { print("PASS: " + name); return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        fatalError("TIMEOUT " + name)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/QLab55 Integration/fixture.json"))) as! [String: Any]
        let id = fixture["id"] as! String, path = fixture["path"] as! String
        _ = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set matches to every workspace whose unique id is item 1 of argv
            if (count matches) is 1 then
              set w to item 1 of matches
              if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
              close w saving no
            end if
          end tell
        end run
        """, [id])
        _ = try await MirrorQLab.run(MirrorQLab.openReceived, [id, path, "/private/tmp/QLab55 Integration/Received"])
        let waitID = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            set c to last item of (every cue of w whose q type is "Wait")
            set duration of c to 30
            return uniqueID of c
          end tell
        end run
        """, [id, path])
        _ = try await MirrorQLab.run(MirrorQLab.openReceived, [id, path, "/private/tmp/QLab55 Integration/Received"])
        let results = RealResults()
        let m = NetworkDiscovery(makeOSCClient: { QLabOSCClient(replyPort: 55302) })
        m.testStartNamedBackupOSC("QLab55 Fixture", passcode: "9469")
        defer { m.stop() }
        await waitFor("Real QLab authentication and audio isolation verified") { m.qlabOSCConnected && m.backupAudioIsolationConfirmed }
        let client = m.testCurrentClient()!
        let originalGO = client.onGo
        client.onGo = { cue in results.add("observed:" + cue); originalGO?(cue) }
        precondition(m.qlabOSCWorkspaceID == id)
        precondition(client.executeHotStandbyGo(cueID: waitID))
        try await Task.sleep(nanoseconds: 500_000_000)
        let active = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            set c to item 1 of (every cue of w whose uniqueID is item 3 of argv)
            return running of c
          end tell
        end run
        """, [id, path, waitID])
        precondition(active == "true", "OSC start must really activate Wait")
        print("PASS: real QLab executed OSC cue/start on silent Wait")
        client.executeHotStandbyPanic()
        // Exercise subscription on actual workspace GO, not the mirrored cue/start.
        _ = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            set c to item 1 of (every cue of w whose uniqueID is item 3 of argv)
            set playback position of current cue list of w to c
            go w
          end tell
        end run
        """, [id, path, waitID])
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(results.contains("observed:" + waitID), "Real QLab GO subscription must deliver exact uniqueID")
        print("PASS: real workspace GO detected with exact Wait uniqueID")
        client.executeHotStandbyPanic()
        try await Task.sleep(nanoseconds: 300_000_000)
        m.testStartNamedBackupOSC("QLab55 Fixture", passcode: "9469")
        await waitFor("Real QLab reauthenticates and verifies existing mutes after reconnect") { m.qlabOSCConnected && m.backupAudioIsolationConfirmed }
        _ = try await MirrorQLab.run(MirrorQLab.saveExpected, [id, path])
        _ = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            close w saving no
          end tell
        end run
        """, [id, path])
        _ = try await MirrorQLab.run(MirrorQLab.openReceived, [id, path, "/private/tmp/QLab55 Integration/Received"])
        for cue in fixture["cues"] as! [String] {
            _ = try await MirrorQLab.run(MirrorQLab.verifyTargets, [id, path, cue, fixture["cake"] as! String])
        }
        print("PASS: both Cake file targets survive save and close/reopen")
        // Real initial-application pipeline: relink + save + re-read + verified
        // isolation must finish before TRANSFER_COMPLETE appears on the TCP peer.
        let tcp = try NWListener(using: .tcp, on: 55311)
        tcp.newConnectionHandler = { c in results.accept(c) }
        tcp.start(queue: .global())
        let connection = NWConnection(host: "127.0.0.1", port: 55311, using: .tcp)
        connection.stateUpdateHandler = { state in if case .ready = state { results.add("tcp-ready") } }
        connection.start(queue: .global())
        await waitFor("Real validation ACK test peer ready") { results.contains("tcp-ready") }
        let mediaRoot = URL(fileURLWithPath: path).deletingLastPathComponent()
        let cache = URL(fileURLWithPath: "/private/tmp/QLab55 Integration/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let raw = try await MirrorQLab.run(MirrorQLab.targets, [id])
        let captured = try MirrorMedia.capture(root: mediaRoot, cache: cache, rawTargets: raw)
        let manifest = MirrorManifest(session: UUID().uuidString, revision: 1, workspaceID: id,
            workspacePath: URL(fileURLWithPath: path).lastPathComponent, mediaTargets: captured.targets, files: captured.files)
        m.testApplyInitial(connection, workspace: URL(fileURLWithPath: path), manifest: manifest, mediaRoot: mediaRoot)
        await waitFor("Initial copy sends ACK only after real relink/save/isolation") { m.workspaceTransferReady && results.contains("TRANSFER_COMPLETE") }
        precondition(m.backupAudioIsolationConfirmed && m.qlabOSCConnected)
        precondition(m.localQLabWorkspaceMatchesMaster, "Validated initial transfer must refresh workspace match")
        m.testInvalidateCachedMatch()
        m.testMirrorGo(waitID)
        try await Task.sleep(nanoseconds: 300_000_000)
        let mirroredRunning = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            set c to item 1 of (every cue of w whose uniqueID is item 2 of argv)
            return running of c
          end tell
        end run
        """, [id, waitID])
        precondition(mirroredRunning == "true" && m.localQLabWorkspaceMatchesMaster)
        print("PASS: GO through real BACKUP readiness after initial ACK, without forcing workspace match true")
        m.testCurrentClient()?.executeHotStandbyPanic()
        try await Task.sleep(nanoseconds: 300_000_000)
        let ackCount = results.count("TRANSFER_COMPLETE")
        let missing = "Audio é/missing.flac"
        var brokenTargets = captured.targets
        brokenTargets[(fixture["cues"] as! [String])[0]] = missing
        let brokenManifest = MirrorManifest(session: manifest.session, revision: 1, workspaceID: id,
            workspacePath: manifest.workspacePath, mediaTargets: brokenTargets,
            files: manifest.files + [MirrorFile(path: missing, size: 1, sha256: String(repeating: "0", count: 64))])
        m.testApplyInitial(connection, workspace: URL(fileURLWithPath: path), manifest: brokenManifest, mediaRoot: mediaRoot)
        await waitFor("Missing media prevents real initial-copy validation") { m.workspaceTransferError != nil }
        precondition(!m.workspaceTransferReady && results.count("TRANSFER_COMPLETE") == ackCount)
        await waitFor("Missing media sends an explicit failure to peer") { results.contains("TRANSFER_APPLY_FAILED") }
        print("PASS: missing target never sends a success ACK")
        do {
            _ = try await MirrorQLab.run(MirrorQLab.verifyTargets, [id,
                "/private/tmp/QLab55 Integration/Received/First/QLab55 Fixture.qlab5",
                (fixture["cues"] as! [String])[0], fixture["cake"] as! String])
            fatalError("Different file with same name must be refused")
        } catch { print("PASS: actual wrong workspace path rejected while equivalent paths work") }
        m.testDisconnect(); results.close(); tcp.cancel()
        m.stop()
        _ = try await MirrorQLab.run("""
        on run argv
          tell application id "com.figure53.QLab.5"
            set w to item 1 of (every workspace whose unique id is item 1 of argv)
            if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
            close w saving no
          end tell
        end run
        """, [id, path])
        print("PASS: temporary fixture closed, original workspace left open")
    }
}
