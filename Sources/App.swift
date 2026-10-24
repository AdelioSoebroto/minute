import SwiftUI
import AppKit
import Combine
import CoreSpotlight
import AVFoundation
import CoreAudio
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser
/// Where meetings are saved (chosen in setup, changeable in Settings). See Storage in Setup.swift.
var momRoot: URL { Storage.root }
let momCLI = home.appendingPathComponent(".mom/bin/mom").path

enum Mode: String, CaseIterable, Identifiable {
    case online = "Online", onsite = "Onsite"
    var id: String { rawValue }
    var hint: String { self == .online ? "Meeting audio + your mic" : "Room mic only" }
}

enum Phase: Equatable {
    case idle
    case recording
    case processing(String)   // step 1: transcribing, then drafting
    case transcript           // step 2: check what was heard
    case review               // step 3: edit the minutes
    case exporting(String)    // step 4
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

/// The one long-running pipeline job (transcribing or writing minutes) that the user can cancel.
final class MomJob: @unchecked Sendable {
    static let shared = MomJob()
    private let l = NSLock()
    private var process: Process?
    private var wasCancelled = false
    func set(_ p: Process) { l.lock(); process = p; wasCancelled = false; l.unlock() }
    func finish(_ p: Process) -> Bool { l.lock(); defer { l.unlock() }; if process === p { process = nil }; let c = wasCancelled; if c { wasCancelled = false }; return c }
    func cancel() { l.lock(); wasCancelled = process != nil; let p = process; l.unlock(); p?.terminate() }
}

/// Runs the `mom` pipeline, forwarding "STAGE:" lines. Returns (exit status, last output line). Exit status 130 means the user cancelled.
func runMom(_ args: [String], full: Bool = false, cancellable: Bool = false, stage: @escaping @Sendable (String) -> Void = { _ in }) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: momCLI)
        p.arguments = args
        p.qualityOfService = .utility   // heavy work runs behind the user's apps
        p.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }.merging(AIEngine.environment()) { $1 }
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
            let cancelled = cancellable && MomJob.shared.finish(p)
            cont.resume(returning: (cancelled ? 130 : p.terminationStatus, full ? tail.all.trimmingCharacters(in: .whitespacesAndNewlines) : tail.value))
        }
        if cancellable { MomJob.shared.set(p) }
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
    @Published var tLines: [TLine] = []
    @Published var screenEvents: [ScreenEvent] = []
    @Published var marks: [Mark] = []
    @Published var markFlash: MarkKind?
    @Published var micPaused = false
    static var muteGate: Bool {
        get { UserDefaults.standard.bool(forKey: "muteGate") }
        set { UserDefaults.standard.set(newValue, forKey: "muteGate") }
    }
    private var segLog: SegmentLog?
    private var lastSysRotate = Date.distantPast
    private var clockRestarts = 0
    private var micRotateWork: DispatchWorkItem?
    private var gateBag: AnyCancellable?
    private var gateWork: DispatchWorkItem?
    private var gateArmed = false
    @Published var workTitle = "Transcribing the recording"
    @Published var autoDraft: Bool = UserDefaults.standard.bool(forKey: "autoDraft") { didSet { UserDefaults.standard.set(autoDraft, forKey: "autoDraft") } }
    @Published var lastDir: URL? = Recorder.latestSession()
    @Published var unfinished: [URL] = []
    @Published var failedDir: URL?
    @Published var diagnosticsCopied = false
    private let screens = ScreenContext()
    private var tick = 0

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
        case .transcript: return 1
        case .review: return 2
        case .exporting, .done: return 3
        default: return 0
        }
    }

    static func latestSession() -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: momRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("MoM.json").path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Debug aid: MINUTE_DEMO=review|export|processing launches straight into that step with sample data.
    /// Test hook: MINUTE_DEMO=movetest exercises the library mover on scratch folders (never touches real settings).
    func moveTest() {
        let base = URL(fileURLWithPath: "/tmp/claude-501/movetest"); let fm = FileManager.default
        let old = base.appendingPathComponent("old"), new = base.appendingPathComponent("new")
        for n in ["2026-10-01_0900_a", "2026-10-02_1000_b", "2026-10-03_1100_c"] {
            try? fm.createDirectory(at: old.appendingPathComponent(n), withIntermediateDirectories: true)
            try? "x".write(to: old.appendingPathComponent(n + "/transcript.md"), atomically: true, encoding: .utf8)
        }
        try? fm.createDirectory(at: new.appendingPathComponent("2026-10-02_1000_b"), withIntermediateDirectories: true)   // name clash
        let mover = StorageMover()
        mover.change(to: new, from: old, commit: false) { ok in
            let l = { (u: URL) in ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted().joined(separator: ",") }
            try? "ok=\(ok) old=[\(l(old))] new=[\(l(new))] err=\(mover.error ?? "none") status=\(mover.status)\n".write(to: base.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

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
        case "transcript": tLines = TLine.parse(transcript); phase = .transcript
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
        let free = DiskGuard.freeBytes(at: momRoot)
        if free < DiskGuard.stopBytes {
            phase = .failed("Only \(DiskGuard.text(free)) is free where meetings are saved, which is not enough to record. Free some space or choose another folder in Settings."); return
        }
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
        started = Date(); elapsed = 0; tick = 0; marks = []
        clockRestarts = 0
        segLog = SegmentLog(dir: dir); segLog?.open("mic.caf", at: 0); if mode == .online { segLog?.open("system.caf", at: 0) }
        tap.onFormatChange = { [weak self] in self?.scheduleRotate(mic: false) }
        history = Array(repeating: 0, count: 36)
        Recovery.markStarted(dir)
        CalendarContext.writeContext(for: started, into: dir)
        if mode == .online { screens.begin(dir: dir) { [weak self] in self?.elapsed ?? 0 } }
        if free < DiskGuard.warnBytes { warning = "Low disk space: \(DiskGuard.text(free)) free. Long meetings may not fit." }
        watchDevices()
        startMuteGate()
        phase = .recording
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
                self.micLevel = self.mic.level.read(); self.sysLevel = self.tap.level.read()
                self.history.removeFirst(); self.history.append(max(self.micLevel, self.sysLevel))
                self.tick += 1
                if self.tick % 300 == 0, let dir = self.session {          // every 30 s: never let a full disk ruin a meeting
                    let free = DiskGuard.freeBytes(at: dir)
                    if free < DiskGuard.stopBytes { self.warning = "Disk full. Recording was stopped to keep what you have."; self.stop() }
                    else if free < DiskGuard.warnBytes { self.warning = "Low disk space: \(DiskGuard.text(free)) free." }
                }
                if self.tick % 20 == 0, self.mode == .online { self.checkSystemClock() }      // every 2 s
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
        (isMic ? micRotateWork : rotateWork)?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.rotate(mic: isMic) } }
        if isMic { micRotateWork = w } else { rotateWork = w }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// The meeting audio must arrive at the speed of the wall clock. If it does not (a headset switching to call mode changes the sample rate under the tap),
    /// start a fresh capture that reads the new format instead of recording unintelligible audio for the rest of the meeting.
    private func checkSystemClock() {
        guard isRecording, clockRestarts < 6, Date().timeIntervalSince(lastSysRotate) > 8 else { return }
        let st = tap.stats()
        if SegmentLog.isBroken(SegmentLog.drift(frames: st.frames, rate: st.rate, seconds: st.seconds)) {
            lastSysRotate = Date(); clockRestarts += 1; Stability.note("meeting audio clock off (\(st.frames) frames in \(Int(st.seconds)) s at \(Int(st.rate)) Hz): restarting capture")
            rotate(mic: false)
        }
    }

    private func rotate(mic isMic: Bool) {
        guard isRecording, let dir = session else { return }
        do {
            let now = elapsed
            if isMic {
                mic.stop(); segLog?.close(segURL(dir, "mic", micSeg).lastPathComponent, at: now)
                micSeg += 1; try mic.start(url: segURL(dir, "mic", micSeg)); segLog?.open(segURL(dir, "mic", micSeg).lastPathComponent, at: now)
                if micPaused { mic.setGated(true) }
            } else {
                tap.stop(); segLog?.close(segURL(dir, "system", sysSeg).lastPathComponent, at: now)
                sysSeg += 1; try tap.start(url: segURL(dir, "system", sysSeg)); segLog?.open(segURL(dir, "system", sysSeg).lastPathComponent, at: now)
            }
            warning = nil; Haptic.generic()
        } catch {
            warning = "Audio device changed and recording could not follow: \(error.localizedDescription)"
        }
    }

    /// Optional: while a meeting app has let go of the microphone (you are muted), your mic track is not kept. Only starts once the app was seen using the mic,
    /// so a meeting app that never releases it (or an unknown one) records as usual.
    private func startMuteGate() {
        gateBag = nil; gateWork?.cancel(); gateArmed = false; micPaused = false
        guard Self.muteGate, mode == .online else { return }
        gateBag = MeetingDetector.shared.$micActive.removeDuplicates().sink { [weak self] active in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.gateWork?.cancel()
                if active { self.gateArmed = true; self.mic.setGated(false); self.micPaused = false }
                else if self.gateArmed {
                    let w = DispatchWorkItem { [weak self] in self?.mic.setGated(true); self?.micPaused = true }   // short gaps while reconnecting stay recorded
                    self.gateWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
                }
            }
        }
    }

    /// Drops a flag at this moment; the minutes writer is told that what was said just before it matters.
    func addMark(_ kind: MarkKind) {
        guard isRecording, let dir = session else { return }
        marks.append(Mark(t: Int(elapsed), kind: kind)); Mark.save(marks, to: dir)
        Haptic.confirm(); markFlash = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in if self?.markFlash == kind { self?.markFlash = nil } }
    }

    func stop() {
        guard isRecording, let dir = session else { return }
        timer?.invalidate(); timer = nil
        unwatchDevices()
        gateBag = nil; gateWork?.cancel(); micPaused = false
        mic.stop(); tap.stop(); screens.end(); tap.onFormatChange = nil
        segLog?.closeAll(at: elapsed); segLog = nil
        Recovery.markFinished(dir)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        try? "\(mode.rawValue)\n".write(to: dir.appendingPathComponent("mode.txt"), atomically: true, encoding: .utf8)
        draft(dir)
    }

    /// Step 1: transcribe on this Mac, then slide to the transcript check (or straight on to the minutes if the user skips that step).
    func draft(_ dir: URL) {
        session = dir
        workTitle = "Transcribing the recording"
        phase = .processing("Starting…")
        Task {
            let (code, tail) = await runMom([dir.path, "--transcript-only"], cancellable: true) { s in Task { @MainActor in if case .processing = self.phase { self.phase = .processing(s) } } }
            if code == 0 {
                loadTranscript(dir)
                let env = ProcessInfo.processInfo.environment
                if autoDraft || env["MINUTE_AUTODRAFT"] != nil || env["MINUTE_AUTOEXPORT"] != nil { writeMinutes() }
                else { phase = .transcript; notify("Transcript ready", "Open Minute to check it, then write the minutes.") }
            } else if code == 130 {
                failedDir = dir
                phase = .failed("Stopped. Your recording is saved in \(dir.lastPathComponent); you can transcribe it again any time.")
            } else {
                failedDir = dir
                phase = .failed("Could not transcribe the recording: \(tail)\nYour audio is safe in \(dir.lastPathComponent).")
                notify("Minute failed", "Audio is saved. Open Minute for details.")
            }
        }
    }

    func loadTranscript(_ dir: URL) {
        session = dir
        transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        tLines = TLine.parse(transcript)
        screenEvents = ScreenEvent.load(from: dir); marks = Mark.load(from: dir)
    }

    /// Step 2 to 3: save the (possibly corrected) transcript and write the minutes from it.
    func writeMinutes() {
        guard let dir = session else { return }
        let text = TLine.serialize(tLines)
        do { try text.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        catch { phase = .failed("Could not save the transcript: \(error.localizedDescription)"); return }
        transcript = text
        workTitle = "Writing your minutes"
        phase = .processing("Starting…")
        Task {
            let (code, tail) = await runMom(["--draft", dir.path], cancellable: true) { s in Task { @MainActor in if case .processing = self.phase { self.phase = .processing(s) } } }
            if code == 0, loadDraft(dir) {
                phase = .review
                if ProcessInfo.processInfo.environment["MINUTE_AUTOEXPORT"] != nil { export() }   // test hook
                notify("Minutes drafted", "Open Minute to review and export.")
            } else if code == 130 {
                phase = .transcript
            } else {
                failedDir = dir
                phase = .failed("Could not write the minutes: \(tail)\nYour transcript is saved in \(dir.lastPathComponent).")
                notify("Minute failed", "The transcript is saved. Open Minute for details.")
            }
        }
    }

    // MARK: Cancel, retry, recovery, support

    func cancelProcessing() { MomJob.shared.cancel() }

    func retry() {
        guard let dir = failedDir ?? session else { return }
        failedDir = nil
        let tr = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        if tr.count > 100 { loadTranscript(dir); writeMinutes() } else { draft(dir) }
    }

    func checkUnfinished() { unfinished = Recovery.unfinished(in: momRoot, excluding: isRecording ? session : nil) }

    /// A recording that was cut short (crash, power loss): keep what was captured and carry on as if it had been stopped.
    func recover(_ dir: URL) {
        Recovery.markFinished(dir)
        unfinished.removeAll { $0 == dir }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent("mode.txt").path) {
            let m = fm.fileExists(atPath: dir.appendingPathComponent("system.caf").path) ? "Online" : "Onsite"
            try? "\(m)\n".write(to: dir.appendingPathComponent("mode.txt"), atomically: true, encoding: .utf8)
        }
        draft(dir)
    }

    func dismissUnfinished(_ dir: URL) { Recovery.markFinished(dir); unfinished.removeAll { $0 == dir } }

    func copyDiagnostics() {
        Task {
            let (_, out) = await runMom(["--diagnostics"] + [(failedDir ?? session)?.path].compactMap { $0 }, full: true)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(out, forType: .string)
            diagnosticsCopied = true
            try? await Task.sleep(nanoseconds: 2_500_000_000); diagnosticsCopied = false
        }
    }

    // MARK: Step 2 - review

    @discardableResult
    func loadDraft(_ dir: URL) -> Bool {
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent("MoM.json")),
              let d = try? JSONDecoder().decode(MoMData.self, from: raw) else { return false }
        session = dir
        apply(d)
        loadTranscript(dir)
        return true
    }

    private func apply(_ d: MoMData) {
        agenda = d.agenda; date = d.date; time = d.time
        telkNames = d.telkomsel_names.joined(separator: "\n"); telkUnit = d.telkomsel_unit
        tpNames = d.third_party_names.joined(separator: "\n"); tpCompany = d.third_party_company
        topics = d.topics.map { Topic(text: $0) }
    }

    /// Diagnostic: capture system audio for 4 s while a system sound plays and write the peak level to ~/.mom/selftest.txt.
    func selfTestSystemAudio() {
        let out = home.appendingPathComponent(".mom/selftest.txt")
        let t = SystemTap()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minute-selftest.caf")
        do { try t.start(url: url) } catch { try? "tap failed: \(error.localizedDescription)\n".write(to: out, atomically: true, encoding: .utf8); NSApp.terminate(nil); return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = ["/System/Library/Sounds/Glass.aiff"]; try? p.run()
        var peak: Float = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in peak = max(peak, t.level.read()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            t.stop()
            try? "peak level \(peak)\n".write(to: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
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
    var size: CGFloat = 92
    var showTitle = true
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @State private var ticker: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.clear.glass(Circle(), tint: tint.opacity(pressing ? 0.35 : 0.18), interactive: true)
                Circle().stroke(tint.opacity(0.22), lineWidth: size > 70 ? 4 : 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: size > 70 ? 4 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: size * 0.33, weight: .medium)).foregroundStyle(tint)
                    .scaleEffect(pressing && !reduceMotion ? 0.88 : 1)
                    .animation(.spring(duration: 0.3, bounce: 0.3), value: pressing)
            }
            .frame(width: size, height: size)
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
            if showTitle { Text(title).font(.callout).foregroundStyle(.secondary) }
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
            if r.micPaused {
                Label("Your mic is paused while you're muted in the meeting", systemImage: "mic.slash.fill").font(.caption).foregroundStyle(.secondary)
            }
            if let w = r.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(MarkKind.allCases, id: \.self) { k in
                    Button { r.addMark(k) } label: { Label(k.label, systemImage: r.markFlash == k ? "checkmark" : k.symbol).font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small).tint(k.tint).help("Flag this moment as \(k.label.lowercased()) (⌃⌥\(k.hotkey) from any app)")
                }
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
        case .transcript: return "Your transcript is ready to check"
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
    let titles = ["Record", "Transcript", "Minutes", "Export"]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<4) { i in
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
                if i < 3 {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var r: Recorder
    @State private var showTranscript = false

    var body: some View {
        ZStack {
            Group {
                switch r.step {
                case 0: StepRecord(r: r)
                case 1: StepTranscript(r: r)
                case 2: StepReview(r: r)
                default: StepExport(r: r)
                }
            }
            .id(r.step)
            .transition(.stepSlide(reduceMotion))
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
                if r.step == 2 {
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
                Text(r.workTitle).font(.title2.weight(.semibold))
                Text(s).foregroundStyle(.secondary).contentTransition(.opacity).animation(.default, value: s)
                Text("Everything stays on this Mac. You can close this window; you'll get a notification.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Cancel") { r.cancelProcessing() }.glassButton().controlSize(.large).padding(.top, 6)
            case .failed(let m):
                Hero(symbol: "exclamationmark.triangle", tint: .orange, title: "Something went wrong", subtitle: m)
                HStack(spacing: 10) {
                    Button { r.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise") }.glassButton(prominent: true)
                    Button { r.copyDiagnostics() } label: { Label(r.diagnosticsCopied ? "Copied" : "Copy Diagnostics", systemImage: r.diagnosticsCopied ? "checkmark" : "doc.on.doc") }.glassButton()
                    Button("OK") { r.reset() }.glassButton()
                }.controlSize(.large)
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
    func open(_ ext: String) { if let d = r.session, let f = exportedFile(in: d, ext: ext) { NSWorkspace.shared.open(f) } }
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
                            Button { open("docx") } label: { Label("Open Word", systemImage: "doc.text").frame(minWidth: 100) }.glassButton(prominent: true)
                            Button { open("pdf") } label: { Label("Open PDF", systemImage: "doc.richtext").frame(minWidth: 100) }.glassButton()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([exportedFile(in: d, ext: "pdf") ?? d]) } label: { Label("Show in Finder", systemImage: "folder") }.glassButton()
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

/// Opening the app again (Spotlight, Finder, `open`) shows the Meetings window, since a menu bar app has no Dock icon to click.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var showLibrary: (() -> Void)?
    static var isBusy: (() -> Bool)?
    static var openURL: ((URL) -> Void)?
    func applicationWillTerminate(_ notification: Notification) { Stability.cleanExit() }
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { AppDelegate.openURL?($0) } }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType, let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        AppDelegate.showLibrary?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .openMeeting, object: URL(fileURLWithPath: id)) }
        return true
    }
    /// Never lose a meeting to an accidental ⌘Q or Dock > Quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.isBusy?() == true else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Minute is recording or writing minutes"
        a.informativeText = "Quitting now would interrupt it. Your audio is saved as it is recorded, but the minutes would not be written."
        a.addButton(withTitle: "Keep Going"); a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.showLibrary?() }
        return true
    }
}

@main
struct MinuteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var r = Recorder()
    @StateObject private var lib = Library()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        // Pinned: the icon always stays in the menu bar. Dragging it out (or hiding it) is ignored, and it is re-inserted.
        MenuBarExtra(isInserted: Binding(get: { true }, set: { _ in })) {
            PanelView(r: r)
        } label: {
            Group {
                switch r.phase {
                case .recording:
                    HStack(spacing: 4) { Image(nsImage: redDot); Text(clock(r.elapsed)).monospacedDigit() }
                case .processing, .exporting: Image(systemName: "ellipsis.circle")
                case .review, .transcript: Image(systemName: "doc.text")
                default: Image(systemName: "waveform.circle")
                }
            }
            .onAppear {
                AppDelegate.showLibrary = { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
                AppDelegate.isBusy = { r.isRecording || r.isBusy }
                Stability.shared.start()
                AppDelegate.openURL = { url in Links.handle(url, r: r, showRecorder: { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) },
                                                            showLibrary: { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }) }
                FloatingControl.shared.openApp = { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }
                if ProcessInfo.processInfo.environment["MINUTE_DEMO"] == nil {
                    FloatingControl.shared.attach(r)
                    r.checkUnfinished()
                    openWindow(id: Storage.setupDone ? "library" : "setup"); NSApp.activate(ignoringOtherApps: true)   // first launch: setup; afterwards: the main window
                }
                if ProcessInfo.processInfo.environment["MINUTE_SELFTEST"] != nil { r.selfTestSystemAudio(); return }
                if ProcessInfo.processInfo.environment["MINUTE_DEMO"] == "movetest" { r.moveTest(); return }
                if let d = ProcessInfo.processInfo.environment["MINUTE_DEMO"] {
                    if d == "draft", let dir = ProcessInfo.processInfo.environment["MINUTE_DIR"] { r.draft(URL(fileURLWithPath: dir)) } else { r.demo(d) }
                    openWindow(id: d == "library" ? "library" : "minute"); NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Minute", id: "setup") { SetupView(r: r) }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)

        Settings { SettingsView(r: r, lib: lib) }

        Window("Minute", id: "library") { LibraryView(lib: lib, r: r) }
            .windowToolbarStyle(.unified)
            .defaultSize(width: 1440, height: 860)

        Window("New Minutes", id: "minute") { MainWindow(r: r) }
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
            .defaultSize(width: 860, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(r.isRecording ? "Stop Recording…" : "Start Recording…") { MinuteApp.confirmToggle(r) { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(r.isBusy)
                Divider()
                Button("All Meetings") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("l", modifiers: .command)
                Menu("Flag This Moment") {
                    ForEach(MarkKind.allCases, id: \.self) { k in Button(k.label) { r.addMark(k) } }
                }.disabled(!r.isRecording)
                Button("Current Recording") { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("What's New in Minute") { NotificationCenter.default.post(name: .showWhatsNew, object: nil); openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
                Button("Welcome Tour & Setup…") { openWindow(id: "setup"); NSApp.activate(ignoringOtherApps: true) }
                Button(r.diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") { r.copyDiagnostics() }
            }
        }
    }

    /// A deliberate menu or keyboard start/stop still asks first, so a stray shortcut can't begin or end a meeting.
    @MainActor static func confirmToggle(_ r: Recorder, then: () -> Void) {
        let a = NSAlert()
        a.alertStyle = r.isRecording ? .warning : .informational
        a.messageText = r.isRecording ? "Stop recording?" : "Start recording?"
        a.informativeText = r.isRecording ? "The recording is saved and the transcript is made next." : "Minute will record your microphone\(r.mode == .online ? " and the meeting audio" : "").\nOnly record with everyone's consent."
        a.addButton(withTitle: r.isRecording ? "Stop" : "Start")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { if r.isRecording { r.stop() } else { r.start() }; then() }
    }

    var redDot: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        img.isTemplate = false
        return img
    }
}
