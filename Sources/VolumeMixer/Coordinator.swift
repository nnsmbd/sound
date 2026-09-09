import AppKit

struct MixerRowState {
    var source: AudioSource
    var volume: Int = 100
    var muted = false
    var busy = false
}
struct MixerSnapshot {
    var rows: [MixerRowState]
    var output: String
    var error: String?
    var devices: [OutputDevice] = []
    var selectedUID: String? = nil
}
final class AudioCoordinator {
    private let queue = DispatchQueue(label: "dev.samir.VolumeMixer.audio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var rows: [String: MixerRowState] = [:]
    private var order: [String] = []
    private var routes: [String: TapRoute] = [:]
    private var output: OutputDevice?
    private var error: String?
    private var suspended = false
    var onChange: ((MixerSnapshot) -> Void)?
    func selectOutput(_ uid: String) {
        queue.async {
            guard !self.suspended else { return }
            // Stop reading taps before switching hardware; preserve requested gains for the new routes.
            self.routes.values.forEach { $0.stop() }; self.routes.removeAll()
            do { try HAL.selectOutput(uid: uid); self.error = nil }
            catch { self.error = error.localizedDescription }
            self.refresh()
        }
    }
    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    func change(_ key: String, volume: Int? = nil, toggleMute: Bool = false) {
        queue.async {
            guard var row = self.rows[key], !self.suspended else { return }
            if let volume { row.volume = min(100, max(0, volume)); row.muted = false }
            if toggleMute { row.muted.toggle() }
            self.rows[key] = row; self.error = nil
            self.apply(key); self.publish()
        }
    }
    private func apply(_ key: String) {
        guard let row = rows[key], let output else { return }
        let gain = row.muted ? Float(0) : Float(row.volume) / 100
        if gain == 1 { routes.removeValue(forKey: key)?.stop(); return }
        if let route = routes[key] { route.setGain(gain); return }
        do { routes[key] = try TapRoute(source: row.source, output: output, gain: gain) }
        catch { reset(key); self.error = error.localizedDescription }
    }
    private func reset(_ key: String) {
        routes.removeValue(forKey: key)?.stop()
        rows[key]?.volume = 100; rows[key]?.muted = false
    }
    private func refresh() {
        guard !suspended else { return }
        do {
            let next = try HAL.output()
            let changed = output != nil && output != next
            if changed { routes.values.forEach { $0.stop() }; routes.removeAll() }
            output = next
            let sources = try SourceDiscovery.list()
            let keys = Set(sources.map(\.key))
            for key in order where !keys.contains(key) { reset(key); rows.removeValue(forKey: key) }
            order.removeAll { rows[$0] == nil }
            for source in sources where source.playing || rows[source.key] != nil {
                if var row = rows[source.key] {
                    if row.source.processes != source.processes { routes.removeValue(forKey: source.key)?.stop() }
                    row.source = source; rows[source.key] = row
                } else {
                    rows[source.key] = MixerRowState(source: source); order.append(source.key)
                }
                if let route = routes[source.key], let fault = route.healthError() { reset(source.key); error = fault }
                // Retain a paused source's row; the order never changes while the slider is being dragged.
                if rows[source.key]!.volume != 100 || rows[source.key]!.muted { apply(source.key) }
            }
            publish()
        } catch {
            for key in order { reset(key) }
            self.error = error.localizedDescription; publish()
        }
    }
    func resetAll() { queue.async { for key in self.order { self.reset(key) }; self.error = nil; self.publish() } }
    func suspend() { queue.async { self.suspended = true; self.routes.values.forEach { $0.stop() }; self.routes.removeAll() } }
    func resume() { queue.async { self.suspended = false; self.refresh() } }
    func shutdown() { queue.sync { timer?.cancel(); timer = nil; routes.values.forEach { $0.stop() }; routes.removeAll() } }
    private func publish() {
        let snapshot = MixerSnapshot(rows: order.compactMap { rows[$0] }, output: output?.name ?? "Нет устройства вывода", error: error, devices: (try? HAL.outputs()) ?? [], selectedUID: output?.uid)
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }
}
