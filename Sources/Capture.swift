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

/// Records the default microphone. While "gated" (you are muted in the meeting) the mic is not kept: silence is written instead, so the timeline
/// still lines up. The last few seconds are held back so your first words after unmuting are not clipped.
final class MicRecorder {
    let level = Level()
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var gated = false
    private var held: [AVAudioPCMBuffer] = []
    private var heldSeconds = 0.0
    private let preRoll = 3.0

    func setGated(_ g: Bool) {
        lock.lock(); defer { lock.unlock() }
        if g == gated { return }
        gated = g
        if !g { flushHeld(real: true) }
    }

    private func write(_ b: AVAudioPCMBuffer) { try? file?.write(from: b) }

    private func silence(like b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let z = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        z.frameLength = b.frameLength     // freshly allocated buffers are zeroed
        if let ch = z.floatChannelData { for c in 0..<Int(z.format.channelCount) { memset(ch[c], 0, Int(z.frameLength) * MemoryLayout<Float>.size) } }
        return z
    }

    private func flushHeld(real: Bool) {      // caller holds the lock
        for b in held { if real { write(b) } else if let z = silence(like: b) { write(z) } }
        held = []; heldSeconds = 0
    }

    func attach(file f: AVAudioFile) { lock.lock(); gated = false; held = []; heldSeconds = 0; file = f; lock.unlock() }

    func handle(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if !gated { write(buf); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
        copy.frameLength = buf.frameLength
        if let src = buf.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<Int(buf.format.channelCount) { memcpy(dst[c], src[c], Int(buf.frameLength) * MemoryLayout<Float>.size) }
        }
        held.append(copy); heldSeconds += Double(buf.frameLength) / buf.format.sampleRate
        while heldSeconds > preRoll, let first = held.first {       // older than the pre-roll: keep the time, drop the sound
            held.removeFirst(); heldSeconds -= Double(first.frameLength) / first.format.sampleRate
            if let z = silence(like: first) { write(z) }
        }
    }

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError(message: "No microphone available.") }
        let f = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        attach(file: f)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            self?.level.update(peak(buf))
            self?.handle(buf)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); flushHeld(real: true); file = nil; lock.unlock()
    }
}
