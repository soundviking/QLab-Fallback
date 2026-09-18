import Foundation
@main struct ReuseBenchmark {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("qlab55-reuse-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let master = tmp.appendingPathComponent("PRIMARY"), backup = tmp.appendingPathComponent("BACKUP")
        let cache = tmp.appendingPathComponent("cache"), backupCache = tmp.appendingPathComponent("backup-cache")
        for d in [master, backup, cache, backupCache] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("QLab-Fallback-Test-Media/CAKE - I Will Survive.flac")
        let originalHash = try MirrorFiles.hashFile(source)
        let media = master.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: media)
        try fm.copyItem(at: source, to: backup.appendingPathComponent(source.lastPathComponent))
        try Data("workspace fixture".utf8).write(to: master.appendingPathComponent("Fixture.qlab5"))
        let captured = try MirrorMedia.capture(root: master, cache: cache, rawTargets: "cue1\t\(media.path)\ncue15\t\(media.path)\n")
        let manifest = MirrorManifest(session: UUID().uuidString, revision: 1, workspaceID: "BENCH", workspacePath: "Fixture.qlab5", mediaTargets: captured.targets, files: captured.files)
        let start = Date()
        let full = try WorkspaceTransferSupport.portableArchive(manifest: manifest, cache: cache, projectName: "Project", availableMedia: [])
        defer { try? fm.removeItem(at: full) }
        let fullTime = Date().timeIntervalSince(start)
        let reuseStart = Date()
        let available = try WorkspaceTransferSupport.availableMedia(in: backup, cache: backupCache)
        let incremental = try WorkspaceTransferSupport.portableArchive(manifest: manifest, cache: cache, projectName: "Project", availableMedia: available)
        defer { try? fm.removeItem(at: incremental) }
        let reuseTime = Date().timeIntervalSince(reuseStart)
        let fullBytes = try full.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let deltaBytes = try incremental.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(deltaBytes < fullBytes / 100)
        let finalHash = try MirrorFiles.hashFile(source)
        precondition(finalHash == originalHash)
        print("PASS: real Cake full archive=\(fullBytes) bytes; incremental archive=\(deltaBytes) bytes")
        print(String(format: "Local preparation full=%.3fs; inventory + incremental=%.3fs. This is not a two-Mac timing.", fullTime, reuseTime))
    }
}
