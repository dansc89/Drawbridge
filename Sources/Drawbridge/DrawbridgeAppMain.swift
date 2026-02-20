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
        app.run()
    }
}
