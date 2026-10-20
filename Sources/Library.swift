import SwiftUI
import AppKit
import CoreText

// MARK: - The page (a live preview of the Word document)

enum PaperAssets {
    /// Pulls the logo out of the user's Word template once so the preview looks like the real document.
    static let logo: NSImage? = {
        let png = home.appendingPathComponent(".mom/logo.png")
        let docx = home.appendingPathComponent(".mom/template.docx")
        if !FileManager.default.fileExists(atPath: png.path), FileManager.default.fileExists(atPath: docx.path) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", docx.path, "word/media/image1.png"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            if (try? p.run()) != nil { let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); if !d.isEmpty { try? d.write(to: png) } }
        }
        return NSImage(contentsOf: png)
    }()
    /// Calibri ships inside Word, not the system; register it for this app so the page matches the document.
    static let fontsReady: Bool = {
        let dir = "/Applications/Microsoft Word.app/Contents/Resources/DFonts/"
        for f in ["Calibri.ttf", "Calibrib.ttf"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: dir + f) as CFURL, .process, nil)
        }
        return NSFont(name: "Calibri", size: 12) != nil
    }()
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        guard fontsReady else { return .system(size: size, weight: bold ? .bold : .regular) }
        return .custom(bold ? "Calibri-Bold" : "Calibri", size: size)
    }
}

/// Auto-sizing multi-line field for names (one per line).
struct LinesField: View {
    @Binding var text: String
    let editable: Bool
    var align: TextAlignment = .leading
    var body: some View {
        if editable {
            let n = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            TextEditor(text: $text).font(PaperAssets.font(12)).scrollContentBackground(.hidden)
                .multilineTextAlignment(align).frame(height: CGFloat(n) * 16 + 14).padding(.vertical, 2)
        } else {
            Text(text).font(PaperAssets.font(12)).multilineTextAlignment(align)
                .frame(maxWidth: .infinity, alignment: align == .center ? .center : .leading).padding(7)
        }
    }
}

struct InlineField: View {
    let placeholder: String
    @Binding var text: String
    let editable: Bool
    var center = true
    var body: some View {
        Group {
            if editable {
                TextField(placeholder, text: $text, axis: .vertical).textFieldStyle(.plain)
            } else {
                Text(text).frame(maxWidth: .infinity, alignment: center ? .center : .leading)
            }
        }
        .font(PaperAssets.font(12)).multilineTextAlignment(center ? .center : .leading)
        .padding(.horizontal, 7).padding(.vertical, 5)
    }
}

struct MinutesPaper: View {
    @Binding var agenda: String
    @Binding var date: String
    @Binding var time: String
    @Binding var telkNames: String
    @Binding var telkUnit: String
    @Binding var tpNames: String
    @Binding var tpCompany: String
    @Binding var topics: [Topic]
    let editable: Bool

    private let w: CGFloat = 560
    private let line = Color.black

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(label).font(PaperAssets.font(12, bold: true)).frame(width: 140).frame(maxHeight: .infinity)
                .overlay(Rectangle().stroke(line, lineWidth: 0.6))
            content().frame(maxWidth: .infinity).frame(maxHeight: .infinity).overlay(Rectangle().stroke(line, lineWidth: 0.6))
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func bar(_ s: String) -> some View {
        Text(s).font(PaperAssets.font(12, bold: true)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 7).padding(.vertical, 3).background(Color.black)
    }

    private func cell<C: View>(_ width: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content().frame(width: width).frame(maxHeight: .infinity, alignment: .top).overlay(Rectangle().stroke(line, lineWidth: 0.6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let logo = PaperAssets.logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 44).accessibilityHidden(true)
            }
            Text("MINUTES OF MEETING").font(PaperAssets.font(13, bold: true)).frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                row("Meeting Agenda") { InlineField(placeholder: "Meeting agenda", text: $agenda, editable: editable) }
                row("Date") { InlineField(placeholder: "Date", text: $date, editable: editable) }
                row("Time") { InlineField(placeholder: "Time", text: $time, editable: editable) }
                Text("List of Participants").font(PaperAssets.font(12, bold: true)).frame(maxWidth: .infinity).padding(.vertical, 3)
                    .overlay(Rectangle().stroke(line, lineWidth: 0.6))
                bar("Telkomsel:")
                HStack(spacing: 0) {
                    cell(w / 4) { LinesField(text: $telkNames, editable: editable) }
                    cell(w / 4) { InlineField(placeholder: "Unit", text: $telkUnit, editable: editable) }
                    cell(w / 4) { Color.clear }
                    cell(w / 4) { Color.clear }
                }.fixedSize(horizontal: false, vertical: true)
                bar("3rd party:")
                HStack(spacing: 0) {
                    cell(w / 2) { LinesField(text: $tpNames, editable: editable) }
                    cell(w / 4) { InlineField(placeholder: "Company", text: $tpCompany, editable: editable) }
                    cell(w / 4) { Color.clear }
                }.fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: w)

            Text("Topic Discussed:").font(PaperAssets.font(12, bold: true)).padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(topics.enumerated()), id: \.element.id) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").font(PaperAssets.font(12)).frame(width: 22, alignment: .trailing)
                        if editable {
                            TextField("Describe the topic", text: $topics[i].text, axis: .vertical).textFieldStyle(.plain)
                                .font(PaperAssets.font(12)).padding(.horizontal, 6).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.07)))
                            Button { Haptic.tick(); withAnimation(.spring(duration: 0.3)) { _ = topics.remove(at: i) } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless).help("Remove topic")
                        } else {
                            Text(t.text).font(PaperAssets.font(12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if editable {
                    Button { Haptic.tick(); withAnimation(.spring(duration: 0.3)) { topics.append(Topic(text: "")) } } label: {
                        Label("Add topic", systemImage: "plus.circle.fill").font(.callout)
                    }.buttonStyle(.borderless).padding(.leading, 30)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(40).frame(width: w + 80, alignment: .leading).frame(minHeight: 700, alignment: .top)
        .background(Color.white).foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }
}

/// Grey desk with the page centred on it, like a document viewer.
struct PaperDesk<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            content.padding(.vertical, 28).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .background(Color(nsColor: .underPageBackgroundColor))
        .softScrollEdges()
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let text: String
    var query = ""

    struct Line: Identifiable { let id = UUID(); let time: String; let who: String; let text: String }

    var lines: [Line] {
        text.split(separator: "\n").compactMap { raw -> Line? in
            let s = String(raw)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
            let time = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            return Line(time: time, who: String(rest[..<colon]),
                        text: String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    func tint(_ who: String) -> Color { who == "Me" ? .blue : who == "Others" ? .orange : .gray }

    var body: some View {
        let ls = lines
        if ls.isEmpty {
            ContentUnavailableView("No transcript", systemImage: "text.alignleft", description: Text("This recording has not been transcribed yet."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ls) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(l.time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 58, alignment: .leading)
                            Text(l.who).font(.caption.weight(.semibold)).foregroundStyle(tint(l.who))
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(tint(l.who).opacity(0.12)))
                                .frame(width: 66, alignment: .leading)
                            Text(l.text).font(.body).textSelection(.enabled)
                                .opacity(query.isEmpty || l.text.localizedCaseInsensitiveContains(query) ? 1 : 0.4)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Library of past meetings

struct Meeting: Identifiable, Hashable {
    let dir: URL
    var id: URL { dir }
    var date: Date
    var data: MoMData?
    var hasDocx: Bool
    var hasPdf: Bool
    var transcript: String
    var title: String { (data?.agenda.isEmpty == false ? data?.agenda : nil) ?? "Untitled meeting" }
    var status: String { hasPdf ? "Exported" : data != nil ? "Draft" : transcript.isEmpty ? "Audio only" : "Transcribed" }
    static func == (a: Meeting, b: Meeting) -> Bool { a.dir == b.dir && a.hasPdf == b.hasPdf && a.date == b.date && a.title == b.title }
    func hash(into h: inout Hasher) { h.combine(dir) }
}

@MainActor
final class Library: ObservableObject {
    @Published var meetings: [Meeting] = []

    func refresh() {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let dirs = (try? fm.contentsOfDirectory(at: momRoot, includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.compactMap { d in
            guard (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let date = f.date(from: String(d.lastPathComponent.prefix(15))) else { return nil }
            let data = (try? Data(contentsOf: d.appendingPathComponent("MoM.json"))).flatMap { try? JSONDecoder().decode(MoMData.self, from: $0) }
            let tr = (try? String(contentsOf: d.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            return Meeting(dir: d, date: date, data: data,
                           hasDocx: fm.fileExists(atPath: d.appendingPathComponent("MoM.docx").path),
                           hasPdf: fm.fileExists(atPath: d.appendingPathComponent("MoM.pdf").path),
                           transcript: tr.replacingOccurrences(of: "# Transcript\n\n", with: ""))
        }.sorted { $0.date > $1.date }
    }

    func trash(_ m: Meeting) {
        NSWorkspace.shared.recycle([m.dir]) { _, _ in Task { @MainActor in self.refresh() } }
    }
}

/// Record controls inside the main window, so recording does not depend on the menu bar.
struct RecordCard: View {
    @ObservedObject var r: Recorder
    @Environment(\.openWindow) private var openWindow
    func showFlow() { openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }

    var body: some View {
        VStack(spacing: 12) {
            switch r.phase {
            case .idle:
                Picker("Mode", selection: $r.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                HoldButton(title: "Hold to record · \(r.mode.hint.lowercased())", symbol: "mic.fill", tint: .red, seconds: 0.8) { r.start() }
            case .recording:
                HStack(spacing: 6) { Circle().fill(.red).frame(width: 7, height: 7); Text("Recording · \(r.mode.rawValue)").font(.callout.weight(.semibold)) }
                Text(clock(r.elapsed)).font(.system(size: 36, weight: .light, design: .rounded)).monospacedDigit()
                Waveform(samples: r.history)
                if let w = r.warning {
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HoldButton(title: "Hold to stop", symbol: "stop.fill", tint: .primary, seconds: 1.5) { r.stop(); showFlow() }
            default:
                if r.isBusy { ProgressView() } else { Image(systemName: r.phase == .done ? "checkmark.circle.fill" : "doc.text").font(.title2).foregroundStyle(r.phase == .done ? .green : .secondary) }
                Text(statusText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open") { showFlow() }.glassButton(prominent: true)
                if case .failed = r.phase { Button("Dismiss") { r.reset() }.buttonStyle(.borderless) }
                if r.phase == .done { Button("New recording") { r.reset() }.buttonStyle(.borderless) }
            }
        }
        .padding(14).frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .animation(.spring(duration: 0.4), value: r.phase)
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

struct LibraryView: View {
    @ObservedObject var lib: Library
    @ObservedObject var r: Recorder
    @Environment(\.openWindow) private var openWindow
    @State private var selection: URL?
    @State private var query = ""
    @State private var tab = 0
    @State private var confirmDelete: Meeting?
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false

    var filtered: [Meeting] {
        guard !query.isEmpty else { return lib.meetings }
        return lib.meetings.filter { m in
            m.title.localizedCaseInsensitiveContains(query) || m.transcript.localizedCaseInsensitiveContains(query)
                || (m.data?.topics.contains { $0.localizedCaseInsensitiveContains(query) } ?? false)
                || (m.data?.telkomsel_names.contains { $0.localizedCaseInsensitiveContains(query) } ?? false)
        }
    }

    func bucket(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let w = cal.dateInterval(of: .weekOfYear, for: Date()), w.contains(d) { return "This week" }
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }

    var groups: [(String, [Meeting])] {
        var order: [String] = []; var dict: [String: [Meeting]] = [:]
        for m in filtered { let b = bucket(m.date); if dict[b] == nil { order.append(b) }; dict[b, default: []].append(m) }
        return order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            RecordCard(r: r)
            List(selection: $selection) {
                ForEach(groups, id: \.0) { name, items in
                    Section(name) { ForEach(items) { m in row(m).tag(m.id) } }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search meetings and transcripts")
            .overlay {
                if lib.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Record one from the menu bar."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let m = lib.meetings.first(where: { $0.id == selection }) { detail(m) }
            else { ContentUnavailableView("Select a meeting", systemImage: "doc.text.magnifyingglass", description: Text("Its minutes and transcript appear here.")) }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            lib.refresh(); if selection == nil { selection = lib.meetings.first?.id }
            AppDelegate.showLibrary = { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
            AppDelegate.isBusy = { r.isRecording || r.isBusy }
        }
        .onChange(of: r.phase) { _, _ in lib.refresh() }
        .confirmationDialog("Move this meeting to the Bin?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { m in
            Button("Move to Bin", role: .destructive) { lib.trash(m); selection = nil }
        } message: { m in Text("“\(m.title)” — recording, transcript and minutes. You can restore it from the Bin.") }
    }

    func row(_ m: Meeting) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.hasPdf ? "doc.text.fill" : m.data != nil ? "pencil.line" : "waveform")
                .foregroundStyle(m.hasPdf ? Color.accentColor : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).lineLimit(1).font(.body.weight(.medium))
                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.dir]) }
            Button("Move to Bin…", role: .destructive) { confirmDelete = m }
        }
    }

    @ViewBuilder func detail(_ m: Meeting) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title).font(.title2.weight(.semibold)).lineLimit(2)
                    Text("\(m.date.formatted(date: .complete, time: .shortened)) · \(m.status)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) { Text("Minutes").tag(0); Text("Transcript").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            Group {
                if tab == 0 { minutes(m) } else { VStack(spacing: 0) { TranscriptView(text: m.transcript, query: query); if !m.transcript.isEmpty { askBar(m) } } }
            }
            Divider()
            GlassGroup(spacing: 12) { HStack(spacing: 10) {
                if m.hasDocx { Button { NSWorkspace.shared.open(m.dir.appendingPathComponent("MoM.docx")) } label: { Label("Word", systemImage: "doc.text") }.glassButton() }
                if m.hasPdf { Button { NSWorkspace.shared.open(m.dir.appendingPathComponent("MoM.pdf")) } label: { Label("PDF", systemImage: "doc.richtext") }.glassButton() }
                Button { NSWorkspace.shared.activateFileViewerSelecting([m.dir]) } label: { Label("Finder", systemImage: "folder") }.glassButton()
                Spacer()
                Button(role: .destructive) { confirmDelete = m } label: { Label("Delete", systemImage: "trash") }.glassButton()
                if m.data != nil {
                    Button { edit(m) } label: { Text(m.hasPdf ? "Edit & re-export" : "Review & export") }
                        .glassButton(prominent: true).disabled(r.isBusy || r.isRecording)
                }
            } }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .id(m.id)
        .onChange(of: selection) { _, _ in answer = ""; question = "" }
    }

    func askBar(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !answer.isEmpty || asking {
                Group { if asking { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) } } else { Text(answer).textSelection(.enabled) } }
                    .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .glass(RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Ask about this meeting…", text: $question).textFieldStyle(.plain).onSubmit { ask(m) }
                if !question.isEmpty { Button { ask(m) } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless).disabled(asking) }
            }.padding(.horizontal, 14).padding(.vertical, 10).glass(Capsule(), interactive: true)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    func ask(_ m: Meeting) {
        let q = question.trimmingCharacters(in: .whitespaces); guard !q.isEmpty, !asking else { return }
        asking = true; answer = ""
        Task {
            let (code, out) = await runMom(["--ask", m.dir.path, q], full: true)
            answer = code == 0 ? out : "Couldn't answer: \(out)"
            asking = false
        }
    }

    @ViewBuilder func minutes(_ m: Meeting) -> some View {
        if let d = m.data {
            PaperDesk {
                MinutesPaper(agenda: .constant(d.agenda), date: .constant(d.date), time: .constant(d.time),
                             telkNames: .constant(d.telkomsel_names.joined(separator: "\n")), telkUnit: .constant(d.telkomsel_unit),
                             tpNames: .constant(d.third_party_names.joined(separator: "\n")), tpCompany: .constant(d.third_party_company),
                             topics: .constant(d.topics.map { Topic(text: $0) }), editable: false)
            }
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView("No minutes yet", systemImage: "doc.badge.ellipsis",
                                       description: Text(m.transcript.isEmpty ? "Only the recording was saved." : "The transcript is ready; the minutes were not drafted."))
                Button("Draft minutes") { r.draft(m.dir); openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(r.isBusy || r.isRecording || !FileManager.default.fileExists(atPath: m.dir.appendingPathComponent("mic.caf").path))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func edit(_ m: Meeting) {
        guard r.loadDraft(m.dir) else { return }
        r.phase = .review
        openWindow(id: "minute"); NSApp.activate(ignoringOtherApps: true)
    }
}
