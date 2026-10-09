import AppKit

@main
struct Drawbridge {
    static func main() {
        if CommandLine.arguments.contains("--stress") {
            let exitCode = StressHarness.run(arguments: CommandLine.arguments)
            exit(Int32(exitCode))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        // NSApplication keeps a weak delegate. Keep the controller/window owner
        // alive throughout the event loop, including optimized release builds.
        withExtendedLifetime(delegate) { app.run() }
    }
}
