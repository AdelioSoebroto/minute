import Foundation
import EventKit

/// If a calendar event is running when a recording starts, its title and invitees help name the meeting and spell the names right.
enum CalendarContext {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "useCalendar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useCalendar") }
    }
    static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func request() async -> Bool { (try? await EKEventStore().requestFullAccessToEvents()) ?? false }

    /// Writes meeting.json (title, invitees) into the recording folder when an event is in progress.
    static func writeContext(for start: Date, into dir: URL) {
        guard enabled, allowed else { return }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start.addingTimeInterval(-20 * 60), end: start.addingTimeInterval(20 * 60), calendars: nil))
            .filter { !$0.isAllDay && $0.startDate <= start.addingTimeInterval(10 * 60) && $0.endDate >= start }
        let ranked = events.sorted { score($0) > score($1) }
        guard let e = ranked.first, let title = e.title, !title.isEmpty else { return }
        let names = (e.attendees ?? []).compactMap { $0.name }.filter { !$0.contains("@") }
        let json: [String: Any] = ["title": title, "attendees": names]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("meeting.json")) }
    }

    private static func score(_ e: EKEvent) -> Int {
        let hay = ((e.notes ?? "") + (e.location ?? "") + (e.url?.absoluteString ?? "")).lowercased()
        var s = (e.attendees?.count ?? 0) > 1 ? 2 : 0
        if ["teams.microsoft", "zoom.us", "meet.google", "webex"].contains(where: hay.contains) { s += 3 }
        return s
    }
}
