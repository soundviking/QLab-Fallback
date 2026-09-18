import Foundation

@main struct RecoveryRealTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let id = "1ED132E6-4149-4A7C-B648-7E66B891D68F"
        let path = "/private/tmp/QLab55 Integration/Received/Second/QLab55 Fixture.qlab5"
        let waitID = "DA228411-E5BC-4A53-BA4C-B8865B9076CA"
        let close = """
        on run argv
          tell application id "com.figure53.QLab.5"
            set ws to every workspace whose unique id is item 1 of argv
            if (count ws) is 1 then
              set w to item 1 of ws
              if name of w does not start with "QLab55 Fixture" then error "Wrong fixture"
              close w saving no
            end if
          end tell
        end run
        """
        _ = try await MirrorQLab.run(MirrorQLab.openReceived, [id, path, "/private/tmp/QLab55 Integration/Received"])
        let client = QLabOSCClient()
        let io = RecoveryIO(); io.persist = false
        var connected = false
        client.onConnected = { got in Task { @MainActor in connected = got == id } }
        io.client = { client }; io.identity = { connected ? id : nil }
        client.start(workspaceName: "QLab55 Fixture", passcode: "9469")
        do {
            for _ in 0..<100 where !connected { try await Task.sleep(nanoseconds: 100_000_000) }
            guard connected else { throw MirrorFailure.invalid("Connexion OSC du test temporaire non confirmée") }
            try await io.isolate()
            let target = try await io.snapshot(cueID: waitID)
            guard let cue = target.cues.first, cue.id == waitID, cue.type == "Wait" else {
                throw MirrorFailure.invalid("Silent test cue absent")
            }
            for cycle in 1...5 {
            print("Silent transition cycle \(cycle)")
            let playing = RecoverySnapshot(workspaceID: id, playheadID: waitID,
                cues: [.init(id: waitID, type: "Wait", elapsed: 5, paused: false, duration: cue.duration, mediaHash: nil)])
            try await io.restore(playing, age: 0)
            let first = try await io.snapshot()
            precondition(first.cues.count == 1 && first.cues[0].elapsed >= 5 && !first.cues[0].paused)
            print("PASS: real silent Wait resumes from requested elapsed position")
            let paused = RecoverySnapshot(workspaceID: id, playheadID: waitID,
                cues: [.init(id: waitID, type: "Wait", elapsed: 8, paused: true, duration: cue.duration, mediaHash: nil)])
            try await io.restore(paused, age: 0)
            let second = try await io.snapshot()
            precondition(second.cues.count == 1 && second.cues[0].paused && abs(second.cues[0].elapsed - 8) < 0.8)
            print("PASS: real silent Wait pause and position restored")
            }
            _ = try await MirrorQLab.run(RecoveryQLab.stopCue, [id, waitID])
            _ = try await MirrorQLab.run(close, [id])
            client.stop()
            print("PASS: temporary workspace closed; original show workspace untouched")
        } catch {
            _ = try? await MirrorQLab.run(RecoveryQLab.stopCue, [id, waitID])
            _ = try? await MirrorQLab.run(close, [id])
            client.stop(); throw error
        }
    }
}
