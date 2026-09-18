import Foundation
import Network

// Dedicated file channel: bounded memory, no Base64/JSON, no main-thread I/O.
// Metadata/token travel on the existing control connection. Only the receiver
// acknowledges EOF after writing the exact announced size. SHA-256 and QLab
// application are still verified by the existing installation pipeline.
final class WorkspaceBinaryTransfer: @unchecked Sendable {
    struct Measurement: Sendable {
        let bytes: Int64
        let seconds: Double
        var bytesPerSecond: Double { Double(bytes) / max(seconds, 0.000001) }
    }
    private let queue = DispatchQueue(label: "qlab.workspace.binary", qos: .userInitiated)
    private let token: String
    private let size: Int64
    private let progress: @Sendable (Measurement) -> Void
    private let completion: @Sendable (Result<Measurement, Error>) -> Void
    private var listener: NWListener?
    private var peer: NWConnection?
    private var file: FileHandle?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var bytes: Int64 = 0
    private var queued: Int64 = 0
    private var pending = 0
    private var sentEOF = false
    private var began = ProcessInfo.processInfo.systemUptime
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var lastProgress = 0.0
    init(token: String, size: Int64,
         progress: @escaping @Sendable (Measurement) -> Void,
         completion: @escaping @Sendable (Result<Measurement, Error>) -> Void) {
        self.token = token; self.size = size; self.progress = progress; self.completion = completion
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    private func invalid(_ text: String) { finish(.failure(MirrorFailure.invalid(text))) }
    private func measurement() -> Measurement {
        .init(bytes: bytes, seconds: ProcessInfo.processInfo.systemUptime - began)
    }
    private func report(force: Bool = false) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        if force || lastActivity - lastProgress >= 0.1 {
            lastProgress = lastActivity; progress(measurement())
        }
    }
    private func finish(_ result: Result<Measurement, Error>) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil; peer?.cancel(); peer = nil
        try? file?.close(); file = nil
        completion(result)
    }
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastActivity > 30 {
                self.invalid("Transfert binaire interrompu : aucun progrès depuis 30 secondes")
            }
        }
        timer.resume()
    }
    func serve(file url: URL, parameters: NWParameters, ready: @escaping @Sendable (UInt16) -> Void) {
        queue.async { [self] in
            guard !self.finished else { return }
            do {
                guard self.size > 0, UUID(uuidString: self.token) != nil else {
                    self.invalid("Métadonnées binaires invalides"); return
                }
                self.file = try FileHandle(forReadingFrom: url)
                let listener = try NWListener(using: parameters, on: .any); self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, !self.finished else { return }
                    if case .ready = state, let port = listener?.port { ready(port.rawValue) }
                    if case .failed(let error) = state { self.finish(.failure(error)) }
                }
                listener.newConnectionHandler = { [weak self] peer in
                    guard let self, !self.finished, self.peer == nil else { peer.cancel(); return }
                    self.peer = peer; peer.start(queue: self.queue)
                    self.handshake(peer, received: Data())
                }
                listener.start(queue: self.queue); self.startTimer()
            } catch { self.finish(.failure(error)) }
        }
    }
    private func handshake(_ peer: NWConnection, received: Data) {
        let expected = Data((token + "\n").utf8)
        peer.receive(minimumIncompleteLength: 1, maximumLength: expected.count - received.count) { [weak self] part, _, ended, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            var data = received; data.append(part ?? Data())
            guard expected.starts(with: data) else { self.invalid("Jeton du transfert binaire incorrect"); return }
            if data == expected {
                self.listener?.cancel(); self.listener = nil
                self.began = ProcessInfo.processInfo.systemUptime; self.lastActivity = self.began
                self.pump(peer)
            } else if ended { self.invalid("Connexion binaire fermée avant authentification") }
            else { self.handshake(peer, received: data) }
        }
    }
    private func pump(_ peer: NWConnection) {
        guard !finished else { return }
        do {
            // Four in-flight 1 MiB blocks keep TCP fed without loading the archive.
            while pending < 4 && queued < size {
                let data = try file?.read(upToCount: Int(min(1024 * 1024, size - queued))) ?? Data()
                guard !data.isEmpty else { invalid("Archive PRIMARY tronquée pendant l’envoi"); return }
                queued += Int64(data.count); pending += 1
                peer.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished else { return }
                    if let error { self.finish(.failure(error)); return }
                    self.bytes += Int64(data.count); self.pending -= 1; self.report(); self.pump(peer)
                })
            }
            if queued == size && pending == 0 && !sentEOF {
                sentEOF = true
                peer.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished else { return }
                    if let error { self.finish(.failure(error)); return }
                    peer.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
                        guard let self, !self.finished else { return }
                        if let error { self.finish(.failure(error)); return }
                        guard data == Data([1]) else { self.invalid("Réception du fichier non confirmée"); return }
                        self.report(force: true); self.finish(.success(self.measurement()))
                    }
                })
            }
        } catch { finish(.failure(error)) }
    }
    func receive(file url: URL, host: NWEndpoint.Host, port: UInt16, parameters: NWParameters) {
        queue.async { [self] in
            guard !self.finished else { return }
            do {
                guard self.size > 0, UUID(uuidString: self.token) != nil,
                      let port = NWEndpoint.Port(rawValue: port) else {
                    self.invalid("Métadonnées binaires invalides"); return
                }
                self.file = try FileHandle(forWritingTo: url)
                try self.file?.truncate(atOffset: 0)
                let peer = NWConnection(host: host, port: port, using: parameters); self.peer = peer
                peer.stateUpdateHandler = { [weak self, weak peer] state in
                    guard let self, let peer, !self.finished else { return }
                    if case .ready = state {
                        self.began = ProcessInfo.processInfo.systemUptime; self.lastActivity = self.began
                        peer.send(content: Data((self.token + "\n").utf8), completion: .contentProcessed { [weak self] error in
                            if let error { self?.finish(.failure(error)) }
                        })
                        self.readNext(peer)
                    }
                    if case .failed(let error) = state { self.finish(.failure(error)) }
                }
                peer.start(queue: self.queue); self.startTimer()
            } catch { self.finish(.failure(error)) }
        }
    }
    private func readNext(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, ended, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            do {
                if let data, !data.isEmpty {
                    guard Int64(data.count) <= self.size - self.bytes else { self.invalid("Archive reçue plus grande qu’annoncé"); return }
                    try self.file?.write(contentsOf: data); self.bytes += Int64(data.count); self.report()
                }
                if ended {
                    guard self.bytes == self.size else { self.invalid("Archive binaire incomplète"); return }
                    try self.file?.synchronize(); try self.file?.close(); self.file = nil
                    self.report(force: true)
                    peer.send(content: Data([1]), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.finished else { return }
                        if let error { self.finish(.failure(error)) }
                        else { self.finish(.success(self.measurement())) }
                    })
                } else { self.readNext(peer) }
            } catch { self.finish(.failure(error)) }
        }
    }
}
