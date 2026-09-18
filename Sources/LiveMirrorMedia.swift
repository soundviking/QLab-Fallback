import Foundation

// Cue IDs, not names or numbers, bind targets. Two cues can share one file;
// files with identical basenames remain distinct.
enum MirrorMedia {
    static let manifestName = "Fallback-Media-Manifest.json"
    static let externalDirectory = "Fallback-External-Media"

    static func capture(root: URL, cache: URL, rawTargets: String) throws -> (files: [MirrorFile], targets: [String: String]) {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var files = try MirrorFiles.capture(root: root, cache: cache)
        var targets = [String: String]()
        for line in rawTargets.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
                throw MirrorFailure.invalid("Cible média illisible : \(line)")
            }
            let id = String(parts[0])
            let media = URL(fileURLWithPath: String(parts[1])).resolvingSymlinksInPath().standardizedFileURL
            guard try media.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw MirrorFailure.invalid("Média non lisible pour cue \(id) : \(media.path)")
            }
            let relative: String
            if media.path.hasPrefix(root.path + "/") {
                relative = String(media.path.dropFirst(root.path.count + 1))
                guard let file = files.first(where: { $0.path == relative }),
                      try MirrorFiles.hashFile(media) == file.sha256 else {
                    throw MirrorFailure.invalid("Média absent ou modifié pendant capture : \(media.path)")
                }
            } else {
                let hash = try MirrorFiles.hashFile(media)
                relative = externalDirectory + "/" + MirrorFiles.hash(Data(media.path.utf8)) + "/" + media.lastPathComponent
                let object = cache.appendingPathComponent(hash)
                if FileManager.default.fileExists(atPath: object.path), try MirrorFiles.hashFile(object) != hash {
                    try FileManager.default.removeItem(at: object)
                }
                if !FileManager.default.fileExists(atPath: object.path) {
                    let temp = cache.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try FileManager.default.copyItem(at: media, to: temp)
                    guard try MirrorFiles.hashFile(temp) == hash, try MirrorFiles.hashFile(media) == hash else {
                        throw MirrorFailure.invalid("Média externe modifié pendant copie : \(media.path)")
                    }
                    try FileManager.default.moveItem(at: temp, to: object)
                }
                if let existing = files.first(where: { $0.path == relative }) {
                    guard existing.sha256 == hash else { throw MirrorFailure.invalid("Collision média externe : \(relative)") }
                } else {
                    files.append(MirrorFile(path: relative, size: Int64(try object.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1), sha256: hash))
                }
            }
            guard targets[id] == nil else { throw MirrorFailure.invalid("Cue média dupliquée : \(id)") }
            targets[id] = relative
        }
        return (files.sorted { $0.path < $1.path }, targets)
    }

    static func verify(_ manifest: MirrorManifest, root: URL) throws {
        try MirrorFiles.validate(manifest)
        for file in manifest.files {
            let url = try MirrorFiles.safeURL(file.path, under: root)
            guard try MirrorFiles.hashFile(url) == file.sha256 else {
                throw MirrorFailure.invalid("Fichier reçu incorrect : \(file.path)")
            }
        }
    }
}
