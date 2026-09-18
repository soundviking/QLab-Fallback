import Foundation
@main struct WorkspaceSignatureTests {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() { print(try MirrorWorkspaceSignature.capture(path)) }
    }
}
