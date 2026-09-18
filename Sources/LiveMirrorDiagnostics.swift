import Foundation

// The app has no terminal when launched from Finder. Keep the test evidence accessible.
enum MirrorDiagnostics {
    private static let lock = NSLock()
    static func log(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        print(line, terminator: "")
        if ProcessInfo.processInfo.environment["QLAB_FALLBACK_TEST_LOG_STDOUT"] == "1" { return }
        lock.lock(); defer { lock.unlock() }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QLab Fallback Build5.13-test")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("diagnostic.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data(line.utf8))
        } catch { print("Journal indisponible: \(error.localizedDescription)") }
    }
}

// Both clocks are monotonic. The local send instant yields an upper bound on age,
// including clock-probe transit time, without comparing the two Macs' wall clocks.
struct MirrorEventClock {
    private var localSent: Double?
    private var remoteSample: Double?
    mutating func calibrate(sent: Double, received: Double, remote: Double) -> Bool {
        guard sent.isFinite, received.isFinite, remote.isFinite, remote >= 0,
              received >= sent, received - sent <= 0.5 else { return false }
        localSent = sent; remoteSample = remote
        return true
    }
    func age(of remoteEvent: Double, now: Double) -> Double? {
        guard let localSent, let remoteSample, now >= localSent,
              now - localSent < 10, remoteEvent.isFinite else { return nil }
        let upper = now - localSent - (remoteEvent - remoteSample)
        guard upper >= -0.05 else { return nil }
        return max(0, upper)
    }
}

struct MirrorGoReadiness {
    var enabled = true
    var oscConnected = true
    var workspaceMatches = true
    var contentReady = true
    var initialTransfer = false
    var reloading = false
    var missedGo = false
    var takeover = false
    var outputIsolationDeclared = true
    var armed = true
    var audioIsolationVerified = true
    var outputTest = false

    var refusal: String? {
        if reloading { return "GO reçu pendant rechargement : revalidation BACKUP requise" }
        if takeover { return "Prise de relais active : aucun lancement distant" }
        if initialTransfer { return "Application initiale du workspace en cours" }
        if !contentReady { return "Workspace/médias BACKUP non validés" }
        if missedGo { return "GO manqué pendant reload : revalidation nécessaire" }
        if !enabled { return "HOT STANDBY désactivé" }
        if !oscConnected { return "QLab BACKUP non connecté en OSC" }
        if !workspaceMatches { return "Workspace BACKUP différent du PRIMARY" }
        if !outputIsolationDeclared { return "Sorties BACKUP non déclarées isolées" }
        if !armed { return "Exécution HOT STANDBY non armée" }
        if !audioIsolationVerified && !outputTest { return "Isolation audio non confirmée" }
        return nil
    }
}


enum MirrorTransferDisplay {
    static func status(master: Bool, connected: Bool, synchronized: Bool, ready: Bool,
                       transferring: Bool, error: String?, transferStatus: String) -> String {
        if error != nil { return "Validation du fallback échouée" }
        if !connected { return master ? "En attente d’un BACKUP…" : "Recherche d’un PRIMARY…" }
        if transferring { return transferStatus }
        if synchronized { return "Synchronisé" }
        if ready { return master ? "BACKUP connecté · copie validée" : "Copie validée · miroir en attente" }
        return master ? "BACKUP connecté · validation en attente" : "PRIMARY connecté · validation en attente"
    }
}

// Identity is refreshed from the authenticated workspace, never from the front window.
// After initial application the manifest UUID is stronger evidence than a display name.
enum QLabWorkspaceIdentity {
    static func normalized(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".qlab5") { value.removeLast(6) }
        return value
    }
    static func matches(localName: String, masterName: String, connected: Bool,
                        localID: String?, validatedID: String?) -> Bool {
        guard connected, let localID, !localID.isEmpty else { return false }
        if let validatedID { return localID == validatedID }
        let local = normalized(localName), master = normalized(masterName)
        return !local.isEmpty && !master.isEmpty && local == master
    }
}
