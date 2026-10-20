import SwiftUI
import AppKit

// MARK: - What this Mac still needs (`mom --doctor`), with one-click installs

struct DoctorItem: Decodable, Identifiable, Equatable {
    let id: String, title: String, detail: String, ok: Bool
    let action: String?
    let size: Double
    var optional: Bool? = nil
    var needs_brew: Bool? = nil
    var blocked_by: String? = nil
    var sizeText: String { size < 0.05 ? "" : size < 1 ? "\(Int(size * 1000)) MB" : String(format: "%.1f GB", size) }
}

struct Doctor: Decodable {
    let chip: String, ram: Int, tier: String, model: String, brew: Bool, items: [DoctorItem]
}

@MainActor
final class Readiness: ObservableObject {
    @Published var report: Doctor?
    @Published var busy: String?          // id of the item being installed
    @Published var stage = ""
    @Published var error: String?

    var missing: [DoctorItem] { (report?.items ?? []).filter { !$0.ok && $0.optional != true } }
    var ready: Bool { report != nil && missing.isEmpty }

    func refresh() async {
        let (_, out) = await runMom(["--doctor"], full: true)
        if let line = out.split(separator: "\n").last(where: { $0.hasPrefix("DOCTOR ") }),
           let d = line.dropFirst(7).data(using: .utf8), let r = try? JSONDecoder().decode(Doctor.self, from: d) { report = r }
    }

    private func args(for item: DoctorItem) -> [String]? {
        switch item.action {
        case "tools": return ["--install-tools"]
        case "whisper": return ["--get-whisper"]
        case "llm": return ["--pull-model"]
        case "docx": return ["--install-docx"]
        default: return nil
        }
    }

    /// Installs one item. Returns false (with `error` set) when it failed.
    @discardableResult
    func install(_ item: DoctorItem) async -> Bool {
        guard busy == nil, let a = args(for: item) else { return false }
        busy = item.id; error = nil; stage = "Starting…"
        let (code, tail) = await runMom(a, full: false) { s in Task { @MainActor in self.stage = s } }
        busy = nil
        await refresh()
        if code != 0 { error = tail; return false }
        Haptic.confirm()
        return true
    }

    func installAll() async {
        // tools first (they provide ollama), then models
        for id in ["tools", "docx", "whisper", "llm"] {
            await refresh()
            guard let item = report?.items.first(where: { $0.id == id }), !item.ok else { continue }
            if !(await install(item)) { return }
        }
    }
}

struct ReadyStep: View {
    @StateObject private var rd = Readiness()
    var compact = false
    var onChange: (Bool) -> Void = { _ in }

    private var totalGB: Double { rd.missing.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = rd.report {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(r.chip), \(r.ram) GB").font(.body.weight(.medium))
                        Text("\(r.tier == "light" ? "Light" : "Standard") setup · \(r.model). Minute also eases off by itself on battery or when the Mac gets warm.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(spacing: 8) {
                    ForEach(r.items) { item in row(item, brew: r.brew) }
                }
                if !rd.missing.isEmpty {
                    HStack {
                        Text("Downloads once (about \(String(format: "%.1f", totalGB)) GB). After that Minute works fully offline.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await rd.installAll() } } label: { Text("Get everything").frame(minWidth: 110) }
                            .glassButton(prominent: true).controlSize(.large).disabled(rd.busy != nil)
                    }
                } else {
                    Label("Everything Minute needs is on this Mac.", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.green)
                }
                if let e = rd.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking this Mac…").foregroundStyle(.secondary) }
            }
        }
        .task { await rd.refresh(); onChange(rd.ready) }
        .onChange(of: rd.ready) { _, v in onChange(v) }
    }

    private func row(_ item: DoctorItem, brew: Bool) -> some View {
        let blocked = !item.ok && (item.blocked_by != nil || (item.needs_brew == true && !brew))
        return HStack(spacing: 12) {
            ZStack {
                if rd.busy == item.id { ProgressView().controlSize(.small) }
                else if item.ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if item.optional == true { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                else { Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor) }
            }.font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout.weight(.medium))
                Text(rd.busy == item.id ? rd.stage : (item.needs_brew == true && !brew && !item.ok ? "Needs Homebrew (brew.sh) to install." : item.detail))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !item.ok && item.action != nil {
                if !item.sizeText.isEmpty { Text(item.sizeText).font(.caption).foregroundStyle(.tertiary) }
                Button("Get") { Task { await rd.install(item) } }.glassButton().disabled(rd.busy != nil || blocked)
                    .help(blocked ? "Install the language engine first." : "")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9).glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Welcome page

struct WelcomePage: View {
    var next: () -> Void
    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            Text("Welcome to Minute").font(.system(size: 34, weight: .bold)).padding(.top, 18)
            Text("Meeting minutes that write themselves.").font(.title3).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 22) {
                feature("waveform.badge.mic", "Record any meeting", "Teams, Zoom, Meet or a meeting in the room. No bot joins, and nobody needs to record in Teams.")
                feature("lock.shield", "Private by design", "Recording, transcript and minutes are made on this Mac. Nothing is uploaded.")
                feature("text.badge.checkmark", "You stay in charge", "Check what was heard, edit the minutes, then export Word and PDF in your own template.")
            }
            .padding(.top, 34).frame(maxWidth: 430)
            Spacer(minLength: 10)
            Button { next() } label: { Text("Get Started").frame(width: 200) }
                .glassButton(prominent: true).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            Text("Only record with everyone's consent, and follow your company's policy.").font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
        }
        .padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: .infinity)
    }
}

// MARK: - Quick tour

struct TourPages: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var finish: () -> Void
    var back: () -> Void
    @State private var page = 0
    @State private var tried = false
    private let count = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: holdPage
                    case 1: transcriptPage
                    case 2: minutesPage
                    default: exportPage
                    }
                }
                .id(page)
                .transition(.stepSlide(reduceMotion))
            }
            .animation(.spring(duration: 0.5, bounce: 0.1), value: page)
            .clipped()
            HStack(spacing: 7) {
                ForEach(0..<count, id: \.self) { i in Circle().fill(i == page ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.25)).frame(width: 7, height: 7) }
            }.padding(.bottom, 16)
            HStack {
                Button("Back") { if page == 0 { back() } else { page -= 1 } }.glassButton().controlSize(.large)
                Spacer()
                if page < count - 1 { Button("Next") { page += 1 }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction) }
                else { Button("Start Using Minute") { finish() }.glassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction) }
            }.padding(.horizontal, 40).padding(.bottom, 32)
        }
    }

    private func page(_ title: String, _ text: String, @ViewBuilder art: () -> some View) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            art().frame(height: 210)
            Text(title).font(.system(size: 28, weight: .bold)).padding(.top, 8)
            Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer(minLength: 8)
        }.padding(.horizontal, 40).frame(maxWidth: .infinity)
    }

    private var holdPage: some View {
        page("Hold to record", "Press and hold the red button to start, and hold the stop button to finish. The hold keeps a stray click from ending your meeting.") {
            VStack(spacing: 14) {
                HoldButton(title: "Hold to try", symbol: tried ? "checkmark" : "mic.fill", tint: tried ? .green : .red, seconds: 0.8, size: 96, showTitle: false) {
                    withAnimation(.spring) { tried = true }
                }
                Text(tried ? "That's all it takes." : "Try it. Hold the button.").font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
                Label("Minute stays in your menu bar", systemImage: "menubar.rectangle").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var transcriptPage: some View {
        page("Check what was heard", "After a meeting you see the transcript first. Fix a misheard word, play any line, and Minute learns the names you correct.") {
            VStack(spacing: 8) {
                ForEach([("00:00:04", "You", "Besok kita kasih Teazzi ke tim sales ya.", Color.blue), ("00:00:19", "Others", "Siap, nanti saya follow up ke vendor.", Color.orange)], id: \.0) { t in
                    HStack(spacing: 8) {
                        Label(t.0, systemImage: "play.fill").labelStyle(.titleAndIcon).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(t.1).font(.caption.weight(.semibold)).foregroundStyle(t.3).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(t.3.opacity(0.14)))
                        Text(t.2).font(.callout)
                    }
                    .padding(12).frame(width: 440, alignment: .leading).glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var minutesPage: some View {
        page("Edit the minutes", "The minutes appear exactly as the document will look, in your template. Click anywhere on the page to edit.") {
            VStack(alignment: .leading, spacing: 8) {
                Text("MINUTES OF MEETING").font(.system(size: 11, weight: .bold)).frame(maxWidth: .infinity)
                ForEach(["Meeting Agenda", "Date", "Time"], id: \.self) { l in
                    HStack(spacing: 0) {
                        Text(l).font(.system(size: 10, weight: .bold)).frame(width: 90).padding(5).border(Color.black.opacity(0.5), width: 0.5)
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.15)).frame(height: 18).padding(5).frame(maxWidth: .infinity).border(Color.black.opacity(0.5), width: 0.5)
                    }
                }
                ForEach(0..<2, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text("\(i + 1).").font(.system(size: 10))
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.14)).frame(height: 18)
                    }
                }
            }
            .padding(16).frame(width: 360).background(RoundedRectangle(cornerRadius: 4).fill(.white))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
    }

    private var exportPage: some View {
        page("Export, and find it later", "One click makes the Word file and the PDF. Every meeting stays in All Meetings, where you can search any word and reopen the transcript beside the minutes.") {
            HStack(spacing: 18) {
                ForEach([("doc.text.fill", "Word"), ("doc.richtext.fill", "PDF")], id: \.0) { t in
                    VStack(spacing: 8) {
                        Image(systemName: t.0).font(.system(size: 54)).foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical)
                        Text(t.1).font(.callout.weight(.medium))
                    }.frame(width: 120, height: 130).glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 54)).foregroundStyle(.orange).symbolRenderingMode(.hierarchical)
                    Text("All Meetings").font(.callout.weight(.medium))
                }.frame(width: 140, height: 130).glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}
