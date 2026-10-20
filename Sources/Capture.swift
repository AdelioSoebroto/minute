import AVFoundation
import CoreAudio

/// Thread-safe peak level for the UI meters.
final class Level {
    private let lock = NSLock()
    private var v: Float = 0
    func update(_ x: Float) { lock.lock(); v = max(v * 0.8, x); lock.unlock() }
    func read() -> Float { lock.lock(); defer { lock.unlock() }; let r = v; v = v * 0.5; return r }
}

private func peak(_ buf: AVAudioPCMBuffer) -> Float {
    guard let ch = buf.floatChannelData else { return 0 }
    var m: Float = 0
    for c in 0..<Int(buf.format.channelCount) {
        for i in stride(from: 0, to: Int(buf.frameLength), by: 8) { m = max(m, abs(ch[c][i])) }
    }
    return m
}

struct CaptureError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records everything playing on the Mac (Teams, Zoom, Meet...) through a Core Audio process tap.
final class SystemTap {
    let level = Level()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "mom.systemtap")

    func start(url: URL) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Minute tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw CaptureError(message: "System audio tap failed (\(st)). Allow System Audio Recording for Minute in System Settings > Privacy & Security.") }

        let outUID = try Self.defaultOutputUID()
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minute",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard st == noErr else { stop(); throw CaptureError(message: "Could not create capture device (\(st)).") }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard st == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw CaptureError(message: "Could not read system audio format (\(st)).")
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inData, _, _, _ in
            guard let self, let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inData, deallocator: nil) else { return }
            self.level.update(peak(buf))
            try? self.file?.write(from: buf)
        }
        guard st == noErr else { stop(); throw CaptureError(message: "Could not start capture (\(st)).") }
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { stop(); throw CaptureError(message: "Could not start capture (\(st)).") }
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
            AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        queue.sync { file = nil }
    }

    private static func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else {
            throw CaptureError(message: "No audio output device found.")
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else {
            throw CaptureError(message: "Could not read output device.")
        }
        return u.takeRetainedValue() as String
    }
}

/// Records the default microphone.
final class MicRecorder {
    let level = Level()
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError(message: "No microphone available.") }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.level.update(peak(buf))
            try? self?.file?.write(from: buf)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}
