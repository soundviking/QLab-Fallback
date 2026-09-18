import Foundation

@main
struct LiveMirrorTests {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        precondition(value, label); checks += 1
    }
    static func rejects(_ label: String, _ block: () throws -> Void) {
        do { try block(); fatalError("Expected rejection: " + label) }
        catch { checks += 1 }
    }
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("build5-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), cache = root.appendingPathComponent("objects")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("workspace v1".utf8).write(to: source.appendingPathComponent("Show.qlab5"))
        try Data("audio A".utf8).write(to: source.appendingPathComponent("sound.wav"))
        try Data().write(to: source.appendingPathComponent("empty"))
        let first = try MirrorFiles.capture(root: source, cache: cache)
        expect(first.count == 3, "Complete capture")
        let session = UUID().uuidString
        let m = MirrorManifest(session: session, revision: 1, workspaceID: "workspace-1", workspacePath: "Show.qlab5", mediaTargets: ["cue1": "sound.wav"], files: first)
        try MirrorFiles.validate(m)
        expect(m.digest.count == 64, "Canonical SHA256 manifest")
        expect(try JSONDecoder().decode(MirrorManifest.self, from: JSONEncoder.sorted.encode(m)) == m, "Round trip")
        for path in ["../escape", "/absolute", "a//b", "a/../b", "a\\b", "a/", "a\0b"] {
            rejects("Unsafe path " + path) { _ = try MirrorFiles.safeURL(path, under: source) }
        }
        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        rejects("Symlink") { _ = try MirrorFiles.safeURL("link/outside", under: source) }
        rejects("Capture symlink") { _ = try MirrorFiles.capture(root: source, cache: cache) }
        try fm.removeItem(at: link)
        let stage = root.appendingPathComponent("stage")
        try MirrorFiles.materialize(m, cache: cache, destination: stage)
        expect(try Data(contentsOf: stage.appendingPathComponent("sound.wav")) == Data("audio A".utf8), "Materialized exact media")
        try Data("edited locally".utf8).write(to: stage.appendingPathComponent("sound.wav"))
        expect(try MirrorFiles.hashFile(cache.appendingPathComponent(first.first { $0.path == "sound.wav" }!.sha256)) == first.first { $0.path == "sound.wav" }!.sha256, "Staging never mutates cache")
        let audio = source.appendingPathComponent("sound.wav")
        let date = try fm.attributesOfItem(atPath: audio.path)[.modificationDate] as! Date
        try Data("audio B".utf8).write(to: audio); try fm.setAttributes([.modificationDate: date], ofItemAtPath: audio.path)
        let second = try MirrorFiles.capture(root: source, cache: cache)
        expect(second != first, "Same size and mtime edit detected")
        let corrupt = cache.appendingPathComponent(first[0].sha256)
        try Data("corrupt".utf8).write(to: corrupt)
        rejects("Corrupt object") { try MirrorFiles.materialize(m, cache: cache, destination: root.appendingPathComponent("bad")) }
        _ = try MirrorFiles.capture(root: source, cache: cache)
        expect(try MirrorFiles.hashFile(corrupt) == first[0].sha256, "Corrupt cache repaired from source")
        // Restore v1 media into cache for wire tests.
        try Data("audio A".utf8).write(to: cache.appendingPathComponent(first.first { $0.path == "sound.wav" }!.sha256))
        let receiverCache = root.appendingPathComponent("receiver")
        try fm.createDirectory(at: receiverCache, withIntermediateDirectories: true)
        let e = LiveMirrorEngine(); e.cacheOverride = receiverCache; e.revisionsOverride = root.appendingPathComponent("revisions"); e.verificationAttempts = 1
        e.workspaceSignature = { try MirrorFiles.hashFile(URL(fileURLWithPath: $0)) }
        var c = LiveMirrorEngine.Context(master: false, connected: true, session: session, workspaceID: "workspace-1", root: nil, canReload: false, initialTransfer: false)
        e.context = { c }
        var sent = [[String: Any]](), reloads = 0, currentPath = "/old/Show.qlab5", ready = false
        var invalidTargets = true
        e.send = { sent.append($0) }
        e.readyAfterReload = { ready }
        e.qlab = { script, args in
            if script == MirrorQLab.verifyTargets && invalidTargets { throw MirrorFailure.invalid("Target not persisted") }
            if script == MirrorQLab.reload { reloads += 1; currentPath = args[2] }
            if script == MirrorQLab.verify, args[1] != currentPath { throw MirrorFailure.invalid("Wrong open document") }
            return currentPath
        }
        func wire(_ type: String) -> [String: Any] { ["type": type, "session": session, "revision": 1, "digest": m.digest] }
        func deliver(_ obj: [String: Any], delay: UInt64 = 100_000_000) async throws {
            let data = try JSONSerialization.data(withJSONObject: obj)
            e.enqueue(try JSONSerialization.jsonObject(with: data) as! [String: Any])
            try await Task.sleep(nanoseconds: delay)
        }
        var offer = wire("MIRROR_OFFER"); offer["manifest"] = try JSONSerialization.jsonObject(with: JSONEncoder.sorted.encode(m))
        try await deliver(offer)
        expect(sent.last?["type"] as? String == "MIRROR_NEED", "Offer requests missing objects")
        expect(!e.synchronized && !e.contentReady, "Offer never marks ready")
        for file in first {
            let data = try Data(contentsOf: cache.appendingPathComponent(file.sha256))
            if !data.isEmpty {
                var chunk = wire("MIRROR_CHUNK"); chunk["hash"] = file.sha256; chunk["offset"] = 0; chunk["data"] = data.base64EncodedString()
                try await deliver(chunk)
            }
            var end = wire("MIRROR_FILE_END"); end["hash"] = file.sha256
            try await deliver(end)
        }
        try await deliver(wire("MIRROR_COMMIT"))
        expect(reloads == 0, "Unconfirmed isolation defers reload")
        expect(!sent.contains { $0["type"] as? String == "MIRROR_ACK" }, "No ACK on file reception")
        c.canReload = true
        try await deliver(wire("MIRROR_COMMIT"), delay: 800_000_000)
        expect(reloads == 1, "Real application requested")
        expect(!sent.contains { $0["type"] as? String == "MIRROR_ACK" }, "No ACK before audio isolation")
        ready = true
        try await deliver(wire("MIRROR_COMMIT"), delay: 800_000_000)
        expect(!sent.contains { $0["type"] as? String == "MIRROR_ACK" }, "No ACK when saved target verification fails")
        expect(!e.contentReady, "Invalid saved target keeps GO readiness false")
        invalidTargets = false
        try await deliver(wire("MIRROR_COMMIT"), delay: 800_000_000)
        expect(reloads == 1, "Retry reuses already opened revision")
        expect(sent.last?["type"] as? String == "MIRROR_ACK", "ACK after application and isolation")
        expect(!e.contentReady, "Wait for PRIMARY acknowledgement confirmation")
        var status = wire("MIRROR_STATUS"); status["acknowledged"] = true
        try await deliver(status)
        expect(e.synchronized && e.contentReady, "Latest ACK confirmed by PRIMARY")
        await e.tick()
        expect(e.contentReady, "First periodic tick preserves session adopted from incoming offer")
        try await deliver(offer)
        expect(reloads == 1, "Duplicate does not reapply")
        expect(sent.last?["type"] as? String == "MIRROR_ACK", "Lost ACK replay")
        var newer = status; newer["revision"] = 2; newer["digest"] = String(repeating: "a", count: 64); newer["acknowledged"] = false
        try await deliver(newer)
        expect(!e.synchronized && !e.contentReady, "Newer version invalidates readiness immediately")
        try await deliver(status)
        expect(!e.synchronized && !e.contentReady, "Old status cannot restore readiness")
        var wrongSession = offer; wrongSession["session"] = UUID().uuidString
        let sentBefore = sent.count
        try await deliver(wrongSession)
        expect(sent.count == sentBefore, "Foreign session ignored")
        e.stop(); expect(!e.contentReady, "Stop clears applied state")
        // Two engines over an in-memory JSON wire exercise chunk flow control,
        // ACK ordering, delta selection and PRIMARY version freshness together.
        let master = LiveMirrorEngine()
        master.workspaceSignature = {
            let text = try String(contentsOfFile: $0, encoding: .utf8)
            return MirrorFiles.hash(Data(text.components(separatedBy: "\ncontroller=")[0].utf8))
        }
        let backup = LiveMirrorEngine()
        backup.workspaceSignature = { try MirrorFiles.hashFile(URL(fileURLWithPath: $0)) }
        let backupCache = root.appendingPathComponent("end-to-end-cache")
        try fm.createDirectory(at: backupCache, withIntermediateDirectories: true)
        master.cacheOverride = cache; backup.cacheOverride = backupCache
        backup.revisionsOverride = root.appendingPathComponent("end-to-end-versions")
        backup.verificationAttempts = 1
        let session2 = UUID().uuidString
        let sourceWorkspace = source.appendingPathComponent("Show.qlab5").path
        var backupPath = "/initial/Show.qlab5", endToEndReloads = 0
        master.context = { .init(master: true, connected: true, session: session2, workspaceID: "workspace-1", root: source.path, canReload: false, initialTransfer: false) }
        backup.context = { .init(master: false, connected: true, session: session2, workspaceID: "workspace-1", root: nil, canReload: true, initialTransfer: false) }
        master.qlab = { script, _ in
            script == MirrorQLab.targets ? "cue1\t" + source.appendingPathComponent("sound.wav").path : sourceWorkspace
        }
        backup.qlab = { script, args in
            if script == MirrorQLab.reload { backupPath = args[2]; endToEndReloads += 1 }
            if script == MirrorQLab.verify && args[1] != backupPath { throw MirrorFailure.invalid("Wrong document") }
            return backupPath
        }
        backup.readyAfterReload = { true }
        var wireLog = [[String: Any]]()
        master.send = { obj in
            wireLog.append(obj)
            backup.enqueue(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: obj)) as! [String: Any])
        }
        backup.send = { obj in
            wireLog.append(obj)
            master.enqueue(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: obj)) as! [String: Any])
        }
        try Data(repeating: 0x4A, count: 1_200_000).write(to: audio)
        await master.tick()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await master.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        expect(master.synchronized && backup.synchronized, "Two-engine applied/ACK round trip")
        expect(endToEndReloads == 1, "Single reload across full transfer")
        expect(wireLog.filter { $0["type"] as? String == "MIRROR_CHUNK" }.count >= 2, "Multi-chunk file transmitted")
        expect(wireLog.contains { $0["type"] as? String == "MIRROR_FILE_OK" }, "Per-file verification backpressure")
        wireLog.removeAll()
        let savedWorkspace = try String(contentsOfFile: sourceWorkspace, encoding: .utf8)
        try (savedWorkspace + "\ncontroller=remote-selection").write(toFile: sourceWorkspace, atomically: true, encoding: .utf8)
        await master.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        expect(master.synchronized && backup.synchronized && endToEndReloads == 1, "Runtime-only save preserves readiness without reload")
        expect(!wireLog.contains { $0["type"] as? String == "MIRROR_OFFER" }, "Runtime-only save sends no new revision")
        wireLog.removeAll()
        try Data(repeating: 0x4B, count: 100000).write(to: audio)
        await master.tick()
        expect(!master.synchronized, "PRIMARY edit immediately invalidates old ACK")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await master.tick()
        try await Task.sleep(nanoseconds: 200_000_000)
        let requested = wireLog.first { $0["type"] as? String == "MIRROR_NEED" }?["hashes"] as? [String]
        expect(requested?.count == 1, "Only changed media requested after initial transfer")
        expect(endToEndReloads == 2 && backup.synchronized, "Delta applied and latest version acknowledged")
        let currentOffer = wireLog.first { $0["type"] as? String == "MIRROR_OFFER" }!
        let revision = currentOffer["revision"] as! Int
        var staleAck = currentOffer; staleAck["type"] = "MIRROR_ACK"; staleAck["revision"] = revision - 1
        master.enqueue(staleAck)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(master.synchronized, "Stale ACK cannot replace current acknowledgement")
        master.stop(); backup.stop()
        print("PASS: \(checks) integrity and protocol checks")
    }
}
