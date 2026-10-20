import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser
let momRoot = home.appendingPathComponent("Documents/MoM")
let momCLI = home.appendingPathComponent(".mom/bin/mom").path

enum Mode: String, CaseIterable, Identifiable {
    case online = "Online", onsite = "Onsite"
    var id: String { rawValue }
    var hint: String { self == .online ? "Meeting audio + your mic" : "Room mic only" }
}

enum Phase: Equatable {
    case idle
    case recording
    case processing(String)   // step 1: transcribing + drafting
    case review               // step 2
    case exporting(String)    // step 3
    case done
    case failed(String)
}

struct Topic: Identifiable, Equatable { let id = UUID(); var text: String }

struct MoMData: Codable {
    var agenda = "", date = "", time = ""
    var telkomsel_names: [String] = [], telkomsel_unit = ""
    var third_party_names: [String] = [], third_party_company = ""
    var topics: [String] = []
}

final class Tail: @unchecked Sendable {
    private let l = NSLock(); private var v = ""; private var a = ""
    var value: String { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
    var all: String { get { l.lock(); defer { l.unlock() }; return a } set { l.lock(); a = newValue; l.unlock() } }
}

/// Runs the `mom` pipeline, forwarding "STAGE:" lines. Returns (exit status, last output line).
func runMom(_ args: [String], full: Bool = false, stage: @escaping @Sendable (String) -> Void = { _ in }) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: momCLI)
        p.arguments = args
        p.qualityOfService = .utility   // heavy work runs behind the user's apps
        p.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let tail = Tail()
        out.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            tail.all += s
            for line in s.split(separator: "\n") {
                tail.value = String(line)
                if line.hasPrefix("STAGE:") { stage(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            cont.resume(returning: (p.terminationStatus, full ? tail.all.trimmingCharacters(in: .whitespacesAndNewlines) : tail.value))
        }
        do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .online {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var history: [Float] = Array(repeating: 0, count: 36)
    @Published var warning: String?
    private var micSeg = 1, sysSeg = 1
    private var sysHeard = false
    private var outListener: AudioObjectPropertyListenerBlock?
    private var micObserver: NSObjectProtocol?
    private var rotateWork: DispatchWorkItem?
    @Published var session: URL?
    @Published var transcript = ""
    @Published var lastDir: URL? = Recorder.latestSession()

    // Review form
    @Published var agenda = ""
    @Published var date = ""
    @Published var time = ""
    @Published var telkNames = ""
    @Published var telkUnit = ""
    @Published var tpNames = ""
    @Published var tpCompany = ""
    @Published var topics: [Topic] = []
    @Published var tidying = false
    @Published var canUndoTidy = false
    @Published var autoTidy: Bool = UserDefaults.standard.object(forKey: "autoTidy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTidy, forKey: "autoTidy") }
    }
    private var preTidy: MoMData?

    private let mic = MicRecorder()
    private let tap = SystemTap()
    private var timer: Timer?
    private var started = Date()
    private var activity: NSObjectProtocol?

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { switch phase { case .processing, .exporting: return true; default: return false } }
    var step: Int {
        switch phase {
        case .review: return 1
        case .exporting, .done: return 2
        default: return 0
        }
    }

    static func latestSession() -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: momRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("MoM.json").path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Debug aid: MINUTE_DEMO=review|export|processing launches straight into that step with sample data.
    func demo(_ name: String) {
        agenda = "Operational – Update SSL Ondeck"; date = "October 20th, 2026"; time = "9:00 AM"
        telkNames = "Adelio Ferhan\nIvan Saputra"; telkUnit = "IT Digital Advertising Management"
        tpNames = "Kiki Latief"; tpCompany = "iCode"
        topics = [Topic(text: "Pada renewal SSL LBA terdapat issue pada sudo command yang sudah expired dan harus di-request ulang."),
                  Topic(text: "Remediasi akan dilaksanakan pada 21 Oktober 2026 pukul 22:00 hingga 05:00 oleh iCode.")]
        transcript = "[00:00:02] Me: Selamat pagi semuanya.\n[00:00:09] Others: Understood. We will submit the standard change request today."
        session = momRoot.appendingPathComponent("2026-10-20_0900_test")
        switch name {
        case "review": phase = .review
        case "export": phase = .done
        case "processing": phase = .processing("Transcribing Me: 2 of 5 min")
        default: break
        }
    }

    // MARK: Step 1 - record

    func start() {
        guard phase == .idle || phase.isTerminal else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async { ok ? self?.begin() : (self?.phase = .failed("Microphone access is off. Enable it in System Settings > Privacy & Security > Microphone.")) }
        }
    }

    private func begin() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let dir = momRoot.appendingPathComponent(f.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            micSeg = 1; sysSeg = 1; sysHeard = false; warning = nil
            try mic.start(url: segURL(dir, "mic", 1))
            if mode == .online { try tap.start(url: segURL(dir, "system", 1)) }
        } catch {
            mic.stop(); tap.stop()
            phase = .failed(error.localizedDescription); return
        }
        session = dir
        started = Date(); elapsed = 0
        history = Array(repeating: 0, count: 36)
        watchDevices()
        phase = .recording
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
                self.micLevel = self.mic.level.read(); self.sysLevel = self.tap.level.read()
                self.history.removeFirst(); self.history.append(max(self.micLevel, self.sysLevel))
                if self.sysLevel > 0.01 { self.sysHeard = true; if self.warning?.hasPrefix("No meeting") == true { self.warning = nil } }
                if self.mode == .online, !self.sysHeard, self.elapsed > 25, self.warning == nil {
                    self.warning = "No meeting audio heard yet. Check System Audio Recording in System Settings, or that the meeting is playing."
                }
            }
        }
    }

    private func segURL(_ dir: URL, _ name: String, _ n: Int) -> URL {
        dir.appendingPathComponent(n == 1 ? "\(name).caf" : "\(name)_\(n).caf")
    }

    /// If headphones are plugged in or the output/input device changes mid-meeting, carry on in a new file segment.
    private func watchDevices() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.scheduleRotate(mic: false) } }
        outListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRotate(mic: true) }
        }
    }

    private func unwatchDevices() {
        if let b = outListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, b)
            outListener = nil
        }
        if let o = micObserver { NotificationCenter.default.removeObserver(o); micObserver = nil }
        rotateWork?.cancel()
    }

    private func scheduleRotate(mic isMic: Bool) {
        guard isRecording else { return }
        if !isMic && mode != .online { return }
        rotateWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.rotate(mic: isMic) } }
        rotateWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    private func rotate(mic isMic: Bool) {
        guard isRecording, let dir = session else { return }
        do {
            if isMic { mic.stop(); micSeg += 1; try mic.start(url: segURL(dir, "mic", micSeg)) }
            else { tap.stop(); sysSeg += 1; try tap.start(url: segURL(dir, "system", sysSeg)) }
            warning = nil; Haptic.generic()
        } catch {
            warning = "Audio device changed and recording could not follow: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording, let dir = session else { return }
        timer?.invalidate(); timer = nil
        unwatchDevices()
        mic.stop(); tap.stop()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        try? "\(mode.rawValue)\n".write(to: dir.appendingPathComponent("mode.txt"), atomically: true, encoding: .utf8)
        draft(dir)
    }

    /// Transcribe + draft the MoM, then slide to review.
    func draft(_ dir: URL) {
        session = dir
        phase = .processing("Starting…")
        Task {
            let (code, tail) = await runMom([dir.path]) { s in Task { @MainActor in if case .processing = self.phase { self.phase = .processing(s) } } }
            if code == 0, loadDraft(dir) {
                phase = .review
                if ProcessInfo.processInfo.environment["MINUTE_AUTOEXPORT"] != nil { export() }   // test hook
                notify("Minutes drafted", "Open Minute to review and export.")
            } else {
                phase = .failed("Could not draft the minutes: \(tail)\nYour audio is safe in \(dir.lastPathComponent).")
                notify("Minute failed", "Audio is saved. Open Minute for details.")
            }
        }
    }

    // MARK: Step 2 - review

    @discardableResult
    func loadDraft(_ dir: URL) -> Bool {
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent("MoM.json")),
              let d = try? JSONDecoder().decode(MoMData.self, from: raw) else { return false }
        session = dir
        apply(d)
        transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        return true
    }

    private func apply(_ d: MoMData) {
        agenda = d.agenda; date = d.date; time = d.time
        telkNames = d.telkomsel_names.joined(separator: "\n"); telkUnit = d.telkomsel_unit
        tpNames = d.third_party_names.joined(separator: "\n"); tpCompany = d.third_party_company
        topics = d.topics.map { Topic(text: $0) }
    }

    func reviewLast() { if let d = Recorder.latestSession(), loadDraft(d) { phase = .review } }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func currentData() -> MoMData {
        MoMData(agenda: agenda, date: date, time: time, telkomsel_names: lines(telkNames), telkomsel_unit: telkUnit,
                third_party_names: lines(tpNames), third_party_company: tpCompany,
                topics: topics.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func saveDraft() throws {
        guard let dir = session else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(currentData()).write(to: dir.appendingPathComponent("MoM.json"))
    }

    // MARK: Tidy - fix spacing, punctuation and wording

    func tidy(thenExport: Bool = false) {
        guard let dir = session, !tidying else { return }
        do { try saveDraft() } catch { phase = .failed("Could not save: \(error.localizedDescription)"); return }
        preTidy = currentData()
        tidying = true
        if thenExport { phase = .exporting("Tidying the minutes…") }
        Task {
            let (code, _) = await runMom(["--tidy", dir.path]) { st in
                Task { @MainActor in if thenExport, case .exporting = self.phase { self.phase = .exporting(st + "…") } }
            }
            tidying = false
            if code == 0, loadDraft(dir) { canUndoTidy = !thenExport; if !thenExport { Haptic.confirm() } }
            if thenExport { runExport(dir) }
        }
    }

    func undoTidy() {
        guard let d = preTidy else { return }
        withAnimation { apply(d) }
        canUndoTidy = false; Haptic.generic()
    }

    // MARK: Step 3 - export

    func export() {
        guard let dir = session else { return }
        if autoTidy { tidy(thenExport: true); return }
        do { try saveDraft() } catch { phase = .failed("Could not save: \(error.localizedDescription)"); return }
        runExport(dir)
    }

    private func runExport(_ dir: URL) {
        phase = .exporting("Filling the template…")
        Task {
            let (code, tail) = await runMom(["--export", dir.path]) { st in Task { @MainActor in if case .exporting = self.phase { self.phase = .exporting(st) } } }
            if code == 0 { phase = .done; lastDir = dir; notify("MoM ready", "Word and PDF saved in \(dir.lastPathComponent)") }
            else { phase = .failed("Export failed: \(tail)") }
        }
    }

    func reset() { phase = .idle; canUndoTidy = false; lastDir = Recorder.latestSession() }
    func backToReview() { phase = .review }

    func notify(_ title: String, _ body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let n = UNMutableNotificationContent(); n.title = title; n.body = body; n.sound = .default
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }
}

extension Phase {
    var isTerminal: Bool { if case .failed = self { return true }; return self == .done }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - Haptics

enum Haptic {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func confirm() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func generic() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}

// MARK: - Shared components

/// Only fires after being held, so an accidental click can't start or stop anything.
/// Gives a soft haptic tick while you hold and a firm one when it commits.
struct HoldButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let seconds: Double
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @State private var ticker: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.clear.glass(Circle(), tint: tint.opacity(pressing ? 0.35 : 0.18), interactive: true)
                Circle().stroke(tint.opacity(0.22), lineWidth: 4)
                Circle().trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(tint)
                    .scaleEffect(pressing && !reduceMotion ? 0.88 : 1)
                    .animation(.spring(duration: 0.3, bounce: 0.3), value: pressing)
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: seconds, maximumDistance: 60, perform: {
                stopTicker(); Haptic.confirm()
                progress = 0; pressing = false; action()
            }, onPressingChanged: { down in
                pressing = down
                if down {
                    Haptic.generic()
                    withAnimation(.linear(duration: seconds)) { progress = 1 }
                    ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in Haptic.tick() }
                } else {
                    stopTicker()
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            })
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

/// Voice-Memos-style live waveform.
struct Waveform: View {
    let samples: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, v in
                Capsule().fill(.red.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(min(1, v * 3)) * 40))
            }
        }
        .frame(height: 40).frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.1), value: samples)
        .accessibilityHidden(true)
    }
}

struct SourceChip: View {
    let symbol: String
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2)
            Text(label).font(.caption)
            Circle().fill(level > 0.01 ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glass(Capsule())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Menu bar panel (quick start / stop)

struct PanelView: View {
    @ObservedObject var r: Recorder
    @Environment(\.openWindow) private var openWindow

    func showWindow() { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }

    var body: some View {
        VStack(spacing: 14) {
            switch r.phase {
            case .idle: idle
            case .recording: recording
            default: busy
            }
            Divider()
            HStack {
                Button { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) } label: { Label("All meetings", systemImage: "books.vertical") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(r.isRecording || r.isBusy)
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).font(.callout)
        }
        .padding(18).frame(width: 290)
        .animation(.spring(duration: 0.4), value: r.phase)
    }

    var idle: some View {
        VStack(spacing: 14) {
            Picker("Mode", selection: $r.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(r.mode.hint).font(.caption).foregroundStyle(.secondary)
            HoldButton(title: "Hold to record", symbol: "mic.fill", tint: .red, seconds: 0.8) { r.start() }.padding(.vertical, 4)
            if r.lastDir != nil {
                Button("Review last meeting") { r.reviewLast(); showWindow() }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
    }

    var recording: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                    .opacity(Int(r.elapsed * 1.5) % 2 == 0 ? 1 : 0.35).animation(.easeInOut(duration: 0.4), value: Int(r.elapsed * 1.5))
                Text("Recording").font(.callout.weight(.semibold))
            }
            Text(clock(r.elapsed)).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Waveform(samples: r.history)
            HStack(spacing: 8) {
                SourceChip(symbol: "mic.fill", label: "Mic", level: r.micLevel)
                if r.mode == .online { SourceChip(symbol: "speaker.wave.2.fill", label: "Meeting", level: r.sysLevel) }
            }
            if let w = r.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            HoldButton(title: "Hold to stop", symbol: "stop.fill", tint: .primary, seconds: 1.5) { r.stop(); showWindow() }
        }
    }

    var busy: some View {
        VStack(spacing: 12) {
            if r.isBusy { ProgressView() }
            else { Image(systemName: r.phase == .done ? "checkmark.circle.fill" : "doc.text").font(.title).foregroundStyle(r.phase == .done ? .green : .secondary) }
            Text(statusText).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Open Minute") { showWindow() }.buttonStyle(.borderedProminent).controlSize(.large)
            if case .failed = r.phase { Button("Dismiss") { r.reset() }.buttonStyle(.borderless) }
            if r.phase == .done { Button("New recording") { r.reset() }.buttonStyle(.borderless) }
        }
    }

    var statusText: String {
        switch r.phase {
        case .processing(let s): return s
        case .review: return "Your minutes are ready to review"
        case .exporting(let s): return s
        case .done: return "Word and PDF are ready"
        case .failed(let m): return m
        default: return ""
        }
    }
}

// MARK: - Main window: Record -> Review -> Export

struct StepBar: View {
    let step: Int
    let titles = ["Record", "Review", "Export"]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3) { i in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.18)).frame(width: 20, height: 20)
                        if i < step { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(i == step ? .white : .secondary) }
                    }
                    Text(titles[i]).font(.callout.weight(i == step ? .semibold : .regular))
                        .foregroundStyle(i <= step ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(i + 1), \(titles[i])\(i == step ? ", current" : "")")
                if i < 2 {
                    Capsule().fill(i < step ? Color.accentColor : Color.secondary.opacity(0.18)).frame(width: 28, height: 2)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .glass(Capsule())
        .animation(.spring(duration: 0.5), value: step)
    }
}

struct HideTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

struct MainWindow: View {
    @ObservedObject var r: Recorder
    @State private var showTranscript = false

    var body: some View {
        ZStack {
            Group {
                switch r.step {
                case 0: StepRecord(r: r)
                case 1: StepReview(r: r)
                default: StepExport(r: r)
                }
            }
            .id(r.step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.spring(duration: 0.55, bounce: 0.1), value: r.step)
        .safeAreaInset(edge: .top, spacing: 0) {
            StepBar(step: r.step).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: .infinity)
        }
        .clipped()
        .frame(minWidth: 760, minHeight: 640)
        .background(.background)
        .inspector(isPresented: $showTranscript) {
            TranscriptView(text: r.transcript.replacingOccurrences(of: "# Transcript\n\n", with: ""))
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if r.step == 1 {
                    Button { showTranscript.toggle() } label: { Label("Transcript", systemImage: "sidebar.right") }
                        .help("Show the transcript to check the minutes against")
                }
            }
        }
        .modifier(HideTitle())
        .onChange(of: r.step) { _, _ in Haptic.generic() }
        .onChange(of: r.phase) { _, p in
            if p == .done { Haptic.confirm() }
            if case .failed = p { NSSound.beep() }
        }
    }
}

struct Hero: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 52, weight: .light)).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420) }
        }
    }
}

struct StepRecord: View {
    @ObservedObject var r: Recorder
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            switch r.phase {
            case .processing(let s):
                ProgressView().controlSize(.large).padding(.bottom, 4)
                Text("Writing your minutes").font(.title2.weight(.semibold))
                Text(s).foregroundStyle(.secondary).contentTransition(.opacity).animation(.default, value: s)
                Text("Everything stays on this Mac. You can close this window; you'll get a notification.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
            case .failed(let m):
                Hero(symbol: "exclamationmark.triangle", tint: .orange, title: "Something went wrong", subtitle: m)
                Button("OK") { r.reset() }.controlSize(.large)
            case .recording:
                Hero(symbol: "record.circle", tint: .red, title: "Recording", subtitle: "Use the menu bar icon to stop.")
            default:
                Hero(symbol: "waveform.circle", tint: .secondary, title: "Ready when you are", subtitle: "Hold the record button in the menu bar to begin.")
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct StepReview: View {
    @ObservedObject var r: Recorder

    var body: some View {
        PaperDesk {
            VStack(spacing: 14) {
                Text("Check the minutes. Click anywhere on the page to edit; it exports exactly like this.")
                    .font(.callout).foregroundStyle(.secondary)
                MinutesPaper(agenda: $r.agenda, date: $r.date, time: $r.time, telkNames: $r.telkNames, telkUnit: $r.telkUnit,
                             tpNames: $r.tpNames, tpCompany: $r.tpCompany, topics: $r.topics, editable: true)
            }
        }
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .softScrollEdges()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassGroup(spacing: 14) {
                HStack(spacing: 12) {
                    Button("Discard") { r.reset() }.glassButton()
                    Button { r.tidy() } label: {
                        if r.tidying { ProgressView().controlSize(.small).frame(width: 70) } else { Label("Tidy up", systemImage: "sparkles") }
                    }.glassButton().disabled(r.tidying).help("Fix spacing, punctuation and wording with the on-device model")
                    if r.canUndoTidy { Button("Undo tidy") { r.undoTidy() }.glassButton().transition(.scale.combined(with: .opacity)) }
                    Spacer(minLength: 8)
                    Toggle("Auto-tidy", isOn: $r.autoTidy).toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8).glass(Capsule())
                    Button { r.export() } label: { Text("Export Word & PDF").frame(minWidth: 140) }
                        .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .animation(.spring(duration: 0.4), value: r.canUndoTidy)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct StepExport: View {
    @ObservedObject var r: Recorder
    func open(_ name: String) { if let d = r.session { NSWorkspace.shared.open(d.appendingPathComponent(name)) } }
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if r.phase == .done, let d = r.session {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64, weight: .light)).foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical).symbolEffect(.bounce, value: r.phase)
                Text("Your minutes are ready").font(.title2.weight(.semibold))
                Text(d.path.replacingOccurrences(of: home.path, with: "~")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 10) {
                    GlassGroup(spacing: 12) {
                        HStack(spacing: 10) {
                            Button { open("MoM.docx") } label: { Label("Open Word", systemImage: "doc.text").frame(minWidth: 100) }.glassButton(prominent: true)
                            Button { open("MoM.pdf") } label: { Label("Open PDF", systemImage: "doc.richtext").frame(minWidth: 100) }.glassButton()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([d.appendingPathComponent("MoM.pdf")]) } label: { Label("Show in Finder", systemImage: "folder") }.glassButton()
                        }
                    }
                }.controlSize(.large)
                HStack(spacing: 18) {
                    Button("Edit again") { r.backToReview() }
                    Button("New recording") { r.reset() }
                }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.top, 6)
            } else if case .failed(let m) = r.phase {
                Hero(symbol: "exclamationmark.triangle", tint: .orange, title: "Export failed", subtitle: m)
                Button("Back to review") { r.backToReview() }.controlSize(.large)
            } else {
                ProgressView().controlSize(.large).padding(.bottom, 4)
                Text("Creating Word and PDF").font(.title2.weight(.semibold))
                if case .exporting(let s) = r.phase { Text(s).foregroundStyle(.secondary) }
                Text("Word may flash open briefly to make the PDF.").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

@main
struct MinuteApp: App {
    @StateObject private var r = Recorder()
    @StateObject private var lib = Library()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        MenuBarExtra {
            PanelView(r: r)
        } label: {
            Group {
                switch r.phase {
                case .recording:
                    HStack(spacing: 4) { Image(nsImage: redDot); Text(clock(r.elapsed)).monospacedDigit() }
                case .processing, .exporting: Image(systemName: "ellipsis.circle")
                case .review: Image(systemName: "doc.text")
                default: Image(systemName: "waveform.circle")
                }
            }
            .onAppear {
                if let d = ProcessInfo.processInfo.environment["MINUTE_DEMO"] {
                    if d == "draft", let dir = ProcessInfo.processInfo.environment["MINUTE_DIR"] { r.draft(URL(fileURLWithPath: dir)) } else { r.demo(d) }
                    openWindow(id: d == "library" ? "library" : "minute"); NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Meetings", id: "library") { LibraryView(lib: lib, r: r) }
            .windowToolbarStyle(.unified)
            .defaultSize(width: 1040, height: 700)

        Window("Minute", id: "minute") { MainWindow(r: r) }
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
            .defaultSize(width: 860, height: 760)
    }

    var redDot: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        img.isTemplate = false
        return img
    }
}
