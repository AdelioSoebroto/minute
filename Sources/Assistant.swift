import SwiftUI

// MARK: - Mini Claude beside a meeting: point out what the minutes missed, ask questions, undo a change

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String          // "user" or "assistant"
    let text: String
    var changed = false
}

@MainActor
final class AssistantChat: ObservableObject {
    let dir: URL
    @Published var messages: [ChatMessage] = []
    @Published var busy: String?
    @Published var canUndo = false

    init(dir: URL) { self.dir = dir; load() }

    func load() {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("assistant.json")),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        messages = arr.compactMap { e in
            guard let role = e["role"] as? String, let text = e["text"] as? String else { return nil }
            return ChatMessage(role: role, text: text, changed: e["changed"] as? Bool ?? false)
        }
    }

    func send(_ text: String, editor: MeetingEditor, then: @escaping () -> Void) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, busy == nil else { return }
        editor.save()                              // the assistant must see the user's latest edits
        messages.append(ChatMessage(role: "user", text: t)); busy = "Thinking…"
        Task {
            let (code, out) = await runMom(["--assist", dir.path, t], full: true) { s in Task { @MainActor in self.busy = s + "…" } }
            busy = nil
            if code == 0, let line = out.split(separator: "\n").last(where: { $0.hasPrefix("ASSIST ") }),
               let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8)) as? [String: Any] {
                let changed = j["changed"] as? Bool ?? false
                messages.append(ChatMessage(role: "assistant", text: j["reply"] as? String ?? "", changed: changed))
                if changed { canUndo = true; editor.load(); Haptic.confirm(); then() }
            } else {
                messages.append(ChatMessage(role: "assistant", text: "Couldn't answer: " + (out.split(separator: "\n").last.map(String.init) ?? out)))
            }
        }
    }

    /// Puts back the minutes and action items from before the assistant's last change.
    func undo(editor: MeetingEditor, then: () -> Void) {
        let fm = FileManager.default
        for (prev, cur) in [("MoM.previous.json", "MoM.json"), ("analysis.previous.json", "analysis.json")] {
            let p = dir.appendingPathComponent(prev), c = dir.appendingPathComponent(cur)
            if fm.fileExists(atPath: p.path) { _ = try? fm.replaceItemAt(c, withItemAt: p) }
        }
        canUndo = false; editor.load()
        messages.append(ChatMessage(role: "assistant", text: "Undone: the minutes are back to how they were before my last change."))
        then()
    }
}

struct AssistantPanel: View {
    @ObservedObject var editor: MeetingEditor
    @StateObject private var chat: AssistantChat
    @State private var field = ""
    @FocusState private var focused: Bool
    var close: () -> Void
    var changed: () -> Void

    init(editor: MeetingEditor, close: @escaping () -> Void, changed: @escaping () -> Void) {
        self.editor = editor; self.close = close; self.changed = changed
        _chat = StateObject(wrappedValue: AssistantChat(dir: editor.dir))
    }

    private var engine: String { AIEngine.useClaude ? "Claude Sonnet" : "On this Mac" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Claude", systemImage: "sparkles").font(.callout.weight(.semibold))
                Text(engine).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Close")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty { intro }
                        ForEach(chat.messages) { m in bubble(m).id(m.id) }
                        if let b = chat.busy { HStack { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }.id("busy") }
                    }.padding(14)
                }
                .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) } }
                .onChange(of: chat.busy != nil) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                .onAppear { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
            if chat.canUndo {
                Button { chat.undo(editor: editor, then: changed) } label: { Label("Undo last change", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).font(.caption).padding(.bottom, 4)
            }
            HStack(alignment: .bottom) {
                TextField("Tell Claude what it missed, or ask…", text: $field, axis: .vertical).textFieldStyle(.plain).lineLimit(1...5)
                    .focused($focused).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).disabled(field.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy != nil).accessibilityLabel("Send")
            }
            .padding(.horizontal, 12).padding(.vertical, 9).glass(RoundedRectangle(cornerRadius: 16), interactive: true)
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func send() { let t = field; field = ""; chat.send(t, editor: editor, then: changed) }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Point out anything the minutes missed or got wrong, and I'll fix them. For example:").font(.callout).foregroundStyle(.secondary)
            ForEach(["Add an action: Budi sends the revised proposal by Friday", "You missed that we agreed to run the test again next week", "Who raised the pricing question, and what was decided?"], id: \.self) { s in
                Button { field = s; focused = true } label: { Text(s).font(.caption).multilineTextAlignment(.leading).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08))) }.buttonStyle(.plain)
            }
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.role == "user"
        return HStack {
            if mine { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 4) {
                Text(m.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if m.changed { Label("Minutes updated", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10)))
            if !mine { Spacer(minLength: 30) }
        }
    }
}
