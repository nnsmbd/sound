import AppKit

final class MixerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}
func symbolButton(_ symbol: String, label: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target, action: action)
    button.bezelStyle = .accessoryBarAction; button.isBordered = false
    button.toolTip = label; button.setAccessibilityLabel(label)
    return button
}
final class AppVolumeRow: NSView {
    override var isFlipped: Bool { true }
    let key: String
    private let icon = NSImageView()
    private let name: NSTextField
    private let percent = text("100%", size: 13, color: .secondaryLabelColor)
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var mute: NSButton!
    var onVolume: ((Int) -> Void)?
    var onMute: (() -> Void)?
    init(_ state: MixerRowState) {
        key = state.source.key; name = text(state.source.name, size: 12, weight: .medium)
        super.init(frame: .zero)
        icon.image = state.source.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); percent.alignment = .right
        slider.target = self; slider.action = #selector(slid); slider.isContinuous = true
        slider.controlSize = .regular
        slider.setAccessibilityLabel("Громкость \(state.source.name)")
        mute = symbolButton("speaker.wave.2", label: "Отключить звук \(state.source.name)", target: self, action: #selector(mutePressed))
        [icon, name, percent, slider, mute].forEach(addSubview)
        update(state)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 10, width: 22, height: 22)
        name.frame = NSRect(x: 30, y: 4, width: bounds.width - 79, height: 22)
        percent.frame = NSRect(x: bounds.width - 45, y: 5, width: 45, height: 20)
        slider.frame = NSRect(x: 28, y: 25, width: bounds.width - 61, height: 24)
        mute.frame = NSRect(x: bounds.width - 30, y: 22, width: 30, height: 30)
    }
    func update(_ state: MixerRowState) {
        // Never overwrite the thumb with a delayed snapshot during a continuous drag.
        if NSApp.currentEvent?.type != .leftMouseDragged { slider.doubleValue = Double(state.volume) }
        percent.stringValue = state.muted ? "Выкл." : "\(state.volume)%"
        slider.alphaValue = state.muted ? 0.45 : 1
        mute.image = NSImage(systemSymbolName: state.muted ? "speaker.slash.fill" : "speaker.wave.2", accessibilityDescription: nil)
        mute.contentTintColor = state.muted ? .controlAccentColor : .secondaryLabelColor
        mute.setAccessibilityLabel("\(state.muted ? "Включить" : "Отключить") звук \(state.source.name)")
        slider.setAccessibilityValueDescription("\(state.volume) процентов\(state.muted ? ", звук отключён" : "")")
    }
    @objc private func slid() { let v = Int(slider.doubleValue.rounded()); percent.stringValue = "\(v)%"; onVolume?(v) }
    @objc private func mutePressed() { onMute?() }
}

final class MixerPanelController: NSObject {
    let panel: MixerPanel
    private let content = FlippedView()
    private let titleLabel = text("Громкость", size: 14, weight: .semibold)
    private let outputLabel = text("", size: 11, color: .secondaryLabelColor)
    private let outputIcon = NSImageView(image: NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: nil)!)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let rowContainer = FlippedView()
    private var rows: [String: AppVolumeRow] = [:]
    private var gear: NSButton!
    private var divider = NSBox()
    private var lastKeys: [String] = []
    var onVolume: ((String, Int) -> Void)?
    var onMute: ((String) -> Void)?
    var onReset: (() -> Void)?
    var anchor: (() -> NSPoint?)?
    let preview: Bool
    init(preview: Bool) {
        self.preview = preview
        panel = MixerPanel(contentRect: NSRect(x: 0, y: 0, width: 224, height: 230), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Громкость"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 16; glass.contentView = content
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView(); material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
            material.wantsLayer = true; material.layer?.cornerRadius = 16; material.layer?.masksToBounds = true
            material.addSubview(content); content.autoresizingMask = [.width, .height]; panel.contentView = material
        }
        gear = symbolButton("gearshape", label: "Настройки", target: self, action: #selector(settings))
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = rowContainer
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        divider.boxType = .separator
        [titleLabel, gear, scroll, message, divider, outputIcon, outputLabel].forEach(content.addSubview)
        outputLabel.setAccessibilityLabel("Устройство вывода")
        if preview { titleLabel.stringValue = "Громкость · макет" }
    }
    func render(_ snapshot: MixerSnapshot) {
        let keys = snapshot.rows.map { $0.source.key }
        for key in lastKeys where !keys.contains(key) { rows.removeValue(forKey: key)?.removeFromSuperview() }
        for (index, state) in snapshot.rows.enumerated() {
            let row: AppVolumeRow
            if let existing = rows[state.source.key] { row = existing } else {
                row = AppVolumeRow(state); rows[state.source.key] = row; rowContainer.addSubview(row)
                row.onVolume = { [weak self] value in self?.onVolume?(state.source.key, value) }
                row.onMute = { [weak self] in self?.onMute?(state.source.key) }
            }
            row.update(state); row.frame = NSRect(x: 0, y: index * 50, width: 200, height: 50)
        }
        lastKeys = keys
        let empty = snapshot.rows.isEmpty
        let listHeight = min(300, snapshot.rows.count * 50)
        let messageText = snapshot.error ?? (empty ? "Включите звук в любом приложении.\nОно появится здесь автоматически." : "")
        message.stringValue = messageText
        message.textColor = snapshot.error == nil ? .secondaryLabelColor : .systemOrange
        let messageHeight = messageText.isEmpty ? 0 : (empty ? 80 : 64)
        let height = CGFloat(44 + listHeight + messageHeight + 38)
        let oldTop = panel.frame.maxY
        panel.setContentSize(NSSize(width: 224, height: height))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - height))
        content.frame = NSRect(x: 0, y: 0, width: 224, height: height)
        titleLabel.frame = NSRect(x: 12, y: 12, width: 166, height: 25)
        gear.frame = NSRect(x: 188, y: 9, width: 28, height: 28)
        scroll.frame = NSRect(x: 12, y: 40, width: 202, height: listHeight)
        rowContainer.frame = NSRect(x: 0, y: 0, width: 200, height: snapshot.rows.count * 50)
        message.frame = NSRect(x: 12, y: 44 + listHeight, width: 200, height: messageHeight)
        divider.frame = NSRect(x: 12, y: height - 37, width: 200, height: 1)
        outputIcon.frame = NSRect(x: 12, y: height - 27, width: 18, height: 18)
        outputLabel.frame = NSRect(x: 36, y: height - 27, width: 170, height: 20)
        outputLabel.stringValue = snapshot.output
        outputLabel.toolTip = snapshot.output
        if panel.isVisible { position() }
    }
    func position() {
        guard let p = anchor?() else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(p.x - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: p.y - panel.frame.height - 7))
    }
    func toggle() { if panel.isVisible { panel.orderOut(nil) } else { position(); panel.makeKeyAndOrderFront(nil) } }
    @objc private func settings() {
        let menu = NSMenu()
        let reset = menu.addItem(withTitle: "Вернуть исходную громкость", action: #selector(resetAll), keyEquivalent: ""); reset.target = self
        let permission = menu.addItem(withTitle: "Доступ к системному аудио…", action: #selector(permissions), keyEquivalent: ""); permission.target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "О программе…", action: #selector(aboutApp), keyEquivalent: ""); about.target = self
        menu.addItem(withTitle: "Завершить VolumeMixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: gear.bounds.maxY + 5), in: gear)
    }
    @objc private func resetAll() { onReset?() }
    @objc private func permissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    @objc private func aboutApp() {
        let alert = NSAlert(); alert.messageText = "VolumeMixer"
        alert.informativeText = "Независимая громкость приложений.\n\nЗвук обрабатывается только в памяти: без записи и отправки. macOS запросит доступ к системному аудио при первой регулировке.\n\n100% — исходный уровень приложения. Первая версия поддерживает стереовыход."
        alert.runModal()
    }
}
