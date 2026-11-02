import AppKit
import Foundation

/// Real local WebKit generation with invented DSID/GUID; no account or network.
@main
struct KBSyncSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Task { @MainActor in
            do {
                let blob = try await KBSyncGenerator.generate(guid: "001122334455", dsid: "123456789", runtimeRoot: root)
                guard let data = Data(base64Encoded: blob), !data.isEmpty else { fatalError("Empty kbsync") }
                print("Local WebKit kbsync generation succeeded (synthetic identity)")
                exit(0)
            } catch {
                fputs("Local WebKit kbsync check failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
