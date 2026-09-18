import Foundation
import Network
import CryptoKit

@MainActor final class BinaryResults {
    var sent: Result<WorkspaceBinaryTransfer.Measurement, Error>?
    var received: Result<WorkspaceBinaryTransfer.Measurement, Error>?
    var completions = 0
    var progress = 0
}
@main struct BinaryTransferTests {
    static var checks = 0
    static func expect(_ value: Bool, _ text: String) {
        precondition(value, text); checks += 1; print("PASS: " + text)
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        expect(condition(), "Transfer terminates within deadline")
    }
    static func hash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var digest = SHA256()
        while let block = try h.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @MainActor static func run(source: URL, destination: URL, size: Int64,
        receiverSize: Int64? = nil, wrongToken: Bool = false, cancel: Bool = false) async -> BinaryResults {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let results = BinaryResults(), token = UUID().uuidString
        let receiver = WorkspaceBinaryTransfer(token: wrongToken ? UUID().uuidString : token, size: receiverSize ?? size,
            progress: { _ in Task { @MainActor in results.progress += 1 } },
            completion: { r in Task { @MainActor in results.received = r; results.completions += 1 } })
        let sender = WorkspaceBinaryTransfer(token: token, size: size, progress: { _ in },
            completion: { r in Task { @MainActor in results.sent = r; results.completions += 1 } })
        sender.serve(file: source, parameters: ResponsivenessPolicy.tcpParameters()) { port in
            receiver.receive(file: destination, host: "127.0.0.1", port: port, parameters: ResponsivenessPolicy.tcpParameters())

        }
        if cancel {
            await wait { results.progress > 0 }
            receiver.cancel(); sender.cancel() // same cancellation on the control channel
        }
        await wait { results.received != nil && results.sent != nil }
        sender.cancel(); receiver.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        expect(results.completions == 2, "Exactly one completion per endpoint, including cancellation")
        return results
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("binary-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        // Nonzero varying data; a non-block-aligned tail exercises partial blocks.
        let block = Data((0..<(1024*1024)).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) })
        for _ in 0..<128 { try file.write(contentsOf: block) }
        try file.write(contentsOf: Data([19, 37, 251])); try file.close()
        let size = Int64(128 * 1024 * 1024 + 3)
        for iteration in 1...2 {
            let result = await run(source: source, destination: target, size: size)
            guard case .success(let measure) = result.received, case .success = result.sent else { fatalError("File transfer failed") }
            expect(measure.bytes == size, "Exact size including non-aligned tail")
            expect(try hash(source) == hash(target), "Full file SHA-256 identical after real disk/network/disk transfer")
            expect(result.progress > 0, "Progress is delivered")
            print("MEASURE disk-to-disk loopback run \(iteration): \(measure.bytesPerSecond / 1_000_000) Mo/s (not a two-Mac Ethernet measurement)")
        }
        let wrong = await run(source: source, destination: target, size: size, wrongToken: true)
        if case .failure = wrong.sent { expect(true, "Wrong token refused") } else { fatalError("Token accepted") }
        expect((try Data(contentsOf: target)).isEmpty, "Unauthorized receiver gets no file data")
        let short = await run(source: source, destination: target, size: size, receiverSize: size + 1)
        if case .failure = short.received { expect(true, "Premature EOF refused") } else { fatalError("Short file accepted") }
        let extra = await run(source: source, destination: target, size: size, receiverSize: size - 1)
        if case .failure = extra.received { expect(true, "Excess data refused") } else { fatalError("Oversize file accepted") }
        let cancelled = await run(source: source, destination: target, size: size, cancel: true)
        if case .failure = cancelled.received { expect(true, "Cancelled transfer cannot succeed") } else { fatalError("Cancel accepted") }
        let missing = await run(source: source, destination: target, size: size + 1)
        if case .failure = missing.sent { expect(true, "Truncated source refused") } else { fatalError("Truncated source accepted") }
        print("\(checks) binary file-transfer checks passed")
    }
}
