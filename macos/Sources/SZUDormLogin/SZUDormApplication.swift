import AppKit

public enum SZUDormApplication {
    @MainActor
    public static func run() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let openSettingsOnLaunch = arguments.first == "--open-settings"
        if let command = arguments.first, command.hasPrefix("--") {
            if command == "--ui-smoke-test" {
                UISmokeTestRunner.run()
            }
            if !openSettingsOnLaunch {
                CommandLineRunner.run(command)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate(openSettingsOnLaunch: openSettingsOnLaunch)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
