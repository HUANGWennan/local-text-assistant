import AppKit
import ApplicationServices

struct TextSelection {
    let pid: pid_t
    let element: AXUIElement
    let text: String

    static func read() -> TextSelection? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        guard let value = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focus = value as! AXUIElement
        guard !isSecure(focus) else { return nil }
        if let text = selectedText(focus) {
            return TextSelection(pid: app.processIdentifier, element: focus, text: text)
        }
        let role = attribute(focus, kAXRoleAttribute) as? String
        guard ["AXWebArea", "AXGroup", "AXTextArea", "AXScrollArea"].contains(role ?? "") else { return nil }
        var pending = (attribute(focus, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed().map { $0 }
        var match: TextSelection?
        for _ in 0..<160 {
            guard let element = pending.popLast() else { break }
            if isSecure(element) { continue }
            if let text = selectedText(element) {
                if match != nil { return nil }
                match = TextSelection(pid: app.processIdentifier, element: element, text: text)
                continue
            }
            pending.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed())
        }
        return match
    }

    func matches(_ other: TextSelection) -> Bool {
        pid == other.pid && text == other.text && CFEqual(element, other.element)
    }

    func replace(with result: String) -> Bool {
        guard !Self.isSecure(element), Self.selectedText(element) == text,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let root = AXUIElementCreateApplication(pid)
        guard let originalWindow = Self.attribute(element, kAXWindowAttribute),
              let currentWindow = Self.attribute(root, kAXFocusedWindowAttribute),
              CFEqual(originalWindow, currentWindow) else { return false }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, result as CFString) == .success else {
            return false
        }
        app.activate(options: [])
        return true
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField"
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        guard let text = attribute(element, kAXSelectedTextAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 24000 else { return nil }
        return text
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

private final class SelectionToolbarButton: NSButton {
    private let usesAccent: Bool
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    init(title: String, symbol: String, usesAccent: Bool = false, target: AnyObject, action: Selector) {
        self.usesAccent = usesAccent
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .center
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        image?.isTemplate = true
        imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        imageHugsTitle = true
        contentTintColor = usesAccent ? .controlAccentColor : .labelColor
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    func clearHover() {
        isHovered = false
        needsDisplay = true
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || isHovered || usesAccent {
            let color: NSColor = usesAccent ? .controlAccentColor : .labelColor
            let opacity = isHighlighted ? 0.22 : isHovered ? 0.13 : 0.09
            color.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class SelectionToolbarSurface: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

final class FloatingSelectionPanel: NSObject {
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 494, height: 48),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var timer: Timer?
    private var candidate: TextSelection?
    private var dismissed: TextSelection?
    private var changedAt = Date()
    private var speechButton: NSButton?
    var onAction: ((String, TextSelection) -> Void)?
    var isSuppressed: (() -> Bool)?

    override init() {
        super.init()
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let surface = SelectionToolbarSurface(frame: NSRect(origin: .zero, size: window.frame.size))
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 13
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.updateBorder()
        window.contentView = surface

        let options = [
            ("英文润色", "english", "pencil.line", 91.0),
            ("译为中文", "chinese", "character.bubble", 91.0),
            ("智能清理", "clean", "sparkles", 91.0),
            ("加入 To Do", "todo", "checkmark.circle", 93.0),
            ("朗读", "speak", "speaker.wave.2", 85.0)
        ]
        var x: CGFloat = 6
        for (title, identifier, symbol, width) in options {
            if identifier == "todo" {
                let separator = NSBox(frame: NSRect(x: x - 2, y: 14, width: 1, height: 20))
                separator.boxType = .separator
                surface.addSubview(separator)
                x += 3
            }
            let button = SelectionToolbarButton(title: title, symbol: symbol, usesAccent: identifier == "chinese",
                                                target: self, action: #selector(selectAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.frame = NSRect(x: x, y: 7, width: width - 4, height: 34)
            surface.addSubview(button)
            if identifier == "speak" { speechButton = button }
            x += width
        }
        let close = SelectionToolbarButton(title: "", symbol: "xmark", target: self, action: #selector(dismiss))
        close.frame = NSRect(x: x, y: 9, width: 28, height: 30)
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "关闭浮窗"
        close.setAccessibilityLabel("关闭浮窗")
        surface.addSubview(close)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit { timer?.invalidate() }

    @objc func dismiss() {
        dismissed = candidate
        window.orderOut(nil)
    }

    func resume() { dismissed = nil; candidate = nil }

    private func poll() {
        guard isSuppressed?() != true else { window.orderOut(nil); return }
        guard let selection = TextSelection.read() else {
            window.orderOut(nil)
            candidate = nil
            dismissed = nil
            return
        }
        guard candidate?.matches(selection) == true else {
            candidate = selection
            changedAt = Date()
            window.orderOut(nil)
            if dismissed?.matches(selection) != true { dismissed = nil }
            return
        }
        guard !window.isVisible, dismissed?.matches(selection) != true,
              Date().timeIntervalSince(changedAt) >= 0.35 else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = max(visible.minX, min(point.x, visible.maxX - window.frame.width))
        let y = max(visible.minY, min(point.y - window.frame.height - 10, visible.maxY - window.frame.height))
        for case let button as SelectionToolbarButton in window.contentView?.subviews ?? [] {
            button.clearHover()
        }
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
    }

    @objc private func selectAction(_ sender: NSButton) {
        guard let mode = sender.identifier?.rawValue, let selection = candidate,
              TextSelection.read()?.matches(selection) == true else { dismiss(); return }
        if mode != "speak" { dismiss() }
        onAction?(mode, selection)
    }

    func updateSpeechButton(isSpeaking: Bool) {
        speechButton?.title = isSpeaking ? "停止朗读" : "朗读"
        speechButton?.image = NSImage(systemSymbolName: isSpeaking ? "stop.fill" : "speaker.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        speechButton?.image?.isTemplate = true
    }

}
