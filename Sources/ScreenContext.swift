import Foundation
import AppKit
import ScreenCaptureKit
import Vision

/// While an online meeting is being recorded, looks at the meeting window every few seconds and reads the text on it (slides, documents, shared screens)
/// with on-device OCR. Only the text is kept by default; it is written to screens.json next to the recording and used as context for the minutes.
@MainActor
final class ScreenContext {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "readScreens") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "readScreens") }
    }
    static var keepThumbnails: Bool {
        get { UserDefaults.standard.bool(forKey: "keepThumbnails") }
        set { UserDefaults.standard.set(newValue, forKey: "keepThumbnails") }
    }
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }

    private var timer: Timer?
    private var dir: URL?
    private var elapsed: () -> TimeInterval = { 0 }
    private var events: [[String: Any]] = []
    private var lastTokens = Set<String>()
    private var busy = false

    func begin(dir: URL, elapsed: @escaping () -> TimeInterval) {
        guard Self.enabled, Self.permitted else { return }
        self.dir = dir; self.elapsed = elapsed; events = []; lastTokens = []
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
    }

    func end() { timer?.invalidate(); timer = nil; dir = nil }

    private static let titleWords = ["meet", "teams", "zoom", "webex", "whereby", "jitsi", "around", "huddle", "slack", "presentation", "sharing", "share"]

    private func tick() async {
        guard !busy, let dir, let meeting = MeetingDetector.shared.meeting, elapsed() > 5 else { return }
        busy = true; defer { busy = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let candidates = content.windows.filter { w in
            guard w.isOnScreen, w.frame.width > 480, w.frame.height > 300, w.owningApplication?.bundleIdentifier == meeting.bundleID else { return false }
            return !meeting.isBrowser || Self.titleWords.contains { (w.title ?? "").localizedCaseInsensitiveContains($0) }   // in a browser, only the meeting tab's window
        }
        guard let win = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(min(win.frame.width * 2, 2000)); cfg.height = Int(min(win.frame.height * 2, 1400)); cfg.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) else { return }
        let text = await Task.detached(priority: .utility) { ScreenContext.recognize(image) }.value
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 40 else { return }                       // video tiles and faces carry no text worth keeping
        let tokens = Set(cleaned.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !lastTokens.isEmpty, Double(tokens.intersection(lastTokens).count) / Double(max(1, tokens.union(lastTokens).count)) > 0.8 { return }   // same slide
        lastTokens = tokens
        var ev: [String: Any] = ["t": Int(elapsed()), "app": meeting.kind, "title": win.title ?? "", "text": String(cleaned.prefix(1500))]
        if Self.keepThumbnails, let name = Self.saveThumbnail(image, in: dir, index: events.count + 1) { ev["image"] = name }
        events.append(ev)
        if let d = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("screens.json")) }
    }

    nonisolated static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate; req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let langs = ["id-ID", "en-US"].filter { supported.contains($0) }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence > 0.5 }.map(\.string)
        return lines.joined(separator: "\n")
    }

    nonisolated static func saveThumbnail(_ image: CGImage, in dir: URL, index: Int) -> String? {
        let folder = dir.appendingPathComponent("screens"); try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%03d.jpg", index)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
        return (try? data.write(to: folder.appendingPathComponent(name))) != nil ? "screens/" + name : nil
    }
}

struct ScreenEvent: Identifiable, Equatable {
    let id = UUID()
    let t: Int, app: String, text: String, image: String?
    static func load(from dir: URL?) -> [ScreenEvent] {
        guard let dir, let d = try? Data(contentsOf: dir.appendingPathComponent("screens.json")),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let t = e["t"] as? Int, let text = e["text"] as? String else { return nil }
            return ScreenEvent(t: t, app: e["app"] as? String ?? "", text: text, image: e["image"] as? String)
        }
    }
    var time: String { String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) }
}
