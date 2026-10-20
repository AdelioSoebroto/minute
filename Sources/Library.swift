import SwiftUI
import AppKit
import CoreText

// MARK: - The page (a live preview of the Word document)

enum PaperAssets {
    /// The logo of the current template (~/.mom/logo.png, written when a template is set up). Nil when the template has none.
    private static var logoCache: (Date, NSImage?)?
    static var logo: NSImage? {
        let png = home.appendingPathComponent(".mom/logo.png")
        let m = (try? png.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let c = logoCache, c.0 == m { return c.1 }
        let img = NSImage(contentsOf: png)
        logoCache = (m, img)
        return img
    }
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
    var onJump: ((String) -> Void)? = nil

    private let w: CGFloat = 560
    @Environment(\.undoManager) private var undo
    private var prof: TemplateProfile { TemplateProfile.current }
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
            } else if !prof.org.isEmpty {
                Text(prof.org).font(PaperAssets.font(16, bold: true)).foregroundStyle(Color(red: 0.12, green: 0.23, blue: 0.37))
            }
            Text("MINUTES OF MEETING").font(PaperAssets.font(13, bold: true)).frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                row(prof.label("agenda", "Meeting Agenda")) { InlineField(placeholder: "Meeting agenda", text: $agenda, editable: editable) }
                row(prof.label("date", "Date")) { InlineField(placeholder: "Date", text: $date, editable: editable) }
                row(prof.label("time", "Time")) { InlineField(placeholder: "Time", text: $time, editable: editable) }
                Text(prof.label("participants", "List of Participants")).font(PaperAssets.font(12, bold: true)).frame(maxWidth: .infinity).padding(.vertical, 3)
                    .overlay(Rectangle().stroke(line, lineWidth: 0.6))
                bar(prof.label("internal", "Internal"))
                HStack(spacing: 0) {
                    cell(w / 4) { LinesField(text: $telkNames, editable: editable) }
                    cell(w / 4) { InlineField(placeholder: "Unit", text: $telkUnit, editable: editable) }
                    cell(w / 4) { Color.clear }
                    cell(w / 4) { Color.clear }
                }.fixedSize(horizontal: false, vertical: true)
                bar(prof.label("external", "External"))
                HStack(spacing: 0) {
                    cell(w / 2) { LinesField(text: $tpNames, editable: editable) }
                    cell(w / 4) { InlineField(placeholder: "Company", text: $tpCompany, editable: editable) }
                    cell(w / 4) { Color.clear }
                }.fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: w)

            Text(prof.label("topics", "Topics Discussed")).font(PaperAssets.font(12, bold: true)).padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(topics.enumerated()), id: \.element.id) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").font(PaperAssets.font(12)).frame(width: 22, alignment: .trailing)
                        if editable {
                            TextField("Describe the topic", text: $topics[i].text, axis: .vertical).textFieldStyle(.plain)
                                .font(PaperAssets.font(12)).padding(.horizontal, 6).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.07)))
                            if let jump = onJump {
                                Button { jump(t.text) } label: { Image(systemName: "text.quote").foregroundStyle(Color.accentColor) }
                                    .buttonStyle(.borderless).help("Show where this was said").accessibilityLabel("Show where topic \(i + 1) was said")
                            }
                            Button {
                                Haptic.tick()
                                let removed = topics[i], at = i, binding = $topics
                                withAnimation(.spring(duration: 0.3)) { _ = topics.remove(at: i) }
                                undo?.registerUndo(withTarget: UndoBox.shared) { _ in withAnimation { binding.wrappedValue.insert(removed, at: min(at, binding.wrappedValue.count)) } }
                                undo?.setActionName("Remove Topic")
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless).help("Remove topic").accessibilityLabel("Remove topic \(i + 1)")
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

/// The exported Word/PDF of a meeting: MOM_<name>_<yyyymmdd>.ext (older runs used MoM.ext).
func exportedFile(in dir: URL, ext: String) -> URL? {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.first { $0.pathExtension == ext && ($0.lastPathComponent.hasPrefix("MOM_") || $0.lastPathComponent == "MoM.\(ext)") }
}

@MainActor
final class Library: ObservableObject {
    @Published var meetings: [Meeting] = []

    /// Only folders whose files changed since the last refresh are read again, so a library of hundreds of meetings opens instantly.
    private var cache: [URL: (stamp: [Date], meeting: Meeting)] = [:]

    private func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }

    func refresh() {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let dirs = (try? fm.contentsOfDirectory(at: momRoot, includingPropertiesForKeys: nil)) ?? []
        var next: [URL: (stamp: [Date], meeting: Meeting)] = [:]
        for d in dirs {
            guard (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let date = f.date(from: String(d.lastPathComponent.prefix(15))) else { continue }
            let stamp = [mtime(d), mtime(d.appendingPathComponent("MoM.json")), mtime(d.appendingPathComponent("transcript.md"))]
            if let c = cache[d], c.stamp == stamp { next[d] = c; continue }
            let data = (try? Data(contentsOf: d.appendingPathComponent("MoM.json"))).flatMap { try? JSONDecoder().decode(MoMData.self, from: $0) }
            let tr = (try? String(contentsOf: d.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            next[d] = (stamp, Meeting(dir: d, date: date, data: data,
                                      hasDocx: exportedFile(in: d, ext: "docx") != nil, hasPdf: exportedFile(in: d, ext: "pdf") != nil,
                                      transcript: tr.replacingOccurrences(of: "# Transcript\n\n", with: "")))
        }
        cache = next
        meetings = next.values.map(\.meeting).sorted { $0.date > $1.date }
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
        VStack(alignment: .leading, spacing: 10) {
            switch r.phase {
            case .idle:
                Picker("Mode", selection: $r.mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    HoldButton(title: "Hold to record", symbol: "mic.fill", tint: .red, seconds: 0.8, size: 58, showTitle: false) { r.start() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to record").font(.callout.weight(.semibold))
                        Text(r.mode.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            case .recording:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Circle().fill(.red).frame(width: 7, height: 7); Text("Recording · \(r.mode.rawValue)").font(.caption.weight(.semibold)) }
                        Text(clock(r.elapsed)).font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    HoldButton(title: "Hold to stop", symbol: "stop.fill", tint: .primary, seconds: 1.5, size: 58, showTitle: false) { r.stop(); showFlow() }
                }
                Waveform(samples: r.history)
                if let w = r.warning {
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("Hold the stop button to finish").font(.caption).foregroundStyle(.secondary)
            default:
                HStack(spacing: 10) {
                    if r.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: r.phase == .done ? "checkmark.circle.fill" : "doc.text").foregroundStyle(r.phase == .done ? .green : .secondary) }
                    Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Open") { showFlow() }.glassButton(prominent: true)
                    if case .processing = r.phase { Button("Cancel") { r.cancelProcessing() }.glassButton() }
                    if case .failed = r.phase { Button("Dismiss") { r.reset() }.glassButton() }
                    if r.phase == .done { Button("New") { r.reset() }.glassButton() }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .animation(.spring(duration: 0.4), value: r.phase)
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

/// Always-visible "Saved in … Change" row at the bottom of the sidebar.
struct StorageFooter: View {
    var body: some View {
        SettingsLink {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved in").font(.caption2).foregroundStyle(.secondary)
                    Text(Storage.root.path.replacingOccurrences(of: home.path, with: "~")).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("Change…").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Change where meetings are saved. The whole library moves with it.")
    }
}

struct LibraryView: View {
    @ObservedObject var lib: Library
    @ObservedObject var r: Recorder
    @Environment(\.openWindow) private var openWindow
    @State private var selection: URL?
    @State private var query = ""
    @State private var confirmDelete: Meeting?

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
            ForEach(r.unfinished, id: \.self) { d in RecoveryCard(r: r, dir: d) }
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
            .safeAreaInset(edge: .bottom, spacing: 0) { StorageFooter() }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let m = lib.meetings.first(where: { $0.id == selection }) { detail(m) }
            else { ContentUnavailableView("Select a meeting", systemImage: "doc.text.magnifyingglass", description: Text("Its minutes and transcript appear here.")) }
        }
        .frame(minWidth: 1260, minHeight: 640)
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
        MeetingWorkspace(meeting: m, lib: lib, r: r) { confirmDelete = m }
            .id(m.id)
    }
}


/// Offered after a crash or power loss: the recording that was running is still on disk.
struct RecoveryCard: View {
    @ObservedObject var r: Recorder
    let dir: URL
    var when: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(dir.lastPathComponent.prefix(15))).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? dir.lastPathComponent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unfinished recording", systemImage: "exclamationmark.arrow.circlepath").font(.callout.weight(.semibold))
            Text("\(when) was cut short. The audio up to that point is safe.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Recover") { r.recover(dir) }.glassButton(prominent: true).disabled(r.isBusy || r.isRecording)
                Button("Not Now") { r.dismissUnfinished(dir) }.glassButton()
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color.orange.opacity(0.14))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}
