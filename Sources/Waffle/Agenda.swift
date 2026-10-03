// The calendar event a call belongs to, from the Mac's Calendar (iCloud, Google, Exchange: whatever is added in System Settings), when the
// user allows it: its title names the meeting, and the people invited help name the voices and spell the names in the notes. Read when a
// recording starts; only the title and the names are kept, with the meeting.
import EventKit
import SwiftUI

enum Agenda {
    static let store = EKEventStore()

    /// Settings: on once the user allowed the calendar, until turned off.
    static var enabled: Bool {
        get { allowed && (UserDefaults.standard.object(forKey: "calendar") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "calendar") }
    }

    static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var denied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }

    static func request() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }

    /// The event of the call starting now: of the events that are on now or start in the next 15 minutes (not all-day), those with a call
    /// link or other people, the one whose start is nearest to now. Its title and the people invited, without the user.
    static func current(at now: Date = Date()) -> (title: String, invited: [String])? {
        guard allowed else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(900), calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now && $0.startDate <= now.addingTimeInterval(900) }
        func isCall(_ e: EKEvent) -> Bool {
            let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
            return (e.attendees?.count ?? 0) > 1 || ["zoom.us", "teams.microsoft", "teams.live", "meet.google", "webex", "facetime", "whereby", "slack.com/huddle"].contains { text.contains($0) }
        }
        guard let e = events.filter(isCall).min(by: { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }) else { return nil }
        let invited = (e.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }.compactMap { p -> String? in
            if let n = p.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty, !n.contains("@") { return n }
            let mail = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            let local = mail.split(separator: "@").first.map(String.init) ?? ""
            let words = local.split(whereSeparator: { ".-_".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
        return ((e.title ?? "").trimmingCharacters(in: .whitespaces), Array(Set(invited)).sorted())
    }
}

/// Settings: the calendar on or off, and the permission.
struct AgendaSettings: View {
    @State var on = Agenda.enabled
    @State var allowed = Agenda.allowed

    var body: some View {
        Section {
            if allowed {
                Toggle("Use the calendar event of each call", isOn: $on).onChange(of: on) { Agenda.enabled = on }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calendar not allowed").fontWeight(.semibold)
                        Text("Waffle can take the meeting's title and the people invited from your calendar.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if Agenda.denied {
                        Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
                    } else {
                        Button("Allow...") { Task { allowed = await Agenda.request(); on = Agenda.enabled } }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("When a recording starts, Waffle looks for the event going on in your calendar: its title names the meeting, and the people invited help name the voices and spell names in the notes. In a call with one other person, their voice gets their name.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
