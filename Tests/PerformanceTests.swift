import Foundation
import Combine

@main struct PerformanceTests {
    @MainActor static func main() async {
        var publications = 0
        let manager = NetworkDiscovery()
        manager.testVersion("5.5")
        let subscription = manager.objectWillChange.sink { publications += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { manager.testVersion("5.5") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("MEASURE: identical version probes=1000 publications=\(publications) seconds=\(elapsed)")
        if !CommandLine.arguments.contains("--baseline") { precondition(publications == 0) }
        withExtendedLifetime(subscription) {}
        manager.stop()
        weak var released: NetworkDiscovery?
        do {
            let transient = NetworkDiscovery()
            released = transient
            transient.testHeartbeatMonitor()
            transient.stop()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        precondition(released == nil, "Stopped manager and tasks must release")
        print("PASS: stopped manager/task lifetime")
    }
}
