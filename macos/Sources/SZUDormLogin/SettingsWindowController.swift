import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let model else { return }
        let hostingController = NSHostingController(
            rootView: SettingsView(
                configuration: model.configuration,
                providerConfiguration: model.campusProviderConfiguration,
                passwordSaved: model.passwordSaved,
                configurationPath: model.coordinator.configurationStore.paths.configurationFile.path,
                onSave: {
                    [weak self, weak model]
                    configuration,
                    providerConfiguration,
                    dormPassword,
                    teachingPassword in
                    guard let model else { return }
                    try model.saveConfiguration(configuration, password: nil)
                    try model.saveCampusProviderConfiguration(providerConfiguration)
                    if let dormPassword {
                        try model.saveProviderPassword(
                            dormPassword,
                            providerID: .dorm,
                            providerConfiguration: providerConfiguration
                        )
                    }
                    if let teachingPassword {
                        try model.saveProviderPassword(
                            teachingPassword,
                            providerID: .teaching,
                            providerConfiguration: providerConfiguration
                        )
                    }
                    self?.close()
                },
                onCancel: { [weak self] in self?.close() }
            )
        )
        let window = existingOrNewWindow()
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "SZU Dorm Login 设置"
        created.minSize = NSSize(width: 580, height: 600)
        created.isReleasedWhenClosed = false
        let frameName = "SZUDormLoginSettingsWindow"
        if !created.setFrameUsingName(frameName) {
            created.center()
        }
        created.setFrameAutosaveName(frameName)
        created.delegate = self
        window = created
        return created
    }
}
