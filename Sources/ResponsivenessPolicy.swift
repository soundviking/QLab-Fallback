import Foundation
import Network

// Multiple missed probes are required; never infer a failure from one lost packet.
enum ResponsivenessPolicy {
    static let qlabProbe: UInt64 = 200_000_000
    static let qlabTimeout: TimeInterval = 0.9
    static let heartbeat: UInt64 = 200_000_000
    static let monitor: UInt64 = 100_000_000
    static let peerTimeout: TimeInterval = 0.9
    static let selectionCoalescing: UInt64 = 20_000_000

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }
}
