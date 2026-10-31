import AppKit

@main
enum BurstApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            return
        }
        // `open -n Burst.app --args --status <file>`: what macOS has granted this
        // app, as the app itself (a shell-launched binary inherits the shell's rights).
        if let i = args.firstIndex(of: "--status"), i + 1 < args.count {
            let report = "accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording)\n"
            try? report.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            return
        }
        if args.contains("--selftest") {
            _ = NSApplication.shared
            Task { exit(await SelfTest.run()) }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}
