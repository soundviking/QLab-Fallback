import Foundation
import Network

// A bounded RAM-to-RAM transfer on a separate authenticated TCP connection.
// No workspace, media, disk writes or QLab commands are involved.
final class NetworkSpeedProbe: @unchecked Sendable {
    static let byteCount = 32 * 1024 * 1024
    struct Measurement: Sendable {
        let bytes: Int
        let seconds: Double
        let route: String
        var megabytesPerSecond: Double { Double(bytes) / seconds / 1_000_000 }
    }
    private let queue = DispatchQueue(label: "qlab.network.speed", qos: .utility)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var finished = false
    private var count = 0
    private var began: Double?
    private let token: String
    private let completion: @Sendable (Result<Measurement, Error>) -> Void
    init(token: String, completion: @escaping @Sendable (Result<Measurement, Error>) -> Void) {
        self.token = token; self.completion = completion
    }
    func cancel() { queue.async { self.finish(.failure(MirrorFailure.invalid("Test de débit annulé"))) } }
    private func finish(_ result: Result<Measurement, Error>) {
        guard !finished else { return }; finished = true
        listener?.cancel(); connection?.cancel(); listener = nil; connection = nil
        completion(result)
    }
    private func deadline() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.finish(.failure(MirrorFailure.invalid("Test de débit interrompu : délai de 30 secondes dépassé")))
        }
    }
    func serve(parameters: NWParameters, ready: @escaping @Sendable (UInt16) -> Void) {
        queue.async {
            do {
                let listener = try NWListener(using: parameters, on: .any); self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, !self.finished else { return }
                    if case .ready = state, let port = listener?.port { ready(port.rawValue) }
                    if case .failed(let error) = state { self.finish(.failure(error)) }
                }
                listener.newConnectionHandler = { [weak self] peer in
                    guard let self, !self.finished, self.connection == nil else { peer.cancel(); return }
                    self.connection = peer; peer.start(queue: self.queue)
                    self.handshake(peer, data: Data())
                }
                listener.start(queue: self.queue); self.deadline()
            } catch { self.finish(.failure(error)) }
        }
    }
    private func handshake(_ peer: NWConnection, data: Data) {
        let expected = Data((token + "\n").utf8)
        peer.receive(minimumIncompleteLength: 1, maximumLength: expected.count - data.count) { [weak self, weak peer] part, _, ended, error in
            guard let self, let peer, !self.finished else { return }
            var received = data; received.append(part ?? Data())
            if let error { self.finish(.failure(error)); return }
            guard expected.starts(with: received) else { self.finish(.failure(MirrorFailure.invalid("Jeton du test de débit incorrect"))); return }
            if received.count == expected.count {
                self.listener?.cancel(); self.listener = nil
                self.began = ProcessInfo.processInfo.systemUptime
                self.sendNext(peer)
            } else if ended { self.finish(.failure(MirrorFailure.invalid("Connexion de test fermée"))) }
            else { self.handshake(peer, data: received) }
        }
    }
    private let block = Data(repeating: 0xA7, count: 256 * 1024)
    private func sendNext(_ peer: NWConnection) {
        guard !finished else { return }
        if count == Self.byteCount {
            // Do not close early: the receiver owns the final throughput result.
            peer.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            return
        }
        peer.send(content: block, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            self.count += self.block.count; self.sendNext(peer)
        })
    }
    func receive(host: NWEndpoint.Host, port: UInt16, parameters: NWParameters) {
        queue.async {
            let peer = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: parameters)
            self.connection = peer
            peer.stateUpdateHandler = { [weak self, weak peer] state in
                guard let self, let peer, !self.finished else { return }
                if case .ready = state {
                    self.began = ProcessInfo.processInfo.systemUptime
                    peer.send(content: Data((self.token + "\n").utf8), completion: .contentProcessed { error in
                        if let error { self.finish(.failure(error)) }
                    })
                    self.readNext(peer)
                }
                if case .failed(let error) = state { self.finish(.failure(error)) }
            }
            peer.start(queue: self.queue); self.deadline()
        }
    }
    private func readNext(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self, weak peer] data, _, ended, error in
            guard let self, let peer, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            self.count += data?.count ?? 0
            if self.count == Self.byteCount, let began = self.began {
                let seconds = max(0.000001, ProcessInfo.processInfo.systemUptime - began)
                let path = peer.currentPath
                let kind = path?.usesInterfaceType(.wiredEthernet) == true ? "Ethernet" : path?.usesInterfaceType(.wifi) == true ? "Wi-Fi" : "Autre interface"
                let names = path?.availableInterfaces.filter { path?.usesInterfaceType($0.type) == true }.map(\.name).joined(separator: ", ") ?? ""
                self.finish(.success(.init(bytes: self.count, seconds: seconds, route: kind + (names.isEmpty ? "" : " (" + names + ")"))))
            } else if self.count > Self.byteCount || ended {
                self.finish(.failure(MirrorFailure.invalid("Test de débit incomplet")))
            } else { self.readNext(peer) }
        }
    }
}
