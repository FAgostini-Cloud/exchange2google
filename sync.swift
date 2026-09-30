// m365-calendar-sync
// One-way copy of the M365 (Exchange) calendar into a Google calendar via macOS EventKit.
// Copies are standalone events owned by the Google account: no invites, no forwarding.
// Every copy carries a marker in its notes so the tool only ever touches its own events.
//
// Usage:
//   m365-calendar-sync            run a sync
//   m365-calendar-sync --dry-run  show what would change, change nothing
//   m365-calendar-sync --list     list accounts and calendars visible to macOS Calendar
//   m365-calendar-sync --inspect  print every copy in the target and whether its tag is intact
//   --settings <path>             use another settings file (default: see settingsURL)
//
// All settings live in settings.json (template: settings.example.json) and are read on every run.

import CryptoKit
import EventKit
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
let dryRun = argv.contains("--dry-run")
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/m365-calendar-sync")

let settingsURL: URL = {
    guard let i = argv.firstIndex(of: "--settings") else { return supportDir.appendingPathComponent("settings.json") }
    guard i + 1 < argv.count else { fail("--settings needs a path") }
    return URL(fileURLWithPath: (argv[i + 1] as NSString).expandingTildeInPath)
}()

struct Settings: Decodable {
    let sourceAccount: String
    let sourceCalendar: String
    let targetAccount: String
    let targetCalendar: String
    let daysBack: Int
    let daysForward: Int
    let copyDetails: Bool   // false = copy only as "Busy" blocks
    let skipDeclined: Bool

    enum CodingKeys: String, CodingKey {
        case sourceAccount, sourceCalendar, targetAccount, targetCalendar, daysBack, daysForward, copyDetails, skipDeclined
    }

    // Only the two accounts are required; everything else has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceAccount = try c.decode(String.self, forKey: .sourceAccount)
        sourceCalendar = try c.decodeIfPresent(String.self, forKey: .sourceCalendar) ?? "Calendar"
        targetAccount = try c.decode(String.self, forKey: .targetAccount)
        targetCalendar = try c.decodeIfPresent(String.self, forKey: .targetCalendar) ?? "M365"
        daysBack = try c.decodeIfPresent(Int.self, forKey: .daysBack) ?? 30
        daysForward = try c.decodeIfPresent(Int.self, forKey: .daysForward) ?? 180
        copyDetails = try c.decodeIfPresent(Bool.self, forKey: .copyDetails) ?? true
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? true
    }
}

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: settingsURL) else {
        fail("Settings file not found: \(settingsURL.path). Copy settings.example.json there and fill it in.")
    }
    do {
        return try JSONDecoder().decode(Settings.self, from: data)
    } catch DecodingError.keyNotFound(let key, _) {
        fail("\(settingsURL.path): \"\(key.stringValue)\" is required")
    } catch DecodingError.typeMismatch(_, let ctx) {
        fail("\(settingsURL.path): wrong type for \"\(ctx.codingPath.map(\.stringValue).joined(separator: "."))\"")
    } catch {
        fail("\(settingsURL.path) is not valid JSON")
    }
}

enum Config {
    static let settings = loadSettings()
    static var sourceAccount: String { settings.sourceAccount }
    static var sourceCalendar: String { settings.sourceCalendar }
    static var targetAccount: String { settings.targetAccount }
    static var targetCalendar: String { settings.targetCalendar }
    static var daysBack: Int { settings.daysBack }
    static var daysForward: Int { settings.daysForward }
    static var copyDetails: Bool { settings.copyDetails }
    static var skipDeclined: Bool { settings.skipDeclined }
    static let markerPrefix = "[m365-sync:"
}

let store = EKEventStore()

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(message)")
    fflush(stdout)
}

/// Last-run summary read by the menu bar app. Dry runs and --list don't touch it.
let statusURL = supportDir.appendingPathComponent("status.json")

func writeStatus(_ fields: [String: Any]) {
    guard !dryRun, !argv.contains("--list") else { return }
    var fields = fields
    fields["time"] = ISO8601DateFormatter().string(from: Date())
    try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: fields) {
        try? data.write(to: statusURL, options: .atomic)
    }
}

func fail(_ message: String) -> Never {
    log("ERROR: \(message)")
    writeStatus(["error": message])
    exit(1)
}

func requestAccess() {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var err: Error?
    store.requestFullAccessToEvents { ok, e in
        granted = ok
        err = e
        sem.signal()
    }
    sem.wait()
    if !granted {
        fail("Calendar access denied (\(err?.localizedDescription ?? "no details")). "
            + "Enable it in System Settings > Privacy & Security > Calendars.")
    }
}

/// Calendar.app names accounts "Exchange", "Google", etc., so an email address is matched indirectly:
/// Google accounts have a calendar titled with the address; a single Exchange account is taken as the match.
func sourceMatches(_ source: EKSource, _ account: String) -> Bool {
    if source.title.caseInsensitiveCompare(account) == .orderedSame
        || source.title.localizedCaseInsensitiveContains(account) {
        return true
    }
    guard account.contains("@") else { return false }
    if source.calendars(for: .event).contains(where: { $0.title.caseInsensitiveCompare(account) == .orderedSame }) {
        return true
    }
    let exchangeSources = store.sources.filter { $0.sourceType == .exchange }
    return source.sourceType == .exchange && exchangeSources.count == 1
}

func findCalendar(account: String, title: String) -> EKCalendar? {
    let calendars = store.calendars(for: .event).filter {
        $0.title.caseInsensitiveCompare(title) == .orderedSame
    }
    return calendars.first { sourceMatches($0.source, account) }
}

func listCalendars() {
    if store.calendars(for: .event).isEmpty {
        print("No calendars visible. Add the accounts in System Settings > Internet Accounts with Calendars enabled.")
    }
    for cal in store.calendars(for: .event).sorted(by: { $0.source.title < $1.source.title }) {
        print("account: \(cal.source.title) (\(cal.source.sourceType == .exchange ? "exchange" : "other"))  |  calendar: \(cal.title)  |  writable: \(cal.allowsContentModifications)")
    }
}

func sha(_ s: String, _ length: Int = 16) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
}

struct Desired {
    let key: String
    let fingerprint: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let timeZone: TimeZone?
    let location: String?
    let notes: String
    let url: URL?
    let availability: EKEventAvailability
}

func isDeclined(_ ev: EKEvent) -> Bool {
    ev.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
}

func desired(from ev: EKEvent) -> Desired {
    let id = ev.calendarItemExternalIdentifier ?? ev.eventIdentifier ?? UUID().uuidString
    let occurrence = (ev.occurrenceDate ?? ev.startDate).timeIntervalSince1970
    let key = sha("\(id)|\(occurrence)")

    let title = Config.copyDetails ? (ev.title ?? "(no title)") : "Busy"
    let location = Config.copyDetails ? ev.location : nil
    let body = Config.copyDetails ? (ev.notes ?? "") : ""
    let url = Config.copyDetails ? ev.url : nil

    let fingerprint = sha([
        title, "\(ev.startDate.timeIntervalSince1970)", "\(ev.endDate.timeIntervalSince1970)",
        "\(ev.isAllDay)", location ?? "", body, url?.absoluteString ?? "", "\(ev.availability.rawValue)",
    ].joined(separator: "\u{1F}"), 12)

    let marker = "\(Config.markerPrefix)\(key):\(fingerprint)]"
    let notes = body.isEmpty ? marker : "\(body)\n\n\(marker)"

    return Desired(key: key, fingerprint: fingerprint, title: title, start: ev.startDate, end: ev.endDate,
                   allDay: ev.isAllDay, timeZone: ev.timeZone, location: location, notes: notes,
                   url: url, availability: ev.availability)
}

/// Returns (key, fingerprint) if the event was created by this tool.
func parseMarker(_ ev: EKEvent) -> (String, String)? {
    guard let notes = ev.notes, let range = notes.range(of: Config.markerPrefix, options: .backwards) else {
        return nil
    }
    let rest = notes[range.upperBound...]
    guard let close = rest.firstIndex(of: "]") else { return nil }
    let parts = rest[..<close].split(separator: ":")
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]))
}

func apply(_ d: Desired, to ev: EKEvent) {
    ev.title = d.title
    ev.isAllDay = d.allDay
    ev.startDate = d.start
    ev.endDate = d.end
    ev.timeZone = d.timeZone
    ev.location = d.location
    ev.notes = d.notes
    ev.url = d.url
    ev.availability = d.availability
}

// MARK: - Main

requestAccess()

if argv.contains("--list") {
    listCalendars()
    exit(0)
}

guard let source = findCalendar(account: Config.sourceAccount, title: Config.sourceCalendar) else {
    listCalendars()
    fail("Source calendar '\(Config.sourceCalendar)' in account '\(Config.sourceAccount)' not found (see list above).")
}
guard let target = findCalendar(account: Config.targetAccount, title: Config.targetCalendar) else {
    listCalendars()
    fail("Target calendar '\(Config.targetCalendar)' in account '\(Config.targetAccount)' not found (see list above).")
}
guard target.allowsContentModifications else { fail("Target calendar is read-only.") }
guard source.calendarIdentifier != target.calendarIdentifier else { fail("Source and target are the same calendar.") }

let now = Date()
let windowStart = Calendar.current.date(byAdding: .day, value: -Config.daysBack, to: now)!
let windowEnd = Calendar.current.date(byAdding: .day, value: Config.daysForward, to: now)!

let sourceEvents = store.events(matching:
    store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [source]))
let targetEvents = store.events(matching:
    store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [target]))

if argv.contains("--inspect") {
    for ev in targetEvents.sorted(by: { $0.startDate < $1.startDate }) {
        let notes = ev.notes ?? ""
        let tail = String(notes.suffix(100)).replacingOccurrences(of: "\n", with: "⏎")
        print("\(parseMarker(ev) == nil ? "NO-TAG" : "tagged") \(ev.startDate!) len=\(notes.count) \(ev.title ?? "") | …\(tail)")
    }
    for ev in sourceEvents { print("source len=\((ev.notes ?? "").count) \(ev.startDate!) \(ev.title ?? "")") }
    exit(0)
}

var wanted: [String: Desired] = [:]
for ev in sourceEvents {
    if ev.status == .canceled { continue }
    if Config.skipDeclined && isDeclined(ev) { continue }
    let d = desired(from: ev)
    wanted[d.key] = d
}

var existing: [String: (EKEvent, String)] = [:]
var toDelete: [EKEvent] = []
for ev in targetEvents {
    guard let (key, fp) = parseMarker(ev) else { continue }  // not ours: never touch
    if existing[key] != nil || wanted[key] == nil {
        toDelete.append(ev)  // duplicate, or no longer in source
    } else {
        existing[key] = (ev, fp)
    }
}

var created = 0, updated = 0, deleted = 0, unchanged = 0
do {
    for (key, d) in wanted {
        if let (ev, fp) = existing[key] {
            if fp == d.fingerprint { unchanged += 1; continue }
            log("update: \(d.title) @ \(d.start)")
            if !dryRun { apply(d, to: ev); try store.save(ev, span: .thisEvent, commit: false) }
            updated += 1
        } else {
            log("create: \(d.title) @ \(d.start)")
            if !dryRun {
                let ev = EKEvent(eventStore: store)
                ev.calendar = target
                apply(d, to: ev)
                try store.save(ev, span: .thisEvent, commit: false)
            }
            created += 1
        }
    }
    for ev in toDelete {
        log("delete: \(ev.title ?? "") @ \(ev.startDate!)")
        if !dryRun { try store.remove(ev, span: .thisEvent, commit: false) }
        deleted += 1
    }
    if !dryRun { try store.commit() }
} catch {
    store.reset()
    fail("Save failed: \(error.localizedDescription)")
}

writeStatus(["created": created, "updated": updated, "deleted": deleted, "unchanged": unchanged,
             "sourceEvents": sourceEvents.count])
log("\(dryRun ? "[dry-run] " : "")done: \(created) created, \(updated) updated, \(deleted) deleted, \(unchanged) unchanged "
    + "(\(sourceEvents.count) source events in window)")
