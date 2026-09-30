// M365 Sync menu bar app: shows whether the sync job is running, the last result, and Start/Stop.
// It only talks to launchd and reads the status file written by m365-calendar-sync; it needs no calendar access.

import AppKit
import SwiftUI

let label = "com.fedeagostini.m365-calendar-sync"
let domain = "gui/\(getuid())"
let home = FileManager.default.homeDirectoryForCurrentUser
let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
let supportDir = home.appendingPathComponent("Library/Application Support/m365-calendar-sync")
let statusURL = supportDir.appendingPathComponent("status.json")
let settingsURL = supportDir.appendingPathComponent("settings.json")

func syncIntervalMinutes() -> Int { SyncSettings.load().syncIntervalMinutes }

/// Mirrors settings.json; missing keys get the same defaults as sync.swift.
struct SyncSettings: Equatable {
    var sourceAccount = ""
    var sourceCalendar = "Calendar"
    var targetAccount = ""
    var targetCalendar = "M365"
    var daysBack = 30
    var daysForward = 180
    var copyDetails = true
    var skipDeclined = true
    var syncIntervalMinutes = 15

    static func load() -> SyncSettings {
        var s = SyncSettings()
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        s.sourceAccount = json["sourceAccount"] as? String ?? s.sourceAccount
        s.sourceCalendar = json["sourceCalendar"] as? String ?? s.sourceCalendar
        s.targetAccount = json["targetAccount"] as? String ?? s.targetAccount
        s.targetCalendar = json["targetCalendar"] as? String ?? s.targetCalendar
        s.daysBack = json["daysBack"] as? Int ?? s.daysBack
        s.daysForward = json["daysForward"] as? Int ?? s.daysForward
        s.copyDetails = json["copyDetails"] as? Bool ?? s.copyDetails
        s.skipDeclined = json["skipDeclined"] as? Bool ?? s.skipDeclined
        s.syncIntervalMinutes = json["syncIntervalMinutes"] as? Int ?? s.syncIntervalMinutes
        return s
    }

    /// Returns an error message, or nil if the values can be saved.
    func validationError() -> String? {
        for (name, value) in [("Work account", sourceAccount), ("Work calendar", sourceCalendar),
                              ("Google account", targetAccount), ("Google calendar", targetCalendar)] {
            let v = value.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return "\(name) can't be empty." }
            if v.hasPrefix("my.user@") { return "\(name) is still the placeholder." }
        }
        if !(0...3650).contains(daysBack) { return "Days back must be between 0 and 3650." }
        if !(1...3650).contains(daysForward) { return "Days ahead must be between 1 and 3650." }
        if !(1...1440).contains(syncIntervalMinutes) { return "Interval must be between 1 and 1440 minutes." }
        return nil
    }

    func save() throws {
        var s = self
        for kp in [\SyncSettings.sourceAccount, \.sourceCalendar, \.targetAccount, \.targetCalendar] {
            s[keyPath: kp] = s[keyPath: kp].trimmingCharacters(in: .whitespaces)
        }
        // Written by hand to keep the template's key order (JSONEncoder's order is unstable).
        func str(_ v: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                   as: UTF8.self)
        }
        let lines = [
            "\"sourceAccount\": \(try str(s.sourceAccount))",
            "\"sourceCalendar\": \(try str(s.sourceCalendar))",
            "\"targetAccount\": \(try str(s.targetAccount))",
            "\"targetCalendar\": \(try str(s.targetCalendar))",
            "\"daysBack\": \(s.daysBack)",
            "\"daysForward\": \(s.daysForward)",
            "\"copyDetails\": \(s.copyDetails)",
            "\"skipDeclined\": \(s.skipDeclined)",
            "\"syncIntervalMinutes\": \(s.syncIntervalMinutes)",
        ]
        let json = "{\n  " + lines.joined(separator: ",\n  ") + "\n}\n"
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: settingsURL, options: .atomic)
    }
}

// ObservableObject rather than @State: @State is a macro, and the Command Line Tools ship without SwiftUI's macro plugin.
final class SettingsForm: ObservableObject {
    @Published var settings = SyncSettings.load()
    @Published var error: String?
}

struct SettingsView: View {
    @ObservedObject var form: SettingsForm
    let onSave: (SyncSettings) -> String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Work calendar (copied from)") {
                    TextField("Account", text: $form.settings.sourceAccount, prompt: Text("my.user@m365.com"))
                    TextField("Calendar", text: $form.settings.sourceCalendar, prompt: Text("Calendar"))
                }
                Section("Google calendar (copied to)") {
                    TextField("Account", text: $form.settings.targetAccount, prompt: Text("my.user@gmail.com"))
                    TextField("Calendar", text: $form.settings.targetCalendar, prompt: Text("M365"))
                }
                Section("Sync") {
                    number("Days back", $form.settings.daysBack, step: 5, unit: "days")
                    number("Days ahead", $form.settings.daysForward, step: 10, unit: "days")
                    number("Run every", $form.settings.syncIntervalMinutes, step: 5, unit: "min")
                    Toggle("Copy details (title, location, notes)", isOn: $form.settings.copyDetails)
                    Toggle("Skip meetings I declined", isOn: $form.settings.skipDeclined)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 515)  // a grouped Form scrolls, so it has no natural height of its own

            HStack {
                if let error = form.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { form.error = onSave(form.settings) }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 460)
    }

    func number(_ title: String, _ value: Binding<Int>, step: Int, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Stepper(title, value: value, in: 0...3650, step: step).labelsHidden()
                Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
    }
}

let logURL = home.appendingPathComponent("Library/Logs/m365-calendar-sync.log")

@discardableResult
func launchctl(_ args: String...) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Same LaunchAgent install.sh writes. Keep the two in step.
func writeSyncAgent(intervalMinutes: Int) -> String? {
    let bin = home.appendingPathComponent(".local/bin/m365-calendar-sync").path
    guard FileManager.default.isExecutableFile(atPath: bin) else { return "The sync tool isn't built (\(bin))." }
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [bin],
        "StartInterval": intervalMinutes * 60,
        "RunAtLoad": true,
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
    ]
    let wasStopped = jobState() == .stopped
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: agentPlist), options: .atomic)
    } catch {
        return "Couldn't write \(agentPlist): \(error.localizedDescription)"
    }
    if wasStopped { return nil }
    launchctl("bootout", "\(domain)/\(label)")
    let (code, output) = launchctl("bootstrap", domain, agentPlist)
    return code == 0 ? nil : "launchctl bootstrap failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
}

enum JobState { case stopped, idle, syncing }

func jobState() -> JobState {
    let (code, out) = launchctl("print", "\(domain)/\(label)")
    if code != 0 { return .stopped }
    return out.contains("\n\tstate = running") ? .syncing : .idle
}

struct LastRun {
    let time: Date?
    let created, updated, deleted, unchanged: Int
    let error: String?

    var synced: Int { created + updated + unchanged }

    static func load() -> LastRun? {
        guard let data = try? Data(contentsOf: statusURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return LastRun(time: (json["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                       created: json["created"] as? Int ?? 0, updated: json["updated"] as? Int ?? 0,
                       deleted: json["deleted"] as? Int ?? 0, unchanged: json["unchanged"] as? Int ?? 0,
                       error: json["error"] as? String)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var timer: Timer?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshIcon() }
        }
    }

    func refreshIcon() {
        let state = jobState()
        let run = LastRun.load()
        let symbol: String
        switch state {
        case .stopped: symbol = "calendar.badge.minus"
        case .syncing: symbol = "arrow.triangle.2.circlepath"
        case .idle: symbol = run?.error == nil ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "M365 Sync")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = state == .stopped
        item.button?.toolTip = "M365 Sync: \(describe(state))"
    }

    func describe(_ state: JobState) -> String {
        switch state {
        case .stopped: return "Stopped"
        case .idle: return "Running (every \(syncIntervalMinutes()) min)"
        case .syncing: return "Syncing…"
        }
    }

    // Rebuilt every time the menu opens, so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let state = jobState()
        let run = LastRun.load()
        menu.removeAllItems()

        info("M365 Sync: \(describe(state))")
        if let run {
            if let time = run.time {
                let ago = RelativeDateTimeFormatter().localizedString(for: time, relativeTo: Date())
                info("Last sync: \(time.formatted(date: .omitted, time: .shortened)) (\(ago))")
            }
            if let error = run.error {
                info("⚠️ \(error.count > 80 ? String(error.prefix(80)) + "…" : error)")
            } else {
                info("Synced events: \(run.synced)")
                info("Last changes: \(run.created) created, \(run.updated) updated, \(run.deleted) deleted")
            }
        } else {
            info("No sync has finished yet")
        }

        menu.addItem(.separator())
        let syncNow = action("Sync Now", #selector(syncNow), key: "s")
        syncNow.isEnabled = state == .idle
        if state == .stopped {
            action("Start", #selector(start))
        } else {
            action("Stop", #selector(stop))
        }
        menu.addItem(.separator())
        action("Edit Settings…", #selector(editSettings), key: ",")
        action("Open Log", #selector(openLog), key: "l")
        action("Quit Menu Bar Icon", #selector(quit), key: "q")
    }

    func info(_ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    @discardableResult
    func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
        return mi
    }

    @objc func syncNow() {
        launchctl("kickstart", "\(domain)/\(label)")
        refreshSoon()
    }

    // enable/disable persist across logins, so Stop stays stopped after a restart.
    @objc func start() {
        guard FileManager.default.fileExists(atPath: agentPlist) else {
            let alert = NSAlert()
            alert.messageText = "Sync job not installed"
            alert.informativeText = "Run install.sh first (see README.md)."
            alert.runModal()
            return
        }
        launchctl("enable", "\(domain)/\(label)")
        launchctl("bootstrap", domain, agentPlist)
        refreshSoon()
    }

    @objc func stop() {
        launchctl("disable", "\(domain)/\(label)")
        launchctl("bootout", "\(domain)/\(label)")
        refreshSoon()
    }

    @objc func editSettings() {
        if settingsWindow == nil {
            let view = SettingsView(form: SettingsForm(), onSave: { [unowned self] in self.save($0) },
                                    onCancel: { [unowned self] in self.settingsWindow?.close() })
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "M365 Sync Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(controller.view.fittingSize)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil  // reopening reloads settings.json
    }

    /// Writes settings.json, updates the schedule if the interval changed, and syncs so changes apply now.
    func save(_ new: SyncSettings) -> String? {
        if let error = new.validationError() { return error }
        let intervalChanged = new.syncIntervalMinutes != SyncSettings.load().syncIntervalMinutes
        do { try new.save() } catch { return "Couldn't save: \(error.localizedDescription)" }

        if intervalChanged {
            reinstallSyncJob()  // its RunAtLoad also syncs
        } else if jobState() == .idle {
            launchctl("kickstart", "\(domain)/\(label)")
        }
        settingsWindow?.close()
        refreshSoon()
        return nil
    }

    /// The interval lives in the LaunchAgent, not in settings.json, so a new interval means reinstalling the job:
    /// rewrite its plist the same way install.sh does, then unload and load it. A stopped job stays stopped.
    /// Runs in the background because it first waits for a sync in progress to finish.
    func reinstallSyncJob() {
        DispatchQueue.global().async {
            for _ in 0..<120 where jobState() == .syncing { Thread.sleep(forTimeInterval: 0.5) }
            let error = writeSyncAgent(intervalMinutes: SyncSettings.load().syncIntervalMinutes)
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't update the sync schedule"
                    alert.informativeText = "\(error)\nSettings were saved. Run install.sh to finish."
                    alert.runModal()
                }
                self.refreshSoon()
            }
        }
    }

    /// Accessory apps have no menu bar of their own; without this, ⌘C/⌘V/⌘A don't work in the form.
    func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())  // slot for the (hidden) app menu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func quit() { NSApp.terminate(nil) }

    func refreshSoon() {
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshIcon() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
