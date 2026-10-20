// MicRecorder mute gate: time is preserved, only the last 3 s before unmuting are kept. Run: ./build.sh test
import AVFoundation

func gateTest() -> Int {
    var fails = 0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString).caf")
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    guard let f = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { print("FAIL gate: cannot create file"); return 1 }
    let m = MicRecorder(); m.attach(file: f)
    func second(_ v: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000)!; b.frameLength = 16000
        for i in 0..<16000 { b.floatChannelData![0][i] = v }
        return b
    }
    for _ in 0..<5 { m.handle(second(0.5)) }
    m.setGated(true)
    for _ in 0..<10 { m.handle(second(0.5)) }
    m.setGated(false)
    for _ in 0..<2 { m.handle(second(0.5)) }
    m.stop()
    guard let r = try? AVAudioFile(forReading: url), let b = AVAudioPCMBuffer(pcmFormat: r.processingFormat, frameCapacity: AVAudioFrameCount(r.length)) else { print("FAIL gate: cannot read back"); return 1 }
    try? r.read(into: b)
    let secs = Int(r.length) / 16000
    func loud(_ s: Int) -> Bool { b.floatChannelData![0][s * 16000 + 8000] > 0.1 }
    if secs != 17 { print("FAIL gate: length \(secs) s, expected 17"); fails += 1 }
    if secs == 17 {
        if !(0..<5).allSatisfy(loud) { print("FAIL gate: audio before muting lost"); fails += 1 }
        if (5..<12).contains(where: loud) { print("FAIL gate: muted audio was kept"); fails += 1 }
        if !(12..<15).allSatisfy(loud) { print("FAIL gate: pre-roll not kept"); fails += 1 }
        if !(15..<17).allSatisfy(loud) { print("FAIL gate: audio after unmuting lost"); fails += 1 }
    }
    try? FileManager.default.removeItem(at: url)
    return fails
}
