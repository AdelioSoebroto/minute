import SwiftUI
import AppKit

// MARK: - One past meeting, open for editing: transcript beside the minutes

@MainActor
final class MeetingEditor: ObservableObject {
    let dir: URL
    @Published var agenda = "" { didSet { touch() } }
    @Published var date = "" { didSet { touch() } }
    @Published var time = "" { didSet { touch() } }
    @Published var telkNames = "" { didSet { touch() } }
    @Published var telkUnit = "" { didSet { touch() } }
    @Published var tpNames = "" { didSet { touch() } }
    @Published var tpCompany = "" { didSet { touch() } }
    @Published var topics: [Topic] = [] { didSet { touch() } }
    @Published var tLines: [TLine] = [] { didSet { touch() } }
    @Published var hasMinutes = false
    @Published var screenEvents: [ScreenEvent] = []
    @Published var busy: String?
    @Published var error: String?
    @Published var savedAt: Date?
    private var loading = false
    private var saveTask: Task<Void, Never>?
    private var loadedTranscript = ""

    init(dir: URL) { self.dir = dir; load() }

    func load() {
        loading = true; defer { loading = false }
        let tr = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        tLines = TLine.parse(tr); loadedTranscript = TLine.serialize(tLines)
        screenEvents = ScreenEvent.load(from: dir)
        if let raw = try? Data(contentsOf: dir.appendingPathComponent("MoM.json")), let d = try? JSONDecoder().decode(MoMData.self, from: raw) {
            agenda = d.agenda; date = d.date; time = d.time
            telkNames = d.telkomsel_names.joined(separator: "\n"); telkUnit = d.telkomsel_unit
            tpNames = d.third_party_names.joined(separator: "\n"); tpCompany = d.third_party_company
            topics = d.topics.map { Topic(text: $0) }
            hasMinutes = true
        } else { hasMinutes = false }
    }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    /// Edits are saved shortly after the last keystroke, so nothing is lost and there is no Save button to forget.
    private func touch() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }

    func save() {
        saveTask?.cancel()
        do {
            if hasMinutes {
                let d = MoMData(agenda: agenda, date: date, time: time, telkomsel_names: lines(telkNames), telkomsel_unit: telkUnit,
                                third_party_names: lines(tpNames), third_party_company: tpCompany,
                                topics: topics.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try enc.encode(d).write(to: dir.appendingPathComponent("MoM.json"))
            }
            let t = TLine.serialize(tLines)
            if t != loadedTranscript && !tLines.isEmpty {
                try t.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
                loadedTranscript = t
            }
            savedAt = Date(); error = nil
        } catch { self.error = "Could not save: \(error.localizedDescription)" }
    }

    private func run(_ title: String, _ args: [String], then: @escaping () -> Void) {
        guard busy == nil else { return }
        save(); busy = title; error = nil
        Task {
            let (code, tail) = await runMom(args) { s in Task { @MainActor in self.busy = s + "…" } }
            busy = nil
            if code == 0 { load(); Haptic.confirm() } else { error = tail }
            then()
        }
    }

    func exportAll(then: @escaping () -> Void) { run("Exporting…", ["--export", dir.path], then: then) }
    func tidy(then: @escaping () -> Void) { run("Tidying…", ["--tidy", dir.path], then: then) }
    func regenerate(then: @escaping () -> Void) { run("Writing the minutes…", ["--draft", dir.path], then: then) }
}

struct MeetingWorkspace: View {
    let meeting: Meeting
    @ObservedObject var lib: Library
    @ObservedObject var r: Recorder
    var delete: () -> Void
    @StateObject private var editor: MeetingEditor
    @State private var mode = 0            // 0 both, 1 minutes, 2 transcript
    @State private var confirmRegenerate = false
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var showAsk = false

    init(meeting: Meeting, lib: Library, r: Recorder, delete: @escaping () -> Void) {
        self.meeting = meeting; self.lib = lib; self.r = r; self.delete = delete
        _editor = StateObject(wrappedValue: MeetingEditor(dir: meeting.dir))
    }

    private var locked: Bool { editor.busy != nil || r.isBusy || r.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let both = geo.size.width >= 940
                Group {
                    if both && mode == 0 {
                        HSplitView {
                            transcriptPane.frame(minWidth: 340, idealWidth: 400)
                            minutesPane.frame(minWidth: 600)
                        }
                    } else if mode == 2 { transcriptPane }
                    else { minutesPane }
                }
                .onChange(of: both) { _, b in if !b && mode == 0 { mode = 1 } }
            }
            Divider()
            footer
        }
        .onAppear { if editor.tLines.isEmpty && !editor.hasMinutes { editor.load() } }
        .onDisappear { editor.save() }
        .confirmationDialog("Write the minutes again?", isPresented: $confirmRegenerate) {
            Button("Replace the minutes", role: .destructive) { editor.regenerate { lib.refresh() } }
        } message: { Text("The minutes are rewritten from the transcript on the left. Edits you made to the minutes are replaced; your transcript corrections are used.") }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.agenda.isEmpty ? meeting.title : editor.agenda).font(.title2.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(meeting.date.formatted(date: .complete, time: .shortened)) · \(meeting.status)")
                    if let t = editor.savedAt { Text("· Saved \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary) }
                }.font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $mode) {
                Text("Both").tag(0); Text("Minutes").tag(1); Text("Transcript").tag(2)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Transcript", systemImage: "text.alignleft").font(.callout.weight(.semibold))
                Spacer()
                Button { withAnimation(.spring(duration: 0.3)) { showAsk.toggle() } } label: { Label("Ask", systemImage: "sparkles") }
                    .buttonStyle(.borderless).foregroundStyle(showAsk ? Color.accentColor : .secondary)
                    .disabled(editor.tLines.isEmpty).help("Ask a question about this meeting")
            }.padding(.horizontal, 16).padding(.top, 10)
            TranscriptPane(lines: $editor.tLines, dir: meeting.dir, events: editor.screenEvents)
            if showAsk { askBar }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var minutesPane: some View {
        if editor.hasMinutes {
            PaperDesk {
                MinutesPaper(agenda: $editor.agenda, date: $editor.date, time: $editor.time, telkNames: $editor.telkNames, telkUnit: $editor.telkUnit,
                             tpNames: $editor.tpNames, tpCompany: $editor.tpCompany, topics: $editor.topics, editable: true)
            }
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView("No minutes yet", systemImage: "doc.badge.ellipsis",
                                       description: Text(editor.tLines.isEmpty ? "Only the recording was saved." : "The transcript is ready; write the minutes from it."))
                if !editor.tLines.isEmpty {
                    Button("Write minutes from the transcript") { editor.regenerate { lib.refresh() } }
                        .glassButton(prominent: true).controlSize(.large).disabled(locked)
                } else if FileManager.default.fileExists(atPath: meeting.dir.appendingPathComponent("mic.caf").path) {
                    Button("Transcribe the recording") { r.draft(meeting.dir) }
                        .glassButton(prominent: true).controlSize(.large).disabled(locked)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 10) {
                if meeting.hasDocx { Button { if let f = exportedFile(in: meeting.dir, ext: "docx") { NSWorkspace.shared.open(f) } } label: { Label("Word", systemImage: "doc.text") }.glassButton() }
                if meeting.hasPdf { Button { if let f = exportedFile(in: meeting.dir, ext: "pdf") { NSWorkspace.shared.open(f) } } label: { Label("PDF", systemImage: "doc.richtext") }.glassButton() }
                Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.dir]) } label: { Label("Finder", systemImage: "folder") }.glassButton()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }.glassButton()
                if let b = editor.busy { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary) }
                else if let e = editor.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if editor.hasMinutes {
                    Button { editor.tidy { lib.refresh() } } label: { Label("Tidy up", systemImage: "sparkles") }.glassButton().disabled(locked)
                        .help("Fix spacing, punctuation and wording with the on-device model")
                }
                if !editor.tLines.isEmpty && editor.hasMinutes {
                    Button { confirmRegenerate = true } label: { Label("Rewrite minutes", systemImage: "arrow.triangle.2.circlepath") }.glassButton().disabled(locked)
                        .help("Write the minutes again from the (corrected) transcript")
                }
                if editor.hasMinutes {
                    Button { editor.exportAll { lib.refresh() } } label: { Text(meeting.hasPdf ? "Export again" : "Export Word & PDF").frame(minWidth: 120) }
                        .glassButton(prominent: true).disabled(locked)
                }
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !answer.isEmpty || asking {
                Group { if asking { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) } } else { Text(answer).textSelection(.enabled) } }
                    .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .glass(RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Ask about this meeting…", text: $question).textFieldStyle(.plain).onSubmit { ask() }
                if !question.isEmpty { Button { ask() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless).disabled(asking).accessibilityLabel("Ask") }
            }.padding(.horizontal, 14).padding(.vertical, 10).glass(Capsule(), interactive: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces); guard !q.isEmpty, !asking else { return }
        editor.save(); asking = true; answer = ""
        Task {
            let (code, out) = await runMom(["--ask", meeting.dir.path, q], full: true)
            answer = code == 0 ? out : "Couldn't answer: \(out)"
            asking = false
        }
    }
}
