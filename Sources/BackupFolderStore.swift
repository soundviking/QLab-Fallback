import AppKit
import Combine

@MainActor
final class BackupFolderStore: ObservableObject {
    @Published private(set) var url: URL
    @Published private(set) var configured = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var accesses: [URL] = []
    private let key = "QLabFallback.BackupFolderBookmark.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/QLab Fallback", isDirectory: true)
        guard let data = defaults.data(forKey: key) else { return }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            if resolved.startAccessingSecurityScopedResource() { accesses.append(resolved) }
            url = resolved
            try Self.checkWritable(resolved)
            if stale { defaults.set(try resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key) }
            configured = true
        } catch { self.error = error.localizedDescription }
    }

    static func checkWritable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileWriteInvalidFileName) }
        let probe = url.appendingPathComponent(".qlab-write-check-" + UUID().uuidString)
        try Data([0]).write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
    }

    @discardableResult
    func select(_ candidate: URL, locked: Bool) -> Bool {
        guard !locked else { return false }
        let access = candidate.startAccessingSecurityScopedResource()
        do {
            try Self.checkWritable(candidate)
            let bookmark = try candidate.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: key)
            if access { accesses.append(candidate) }
            url = candidate; configured = true; error = nil
            return true
        } catch {
            if access { candidate.stopAccessingSecurityScopedResource() }
            self.error = error.localizedDescription
            return false
        }
    }

    func choose(locked: Bool) -> Bool {
        guard !locked else { return false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = url
        panel.message = "Choisissez le dossier de réception BACKUP."
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        return select(selected, locked: locked)
    }

    func validate() -> Bool {
        do { try Self.checkWritable(url); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }

    deinit { accesses.forEach { $0.stopAccessingSecurityScopedResource() } }
}
