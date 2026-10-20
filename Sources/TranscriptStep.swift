import SwiftUI
import AVFoundation

// MARK: - Play the recording from a line (mic and meeting audio together, like the meeting sounded)

@MainActor
final class Playback: ObservableObject {
    @Published var playingID: UUID?
    private var players: [AVAudioPlayer] = []
    private var stopTimer: Timer?

    /// Only the first audio segment lines up with the transcript clock, so playback is offered when there is a single segment.
    static func available(in dir: URL?) -> Bool {
        guard let dir else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("mic.caf").path) && !fm.fileExists(atPath: dir.appendingPathComponent("mic_2.caf").path)
    }

    func toggle(_ line: TLine, next: TLine?, in dir: URL?) {
        if playingID == line.id { stop(); return }
        stop()
        guard let dir else { return }
        players = ["mic", "system"].compactMap { n in
            let u = dir.appendingPathComponent(n + ".caf")
            return FileManager.default.fileExists(atPath: u.path) ? try? AVAudioPlayer(contentsOf: u) : nil
        }
        guard !players.isEmpty else { return }
        let start = max(0, line.seconds - 0.3)
        let t0 = players[0].deviceCurrentTime + 0.1
        for p in players { p.currentTime = start; p.prepareToPlay(); p.play(atTime: t0) }
        playingID = line.id
        let length = next.map { max(3, $0.seconds - line.seconds + 0.5) } ?? 25
        stopTimer = Timer.scheduledTimer(withTimeInterval: min(length, 60), repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    func stop() {
        stopTimer?.invalidate(); stopTimer = nil
        players.forEach { $0.stop() }; players = []; playingID = nil
    }
}

// MARK: - The transcript list: search, play, edit, remove (used by the recording flow and by past meetings)

/// Lets Edit > Undo bring back a deleted line or topic.
final class UndoBox: NSObject { static let shared = UndoBox() }

struct JumpRequest: Equatable { let id: UUID; let token = UUID() }

struct TranscriptPane: View {
    @Binding var lines: [TLine]
    let dir: URL?
    var events: [ScreenEvent] = []
    var marks: [Mark] = []
    var jump: JumpRequest? = nil
    @State private var flash: UUID?
    @StateObject private var playback = Playback()
    @Environment(\.undoManager) private var undo
    @State private var query = ""
    @State private var copied = false
    @State private var naming: (id: UUID, all: Bool)?
    @State private var nameField = ""
    @State private var expanded: Set<UUID> = []
    private var invitees: [String] {
        guard let dir, let d = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (j["attendees"] as? [String]) ?? []
    }

    private var words: Int { lines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    private func tint(_ who: String) -> Color { who == "Me" ? .blue : who == "Others" ? .orange : who == "Speaker" ? .gray : .purple }
    private func matches(_ l: TLine) -> Bool { query.isEmpty || l.text.localizedCaseInsensitiveContains(query) || l.speaker.localizedCaseInsensitiveContains(query) }

    private enum Item: Identifiable { case line(UUID), screen(ScreenEvent), mark(Mark)
        var id: UUID { switch self { case .line(let i): return i; case .screen(let e): return e.id; case .mark(let m): return m.id } } }

    /// The transcript with shown-on-screen moments slotted in by time.
    private var items: [Item] {
        var out: [Item] = []; var pending = events.sorted { $0.t < $1.t }; var flags = marks.sorted { $0.t < $1.t }
        for l in lines {
            while let e = pending.first, Double(e.t) <= l.seconds { out.append(.screen(e)); pending.removeFirst() }
            while let m = flags.first, Double(m.t) <= l.seconds { out.append(.mark(m)); flags.removeFirst() }
            out.append(.line(l.id))
        }
        out += pending.map { .screen($0) }
        out += flags.map { .mark($0) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search the transcript", text: $query).textStyle()
                    if !query.isEmpty {
                        Text("\(lines.filter(matches).count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7).glass(Capsule())
                Text("\(words) words").font(.caption).foregroundStyle(.secondary).fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TLine.serialize(lines), forType: .string)
                    Haptic.tick(); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.glassButton().help("Copy the transcript").accessibilityLabel("Copy the transcript")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if lines.isEmpty {
                ContentUnavailableView("Nothing was heard", systemImage: "waveform.slash",
                                       description: Text("The recording had no speech Minute could pick up. Check the microphone, and for online meetings that the meeting audio was playing."))
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            switch item {
                            case .line(let id):
                                if let i = lines.firstIndex(where: { $0.id == id }) { row($lines[i]) }
                            case .screen(let e): screenRow(e)
                            case .mark(let m): markRow(m)
                            }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }
                .softScrollEdges()
                .onChange(of: jump) { _, j in
                    guard let j, let i = lines.firstIndex(where: { $0.id == j.id }) else { return }
                    query = ""
                    withAnimation(.spring(duration: 0.4)) { proxy.scrollTo(j.id, anchor: .center); flash = j.id }
                    if Playback.available(in: dir), playback.playingID != j.id { playback.toggle(lines[i], next: i + 1 < lines.count ? lines[i + 1] : nil, in: dir) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if flash == j.id { withAnimation { flash = nil } } }
                }
                }
            }
        }
        .onDisappear { playback.stop() }
        .alert(naming?.all == true ? "Rename every line from this speaker" : "Who is speaking?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Set") { applyName(nameField) }
        } message: { Text("Names are used in the minutes to say who is responsible for what.") }
    }

    func stopPlayback() { playback.stop() }

    private func applyName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard let n = naming, !name.isEmpty, let line = lines.first(where: { $0.id == n.id }) else { naming = nil; return }
        let old = line.who
        for i in lines.indices where n.all ? lines[i].who == old : lines[i].id == n.id { lines[i].who = name }
        naming = nil
    }

    private func setWho(_ who: String, for id: UUID) { if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].who = who } }

    private func speakerMenu(_ line: TLine) -> some View {
        let known = Array(Set(lines.map(\.who))).filter { !["Me", "Others", "Speaker"].contains($0) }.sorted()
        let invited = invitees.filter { n in !known.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
        let names = known
        return Menu {
            Section("This line") {
                Button("You") { setWho("Me", for: line.id) }
                Button("Others") { setWho("Others", for: line.id) }
                ForEach(names, id: \.self) { n in Button(n) { setWho(n, for: line.id) } }
                if !invited.isEmpty {
                    Divider()
                    Section("Invited") { ForEach(invited, id: \.self) { n in Button(n) { setWho(n, for: line.id) } } }
                }
                Button("New name…") { nameField = ""; naming = (line.id, false) }
            }
            Divider()
            Button("Rename every “\(line.speaker)” line…") { nameField = line.who == "Others" ? "" : line.speaker; naming = (line.id, true) }
        } label: {
            Text(line.speaker).font(.caption.weight(.semibold)).foregroundStyle(tint(line.who)).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(tint(line.who).opacity(0.12)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width: 66, alignment: .leading)
        .help("Say who is speaking").accessibilityLabel("Speaker \(line.speaker). Change speaker")
    }

    private func markRow(_ m: Mark) -> some View {
        HStack(spacing: 8) {
            Image(systemName: m.kind.symbol).foregroundStyle(m.kind.tint).frame(width: 70, alignment: .leading).accessibilityHidden(true)
            Text("You flagged this as \(m.kind.label.lowercased()) · \(m.time)").font(.caption.weight(.semibold)).foregroundStyle(m.kind.tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(m.kind.tint.opacity(0.10)))
        .accessibilityLabel("Flag at \(m.time): \(m.kind.label)")
    }

    private func screenRow(_ e: ScreenEvent) -> some View {
        let open = expanded.contains(e.id)
        return Button { if open { expanded.remove(e.id) } else { expanded.insert(e.id) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.teal).frame(width: 70, alignment: .leading).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("On screen · \(e.time)").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    Text(e.text).font(.caption).foregroundStyle(.secondary).lineLimit(open ? nil : 2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.teal.opacity(0.08)))
        }
        .buttonStyle(.plain).accessibilityLabel("Screen at \(e.time): \(e.text)").accessibilityHint(open ? "Collapse" : "Expand")
    }

    private func row(_ l: Binding<TLine>) -> some View {
        let line = l.wrappedValue
        let idx = lines.firstIndex { $0.id == line.id } ?? 0
        let next = idx + 1 < lines.count ? lines[idx + 1] : nil
        let canPlay = Playback.available(in: dir)
        return HStack(alignment: .top, spacing: 8) {
            Button { Haptic.tick(); playback.toggle(line, next: next, in: dir) } label: {
                HStack(spacing: 4) {
                    Image(systemName: playback.playingID == line.id ? "pause.fill" : "play.fill").font(.system(size: 9))
                    Text(line.time).font(.caption.monospacedDigit())
                }
                .foregroundStyle(playback.playingID == line.id ? Color.accentColor : .secondary)
                .frame(width: 70, alignment: .leading)
            }
            .buttonStyle(.plain).disabled(!canPlay).help(canPlay ? "Play from here" : "")
            .accessibilityLabel(canPlay ? "Play from \(line.time)" : "Time \(line.time)")
            speakerMenu(line)
            TextField("", text: l.text, axis: .vertical).textStyle().font(.callout).accessibilityLabel("Transcript, \(line.speaker), \(line.time)")
            Button { remove(line) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless).help("Remove this line").accessibilityLabel("Remove this line")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(flash == line.id ? Color.orange.opacity(0.22) : playback.playingID == line.id ? Color.accentColor.opacity(0.10) : (query.isEmpty || !matches(line) ? Color.clear : Color.yellow.opacity(0.22))))
        .opacity(matches(line) ? 1 : 0.35)
    }

    private func remove(_ line: TLine) {
        guard let at = lines.firstIndex(where: { $0.id == line.id }) else { return }
        Haptic.tick()
        withAnimation(.spring(duration: 0.3)) { _ = lines.remove(at: at) }
        let binding = $lines
        undo?.registerUndo(withTarget: UndoBox.shared) { _ in withAnimation { binding.wrappedValue.insert(line, at: min(at, binding.wrappedValue.count)) } }
        undo?.setActionName("Remove Line")
    }
}

private extension View {
    func textStyle() -> some View { self.textFieldStyle(.plain) }
}

// MARK: - Step 2: check what was heard

struct StepTranscript: View {
    @ObservedObject var r: Recorder

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check what was heard").font(.title2.weight(.semibold))
                Text("This is the transcript the minutes are written from. Fix any word that was misheard, remove lines that are not part of the meeting, then write the minutes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 4).frame(maxWidth: 760 + 48, alignment: .leading).frame(maxWidth: .infinity)
            TranscriptPane(lines: $r.tLines, dir: r.session, events: r.screenEvents, marks: r.marks).frame(maxWidth: 760 + 48)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var footer: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 12) {
                Button("Discard") { r.reset() }.glassButton()
                Spacer(minLength: 8)
                Toggle("Skip this step next time", isOn: $r.autoDraft).toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(Capsule())
                Button { r.writeMinutes() } label: { Text("Write minutes").frame(minWidth: 140) }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(r.tLines.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
