# m365-calendar-sync

One-way copy of a Microsoft 365 (Exchange) calendar into a Google Calendar, on macOS, for free.

It is meant for when your M365 admin has disabled calendar sharing and publishing, so you can't subscribe to your work calendar from Google.
The tool reads your work calendar through the macOS **Calendar** app and writes copies into a Google calendar.
Nothing is forwarded, no invites are sent, and no third-party service is involved.

> **Company policy:** admins disable sharing to keep work data inside the tenant.
> Check that copying events to a personal account is allowed before you use this.

## How it works

```
M365 (Exchange) ──► macOS Calendar app ──► m365-calendar-sync ──► macOS Calendar app ──► Google Calendar
     account           (Internet Accounts)     (every 15 min)        (Google account)        "M365"
```

- Each run reads the source calendar for the window **30 days back → 180 days ahead** and makes the target calendar match it:
  - **new** work events are created in the target;
  - **changed** events (title, time, location, notes, link, busy/free) are updated;
  - events that were **removed, cancelled or declined** at work are deleted from the target.
- Copies are plain events owned by your Google account. They have **no attendees**, so nobody receives an invite or an update.
- Every copy ends its notes with a hidden tag like `[m365-sync:3f9c…:a1b2…]`.
  The tool only ever edits or deletes events that carry this tag. Anything you add to the target calendar yourself is never touched.
- Recurring meetings are copied as individual occurrences, one event per date.
- It is stateless: all bookkeeping lives in those tags, so there is no database to lose or corrupt.
- Events are skipped when they are cancelled, or when you declined them.
- The sync runs only while your Mac is on and you are logged in. After sleep, it catches up on the next run.

## Requirements

- macOS 14 or later (tested on macOS 26).
- Xcode Command Line Tools, for `swiftc` (`xcode-select --install`).
- Both accounts added to macOS with **Calendars** enabled (see Setup, step 1).

## Setup

### 1. Add both accounts to macOS

**System Settings → Internet Accounts → Add Account**

| Account | Type | Turn on |
|---|---|---|
| `my.user@m365.com` | Microsoft Exchange | Calendars |
| `my.user@gmail.com` | Google | Calendars |

Open the **Calendar** app and wait until events from both accounts show up.
The target calendar (`M365`) must already exist in Google Calendar. Create it at calendar.google.com if needed.

If M365's sign-in page refuses the Apple app, this approach can't work for that account.
The only free fallback is a manual `.ics` export and import.

### 2. Create your settings

```sh
cd ~/m365-calendar-sync
./install.sh
```

The first time, `install.sh` copies [settings.example.json](settings.example.json) to
`~/Library/Application Support/m365-calendar-sync/settings.json` and stops.
Open that file and set your two accounts (see [Settings](#settings)):

```json
"sourceAccount": "my.user@m365.com",
"targetAccount": "my.user@gmail.com",
```

### 3. Install

```sh
./install.sh
```

`install.sh` checks that `settings.json` is valid JSON and that both accounts are set (not the `my.user@…` placeholders). Then it does four things:

1. compiles `sync.swift` into `~/.local/bin/m365-calendar-sync`;
2. signs it and embeds `Info.plist`, which lets macOS show a Calendar permission prompt for it;
3. installs a LaunchAgent (`~/Library/LaunchAgents/com.fedeagostini.m365-calendar-sync.plist`) that runs it at login and every `syncIntervalMinutes`, starting right away;
4. builds the menu bar icon (`~/Applications/M365 Sync.app`) and starts it now and at every login (see [Menu bar icon](#menu-bar-icon)).

### 4. Allow calendar access

On the first run macOS asks: *"m365-calendar-sync" would like full access to your calendars.* Click **Allow**.

You can check or change this later in **System Settings → Privacy & Security → Calendars**.

> Every rebuild (running `install.sh` again) produces a new binary, and macOS may ask again. Just allow it.

### 5. Check it worked

```sh
tail -f ~/Library/Logs/m365-calendar-sync.log
```

A good run ends with a line like:

```
2026-09-29T16:35:44Z done: 116 created, 0 updated, 0 deleted, 0 unchanged (118 source events in window)
```

Later runs usually say `0 created, 0 updated, 0 deleted, N unchanged`.

> The second run may still create a few events. When many copies are created at once, Google can silently drop some of them.
> The next run notices they are missing and creates them again. This doesn't produce duplicates, because every copy is matched by its tag.

## Menu bar icon

A calendar icon in the top bar shows the state of the sync at a glance:

| Icon | Meaning |
|---|---|
| calendar with ✓ | Running; the last sync succeeded |
| calendar with ! | Running; the last sync failed. Open the menu to see the error |
| two circling arrows | A sync is in progress right now |
| calendar with −, dimmed | Stopped |

Clicking the icon opens a menu:

- **Status**, **Last sync** (time, and how long ago), **Synced events** (copies now in the target), and **Last changes** (created / updated / deleted in the last run);
- **Sync Now** (⌘S): run a sync immediately;
- **Start** / **Stop**: switch the background sync on or off. **Stop persists across restarts** until you press Start (or run `install.sh` again);
- **Edit Settings…** (⌘,): open the settings window (see [Settings](#settings));
- **Open Log** (⌘L): open the log in Console;
- **Quit Menu Bar Icon** (⌘Q): hide the icon. The sync keeps running. The icon comes back at the next login, or when you open *M365 Sync* from `~/Applications` or Spotlight.

The icon refreshes every 5 seconds. It needs no calendar permission of its own:
it asks launchd whether the job is loaded or running, and reads the summary each sync writes to
`~/Library/Application Support/m365-calendar-sync/status.json`.

## Settings

Every setting lives in one file:

```
~/Library/Application Support/m365-calendar-sync/settings.json
```

It sits outside the project folder, so your real addresses never end up in the repo.

### Settings window

The easiest way to change settings is **Edit Settings…** (⌘,) in the menu bar icon.
It opens a small form with every setting: accounts, calendars, days back and ahead, interval, and the two switches.

- **Save** (⏎) checks the values, writes `settings.json`, and runs a sync straight away, so the changes apply immediately.
  - If you changed **Run every**, it reinstalls the background job with the new interval: it rewrites the LaunchAgent just as `install.sh` does, then reloads it, which also runs a sync.
    No `install.sh` needed. If a sync is in progress, it waits for it to finish first. If the job is **stopped**, the new interval is saved and it stays stopped until you press **Start**.
  - If a value is wrong (an empty field, a `my.user@…` placeholder, or a number out of range), the form shows the problem and saves nothing.
- **Cancel** (Esc) or ⌘W closes the window without saving.

### Editing the file directly

You can also edit the JSON by hand, with `open -e ~/Library/Application\ Support/m365-calendar-sync/settings.json`.

```json
{
  "sourceAccount": "my.user@m365.com",
  "sourceCalendar": "Calendar",
  "targetAccount": "my.user@gmail.com",
  "targetCalendar": "M365",
  "daysBack": 30,
  "daysForward": 180,
  "copyDetails": true,
  "skipDeclined": true,
  "syncIntervalMinutes": 15
}
```

| Setting | Default | Meaning |
|---|---|---|
| `sourceAccount` | **required** | Account that holds the work calendar |
| `sourceCalendar` | `Calendar` | Name of the work calendar inside that account |
| `targetAccount` | **required** | Account that holds the destination calendar |
| `targetCalendar` | `M365` | Name of the destination calendar |
| `daysBack` | `30` | Days in the past to keep in sync |
| `daysForward` | `180` | Days ahead to keep in sync |
| `copyDetails` | `true` | `false` copies only "Busy" blocks: no title, location or notes |
| `skipDeclined` | `true` | Don't copy meetings you declined |
| `syncIntervalMinutes` | `15` | How often the background job runs |

Every key except the two accounts can be left out, and its default is used.

**When hand edits take effect:**

- `syncIntervalMinutes`: only after you run `./install.sh` again, because it is written into the LaunchAgent. The settings window does this for you;
- everything else: at the next sync, since the file is read on every run. Press **Sync Now** to apply at once. No rebuild is needed.

If the file is missing, isn't valid JSON, or lacks an account, the run fails without changing anything.
The error appears in the log and in the menu bar (calendar with !).

### How account names are matched

The Calendar app names accounts by type (`Exchange`, `Google`), not by email address. A value is accepted if any of these is true:

- it matches the account name shown by `--list` (for example `Exchange` or `Google`);
- it is an email address, and that account has a calendar titled with the address (Google accounts always do);
- it is an email address, and there is exactly one Exchange account on the Mac.

If a calendar can't be found, the run fails without changing anything, and the log lists every account and calendar it can see.

## Command-line flags

The scheduled job runs with no flags. These are for checks by hand:

| Flag | Meaning |
|---|---|
| `--dry-run` | Print what would change, change nothing |
| `--list` | Print every account and calendar the tool can see, then exit. Needs no settings file |
| `--inspect` | Print every event in the target, whether its tag is intact, and each source event's notes length. Changes nothing |
| `--settings <path>` | Use another settings file instead of the default one |

## Running it by hand

Always run through launchd. Running the binary from Terminal or VS Code makes macOS check *that* app's calendar permission, which is usually denied.

```sh
# Trigger a sync now
launchctl kickstart gui/$(id -u)/com.fedeagostini.m365-calendar-sync

# Then read the result
tail -20 ~/Library/Logs/m365-calendar-sync.log
```

For a one-off `--dry-run` or `--list`, the simplest route is a Terminal app that has been granted Calendar access.
Or grant it in **Privacy & Security → Calendars** and then run:

```sh
~/.local/bin/m365-calendar-sync --dry-run
```

## Managing the background job

The menu bar icon covers the everyday controls (Start, Stop, Sync Now). The equivalent commands:

```sh
# Status
launchctl print gui/$(id -u)/com.fedeagostini.m365-calendar-sync | grep -E "state|last exit"

# Stop (stays stopped after restarts)
launchctl disable gui/$(id -u)/com.fedeagostini.m365-calendar-sync
launchctl bootout gui/$(id -u)/com.fedeagostini.m365-calendar-sync

# Start
launchctl enable gui/$(id -u)/com.fedeagostini.m365-calendar-sync
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.fedeagostini.m365-calendar-sync.plist
```

To change the interval, use **Run every** in the settings window. Or set `syncIntervalMinutes` in `settings.json` and run `./install.sh` again.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.fedeagostini.m365-calendar-sync
launchctl bootout gui/$(id -u)/com.fedeagostini.m365-calendar-sync.menubar
rm ~/Library/LaunchAgents/com.fedeagostini.m365-calendar-sync.plist
rm ~/Library/LaunchAgents/com.fedeagostini.m365-calendar-sync.menubar.plist
rm ~/.local/bin/m365-calendar-sync
rm -rf ~/Applications/"M365 Sync.app"
rm -rf ~/Library/Application\ Support/m365-calendar-sync   # also deletes settings.json
rm ~/Library/Logs/m365-calendar-sync.log
```

The copied events stay in Google Calendar. To remove them, delete the `M365` calendar in Google Calendar, or delete the events there.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Settings file not found` | Run `./install.sh` once to create it from the template, then fill it in. |
| `"sourceAccount" is required` / `is not valid JSON` / `wrong type for …` | Fix `settings.json` (check commas and quotes; numbers and `true`/`false` go without quotes). |
| `Calendar access denied` | Allow it in **Privacy & Security → Calendars**. If the tool isn't listed, run `./install.sh` again to trigger the prompt again. |
| `No calendars visible` | The accounts aren't in Internet Accounts, or Calendars is switched off for them. |
| `Source/Target calendar … not found` | A name doesn't match. Compare with the list printed in the log and adjust `settings.json`. |
| `Target calendar is read-only` | You picked a subscribed calendar, such as holidays. Use one you own. |
| Events appear late in Google | macOS pushes changes to Google on its own schedule, usually within a few minutes. Open the Calendar app to speed it up. |
| Double reminders on the copies | Google may add its default reminders. Turn off default notifications for the `M365` calendar in Google Calendar settings. |
| Menu bar icon missing | You quit it, or it hasn't started yet. Open *M365 Sync* from `~/Applications` or Spotlight. If the menu bar is crowded, macOS may hide icons behind the notch. |
| Menu shows "No sync has finished yet" | No run has finished since the menu bar icon was installed. Press **Sync Now**. |
| Suspect duplicates or missing copies | Run with `--inspect` (see [Running it by hand](#running-it-by-hand)). Every copy should say `tagged`. |
| Nothing syncs after the Mac was off | Expected. The next run (at most `syncIntervalMinutes` after wake or login) catches up. |

## Limitations

- Attendees, attachments and Teams join buttons are not copied. The meeting link is usually in the notes, which are copied.
- Exceptions to recurring meetings work, because each occurrence is copied separately. Editing one occurrence at work updates only that copy.
- Events that fall outside the `daysBack` / `daysForward` window are left as they are. Nothing is deleted just for ageing out of the window.
- Changes you make to a copy in Google are overwritten the next time that event changes at work.

## Files

| File | Purpose |
|---|---|
| [settings.example.json](settings.example.json) | Template for `settings.json`, with placeholder accounts |
| [sync.swift](sync.swift) | The sync tool |
| [install.sh](install.sh) | Builds, signs and schedules it, and installs the menu bar icon |
| [Info.plist](Info.plist) | Embedded in the binary so macOS can ask for Calendar permission |
| [menubar/MenuBar.swift](menubar/MenuBar.swift) | The menu bar icon app and its settings window |
| [menubar/Info.plist](menubar/Info.plist) | App bundle settings: runs as a menu bar item with no Dock icon |
