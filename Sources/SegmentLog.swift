import Foundation

/// Which audio file covers which stretch of the meeting (segments.json). A device change starts a new file; the processing step uses this to keep the
/// meeting clock right and to repair a file whose samples were stored at the wrong sample rate.
final class SegmentLog {
    private let url: URL
    private var files: [String: (start: Double, end: Double?)] = [:]
    private var order: [String] = []

    init(dir: URL) { url = dir.appendingPathComponent("segments.json") }

    func open(_ file: String, at t: Double) { files[file] = (t, nil); order.append(file); save() }
    func close(_ file: String, at t: Double) { if let f = files[file], f.end == nil { files[file] = (f.start, max(f.start, t)); save() } }
    func closeAll(at t: Double) { for f in order { close(f, at: t) }; save(total: t) }

    func save(total: Double? = nil) {
        var out: [String: Any] = [:]
        for (name, f) in files { var e: [String: Any] = ["start": (f.start * 100).rounded() / 100]; if let end = f.end { e["end"] = (end * 100).rounded() / 100 }; out[name] = e }
        var root: [String: Any] = ["files": out]
        if let total { root["total"] = total }
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }

    /// Frames received against what the wall clock says should have arrived. About 1.0 when healthy; 0.33 is a 16 kHz stream labelled 48 kHz.
    static func drift(frames: Int64, rate: Double, seconds: Double) -> Double? {
        guard seconds >= 6, rate > 0 else { return nil }
        return Double(frames) / (rate * seconds)
    }
    static func isBroken(_ drift: Double?) -> Bool { guard let d = drift else { return false }; return (d >= 0.05 && d < 0.85) || d > 1.2 }       // ~0 means an idle device with no callbacks, not a wrong rate
}
