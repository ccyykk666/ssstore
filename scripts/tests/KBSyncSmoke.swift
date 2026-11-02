import AppKit
import Foundation

@MainActor
final class KBSyncSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Starting local WebKit check"); fflush(stdout)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Task { @MainActor in
            do {
                let blob = try await KBSyncGenerator.generate(guid: "001122334455", dsid: "123456789",
                    runtimeRoot: root, onEvent: { print($0); fflush(stdout) })
                guard let data = Data(base64Encoded: blob), !data.isEmpty else { fatalError("Empty kbsync") }
                print("Local WebKit kbsync generation succeeded (synthetic identity)")
                exit(0)
            } catch {
                fputs("Local WebKit kbsync check failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

@main
struct KBSyncSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = KBSyncSmokeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
