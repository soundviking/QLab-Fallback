import Foundation

struct RecoveryCue: Codable, Equatable {
    let id: String
    let type: String
    let elapsed: Double
    let paused: Bool
    let duration: Double
    let mediaHash: String?
}
struct RecoverySnapshot: Codable {
    let workspaceID: String
    let playheadID: String
    let cues: [RecoveryCue]
    func validate() throws {
        guard !workspaceID.isEmpty, !playheadID.isEmpty, cues.count <= 64,
              Set(cues.map(\.id)).count == cues.count else { throw MirrorFailure.invalid("État de reprise invalide") }
        for c in cues {
            guard !c.id.isEmpty, ["Audio", "Wait"].contains(c.type), c.elapsed.isFinite,
                  c.duration.isFinite, c.elapsed >= 0, c.duration > c.elapsed,
                  c.type != "Audio" || c.mediaHash.map(MirrorFiles.validHash) == true else {
                throw MirrorFailure.invalid("Reprise automatique non disponible pour cette cue : \(c.id)")
            }
        }
    }
    func matches(_ other: RecoverySnapshot, age: Double, tolerance: Double = 0.8) -> Bool {
        guard workspaceID == other.workspaceID, playheadID == other.playheadID,
              Set(cues.map(\.id)) == Set(other.cues.map(\.id)) else { return false }
        return cues.allSatisfy { c in
            guard let o = other.cues.first(where: { $0.id == c.id }) else { return false }
            return c.type == o.type && c.paused == o.paused && c.mediaHash == o.mediaHash
                && abs(o.elapsed - c.elapsed - (c.paused ? 0 : age)) <= tolerance
        }
    }
}

enum RecoveryQLab {
    // The snapshot covers active audio/wait cues, including paused cues. Other
    // active cue types/chains are rejected, never silently replayed as GO.
    static let snapshot = """
    on run argv
      set rows to {}
      tell application id "com.figure53.QLab.5"
        set ws to every workspace whose unique id is item 1 of argv
        if (count ws) is not 1 then error "Workspace de reprise absent ou ambigu"
        set w to item 1 of ws
        set ph to uniqueID of (playback position of current cue list of w)
        set end of rows to ph
        if (count argv) > 1 then
          set cs to every cue of w whose uniqueID is item 2 of argv
          if (count cs) is not 1 then error "Cue de reprise absente du PRIMARY"
        else
          set cs to active cues of w
        end if
        repeat with c in cs
          set cid to uniqueID of c
          set recoveryCueKind to q type of c
          if recoveryCueKind is not "Audio" and recoveryCueKind is not "Wait" then error "Reprise différée : type de cue actif non pris en charge"
          if continue mode of c is not do_not_continue then error "Reprise différée : séquence automatique active"
          if pre wait of c is not 0 then error "Reprise différée : pré-attente active"
          set elapsedTime to action elapsed of c
          set isPaused to paused of c
          set cueDuration to duration of c
          set targetFile to ""
          if recoveryCueKind is "Audio" then set targetFile to get file target of c
          set end of rows to {cid, recoveryCueKind, elapsedTime, isPaused, cueDuration, targetFile}
        end repeat
      end tell
      set output to (item 1 of rows) as text
      repeat with n from 2 to count rows
        set r to item n of rows
        set mediaPath to ""
        if item 2 of r is "Audio" then set mediaPath to POSIX path of (item 6 of r)
        set output to output & linefeed & (item 1 of r) & tab & (item 2 of r) & tab & (item 3 of r as text) & tab & (item 4 of r as text) & tab & (item 5 of r as text) & tab & mediaPath
      end repeat
      return output
    end run
    """
    static let restoreCue = """
    on run argv
      set cueTime to (item 3 of argv) as real
      tell application id "com.figure53.QLab.5"
        set ws to every workspace whose unique id is item 1 of argv
        if (count ws) is not 1 then error "Workspace de reprise absent ou ambigu"
        set w to item 1 of ws
        set cs to every cue of w whose uniqueID is item 2 of argv
        if (count cs) is not 1 then error "Cue de reprise absente"
        set c to item 1 of cs
        if q type of c is not "Audio" and q type of c is not "Wait" then error "Type de reprise non pris en charge"
        if continue mode of c is not do_not_continue or pre wait of c is not 0 then error "Séquence de reprise non prise en charge"
        if cueTime < 0 or cueTime >= duration of c then error "Position de reprise hors durée"
        stop c
        repeat 50 times
          if not running of c and not paused of c then exit repeat
          delay 0.01
        end repeat
        if running of c or paused of c then error "Arrêt préalable de la cue non confirmé"
        -- QLab finishes its asynchronous unload after reporting not-running.
        -- Let that completion settle before loading a new position.
        delay 0.1
        load c time cueTime
        repeat 100 times
          if loaded of c then exit repeat
          delay 0.01
        end repeat
        if not loaded of c then error "Chargement à la position demandée non confirmé"
        start c
        repeat 50 times
          if running of c then exit repeat
          delay 0.01
        end repeat
        if not running of c then error "Démarrage silencieux de la cue non confirmé"
        if item 4 of argv is "true" then
          pause c
          repeat 50 times
            if paused of c then exit repeat
            delay 0.01
          end repeat
          if not paused of c then error "Pause de la cue non confirmée"
        end if
        return uniqueID of c
      end tell
    end run
    """
    static let stopCue = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set ws to every workspace whose unique id is item 1 of argv
        if (count ws) is not 1 then error "Workspace de reprise absent"
        set cs to every cue of item 1 of ws whose uniqueID is item 2 of argv
        if (count cs) is not 1 then error "Cue de reprise absente"
        stop item 1 of cs
      end tell
    end run
    """
}

@MainActor
final class RecoveryIO {
    var run: (String, [String]) async throws -> String = MirrorQLab.run
    var client: () -> QLabOSCClient? = { nil }
    var identity: () -> String? = { nil }
    var check: () throws -> Void = {}
    private var owned = [String: Set<Int>]()
    private var ownedWorkspace: String?
    var persist = true

    func snapshot(cueID: String? = nil) async throws -> RecoverySnapshot {
        guard let id = identity() else { throw MirrorFailure.invalid("QLab de reprise déconnecté") }
        let raw = try await run(RecoveryQLab.snapshot, [id] + (cueID.map { [$0] } ?? []))
        try check()
        let rows = raw.components(separatedBy: "\n")
        guard let playhead = rows.first, !playhead.isEmpty else { throw MirrorFailure.invalid("Playhead de reprise absent") }
        var cues = [RecoveryCue]()
        for row in rows.dropFirst() where !row.isEmpty {
            let f = row.components(separatedBy: "\t")
            guard (f.count == 6 || (f.count == 5 && f[1] == "Wait")), let time = Double(f[2].replacingOccurrences(of: ",", with: ".")),
                  let duration = Double(f[4].replacingOccurrences(of: ",", with: ".")),
                  ["true", "false"].contains(f[3]) else { throw MirrorFailure.invalid("État QLab de reprise illisible") }
            let hash: String? = f[1] == "Audio" ? try MirrorFiles.hashFile(URL(fileURLWithPath: f[5])) : nil
            cues.append(.init(id: f[0], type: f[1], elapsed: time, paused: f[3] == "true", duration: duration, mediaHash: hash))
        }
        let state = RecoverySnapshot(workspaceID: id, playheadID: playhead, cues: cues)
        try state.validate(); return state
    }
    private func query(_ suffix: String) async throws -> Any {
        guard let id = identity(), let client = client() else { throw MirrorFailure.invalid("OSC de reprise absent") }
        let data = try await client.recoveryQuery("/workspace/\(id)/" + suffix)
        try check()
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    func isolate() async throws {
        guard let id = identity(), let client = client() else { throw MirrorFailure.invalid("PRIMARY non connecté") }
        if ownedWorkspace != id {
            ownedWorkspace = id; owned = [:]
            if persist, let saved = UserDefaults.standard.dictionary(forKey: "RecoveryMute-" + id) as? [String: [Int]] {
                owned = saved.mapValues(Set.init)
            }
        }
        guard let patches = try await query("settings/audio/patchList") as? [[String: Any]], !patches.isEmpty else {
            throw MirrorFailure.invalid("Patches audio PRIMARY non vérifiés")
        }
        for p in patches {
            guard let patch = p["uniqueID"] as? String,
                  let routing = p["routing"] as? [Int], let muted = p["muteChannels"] as? [Int] else {
                throw MirrorFailure.invalid("Patch PRIMARY incomplet")
            }
            let active = Set(routing.filter { $0 > 0 }).subtracting(muted)
            owned[patch, default: []].formUnion(active)
            if persist { UserDefaults.standard.set(owned.mapValues { Array($0) }, forKey: "RecoveryMute-" + id) }
            for output in owned[patch, default: []] {
                guard client.recoveryCommand("/workspace/\(id)/settings/audio/patchID/\(patch)/mute/\(output)", arguments: [.bool(true)]) else {
                    throw MirrorFailure.invalid("Isolation PRIMARY refusée")
                }
            }
            let expected = Set(routing).union(owned[patch, default: []])
            guard let actual = try await query("settings/audio/patchID/\(patch)/muteChannels") as? [Int], expected.isSubset(of: Set(actual)) else {
                throw MirrorFailure.invalid("Isolation PRIMARY non confirmée")
            }
        }
    }
    func release() async throws {
        guard let id = identity(), id == ownedWorkspace, let client = client() else { throw MirrorFailure.invalid("Isolation PRIMARY inconnue") }
        for (patch, outputs) in owned {
            for output in outputs {
                guard client.recoveryCommand("/workspace/\(id)/settings/audio/patchID/\(patch)/mute/\(output)", arguments: [.bool(false)]) else {
                    throw MirrorFailure.invalid("Reprise sonore PRIMARY refusée")
                }
            }
            guard let actual = try await query("settings/audio/patchID/\(patch)/muteChannels") as? [Int], outputs.isDisjoint(with: Set(actual)) else {
                throw MirrorFailure.invalid("Reprise sonore PRIMARY non confirmée")
            }
        }
        owned.removeAll()
        if persist { UserDefaults.standard.removeObject(forKey: "RecoveryMute-" + id) }
    }
    func restore(_ state: RecoverySnapshot, age: Double) async throws {
        try state.validate(); try check()
        guard state.workspaceID == identity(), age >= 0, age < 2 else { throw MirrorFailure.invalid("État BACKUP périmé ou workspace différent") }
        let began = ProcessInfo.processInfo.systemUptime
        // Verify every target before changing any playback state.
        for c in state.cues {
            let local = try await snapshot(cueID: c.id)
            guard let match = local.cues.first, match.type == c.type,
                  match.mediaHash == c.mediaHash, abs(match.duration - c.duration) < 0.01 else {
                throw MirrorFailure.invalid("Cue/média différent sur le PRIMARY : \(c.id)")
            }
        }
        let local = try await snapshot()
        for c in local.cues where !state.cues.contains(where: { $0.id == c.id }) {
            _ = try await run(RecoveryQLab.stopCue, [state.workspaceID, c.id]); try check()
        }
        for c in state.cues {
            let elapsed = c.elapsed + (c.paused ? 0 : age + ProcessInfo.processInfo.systemUptime - began)
            if let old = local.cues.first(where: { $0.id == c.id }), old.paused == c.paused,
               abs(old.elapsed - elapsed) < 0.4 { continue }
            _ = try await run(RecoveryQLab.restoreCue, [state.workspaceID, c.id, String(elapsed), String(c.paused)])
            try check()
        }
        _ = try await run(MirrorQLab.restorePlayhead, [state.workspaceID, state.playheadID]); try check()
        let verified = try await snapshot()
        guard state.matches(verified, age: age + ProcessInfo.processInfo.systemUptime - began) else {
            MirrorDiagnostics.log("RETOUR écart lecture attendu=\(state) obtenu=\(verified)")
            throw MirrorFailure.invalid("Lecture PRIMARY pas encore alignée sur le BACKUP")
        }
    }
}
