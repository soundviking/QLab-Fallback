import Foundation

enum WorkspaceTransferSupport {

    enum TransferError: LocalizedError {

        case invalidSource
        case invalidArchive
        case workspaceNotFound
        case processFailed(String)

        var errorDescription: String? {

            switch self {

            case .invalidSource:
                return "Dossier projet QLab invalide"

            case .invalidArchive:
                return "Archive de transfert invalide"

            case .workspaceNotFound:
                return "Aucun workspace .qlab5 trouvé dans le projet reçu"

            case .processFailed(let message):
                return message
            }
        }
    }


    static func makePortableArchive(sourceDirectory: URL, workspaceID: String, availableMedia: Set<String> = []) async throws -> URL {
        let root = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
        let workspace = try await MirrorQLab.run(MirrorQLab.locate, [workspaceID])
        guard workspace.hasPrefix(root.path + "/") else {
            throw MirrorFailure.invalid("Workspace MASTER hors du dossier projet")
        }
        let rawTargets = try await MirrorQLab.run(MirrorQLab.targets, [workspaceID])
        let cache = try MirrorFiles.cacheRoot()
        let captured = try MirrorMedia.capture(root: root, cache: cache, rawTargets: rawTargets)
        let checked = try await MirrorQLab.run(MirrorQLab.check, [workspaceID])
        guard checked == workspace else { throw MirrorFailure.invalid("Workspace changé pendant capture") }
        let manifest = MirrorManifest(session: UUID().uuidString, revision: 1, workspaceID: workspaceID,
            workspacePath: String(workspace.dropFirst(root.path.count + 1)),
            mediaTargets: captured.targets, files: captured.files)
        return try portableArchive(manifest: manifest, cache: cache,
            projectName: root.lastPathComponent, availableMedia: availableMedia)
    }

    // BACKUP hashes real files and snapshots them into immutable objects before
    // advertising availability. No filename/mtime shortcuts and no external paths.
    static func availableMedia(in root: URL, cache: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try MirrorFiles.capture(root: root, cache: cache)
        return Set(files.prefix(8192).map(\.sha256))
    }

    static func portableArchive(manifest: MirrorManifest, cache: URL,
                                projectName: String, availableMedia: Set<String>) throws -> URL {
        try MirrorFiles.validate(manifest)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stage = temporary.appendingPathComponent(sanitize(projectName))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let mediaPaths = Set(manifest.mediaTargets.values)
        var reused = 0
        var savedBytes: Int64 = 0
        for file in manifest.files {
            if mediaPaths.contains(file.path), availableMedia.contains(file.sha256),
               file.path != manifest.workspacePath, !file.path.hasPrefix(manifest.workspacePath + "/") {
                reused += 1; savedBytes += file.size
                continue
            }
            let object = cache.appendingPathComponent(file.sha256)
            guard try MirrorFiles.hashFile(object) == file.sha256 else {
                throw MirrorFailure.invalid("Objet MASTER altéré : " + file.path)
            }
            let target = try MirrorFiles.safeURL(file.path, under: stage)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: object, to: target)
        }
        let manifestURL = stage.appendingPathComponent(MirrorMedia.manifestName)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MirrorFailure.invalid("Nom réservé déjà présent : " + MirrorMedia.manifestName)
        }
        try JSONEncoder.sorted.encode(manifest).write(to: manifestURL, options: .atomic)
        MirrorDiagnostics.log("TRANSFERT préparation : \(reused) médias réutilisés, \(savedBytes) octets évités sur le réseau")
        return try makeArchive(sourceDirectory: stage)
    }

    static func restoreAvailableMedia(_ manifest: MirrorManifest, root: URL, cache: URL) throws {
        try MirrorFiles.validate(manifest)
        let mediaPaths = Set(manifest.mediaTargets.values)
        for file in manifest.files {
            let target = try MirrorFiles.safeURL(file.path, under: root)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            guard mediaPaths.contains(file.path), file.path != manifest.workspacePath,
                  !file.path.hasPrefix(manifest.workspacePath + "/") else {
                throw MirrorFailure.invalid("Fichier non média absent du transfert : " + file.path)
            }
            let object = try MirrorFiles.safeURL(file.sha256, under: cache)
            guard FileManager.default.fileExists(atPath: object.path),
                  try MirrorFiles.hashFile(object) == file.sha256,
                  Int64(try object.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == file.size else {
                throw MirrorFailure.invalid("Média local absent ou modifié : " + file.path + ". Relancer Créer le fallback pour recalculer les fichiers nécessaires.")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: object, to: target)
            MirrorDiagnostics.log("MEDIA réutilisé localement SHA-256 vérifié target=\(file.path)")
        }
    }

    static func receivedManifest(workspaceURL: URL, extractionRoot: URL) throws -> (MirrorManifest, URL) {
        // Walk only within the extraction, never into a parent Documents folder.
        let workspaceURL = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let extractionRoot = extractionRoot.resolvingSymlinksInPath().standardizedFileURL
        var directory = workspaceURL.deletingLastPathComponent()
        while directory.path == extractionRoot.path || directory.path.hasPrefix(extractionRoot.path + "/") {
            let url = directory.appendingPathComponent(MirrorMedia.manifestName)
            if FileManager.default.fileExists(atPath: url.path) {
                let manifest = try JSONDecoder().decode(MirrorManifest.self, from: Data(contentsOf: url))
                try restoreAvailableMedia(manifest, root: directory, cache: MirrorFiles.cacheRoot())
                try MirrorMedia.verify(manifest, root: directory)
                guard try MirrorFiles.safeURL(manifest.workspacePath, under: directory) == workspaceURL else {
                    throw MirrorFailure.invalid("Manifest destiné à un autre workspace")
                }
                return (manifest, directory)
            }
            directory.deleteLastPathComponent()
        }
        throw MirrorFailure.invalid("Manifest médias absent dans \(extractionRoot.path), workspace=\(workspaceURL.path) : utiliser Build5.13-test sur les deux Mac et refaire le transfert")
    }

    static func makeArchive(
        sourceDirectory: URL
    ) throws -> URL {

        var isDirectory: ObjCBool = false

        guard
            FileManager.default.fileExists(
                atPath: sourceDirectory.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw TransferError.invalidSource
        }


        let archive =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "QLab-Fallback-"
                    + UUID().uuidString
                    + ".zip"
                )


        try? FileManager.default.removeItem(
            at: archive
        )


        try run(
            executable: "/usr/bin/ditto",
            arguments: [
                "-c",
                "-k",
                "--sequesterRsrc",
                "--keepParent",
                sourceDirectory.path,
                archive.path
            ]
        )


        return archive
    }


    static func directorySize(
        of root: URL
    ) throws -> Int64 {

        guard let enumerator =
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ],
                options: [
                    .skipsHiddenFiles
                ]
            )
        else {
            throw TransferError.invalidSource
        }


        var total: Int64 = 0


        for case let url as URL in enumerator {

            let values =
                try? url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .fileSizeKey
                    ]
                )


            guard
                values?.isRegularFile == true
            else {
                continue
            }


            total +=
                Int64(
                    values?.fileSize
                    ?? 0
                )
        }


        return total
    }


    static func availableDiskSpace(
        at url: URL
    ) -> Int64 {

        do {

            let values =
                try url.resourceValues(
                    forKeys: [
                        .volumeAvailableCapacityForImportantUsageKey
                    ]
                )


            if let capacity =
                values
                    .volumeAvailableCapacityForImportantUsage {

                return capacity
            }

        } catch {
        }


        do {

            let attributes =
                try FileManager.default
                    .attributesOfFileSystem(
                        forPath:
                            url.path
                    )


            return (
                attributes[
                    .systemFreeSize
                ] as? NSNumber
            )?.int64Value
            ?? 0

        } catch {

            return 0
        }
    }


    static func sha256(
        of url: URL
    ) throws -> String {

        let data =
            try run(
                executable: "/usr/bin/shasum",
                arguments: [
                    "-a",
                    "256",
                    url.path
                ],
                captureOutput: true
            )


        guard
            let output =
                String(
                    data: data,
                    encoding: .utf8
                ),
            let first =
                output
                    .split(
                        whereSeparator:
                            { $0.isWhitespace }
                    )
                    .first
        else {
            throw TransferError.invalidArchive
        }


        return String(first)
    }


    static func extractArchive(
        _ archive: URL,
        projectName: String
    ) throws -> URL {

        guard
            FileManager.default.fileExists(
                atPath: archive.path
            )
        else {
            throw TransferError.invalidArchive
        }


        let root =
            FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Documents",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "QLab Fallback",
                    isDirectory: true
                )


        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )


        let safeName =
            sanitize(
                projectName
            )


        var destination =
            root.appendingPathComponent(
                safeName,
                isDirectory: true
            )


        if FileManager.default.fileExists(
            atPath: destination.path
        ) {

            let formatter =
                DateFormatter()

            formatter.dateFormat =
                "yyyy-MM-dd HH.mm.ss"

            destination =
                root.appendingPathComponent(
                    safeName
                    + " - "
                    + formatter.string(
                        from: Date()
                    ) + " - " + UUID().uuidString.prefix(8),
                    isDirectory: true
                )
        }


        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )


        try run(
            executable: "/usr/bin/ditto",
            arguments: [
                "-x",
                "-k",
                archive.path,
                destination.path
            ]
        )


        return destination
    }


    static func findWorkspace(
        in root: URL,
        preferredName: String?
    ) -> URL? {

        guard let enumerator =
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [
                    .skipsHiddenFiles
                ]
            )
        else {
            return nil
        }


        let preferred =
            preferredName?
                .replacingOccurrences(
                    of: ".qlab5",
                    with: ""
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()


        var firstWorkspace: URL?


        for case let url as URL in enumerator {

            guard
                url.pathExtension
                    .lowercased()
                    == "qlab5"
            else {
                continue
            }


            if firstWorkspace == nil {
                firstWorkspace = url
            }


            let baseName =
                url
                    .deletingPathExtension()
                    .lastPathComponent
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .lowercased()


            if let preferred,
               !preferred.isEmpty,
               baseName == preferred {

                return url
            }
        }


        return firstWorkspace
    }


    static func normalizedPath(
        from qlabValue: String
    ) -> String {

        let cleaned =
            qlabValue
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )


        if cleaned.hasPrefix("file://"),
           let url = URL(
                string: cleaned
           ) {

            return url
                .standardizedFileURL
                .path
        }


        return URL(
            fileURLWithPath: cleaned
        )
        .standardizedFileURL
        .path
    }


    private static func sanitize(
        _ raw: String
    ) -> String {

        let result =
            raw
                .replacingOccurrences(
                    of: "/",
                    with: "-"
                )
                .replacingOccurrences(
                    of: ":",
                    with: "-"
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )


        return result.isEmpty
            ? "QLab Project"
            : result
    }


    @discardableResult
    private static func run(
        executable: String,
        arguments: [String],
        captureOutput: Bool = false
    ) throws -> Data {

        let process =
            Process()


        process.executableURL =
            URL(
                fileURLWithPath:
                    executable
            )

        process.arguments =
            arguments


        let outputPipe =
            Pipe()

        let errorPipe =
            Pipe()


        if captureOutput {
            process.standardOutput =
                outputPipe
        }


        process.standardError =
            errorPipe


        try process.run()

        process.waitUntilExit()


        guard
            process.terminationStatus == 0
        else {

            let data =
                errorPipe
                    .fileHandleForReading
                    .readDataToEndOfFile()

            let message =
                String(
                    data: data,
                    encoding: .utf8
                )?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )


            throw TransferError.processFailed(
                message?.isEmpty == false
                    ? message!
                    : "Erreur pendant la préparation du fallback"
            )
        }


        if captureOutput {

            return outputPipe
                .fileHandleForReading
                .readDataToEndOfFile()
        }


        return Data()
    }
}
