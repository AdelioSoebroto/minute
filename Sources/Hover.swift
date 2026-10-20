import SwiftUI
import AppKit
import CoreAudio
import Combine

// MARK: - Which online meeting app is using the microphone right now

struct DetectedMeeting: Equatable {
    let kind: String          // "Microsoft Teams", "Zoom", "Google Meet"...
    let bundleID: String      // bundle id of the app that owns the windows (for screen context and the icon)
    let isBrowser: Bool
}

@MainActor
final class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()
    @Published private(set) var meeting: DetectedMeeting?
    @Published private(set) var lastSeen: Date?
    private var timer: Timer?
    private var holdUntil = Date.distantPast        // keeps the meeting "alive" through short mic gaps (muted, reconnecting)

    private static let native: [String: (String, String)] = [   // audio process bundle id -> (name, owner bundle id)
        "com.microsoft.teams2": ("Microsoft Teams", "com.microsoft.teams2"), "com.microsoft.teams": ("Microsoft Teams", "com.microsoft.teams"),
        "us.zoom.xos": ("Zoom", "us.zoom.xos"), "com.cisco.webexmeetingsapp": ("Webex", "com.cisco.webexmeetingsapp"),
        "Cisco-Systems.Spark": ("Webex", "Cisco-Systems.Spark"), "com.webex.meetingmanager": ("Webex", "com.webex.meetingmanager"),
        "com.tinyspeck.slackmacgap": ("Slack huddle", "com.tinyspeck.slackmacgap"), "com.hnc.Discord": ("Discord", "com.hnc.Discord"),
        "com.apple.FaceTime": ("FaceTime", "com.apple.FaceTime"), "com.skype.skype": ("Skype", "com.skype.skype"),
        "com.google.GoogleMeet": ("Google Meet", "com.google.GoogleMeet"),
    ]
    private static let browsers: [(prefix: String, owner: String)] = [
        ("com.google.Chrome", "com.google.Chrome"), ("com.apple.Safari", "com.apple.Safari"), ("com.apple.WebKit", "com.apple.Safari"),
        ("company.thebrowser.Browser", "company.thebrowser.Browser"), ("com.microsoft.edgemac", "com.microsoft.edgemac"),
        ("org.mozilla.firefox", "org.mozilla.firefox"), ("com.brave.Browser", "com.brave.Browser"), ("com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi"),
    ]
    private static let siteWords: [(String, String)] = [("Google Meet", "Google Meet"), ("Meet -", "Google Meet"), ("Microsoft Teams", "Microsoft Teams"), ("| Microsoft Teams", "Microsoft Teams"),
                                                         ("Zoom", "Zoom"), ("Webex", "Webex"), ("Whereby", "Whereby"), ("Jitsi", "Jitsi"), ("Around", "Around"), ("Slack", "Slack huddle")]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
    }

    private func tick() {
        if let m = Self.scan() {
            lastSeen = Date(); holdUntil = Date().addingTimeInterval(20)
            if m != meeting { meeting = m }
        } else if meeting != nil, Date() > holdUntil { meeting = nil }
    }

    /// Reads the audio processes macOS reports (macOS 14.2+) and picks the one that is capturing input and looks like a meeting app.
    static func scan() -> DetectedMeeting? {
        for p in audioProcesses() where p.inputRunning && p.bundleID != "local.minute.app" {
            if let n = native.first(where: { $0.key.caseInsensitiveCompare(p.bundleID) == .orderedSame })?.value { return DetectedMeeting(kind: n.0, bundleID: n.1, isBrowser: false) }
            if let b = browsers.first(where: { p.bundleID.lowercased().hasPrefix($0.prefix.lowercased()) }) {
                let kind = siteKind(owner: b.owner) ?? "Online call"
                return DetectedMeeting(kind: kind, bundleID: b.owner, isBrowser: true)
            }
        }
        return nil
    }

    /// With Screen Recording allowed, window titles reveal which site the browser is on (Meet, Teams, Zoom...).
    private static func siteKind(owner: String) -> String? {
        guard CGPreflightScreenCaptureAccess(), let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == owner }.map { Int($0.processIdentifier) })
        for w in info where pids.contains(w[kCGWindowOwnerPID as String] as? Int ?? -1) {
            let title = w[kCGWindowName as String] as? String ?? ""
            if let hit = siteWords.first(where: { title.localizedCaseInsensitiveContains($0.0) }) { return hit.1 }
        }
        return nil
    }

    struct AudioProc { let bundleID: String; let inputRunning: Bool }

    static func audioProcesses() -> [AudioProc] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var run: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &run) == noErr else { return nil }
            var cf: Unmanaged<CFString>?; var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ba, 0, nil, &bs, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
            return AudioProc(bundleID: s as String, inputRunning: run != 0)
        }
    }
}

// MARK: - The floating control

struct FloatingView: View {
    @ObservedObject var r: Recorder
    @ObservedObject var detector: MeetingDetector
    var dismiss: () -> Void
    var openApp: () -> Void
    @State private var pulse = false

    private var ended: Bool {
        guard r.isRecording, r.mode == .online, r.elapsed > 60, detector.meeting == nil, let seen = detector.lastSeen else { return false }
        return Date().timeIntervalSince(seen) > 45
    }

    var body: some View {
        HStack(spacing: 12) {
            if r.isRecording { recording } else { detected }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .frame(minWidth: 280)
        .glass(Capsule(), tint: r.isRecording ? Color.red.opacity(0.10) : nil)
        .fixedSize()
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }

    private var recording: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10).opacity(pulse ? 0.35 : 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(clock(r.elapsed)).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                Text(ended ? "Meeting ended? Hold to stop" : r.warning != nil ? "Check audio" : "Recording · \(r.mode.rawValue)")
                    .font(.caption2).foregroundStyle(ended || r.warning != nil ? Color.orange : .secondary)
            }
            Waveform(samples: Array(r.history.suffix(18))).frame(width: 54, height: 22)
            Button { openApp() } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Open Minute").accessibilityLabel("Open Minute")
            HoldButton(title: "Hold to stop", symbol: "stop.fill", tint: ended ? .red : .primary, seconds: 1.5, size: 40, showTitle: false) { r.stop(); openApp() }
        }
    }

    private var detected: some View {
        HStack(spacing: 12) {
            if let id = detector.meeting?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            } else { Image(systemName: "video.fill").foregroundStyle(Color.accentColor) }
            VStack(alignment: .leading, spacing: 1) {
                Text(detector.meeting.map { $0.kind == "Online call" ? "Online call detected" : "\($0.kind) call" } ?? "Meeting").font(.callout.weight(.semibold))
                Text("Not recording").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HoldButton(title: "Hold to record", symbol: "mic.fill", tint: .red, seconds: 0.8, size: 40, showTitle: false) { r.mode = .online; r.start() }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Hide until the next meeting").accessibilityLabel("Hide")
        }
    }
}

@MainActor
final class FloatingControl {
    static let shared = FloatingControl()
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "floatingControl") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "floatingControl"); shared.update() }
    }
    private var panel: NSPanel?
    private weak var recorder: Recorder?
    private var bag = Set<AnyCancellable>()
    private var dismissed: DetectedMeeting?
    var openApp: () -> Void = {}

    func attach(_ r: Recorder) {
        guard recorder == nil else { return }
        recorder = r
        let d = MeetingDetector.shared
        d.start()
        r.$phase.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &bag)
        d.$meeting.removeDuplicates().sink { [weak self] m in
            DispatchQueue.main.async { if m == nil { self?.dismissed = nil }; self?.update() }
        }.store(in: &bag)
    }

    func update() {
        guard let r = recorder else { return }
        let d = MeetingDetector.shared
        let want = Self.enabled && (r.isRecording || (r.phase == .idle && d.meeting != nil && d.meeting != dismissed))
        if want { show(r) } else { panel?.orderOut(nil) }
    }

    private func show(_ r: Recorder) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovableByWindowBackground = true; p.backgroundColor = .clear; p.hasShadow = true; p.isOpaque = false
            p.sharingType = .none          // not visible when the screen is shared or recorded
            let host = NSHostingView(rootView: FloatingView(r: r, detector: .shared, dismiss: { [weak self] in
                self?.dismissed = MeetingDetector.shared.meeting; self?.update()
            }, openApp: { [weak self] in self?.openApp() }))
            host.sizingOptions = [.intrinsicContentSize]
            p.contentView = host
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { n in
                if let w = n.object as? NSWindow { UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "floatingOrigin") }
            }
            panel = p
            place(p)
        }
        guard let p = panel else { return }
        if let host = p.contentView { let size = host.fittingSize; if size.width > 0 { p.setContentSize(size) } }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func place(_ p: NSPanel) {
        if let s = UserDefaults.standard.string(forKey: "floatingOrigin") {
            let o = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.contains(o) }) { p.setFrameOrigin(o); return }
        }
        if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.maxX - 340, y: f.maxY - 80)) }
    }
}
