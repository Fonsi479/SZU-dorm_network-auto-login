import AppKit

@MainActor
private final class PillSwitchControl: NSControl {
    var isOn = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isOn ? "开启" : "关闭")
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 22) }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = bounds.insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: trackRect.height / 2, yRadius: trackRect.height / 2)
        let trackColor = isOn
            ? NSColor.systemGreen
            : NSColor(calibratedWhite: 0.64, alpha: 0.34)
        trackColor.withAlphaComponent(isEnabled ? trackColor.alphaComponent : 0.18).setFill()
        track.fill()

        NSColor.white.withAlphaComponent(isOn ? 0.32 : 0.26).setStroke()
        track.lineWidth = 1
        track.stroke()

        let knobSize: CGFloat = 18
        let knobX = isOn ? bounds.maxX - knobSize - 2 : bounds.minX + 2
        let knobRect = NSRect(x: knobX, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
        let knob = NSBezierPath(ovalIn: knobRect)
        NSColor.white.withAlphaComponent(isEnabled ? 0.98 : 0.62).setFill()
        knob.fill()

        NSColor.black.withAlphaComponent(0.18).setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        sendAction(action, to: target)
        return true
    }
}

@MainActor
final class ToggleMenuItem: NSMenuItem {
    private let titleButton = NSButton()
    private let stateLabel = NSTextField(labelWithString: "")
    private let toggle = PillSwitchControl()

    init(title: String, action: Selector) {
        super.init(title: title, action: action, keyEquivalent: "")
        buildView(title: title)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isOn: Bool, stateText: String? = nil) {
        toggle.isOn = isOn
        stateLabel.stringValue = stateText ?? ""
        stateLabel.isHidden = stateText == nil
        stateLabel.textColor = stateText == nil ? .secondaryLabelColor : .systemOrange
        toggle.toolTip = stateText
    }

    override var isEnabled: Bool {
        didSet {
            titleButton.isEnabled = isEnabled
            toggle.isEnabled = isEnabled
            stateLabel.alphaValue = isEnabled ? 1 : 0.5
        }
    }

    private func buildView(title: String) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 30))

        titleButton.title = title
        titleButton.font = .menuFont(ofSize: 0)
        titleButton.alignment = .left
        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.imagePosition = .noImage
        titleButton.target = self
        titleButton.action = #selector(performItemAction)
        titleButton.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.alignment = .right
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.isHidden = true
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        toggle.target = self
        toggle.action = #selector(performItemAction)
        toggle.setAccessibilityRole(.checkBox)
        toggle.setAccessibilityLabel(title)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleButton)
        container.addSubview(stateLabel)
        container.addSubview(toggle)
        NSLayoutConstraint.activate([
            titleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 15),
            titleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: stateLabel.leadingAnchor, constant: -8),

            stateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            stateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 72),

            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        view = container
    }

    @objc private func performItemAction() {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
