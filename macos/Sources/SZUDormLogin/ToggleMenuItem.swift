import AppKit

@MainActor
final class ToggleMenuItem: NSMenuItem {
    init(title: String, action: Selector) {
        super.init(title: title, action: action, keyEquivalent: "")
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isOn: Bool, stateText: String? = nil) {
        state = stateText == nil ? (isOn ? .on : .off) : .mixed
        toolTip = stateText
    }
}
