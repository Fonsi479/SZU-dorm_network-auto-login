import AppKit

public enum SZUDormApplication {
    @MainActor
    public static func run() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, command.hasPrefix("--") {
            if command == "--ui-smoke-test" {
                UISmokeTestRunner.run()
            }
            CommandLineRunner.run(command)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
