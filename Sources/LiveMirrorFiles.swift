import Foundation
import CryptoKit
import Darwin

struct MirrorFile: Codable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
}
struct MirrorManifest: Codable, Equatable {
    let session: String
    let revision: Int
    let workspaceID: String
    let workspacePath: String
    let mediaTargets: [String: String]
    let files: [MirrorFile]
    var digest: String { (try? MirrorFiles.hash(JSONEncoder.sorted.encode(self))) ?? "" }
}
extension JSONEncoder {
    static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
}
enum MirrorFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
enum MirrorFiles {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hashFile(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var digest = SHA256()
        while let block = try h.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validHash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { "0123456789abcdef".contains($0) } }
    static func safeURL(_ path: String, under root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MirrorFailure.invalid("Chemin de fichier refusé : \(path)")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MirrorFailure.invalid("Lien symbolique refusé : \(path)")
            }
        }
        return url
    }
    static func validate(_ m: MirrorManifest) throws {
        guard UUID(uuidString: m.session) != nil, m.revision > 0, !m.workspaceID.isEmpty,
              m.files.count <= 50000, !m.files.isEmpty else { throw MirrorFailure.invalid("Manifest invalide") }
        var paths = Set<String>()
        var total: Int64 = 0
        for f in m.files {
            let sum = total.addingReportingOverflow(f.size)
            guard !sum.overflow, f.size >= 0 else { throw MirrorFailure.invalid("Taille de projet invalide") }
            total = sum.partialValue
            _ = try safeURL(f.path, under: URL(fileURLWithPath: "/tmp/qlab-mirror-validation"))
            guard paths.insert(f.path.lowercased()).inserted, f.size >= 0, validHash(f.sha256) else {
                throw MirrorFailure.invalid("Manifest ambigu ou empreinte invalide")
            }
        }
        for (id, path) in m.mediaTargets {
            guard !id.isEmpty, m.files.contains(where: { $0.path == path }) else {
                throw MirrorFailure.invalid("Média ciblé absent du projet : \(path)")
            }
        }
        guard m.workspacePath.lowercased().hasSuffix(".qlab5"),
              m.files.contains(where: { $0.path == m.workspacePath || $0.path.hasPrefix(m.workspacePath + "/") }) else {
            throw MirrorFailure.invalid("Workspace absent du manifest")
        }
    }
    static func cacheRoot() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QLab Fallback Build5/Objects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    // Every scan hashes contents, including media whose size/mtime stayed unchanged.
    // Copy first, hash the immutable copy, then compare source to avoid torn publications.
    static func capture(root: URL, cache: URL) throws -> [MirrorFile] {
        guard let resolved = realpath(root.path, nil) else { throw MirrorFailure.invalid("Projet introuvable") }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved))
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw MirrorFailure.invalid("Projet illisible")
        }
        var files = [MirrorFile]()
        for case let url as URL in e {
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw MirrorFailure.invalid("Média/projet avec lien symbolique : \(url.path)") }
            guard v.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let hash = try hashFile(url)
            let object = cache.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: object.path), try hashFile(object) != hash {
                try FileManager.default.removeItem(at: object)
            }
            if !FileManager.default.fileExists(atPath: object.path) {
                let temp = cache.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                try FileManager.default.copyItem(at: url, to: temp)
                guard try hashFile(temp) == hash, try hashFile(url) == hash else { throw MirrorFailure.invalid("Fichier modifié pendant la capture : \(rel)") }
                try FileManager.default.moveItem(at: temp, to: object)
            }
            let size = (try object.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            files.append(MirrorFile(path: rel, size: size, sha256: hash))
        }
        return files.sorted { $0.path < $1.path }
    }
    static func materialize(_ m: MirrorManifest, cache: URL, destination: URL) throws {
        try validate(m)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let free = try FileManager.default.attributesOfFileSystem(forPath: destination.path)[.systemFreeSize] as? NSNumber
        let required = m.files.reduce(Int64(0)) { $0 + $1.size }
        guard let free, free.int64Value > required, free.int64Value - required > 256 * 1024 * 1024 else {
            throw MirrorFailure.invalid("Espace disque insuffisant pour préparer la nouvelle version sans écraser l’ancienne")
        }
        for f in m.files {
            let object = cache.appendingPathComponent(f.sha256)
            guard try hashFile(object) == f.sha256,
                  Int64(try object.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == f.size else { throw MirrorFailure.invalid("SHA-256/taille incorrect : \(f.path)") }
            let target = try safeURL(f.path, under: destination)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Real copy, never hard-link a mutable QLab document into the object store.
            try FileManager.default.copyItem(at: object, to: target)
        }
    }
}
