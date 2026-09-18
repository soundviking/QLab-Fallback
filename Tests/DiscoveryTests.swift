import Foundation

@main struct DiscoveryTests {
    @MainActor static func main() async throws {
        var running = false
        var names: [String] = []
        var reads = 0
        let service = QLabDiscoveryService(isRunning: { running }, readNames: { reads += 1; return names })
        await service.refresh()
        precondition(service.workspaces.isEmpty && reads == 0)
        running = true
        await service.refresh()
        precondition(service.workspaces.isEmpty && reads == 1)
        names = ["Selected", "Other"]
        await service.refresh()
        precondition(service.workspaces == names)
        running = false
        await service.refresh()
        precondition(service.workspaces.isEmpty && reads == 2)
        running = true; names = ["Reopened"]
        await service.refresh()
        precondition(service.workspaces == names)
        service.start(); service.start(); service.stop()
        weak var released: QLabDiscoveryService?
        do {
            let transient = QLabDiscoveryService(isRunning: { false }, readNames: { [] })
            released = transient; transient.start()
        }
        precondition(released == nil, "Discovery task must not retain the service while sleeping")
        print("PASS: launch orders, late workspace, quit/relaunch, idle discovery and service lifetime")
    }
}
