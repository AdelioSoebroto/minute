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
    @Published var marks: [Mark] = []
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
        screenEvents = ScreenEvent.load(from: dir); marks = Mark.load(from: dir)
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
            if code == 0 { load() } else { error = tail }
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
    @State private var showAsk = false
    @State private var jump: JumpRequest?
    @State private var notice: String?
    @State private var narrow = false      // too narrow to show transcript and minutes side by side

    init(meeting: Meeting, lib: Library, r: Recorder, delete: @escaping () -> Void) {
        self.meeting = meeting; self.lib = lib; self.r = r; self.delete = delete
        _editor = StateObject(wrappedValue: MeetingEditor(dir: meeting.dir))
    }

    private var locked: Bool { editor.busy != nil || r.isBusy || r.isRecording }

    private var title: String { editor.agenda.isEmpty ? meeting.title : editor.agenda }
    private var subtitle: String {
        var s = "\(meeting.date.formatted(date: .complete, time: .shortened)) · \(meeting.status)"
        if let t = editor.savedAt { s += " · Saved \(t.formatted(date: .omitted, time: .shortened))" }
        return s
    }
    private var canAsk: Bool { !(editor.tLines.isEmpty && !editor.hasMinutes) }

    private func open(_ ext: String) { if let f = exportedFile(in: meeting.dir, ext: ext) { NSWorkspace.shared.open(f) } }
    private func toggleClaude() { withAnimation(.snappy) { showAsk.toggle() } }

    /// What the menu bar's File, View and Meeting menus act on while this meeting is in front.
    private var commands: MeetingCommands {
        MeetingCommands(view: narrow && mode == 0 ? 1 : mode, narrow: narrow, claudeShown: showAsk, canAsk: canAsk,
                        hasMinutes: editor.hasMinutes, hasTranscript: !editor.tLines.isEmpty, locked: locked,
                        hasDocx: meeting.hasDocx, hasPdf: meeting.hasPdf,
                        setView: { mode = $0 }, toggleClaude: toggleClaude,
                        export: { editor.exportAll { lib.refresh() } }, tidy: { editor.tidy { lib.refresh() } },
                        rewrite: { confirmRegenerate = true }, openFile: open,
                        finder: { NSWorkspace.shared.activateFileViewerSelecting([meeting.dir]) }, trash: delete)
    }

    var body: some View {
        GeometryReader { geo in
            let both = geo.size.width >= 940          // too narrow for both (e.g. with Claude open): show one at a time
            Group {
                if both && mode == 0 {
                    HSplitView {
                        transcriptPane.frame(minWidth: 340, idealWidth: 400)
                        minutesPane.frame(minWidth: 520)
                    }
                } else if mode == 2 { transcriptPane }
                else { minutesPane }
            }
            .onChange(of: both, initial: true) { _, b in narrow = !b }
        }
        .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showAsk) {
            AssistantPanel(editor: editor, close: toggleClaude, changed: { lib.refresh() })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .focusedSceneValue(\.meeting, commands)
        .onAppear { if editor.tLines.isEmpty && !editor.hasMinutes { editor.load() } }
        .onDisappear { editor.save() }
        .confirmationDialog("Rewrite the minutes from the transcript?", isPresented: $confirmRegenerate) {
            Button("Rewrite Minutes", role: .destructive) { editor.regenerate { lib.refresh() } }
        } message: { Text("Edits you made to the minutes are replaced. Your transcript corrections are used.") }
    }

    /// Progress and errors sit under the toolbar, like Mail's activity line, instead of in a custom button bar.
    @ViewBuilder private var statusBanner: some View {
        if let b = editor.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary); Spacer() }
                .padding(.horizontal, 16).padding(.vertical, 7).background(.bar)
        } else if let e = editor.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).font(.callout).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { editor.error = nil }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 7).background(.bar)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { narrow && mode == 0 ? 1 : mode }, set: { mode = $0 })) {
                if !narrow { Label("Transcript and Minutes", systemImage: "rectangle.split.2x1").tag(0) }
                Label("Minutes", systemImage: "doc.text").tag(1)
                Label("Transcript", systemImage: "text.bubble").tag(2)
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly)
            .help(narrow ? "Widen the window to see the transcript and minutes side by side" : "Choose what to show (⌘1, ⌘2, ⌘3)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if editor.hasMinutes { shareMenu }
            Menu {
                if editor.hasMinutes {
                    Button { editor.tidy { lib.refresh() } } label: { Label("Tidy Up Wording", systemImage: "wand.and.stars") }.disabled(locked)
                }
                if editor.hasMinutes && !editor.tLines.isEmpty {
                    Button { confirmRegenerate = true } label: { Label("Rewrite Minutes…", systemImage: "arrow.triangle.2.circlepath") }.disabled(locked)
                }
                Divider()
                if meeting.hasDocx { Button { open("docx") } label: { Label("Open in Word", systemImage: "doc.text") } }
                if meeting.hasPdf { Button { open("pdf") } label: { Label("Open PDF", systemImage: "doc.richtext") } }
                Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.dir]) } label: { Label("Show in Finder", systemImage: "folder") }
                Divider()
                Button(role: .destructive, action: delete) { Label("Move to Bin…", systemImage: "trash") }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .help("More actions")
            if editor.hasMinutes {
                Button { editor.exportAll { lib.refresh() } } label: { Label(meeting.hasPdf ? "Export Again" : "Export", systemImage: "arrow.up.doc") }
                    .disabled(locked).help("Make the Word document and PDF (⌘E)")
            }
            Button(action: toggleClaude) { Label("Claude", systemImage: "sparkles") }
                .disabled(!canAsk).help(showAsk ? "Hide Claude (⌘K)" : "Ask Claude about this meeting, or tell it what the minutes missed (⌘K)")
        }
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Transcript", systemImage: "text.alignleft").font(.callout.weight(.semibold))
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 10)
            TranscriptPane(lines: $editor.tLines, dir: meeting.dir, events: editor.screenEvents, marks: editor.marks, jump: jump)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var minutesPane: some View {
        if editor.hasMinutes {
            PaperDesk {
                MinutesPaper(agenda: $editor.agenda, date: $editor.date, time: $editor.time, telkNames: $editor.telkNames, telkUnit: $editor.telkUnit,
                             tpNames: $editor.tpNames, tpCompany: $editor.tpCompany, topics: $editor.topics, editable: true,
                             onJump: editor.tLines.isEmpty ? nil : { showWhere($0) })
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

    private func showWhere(_ text: String) {
        guard let i = TLine.bestMatch(for: text, in: editor.tLines) else { flashNotice("Couldn't find where this was said"); return }
        if mode == 1 || (narrow && mode == 0) { mode = 2 }
        jump = JumpRequest(id: editor.tLines[i].id)
    }

    private func flashNotice(_ s: String) {
        notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if notice == s { notice = nil } }
    }

    private func markdown(withTranscript: Bool = false) -> String {
        func l(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return ShareText.markdown(agenda: editor.agenda, date: editor.date, time: editor.time, internalNames: l(editor.telkNames), unit: editor.telkUnit,
                                  externalNames: l(editor.tpNames), company: editor.tpCompany,
                                  topics: editor.topics.map(\.text).filter { !$0.isEmpty }, transcript: withTranscript ? editor.tLines : [])
    }

    private func copy(_ s: String, _ msg: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); flashNotice(msg)
    }

    private func saveFile(_ name: String, _ text: String) {
        editor.save()
        let u = meeting.dir.appendingPathComponent(name)
        do { try text.write(to: u, atomically: true, encoding: .utf8); NSWorkspace.shared.activateFileViewerSelecting([u]) }
        catch { flashNotice("Couldn't save: \(error.localizedDescription)") }
    }

    private var shareMenu: some View {
        Menu {
            Button("Copy as Markdown") { copy(markdown(), "Copied as Markdown") }
            Button("Copy as plain text") { copy(ShareText.plain(markdown()), "Copied as plain text") }
            Button("Copy with transcript (Markdown)") { copy(markdown(withTranscript: true), "Copied with transcript") }
            Divider()
            Button("Save Markdown file") { saveFile("MoM.md", markdown(withTranscript: true)) }
            if !editor.tLines.isEmpty { Button("Save subtitles (.srt)") { saveFile("transcript.srt", TLine.srt(editor.tLines)) } }
            Divider()
            Button("Email the minutes…") {
                editor.save()
                var items: [Any] = [ShareText.plain(markdown())]
                if let pdf = exportedFile(in: meeting.dir, ext: "pdf") { items.append(pdf) }
                NSSharingService(named: .composeEmail)?.perform(withItems: items)
            }
        } label: { Label(notice ?? "Share", systemImage: notice == nil ? "square.and.arrow.up" : "checkmark") }
            .help(notice ?? "Copy, save or email the minutes")
    }

}


/// The actions of the meeting in front, for the menu bar (File > Export, View, Meeting).
struct MeetingCommands {
    var view: Int; var narrow: Bool; var claudeShown: Bool; var canAsk: Bool
    var hasMinutes: Bool; var hasTranscript: Bool; var locked: Bool; var hasDocx: Bool; var hasPdf: Bool
    var setView: (Int) -> Void; var toggleClaude: () -> Void
    var export: () -> Void; var tidy: () -> Void; var rewrite: () -> Void; var openFile: (String) -> Void
    var finder: () -> Void; var trash: () -> Void
}

struct MeetingCommandsKey: FocusedValueKey { typealias Value = MeetingCommands }
extension FocusedValues {
    var meeting: MeetingCommands? { get { self[MeetingCommandsKey.self] } set { self[MeetingCommandsKey.self] = newValue } }
}

struct MeetingMenus: Commands {
    @FocusedValue(\.meeting) private var m

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Export Word & PDF") { m?.export() }.keyboardShortcut("e").disabled(m?.hasMinutes != true || m?.locked == true)
        }
        CommandGroup(before: .toolbar) {
            Button("Transcript and Minutes") { m?.setView(0) }.keyboardShortcut("1").disabled(m == nil || m?.narrow == true)
            Button("Minutes") { m?.setView(1) }.keyboardShortcut("2").disabled(m == nil)
            Button("Transcript") { m?.setView(2) }.keyboardShortcut("3").disabled(m == nil)
            Divider()
            Button(m?.claudeShown == true ? "Hide Claude" : "Show Claude") { m?.toggleClaude() }.keyboardShortcut("k").disabled(m?.canAsk != true)
            Divider()
        }
        CommandMenu("Meeting") {
            Button("Tidy Up Wording") { m?.tidy() }.disabled(m?.hasMinutes != true || m?.locked == true)
            Button("Rewrite Minutes…") { m?.rewrite() }.disabled(m?.hasMinutes != true || m?.hasTranscript != true || m?.locked == true)
            Divider()
            Button("Open in Word") { m?.openFile("docx") }.disabled(m?.hasDocx != true)
            Button("Open PDF") { m?.openFile("pdf") }.disabled(m?.hasPdf != true)
            Button("Show in Finder") { m?.finder() }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(m == nil)
            Divider()
            Button("Move to Bin…") { m?.trash() }.keyboardShortcut(.delete, modifiers: .command).disabled(m == nil)
        }
    }
}
