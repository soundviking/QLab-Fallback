import Foundation

@main struct BackupFolderTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "QLabFolderTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackupFolderStore(defaults: defaults)
        precondition(!store.configured)
        precondition(!store.select(root, locked: true))
        precondition(store.select(root, locked: false))
        precondition(store.configured && store.validate())
        let reopened = BackupFolderStore(defaults: defaults)
        precondition(reopened.configured && reopened.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        precondition(!store.select(file, locked: false))
        precondition(store.url == root)
        precondition(!store.select(root.appendingPathComponent("missing"), locked: false))
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(children == ["file"])
        print("PASS: folder persistence, lock, write probe, invalid targets and cleanup")
    }
}
