import AppKit
import Combine

/// Read-only discovery has an application lifetime, independent of show control.
@MainActor
final class QLabDiscoveryService: ObservableObject {
    @Published private(set) var workspaces: [String] = []
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var refreshing = false
    private var generation = 0
    private let isRunning: () -> Bool
    private let readNames: () async throws -> [String]

    init(isRunning: @escaping () -> Bool = {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.figure53.QLab") == true }
    }, readNames: @escaping () async throws -> [String] = {
        let result = try await MirrorQLab.run("""
        if application "QLab" is not running then return ""
        tell application "QLab"
            with timeout of 2 seconds
                set names to name of every workspace
                set AppleScript's text item delimiters to ASCII character 31
                return names as text
            end timeout
        end tell
        """, [])
        return result.components(separatedBy: String(UnicodeScalar(31))).filter { !$0.isEmpty }
    }) {
        self.isRunning = isRunning
        self.readNames = readNames
    }

    func start() {
        guard task == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            })
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func refresh() async {
        guard !refreshing else { return }
        guard isRunning() else { publish([], error: nil); return }
        refreshing = true
        defer { refreshing = false }
        let token = generation
        do {
            let names = try await readNames()
            guard generation == token, !Task.isCancelled else { return }
            publish(isRunning() ? names : [], error: nil)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            publish([], error: error.localizedDescription)
        }
    }

    private func publish(_ names: [String], error newError: String?) {
        if workspaces != names { workspaces = names }
        if error != newError { error = newError }
    }

    deinit {
        task?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
