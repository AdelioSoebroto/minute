import SwiftUI

// MARK: - Open items: action points from every meeting in one list

@MainActor
final class ActionTracker: ObservableObject {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mom/actions.json")
    @Published private(set) var state = ActionItems.load(ActionTracker.fileURL)

    struct Item: Identifiable { let id: String; let meeting: Meeting; let text: String; var owner = ""; var due = "" }

    func items(in meetings: [Meeting]) -> [Item] {
        meetings.flatMap { m -> [Item] in
            let f = m.dir.lastPathComponent
            if !m.actions.isEmpty {     // the model's own list, with owner and due date
                return m.actions.map { a in
                    let owner = ["unassigned", "tbd", "-"].contains(a.owner.lowercased()) ? "" : a.owner
                    let due = a.due.lowercased() == "tbd" ? "" : a.due
                    return Item(id: ActionItems.key(folder: f, text: a.task), meeting: m, text: a.task, owner: owner, due: due)
                }
            }
            return (m.data?.topics ?? []).filter(ActionItems.isAction).map { Item(id: ActionItems.key(folder: f, text: $0), meeting: m, text: $0) }
        }.filter { !state.dismissed.contains($0.id) }
    }

    func openCount(_ meetings: [Meeting]) -> Int { items(in: meetings).filter { !state.done.contains($0.id) }.count }
    func isDone(_ i: Item) -> Bool { state.done.contains(i.id) }

    func toggle(_ i: Item) {
        if state.done.contains(i.id) { state.done.remove(i.id) } else { state.done.insert(i.id) }
        ActionItems.save(state, to: Self.fileURL)
    }

    func dismiss(_ i: Item) { state.dismissed.insert(i.id); ActionItems.save(state, to: Self.fileURL) }
}

struct OpenItemsView: View {
    @ObservedObject var lib: Library
    @ObservedObject var tracker: ActionTracker
    var open: (Meeting) -> Void
    @State private var showDone = false
    @State private var owner = ""

    private var all: [ActionTracker.Item] { tracker.items(in: lib.meetings) }
    private var owners: [String] { Array(Set(all.map(\.owner).filter { !$0.isEmpty })).sorted() }
    private var items: [ActionTracker.Item] { all.filter { (showDone || !tracker.isDone($0)) && (owner.isEmpty || $0.owner == owner) } }
    private var overdue: Int { all.filter { !tracker.isDone($0) && ActionItems.isOverdue(due: $0.due) }.count }
    private var groups: [(Meeting, [ActionTracker.Item])] {
        var order: [Meeting] = []; var dict: [URL: [ActionTracker.Item]] = [:]
        for i in items { if dict[i.meeting.dir] == nil { order.append(i.meeting) }; dict[i.meeting.dir, default: []].append(i) }
        return order.map { ($0, dict[$0.dir]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open items").font(.title2.weight(.semibold))
                    Text("\(tracker.openCount(lib.meetings)) to do across all meetings" + (overdue > 0 ? " · \(overdue) overdue" : "")).font(.callout).foregroundStyle(overdue > 0 ? Color.red : .secondary)
                }
                Spacer()
                if !owners.isEmpty {
                    Picker("Owner", selection: $owner) { Text("Everyone").tag(""); ForEach(owners, id: \.self) { Text($0).tag($0) } }.frame(width: 190)
                }
                Toggle("Show completed", isOn: $showDone).toggleStyle(.checkbox)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("Nothing open", systemImage: "checkmark.circle",
                                       description: Text("Action points found in your minutes appear here. Tick them off as they get done."))
            } else {
                List {
                    ForEach(groups, id: \.0.dir) { m, its in
                        Section {
                            ForEach(its) { i in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Button { Haptic.tick(); withAnimation(.snappy) { tracker.toggle(i) } } label: {
                                        Image(systemName: tracker.isDone(i) ? "checkmark.circle.fill" : "circle").font(.title3)
                                            .foregroundStyle(tracker.isDone(i) ? Color.green : .secondary)
                                    }.buttonStyle(.plain).accessibilityLabel(tracker.isDone(i) ? "Mark as not done" : "Mark as done")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(i.text).strikethrough(tracker.isDone(i)).foregroundStyle(tracker.isDone(i) ? .secondary : .primary)
                                        if !i.owner.isEmpty || !i.due.isEmpty {
                                            HStack(spacing: 8) {
                                                if !i.owner.isEmpty { Label(i.owner, systemImage: "person.fill") }
                                                if !i.due.isEmpty { Label(i.due, systemImage: "calendar") }
                                            }.font(.caption).foregroundStyle(!tracker.isDone(i) && ActionItems.isOverdue(due: i.due) ? Color.red : .secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 3)
                                .contextMenu {
                                    Button("Open the meeting") { open(m) }
                                    Button("Not an action item") { tracker.dismiss(i) }
                                }
                            }
                        } header: {
                            Button { open(m) } label: {
                                HStack(spacing: 6) {
                                    Text(m.title).font(.callout.weight(.semibold))
                                    Text(m.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
