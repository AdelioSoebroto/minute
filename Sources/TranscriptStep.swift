import SwiftUI
import AVFoundation

// MARK: - Transcript lines ("[hh:mm:ss] Who: text" in transcript.md)

struct TLine: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var who: String
    var text: String

    var seconds: Double {
        let p = time.split(separator: ":").compactMap { Double($0) }
        return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
    }
    var speaker: String { who == "Me" ? "You" : who }

    static func parse(_ text: String) -> [TLine] {
        text.split(separator: "\n").compactMap { raw -> TLine? in
            let s = String(raw)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
            let time = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            return TLine(time: time, who: String(rest[..<colon]), text: String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func serialize(_ lines: [TLine]) -> String {
        "# Transcript\n\n" + lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "[\($0.time)] \($0.who): \($0.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n"
    }
}

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

// MARK: - Step 2: check what was heard

struct StepTranscript: View {
    @ObservedObject var r: Recorder
    @StateObject private var playback = Playback()
    @State private var query = ""
    @State private var copied = false

    private var words: Int { r.tLines.reduce(0) { $0 + $1.text.split(separator: " ").count } }
    private func tint(_ who: String) -> Color { who == "Me" ? .blue : who == "Others" ? .orange : .gray }
    private func matches(_ l: TLine) -> Bool { query.isEmpty || l.text.localizedCaseInsensitiveContains(query) || l.speaker.localizedCaseInsensitiveContains(query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if r.tLines.isEmpty {
                ContentUnavailableView("Nothing was heard", systemImage: "waveform.slash",
                                       description: Text("The recording had no speech Minute could pick up. Check the microphone, and for online meetings that the meeting audio was playing."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach($r.tLines) { $l in
                            row($l)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
                .softScrollEdges()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onDisappear { playback.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check what was heard").font(.title2.weight(.semibold))
            Text("This is the transcript the minutes are written from. Fix any word that was misheard, remove lines that are not part of the meeting, then write the minutes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the transcript", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Text("\(r.tLines.filter(matches).count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8).glass(Capsule())
                chip("\(words) words")
                chip("\(r.tLines.count) lines")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TLine.serialize(r.tLines), forType: .string)
                    Haptic.tick(); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }.glassButton()
            }
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 10).frame(maxWidth: 760 + 48).frame(maxWidth: .infinity)
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6).glass(Capsule())
    }

    private func row(_ l: Binding<TLine>) -> some View {
        let line = l.wrappedValue
        let idx = r.tLines.firstIndex { $0.id == line.id } ?? 0
        let next = idx + 1 < r.tLines.count ? r.tLines[idx + 1] : nil
        let canPlay = Playback.available(in: r.session)
        return HStack(alignment: .top, spacing: 10) {
            Button { Haptic.tick(); playback.toggle(line, next: next, in: r.session) } label: {
                HStack(spacing: 4) {
                    Image(systemName: playback.playingID == line.id ? "pause.fill" : "play.fill").font(.system(size: 9))
                    Text(line.time).font(.caption.monospacedDigit())
                }
                .foregroundStyle(playback.playingID == line.id ? Color.accentColor : .secondary)
                .frame(width: 74, alignment: .leading)
            }
            .buttonStyle(.plain).disabled(!canPlay).help(canPlay ? "Play from here" : "")
            Text(line.speaker).font(.caption.weight(.semibold)).foregroundStyle(tint(line.who))
                .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(tint(line.who).opacity(0.12)))
                .frame(width: 66, alignment: .leading)
            TextField("", text: l.text, axis: .vertical).textFieldStyle(.plain).font(.body)
            Button { Haptic.tick(); withAnimation(.spring(duration: 0.3)) { r.tLines.removeAll { $0.id == line.id } } } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
            }.buttonStyle(.borderless).help("Remove this line")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(playback.playingID == line.id ? Color.accentColor.opacity(0.10) : (query.isEmpty || !matches(line) ? Color.clear : Color.yellow.opacity(0.22))))
        .opacity(matches(line) ? 1 : 0.35)
    }

    private var footer: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 12) {
                Button("Discard") { r.reset() }.glassButton()
                Spacer(minLength: 8)
                Toggle("Skip this step next time", isOn: $r.autoDraft).toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(Capsule())
                Button { playback.stop(); r.writeMinutes() } label: { Text("Write minutes").frame(minWidth: 140) }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(r.tLines.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
