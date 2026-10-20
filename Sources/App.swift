import SwiftUI
import AppKit
import AVFoundation
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
    private let l = NSLock(); private var v = ""
    var value: String { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

/// Runs the `mom` pipeline, forwarding "STAGE:" lines. Returns (exit status, last output line).
func runMom(_ args: [String], stage: @escaping @Sendable (String) -> Void) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: momCLI)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { $1 }
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let tail = Tail()
        out.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            for line in s.split(separator: "\n") {
                tail.value = String(line)
                if line.hasPrefix("STAGE:") { stage(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            cont.resume(returning: (p.terminationStatus, tail.value))
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
            try mic.start(url: dir.appendingPathComponent("mic.caf"))
            if mode == .online { try tap.start(url: dir.appendingPathComponent("system.caf")) }
        } catch {
            mic.stop(); tap.stop()
            phase = .failed(error.localizedDescription); return
        }
        session = dir
        started = Date(); elapsed = 0
        phase = .recording
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
                self.micLevel = self.mic.level.read(); self.sysLevel = self.tap.level.read()
            }
        }
    }

    func stop() {
        guard isRecording, let dir = session else { return }
        timer?.invalidate(); timer = nil
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
        agenda = d.agenda; date = d.date; time = d.time
        telkNames = d.telkomsel_names.joined(separator: "\n"); telkUnit = d.telkomsel_unit
        tpNames = d.third_party_names.joined(separator: "\n"); tpCompany = d.third_party_company
        topics = d.topics.map { Topic(text: $0) }
        transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        return true
    }

    func reviewLast() { if let d = Recorder.latestSession(), loadDraft(d) { phase = .review } }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func saveDraft() throws {
        guard let dir = session else { return }
        let d = MoMData(agenda: agenda, date: date, time: time, telkomsel_names: lines(telkNames), telkomsel_unit: telkUnit,
                        third_party_names: lines(tpNames), third_party_company: tpCompany,
                        topics: topics.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(d).write(to: dir.appendingPathComponent("MoM.json"))
    }

    // MARK: Step 3 - export

    func export() {
        guard let dir = session else { return }
        do { try saveDraft() } catch { phase = .failed("Could not save: \(error.localizedDescription)"); return }
        phase = .exporting("Filling the template…")
        Task {
            let (code, tail) = await runMom(["--export", dir.path]) { s in Task { @MainActor in if case .exporting = self.phase { self.phase = .exporting(s) } } }
            if code == 0 { phase = .done; lastDir = dir; notify("MoM ready", "Word and PDF saved in \(dir.lastPathComponent)") }
            else { phase = .failed("Export failed: \(tail)"); }
        }
    }

    func reset() { phase = .idle; lastDir = Recorder.latestSession() }
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

// MARK: - Shared components

/// Only fires after being held, so an accidental click can't start or stop anything.
struct HoldButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let seconds: Double
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                Circle().stroke(tint.opacity(0.2), lineWidth: 5)
                Circle().trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(tint)
                    .scaleEffect(pressing ? 0.9 : 1)
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: seconds, maximumDistance: 60, perform: {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                progress = 0; pressing = false; action()
            }, onPressingChanged: { down in
                pressing = down
                if down { withAnimation(.linear(duration: seconds)) { progress = 1 } }
                else { withAnimation(.easeOut(duration: 0.2)) { progress = 0 } }
            })
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LevelBar: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green).frame(width: max(4, g.size.width * CGFloat(min(1, level * 2.5))))
                        .animation(.easeOut(duration: 0.1), value: level)
                }
            }.frame(height: 5)
        }
    }
}

// MARK: - Menu bar panel (quick start / stop)

struct PanelView: View {
    @ObservedObject var r: Recorder
    @Environment(\.openWindow) private var openWindow

    func showWindow() { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }

    var body: some View {
        VStack(spacing: 16) {
            switch r.phase {
            case .idle: idle
            case .recording: recording
            default: busy
            }
            Divider()
            HStack {
                Button { NSWorkspace.shared.open(momRoot) } label: { Label("MoM folder", systemImage: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(r.isRecording || r.isBusy)
            }.font(.callout)
        }
        .padding(20).frame(width: 300)
    }

    var idle: some View {
        VStack(spacing: 16) {
            Picker("", selection: $r.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(r.mode.hint).font(.caption).foregroundStyle(.secondary).offset(y: -8)
            HoldButton(title: "Hold to start recording", symbol: "mic.fill", tint: .red, seconds: 0.8) { r.start() }
            if r.lastDir != nil {
                Button("Review last meeting") { r.reviewLast(); showWindow() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.callout)
            }
        }
    }

    var recording: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Recording · \(r.mode.rawValue)").font(.callout.weight(.medium))
            }
            Text(clock(r.elapsed)).font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            VStack(spacing: 6) {
                LevelBar(label: "Mic", level: r.micLevel)
                if r.mode == .online { LevelBar(label: "Meeting", level: r.sysLevel) }
            }
            HoldButton(title: "Hold to stop", symbol: "stop.fill", tint: .primary, seconds: 1.5) { r.stop(); showWindow() }
        }
    }

    var busy: some View {
        VStack(spacing: 12) {
            if r.isBusy { ProgressView() } else { Image(systemName: "doc.text").font(.title) }
            Text(statusText).font(.callout).multilineTextAlignment(.center)
            Button("Open Minute") { showWindow() }.buttonStyle(.borderedProminent)
            if case .failed = r.phase { Button("Dismiss") { r.reset() } }
            if r.phase == .done { Button("New recording") { r.reset() } }
        }
    }

    var statusText: String {
        switch r.phase {
        case .processing(let s): return "Step 1 · \(s)"
        case .review: return "Your minutes are ready to review"
        case .exporting(let s): return "Step 3 · \(s)"
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
        HStack(spacing: 0) {
            ForEach(0..<3) { i in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                        if i < step { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(i == step ? .white : .secondary) }
                    }
                    Text(titles[i]).font(.callout.weight(i == step ? .semibold : .regular)).foregroundStyle(i <= step ? .primary : .secondary)
                }
                if i < 2 {
                    Capsule().fill(i < step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 2)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.spring(duration: 0.5), value: step)
    }
}

struct MainWindow: View {
    @ObservedObject var r: Recorder

    var body: some View {
        VStack(spacing: 0) {
            StepBar(step: r.step).padding(.horizontal, 32).padding(.vertical, 18)
            Divider()
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
            .clipped()
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(.background)
    }
}

struct StepRecord: View {
    @ObservedObject var r: Recorder
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            switch r.phase {
            case .processing(let s):
                ProgressView().controlSize(.large)
                Text("Writing your minutes").font(.title2.weight(.semibold))
                Text(s).foregroundStyle(.secondary)
                Text("Everything stays on this Mac. You can close this window; you'll get a notification.")
                    .font(.caption).foregroundStyle(.tertiary)
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text(m).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("OK") { r.reset() }
            case .recording:
                Image(systemName: "record.circle").font(.system(size: 44)).foregroundStyle(.red)
                Text("Recording in progress").font(.title2.weight(.semibold))
                Text("Use the menu bar icon to stop.").foregroundStyle(.secondary)
            default:
                Image(systemName: "waveform.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Hold the record button in the menu bar to begin.").foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }
}

struct TextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 60
    var body: some View {
        TextEditor(text: $text).font(.body).scrollContentBackground(.hidden)
            .padding(6).frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct StepReview: View {
    @ObservedObject var r: Recorder
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        Text("Check the minutes").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Fix anything the transcript got wrong. Names and decisions are worth a second look.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Card(title: "Meeting") {
                            TextField("Agenda", text: $r.agenda).textFieldStyle(.roundedBorder)
                            HStack { TextField("Date", text: $r.date); TextField("Time", text: $r.time) }.textFieldStyle(.roundedBorder)
                        }
                        Card(title: "Participants · Telkomsel (one name per line)") {
                            TextArea(text: $r.telkNames, minHeight: 70)
                            TextField("Unit", text: $r.telkUnit).textFieldStyle(.roundedBorder)
                        }
                        Card(title: "Participants · 3rd party") {
                            TextArea(text: $r.tpNames, minHeight: 50)
                            TextField("Company", text: $r.tpCompany).textFieldStyle(.roundedBorder)
                        }
                        Card(title: "Topic discussed") {
                            ForEach(Array(r.topics.enumerated()), id: \.element.id) { i, t in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(i + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing).padding(.top, 8)
                                    TextArea(text: $r.topics[i].text, minHeight: 70)
                                    Button { withAnimation { _ = r.topics.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 8)
                                }
                            }
                            Button { withAnimation { r.topics.append(Topic(text: "")) } } label: { Label("Add topic", systemImage: "plus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        }
                    }.padding(24)
                }
                if showTranscript {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        ScrollView { Text(r.transcript.replacingOccurrences(of: "# Transcript\n\n", with: "")).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(16).frame(width: 300).background(.quaternary.opacity(0.3)).transition(.move(edge: .trailing))
                }
            }
            Divider()
            HStack {
                Toggle(isOn: $showTranscript.animation(.spring(duration: 0.4))) { Label("Transcript", systemImage: "text.alignleft") }
                    .toggleStyle(.button)
                Spacer()
                Button("Discard") { r.reset() }.foregroundStyle(.secondary)
                Button { r.export() } label: { Text("Create Word & PDF").frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
    }
}

struct StepExport: View {
    @ObservedObject var r: Recorder
    func open(_ name: String) { if let d = r.session { NSWorkspace.shared.open(d.appendingPathComponent(name)) } }
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if r.phase == .done, let d = r.session {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: r.phase)
                Text("Your minutes are ready").font(.title2.weight(.semibold))
                Text(d.path.replacingOccurrences(of: home.path, with: "~")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { open("MoM.docx") } label: { Label("Open Word", systemImage: "doc.text").frame(minWidth: 110) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { open("MoM.pdf") } label: { Label("Open PDF", systemImage: "doc.richtext").frame(minWidth: 110) }
                        .controlSize(.large)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([d.appendingPathComponent("MoM.pdf")]) } label: { Label("Show in Finder", systemImage: "folder") }
                        .controlSize(.large)
                }
                HStack(spacing: 18) {
                    Button("Edit again") { r.backToReview() }
                    Button("New recording") { r.reset() }
                }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                ProgressView().controlSize(.large)
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
    var body: some Scene {
        MenuBarExtra {
            PanelView(r: r)
        } label: {
            switch r.phase {
            case .recording:
                HStack(spacing: 4) { Image(nsImage: redDot); Text(clock(r.elapsed)).monospacedDigit() }
            case .processing, .exporting: Image(systemName: "ellipsis.circle")
            case .review: Image(systemName: "doc.text")
            default: Image(systemName: "waveform.circle")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Minute", id: "minute") { MainWindow(r: r) }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 820, height: 680)
    }

    var redDot: NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        img.isTemplate = false
        return img
    }
}
