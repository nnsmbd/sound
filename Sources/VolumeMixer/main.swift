import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var view: MixerPanelController!
    private let audio = AudioCoordinator()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let preview = CommandLine.arguments.contains("--preview")
    private var previewRows: [MixerRowState] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SoundMenuBar"
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Громкость приложений")
        item.button?.image?.isTemplate = true
        item.button?.image?.size = NSSize(width: 16, height: 16)
        item.button?.title = " Sound"
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Громкость приложений"
        item.button?.target = self; item.button?.action = #selector(toggle)
        if let index = CommandLine.arguments.firstIndex(of: "--status-diagnostics"), CommandLine.arguments.count > index + 1 {
            let destination = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let value = "visible=\(self.item.isVisible) image=\(self.item.button?.image != nil) button=\(String(describing: self.item.button?.frame)) window=\(String(describing: self.item.button?.window?.frame)) screens=\(NSScreen.screens.map { "\($0.localizedName):\($0.frame)" })"
                try? value.write(toFile: destination, atomically: true, encoding: .utf8)
            }
        }
        view = MixerPanelController(preview: preview)
        view.anchor = { [weak self] in
            guard let button = self?.item.button, let window = button.window else { return nil }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            return NSPoint(x: rect.midX, y: rect.minY)
        }
        view.onVolume = { [weak self] key, value in
            guard let self else { return }
            if self.preview { self.changePreview(key, value: value) }
            else { self.audio.change(key, volume: value) }
        }
        view.onMute = { [weak self] key in
            guard let self else { return }
            if self.preview { self.changePreview(key, value: nil) }
            else { self.audio.change(key, toggleMute: true) }
        }
        view.onReset = { [weak self] in
            guard let self else { return }
            if self.preview { self.previewRows = self.previewRows.map { MixerRowState(source: $0.source) }; self.renderPreview() }
            else { self.audio.resetAll() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { self?.view.panel.orderOut(nil); return nil }
            if event.type != .keyDown && event.window != self?.view.panel && event.window != self?.item.button?.window { self?.view.panel.orderOut(nil) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.view.panel.orderOut(nil) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.audio.suspend() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.audio.resume() })
        if preview {
            let apps = [("Chrome", "com.google.Chrome", 30), ("Telegram", "ru.keepcoder.Telegram", 70), ("Spotify", "com.spotify.client", 15), ("Discord", "com.hnc.Discord", 100)]
            previewRows = apps.map { name, bundle, volume in
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                return MixerRowState(source: AudioSource(key: bundle, name: name, url: url, processes: [], playing: true), volume: volume)
            }
            renderPreview()
        } else {
            audio.onChange = { [weak self] snapshot in self?.view.render(snapshot) }
            audio.start()
        }
        if CommandLine.arguments.contains("--show") || preview { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.view.showFromLauncher() } }
    }
    private func changePreview(_ key: String, value: Int?) {
        guard let index = previewRows.firstIndex(where: { $0.source.key == key }) else { return }
        if let value { previewRows[index].volume = value; previewRows[index].muted = false } else { previewRows[index].muted.toggle() }
        renderPreview()
    }
    private func renderPreview() { view.render(MixerSnapshot(rows: previewRows, output: "Динамики MacBook Pro", error: nil)) }
    @objc private func toggle() { view.toggle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        view.showFromLauncher()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        audio.shutdown()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

if CommandLine.arguments.contains("--diagnose") {
    do {
        let output = try HAL.output()
        print("Output: \(output.name) · \(output.rate) Hz")
        for source in try SourceDiscovery.list() { print("\(source.name) | \(source.key) | playing=\(source.playing) | objects=\(source.processes)") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--check-route"), CommandLine.arguments.count > index + 1 {
    // Bounded developer smoke check. This captures no files; stats are amplitude/callback counters only.
    do {
        let key = CommandLine.arguments[index + 1]
        guard let source = try SourceDiscovery.list().first(where: { $0.key == key }) else { throw AudioFailure(message: "Источник не найден") }
        let route = try TapRoute(source: source, output: HAL.output(), gain: 0.3)
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(1)); print(route.stats()) }
        route.stop()
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
