import SwiftUI

// MARK: - Open items: action points from every meeting in one list

@MainActor
final class ActionTracker: ObservableObject {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mom/actions.json")
    @Published private(set) var state = ActionItems.load(ActionTracker.fileURL)

    struct Item: Identifiable { let id: String; let meeting: Meeting; let text: String }

    func items(in meetings: [Meeting]) -> [Item] {
        meetings.flatMap { m in
            (m.data?.topics ?? []).filter(ActionItems.isAction).map { Item(id: ActionItems.key(folder: m.dir.lastPathComponent, text: $0), meeting: m, text: $0) }
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

    private var items: [ActionTracker.Item] { tracker.items(in: lib.meetings).filter { showDone || !tracker.isDone($0) } }
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
                    Text("\(tracker.openCount(lib.meetings)) to do across all meetings").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
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
                                    Text(i.text).strikethrough(tracker.isDone(i)).foregroundStyle(tracker.isDone(i) ? .secondary : .primary)
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
