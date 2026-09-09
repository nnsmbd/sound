import AppKit
import CoreAudio
import AudioDSP

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure(message: "\(operation): \(status)") }
}
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(selector, scope), result = initial, size = UInt32(MemoryLayout<T>.size)
        try checked(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "Чтение аудиоустройства")
        return result
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector), result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try checked(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "Чтение имени")
        guard let result else { return "" }
        return result.takeRetainedValue() as String
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope), size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Список аудиоисточников")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try result.withUnsafeMutableBytes { try checked(AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!), "Список аудиоисточников") }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func output() throws -> OutputDevice {
        let id = try scalar(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        guard id != 0 else { throw AudioFailure(message: "Нет устройства вывода") }
        return try OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName), rate: scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)))
    }
    static func validateStereo(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws {
        let streams = try ids(device, kAudioDevicePropertyStreams, scope: scope)
        var channels: UInt32 = 0
        for stream in streams {
            let f = try scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0, f.mBitsPerChannel == 32 else {
                throw AudioFailure(message: "Этот формат выхода пока не поддерживается. Нужен Float32 stereo.")
            }
            channels += f.mChannelsPerFrame
        }
        guard channels == 2 else { throw AudioFailure(message: "В первой версии поддерживается только стереовыход (2 канала).") }
    }
}
struct OutputDevice: Equatable { let id: AudioObjectID; let uid: String; let name: String; let rate: Double }
struct AudioSource {
    let key: String
    let name: String
    let url: URL?
    var processes: [AudioObjectID]
    var playing: Bool
}
enum SourceDiscovery {
    static func list() throws -> [AudioSource] {
        var groups: [String: AudioSource] = [:]
        for id in try HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid: pid_t = try? HAL.scalar(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid != getpid() else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = (try? HAL.string(id, kAudioProcessPropertyBundleID)) ?? ""
            // Parent .app path is concrete ownership evidence for nested helper bundles.
            var url = app?.bundleURL
            if url == nil {
                var path = [CChar](repeating: 0, count: 4096)
                if MixerProcessPath(pid, &path, UInt32(path.count)) > 0 {
                    let executable = String(cString: path)
                    if let range = executable.range(of: ".app/") { url = URL(fileURLWithPath: String(executable[...range.lowerBound]) + "app") }
                }
            }
            if let path = url?.path, let range = path.range(of: ".app/") { url = URL(fileURLWithPath: String(path[...range.lowerBound]) + "app") }
            let bundle = url.flatMap(Bundle.init(url:))
            let key = url?.path ?? (bundleID.isEmpty ? "pid:\(pid)" : bundleID)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? app?.localizedName ?? (bundleID.isEmpty ? "Процесс \(pid)" : bundleID)
            let playing = ((try? HAL.scalar(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            if var existing = groups[key] { existing.processes.append(id); existing.playing = existing.playing || playing; groups[key] = existing }
            else { groups[key] = AudioSource(key: key, name: name, url: url, processes: [id], playing: playing) }
        }
        return groups.values.map { var s = $0; s.processes.sort(); return s }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// Owned exclusively by AudioCoordinator's serial queue. Teardown always stops the callback before freeing its context.
final class TapRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    let processes: [AudioObjectID]
    let output: OutputDevice
    private var previousCallbacks: UInt64 = 0
    private var stalledChecks = 0
    private let created = Date()
    init(source: AudioSource, output: OutputDevice, gain: Float) throws {
        self.processes = source.processes; self.output = output
        do {
            try HAL.validateStereo(output.id, scope: kAudioObjectPropertyScopeOutput)
            let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
            description.name = "VolumeMixer · \(source.name)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try checked(AudioHardwareCreateProcessTap(description, &tap), "Доступ к звуку приложения")
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VolumeMixer · \(source.name)",
                kAudioAggregateDeviceUIDKey: "dev.samir.VolumeMixer.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceOutputChannelsKey: 2]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try checked(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Создание аудиотракта")
            try HAL.validateStereo(aggregate, scope: kAudioObjectPropertyScopeInput)
            try HAL.validateStereo(aggregate, scope: kAudioObjectPropertyScopeOutput)
            guard let state = MixerDSPCreate(gain, output.rate) else { throw AudioFailure(message: "Недостаточно памяти для аудиотракта") }
            dsp = state
            try checked(MixerDSPAttach(aggregate, state, &proc), "Подключение обработки")
            try checked(AudioDeviceStart(aggregate, proc), "Запуск обработки. Проверьте разрешение записи системного аудио")
        } catch { stop(); throw error }
    }
    func setGain(_ gain: Float) { if let dsp { MixerDSPSetGain(dsp, gain) } }
    func healthError() -> String? {
        guard let dsp else { return "Аудиотракт остановлен" }
        if MixerDSPFaults(dsp) > 0 { return "Формат аудиобуфера изменился. Восстановлен исходный звук." }
        let count = MixerDSPCallbacks(dsp)
        stalledChecks = count == previousCallbacks ? stalledChecks + 1 : 0
        previousCallbacks = count
        if Date().timeIntervalSince(created) > 4 && stalledChecks >= 3 { return "Аудиопоток недоступен. Проверьте разрешение записи системного аудио." }
        return nil
    }
    func stats() -> String {
        guard let dsp else { return "stopped" }
        return "callbacks=\(MixerDSPCallbacks(dsp)) faults=\(MixerDSPFaults(dsp)) input=\(MixerDSPInputPeak(dsp)) output=\(MixerDSPOutputPeak(dsp))"
    }
    func stop() {
        var callbackRemoved = true
        if let proc, aggregate != 0 {
            AudioDeviceStop(aggregate, proc)
            callbackRemoved = AudioDeviceDestroyIOProcID(aggregate, proc) == noErr
        }
        proc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        // On an unexpected HAL teardown failure, leak the tiny callback context rather than risk use-after-free.
        if let dsp, callbackRemoved { MixerDSPDestroy(dsp) }; dsp = nil
    }
    deinit { stop() }
}
