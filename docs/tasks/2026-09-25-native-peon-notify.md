# Native peon notifications on macOS

## Outcome

When Claude Code or Codex finishes a task or asks for approval, a real macOS Notification Center banner appears, sent by an app called "Peon" whose icon is the peon. The peon voice line plays at the same time, just as peon-ping plays it today. Clicking the banner brings Ghostty forward and focuses the exact tab or split the session runs in, even when several sessions share one repo.

Day-to-day use needs no commands. Setup, once, in your own terminal (not Claude's sandbox):

    git clone https://github.com/Fleron/peon-ping.git ~/Documents/Tools/peon-ping
    cd ~/Documents/Tools/peon-ping && bash install.sh

On the first banner, macOS asks "Peon would like to send notifications". Allow. On the first click, macOS asks "Peon wants to control Ghostty". Allow. After that:

- Claude or Codex stops: banner "myrepo: done" with the peon icon, plus a peon voice line.
- Claude asks for a permission: banner with the peon icon, plus a voice line.
- Subagent done, pre-compact warning, Bash errors: voice line only, no banner.
- The idle reminder Claude sends when it has waited for you: silent within an hour of a "done" banner (existing peon-ping dedupe, `suppress_idle_prompt_repeats`), otherwise a banner, because it means Claude is waiting on you.
- Ghostty is the frontmost app: no banner (existing peon-ping behaviour), voice line still plays.
- The old osascript banner ("Claude Code needs your attention", Script Editor icon) no longer appears.

## Context

peon-ping is a bash tool that Claude Code and Codex call as a hook on every agent event. It maps each event to a category of the CESP spec (Coding Event Sound Pack, peon-ping's event taxonomy, e.g. `task.complete`, `input.required`, `task.error`, `resource.limit`), plays a sound from the active pack with `afplay`, and optionally shows a desktop notification. Fork: https://github.com/Fleron/peon-ping at v2.37.0 (commit 8ef3766). Personal fork, never merged back upstream, so staying in sync with upstream is not a goal.

Relevant files in the fork (line numbers at 8ef3766):

- `peon.sh` is the hook entry point. An embedded Python block decides per event whether to notify (the `notify` flag, starts at ~:5913). `Stop` (~:5990) and `Notification` with `idle_prompt` map to `task.complete` and notify. `PermissionRequest` (~:6048) maps to `input.required` and notifies. `SubagentStop` maps to `task.complete` and notifies. `suppress_subagent_complete` exists but exits before sound selection (~:6082-6092), so it silences sound, banner and tab title together. `Notification`/`idle_prompt` is already suppressed for 3600s after a `task.complete` in the same session (~:6168-6183, `suppress_idle_prompt_repeats: true` in config.json:19-20). `PreCompact` maps to `resource.limit` and notifies. `PostToolUseFailure` maps to `task.error` and only plays a sound. `categories.<cat>: false` in config turns off both sound and notification for a category (~:6214). Notifications are also skipped when the terminal is frontmost (`terminal_is_focused`, ~:6985). peon.sh exports `PEON_NOTIF_STYLE` and `PEON_BUNDLE_ID` (~:1038) and calls `scripts/notify.sh "$msg" "$title" "$color" "$icon_path"`. It writes the tab title `"${MARKER}${PROJECT}: ${STATUS}"` as OSC 0 to `/dev/$PEON_ENV_HOOK_TTY` (~:6818-6869), where `PEON_ENV_HOOK_TTY` is the session's tty found by walking parent processes (~:5208). Ghostty's bundle id `com.mitchellh.ghostty` is resolved at ~:794.
- `scripts/notify.sh` is the notifier. `notification_style` defaults to `overlay` (a JXA window, not a Notification Center entry). The `standard` branch (~:522) uses `terminal-notifier -title -message [-subtitle] -appIcon "$icon_path" -activate "$bundle_id" -group "peon-ping-${PEON_SESSION_ID}"` plus `-execute "$cmux_focus_cmd"` when a click command exists (~:547-556), else `osascript display notification` (~:567). The click command is built by `_terminal_focus_click_command` (~:168-195), which has cases for iTerm2 and VS Code but none for Ghostty. It receives the session tty as `$2` (notify.sh ~:348 passes `$PEON_SESSION_TTY`, exported by peon.sh ~:959-987, already prefixed with `/dev/`). notify.sh's `$title` argument is the project name, not the tab title.
- `install.sh` copies `scripts/*.sh|py|swift|js` from a local clone when run inside one (~:602-625), compiles Swift helpers with `swiftc -O` (`peon-play` ~:806, `meeting-detect` ~:822), registers Claude hooks in `~/.claude/settings.json` (~:1143-1215) and Codex hooks in `~/.codex/config.toml` via `scripts/codex-config.py` when `~/.codex` exists (~:1517). `~/.codex` exists on this machine. Install target is `~/.claude/hooks/peon-ping/`, icon at `~/.claude/hooks/peon-ping/docs/peon-icon.png`.
- `config.json` holds defaults. `peon update` backfills new keys.
- `tests/` is BATS (`bats tests/`). `tests/setup.bash` mocks `terminal-notifier` and `osascript` by logging their args. It does not override `HOME`, and 126 assertions across 7 test files expect the terminal-notifier mock.
- `config.json` has no `notification_style` key today. The `overlay` default comes from notify.sh ~:69. install.sh copies config.json only on a fresh install (~:412-414, 640-642). `~/.claude/settings.json` has no peon-ping hooks yet, so this is a fresh install.

Why a new app is needed: macOS draws a notification's left icon from the app that posts it. `osascript` posts as Script Editor. `terminal-notifier -appIcon` uses a private API that has been ignored since macOS 11, and terminal-notifier uses the deprecated `NSUserNotification` API. Only an app bundle with its own bundle id and icon, posting through `UNUserNotificationCenter`, shows the peon on the left.

Ghostty 1.3.1 (installed) has an AppleScript dictionary (`/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`) with classes `window`, `tab`, `terminal`; terminal properties `id`, `name`, `working directory`; and a `focus` command that selects the tab and raises the window. It does not expose tty or pid.

Machine: macOS 26.5.2, Xcode with Swift 6.3.3, no terminal-notifier. `~/.claude/settings.json` has a `Notification` hook running `osascript -e 'display notification "Claude Code needs your attention" with title "Claude Code"'` (~line 80-89).

Terms: *ad-hoc signing* is `codesign --sign -`, a local signature with no Apple Developer account. *OSC 0/2* are terminal escape sequences (`\033]0;TEXT\007`) that set the tab title. *Launch Services* is the macOS database that maps bundle ids to app paths; it must know Peon.app so a click can relaunch it.

## Approach

New app `Peon.app`, source in the fork at `native/peon-notify/`:

- `main.swift`, ~200 lines, one code path. It always sets the `UNUserNotificationCenterDelegate` before `NSApplication.run()`, so a click response is delivered to whichever instance is alive, whether a click launched it or an earlier post is still running.
  - If invoked with `-title T -message M [-subtitle S] [-group G] [-execute CMD]` (the flags notify.sh already builds for terminal-notifier), it requests authorization (alert only, no sound) and posts a `UNNotificationRequest` with `sound = nil`, thread id and identifier `G` so a newer banner for the same session replaces the older one, and `CMD` in `userInfo`.
  - If a response arrives, it runs `/bin/bash -c CMD` from `userInfo` and waits for it.
  - It exits after the add callback when it posted, after handling a response when one arrives, and in any case after 10s. That stops a double-clicked or response-less launch from sitting invisible forever.
- `Info.plist`: `CFBundleIdentifier` `com.fleron.peon-notify`, `CFBundleName` `Peon`, `CFBundleExecutable` `peon-notify`, `CFBundlePackageType` `APPL`, `LSUIElement` true (no Dock icon), `CFBundleIconFile` `AppIcon`, `NSAppleEventsUsageDescription` "Peon focuses the Ghostty tab you clicked."
- `build.sh`: `swiftc -O main.swift -o .../Contents/MacOS/peon-notify`, builds `AppIcon.icns` from `docs/peon-icon.png` with `sips` and `iconutil`, copies Info.plist, runs `codesign --force --sign - Peon.app`, then registers it with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Peon.app`. `lsregister` is not on PATH, so use that full path. Output goes to `~/Applications/Peon.app`. Rebuilding is safe to rerun.

Ghostty tab focus, new `scripts/ghostty-focus.sh <tty> <cwd>`:

1. Ask Ghostty for every terminal's `id` and `name`, and keep the list.
2. Write OSC 2 `peon-<8 random hex>` to `<tty>`.
3. Poll up to 1s (every 50ms) for the terminal whose `name` contains the marker. On a hit, `focus` it by `id`.
4. Write that terminal's own name from step 1 back to `<tty>` as OSC 2. The title is snapshotted at click time, so a click minutes after the banner restores the current title, not a stale one.
5. If no hit, focus the first terminal whose `working directory` equals `<cwd>`. If none, `activate` Ghostty.

It runs as a child of Peon.app, so macOS attributes the Apple Events to Peon and asks once for Automation permission to control Ghostty.

peon-ping changes in the fork:

- `scripts/notify.sh`: in the standard branch, before the `terminal-notifier` check, if `$PEON_NATIVE_NOTIFIER` is executable (default `~/Applications/Peon.app/Contents/MacOS/peon-notify`), call it with the same args array minus `-appIcon` and `-activate`, then return. In `_terminal_focus_click_command`, add a case for `com.mitchellh.ghostty` that returns the absolute path of `ghostty-focus.sh` (found with notify.sh's existing `_find_*` helper pattern, since Peon.app runs the click with a bare environment) followed by `"$session_tty" "$PWD"`, `%q`-quoted like the iTerm2 case. `$session_tty` is the function's `$2`, already a full `/dev/ttysNNN` path.
- `peon.sh`: new config key `notification_categories` (list, default `["task.complete", "input.required"]`). After the Python block sets `notify`, clear it when the event's category is not in the list, and also when the event is `SubagentStop`, because that maps to `task.complete` too. Sounds and tab titles are untouched. The idle reminder needs no change, since `suppress_idle_prompt_repeats` already dedupes it.
- `config.json`: add `notification_categories` and add `notification_style: "standard"`. `suppress_subagent_complete` stays false, since it would also mute the subagent sound. `peon update` backfill for `notification_categories`.
- `tests/setup.bash`: export `PEON_NATIVE_NOTIFIER=/nonexistent` by default, so existing tests keep hitting the terminal-notifier mock even after Peon.app is installed on the machine. Native-path tests override it with a mock script.
- `install.sh`: on macOS, run `native/peon-notify/build.sh` after the Swift helper builds, and copy `scripts/ghostty-focus.sh` with the other scripts.

Your settings: the installer merges its hooks into `~/.claude/settings.json` but does not remove unrelated hooks, so a step removes the old osascript `Notification` entry with a backup. The Codex hooks install automatically because `~/.codex` exists.

## Not doing

- No upstream PR, no Homebrew formula, no Developer ID signing or notarization.
- No overlay theme changes. Overlay mode stays available but is off in your config.
- No notification sound in the banner itself. `afplay` keeps playing it, with its volume, pack rotation and random line selection.
- No per-event images (e.g. an angry peon for errors). The peon is only the app icon.
- No terminal support beyond Ghostty for the new click behaviour. Other terminals keep their existing click commands.
- No Linux or Windows changes.
- No README translations or `docs/public/llms.txt` updates (upstream's contributor rules, not needed for a personal fork).

## Decisions

D1. Build our own Swift `Peon.app` instead of rebranding terminal-notifier. Costs half a day instead of an hour, and adds a compiled component to maintain.
D2. Ad-hoc signing only. If macOS 26.5 refuses notification authorization for an ad-hoc signed bundle, step 1 fails and the plan stops for a new decision (options then: a free Apple Development certificate from Xcode, or back to terminal-notifier `-contentImage`). Ad-hoc signatures change on every rebuild, and macOS keys both the notification and the Automation permission on the signature. Each rebuild can bring back the notification prompt, or silently deny Ghostty control. The fix is `tccutil reset AppleEvents com.fleron.peon-notify`, then toggle Peon off and on in System Settings > Notifications.
D3. Sound stays with `afplay`, and banners are posted silent. Banners follow Focus/Do Not Disturb, but sounds only follow peon-ping's own `focus_detect` setting.
D4. Peon.app is used whenever it is installed. There is no new `notification_style` value. Removing the app is how you turn it off.
D5. Tag-and-find tab focus at click time. The tab title flickers for up to a second on click, and each click runs a handful of `osascript` calls (one snapshot plus a few polls). A Ghostty update could rename the AppleScript terms. If you retitle the tab during that one-second window, the restore overwrites your change.
D6. The app lives in `~/Applications`, outside the peon-ping install dir, so Launch Services indexes it and System Settings lists it by name. Uninstalling peon-ping does not remove it.
D7. New `notification_categories` key plus a hardcoded `SubagentStop` banner skip in peon.sh. Subagent completions keep their sound, which is what you asked for, but you lose peon-ping's option to have subagent banners. This diverges from upstream, which is fine because the fork never syncs.D8. Error banners dropped. `PostToolUseFailure` fires on every failed Bash command, which Claude usually recovers from.
D9. Clone and install run in your own terminal. Claude's sandbox blocks writes to `.git/config` under `~/Documents/Tools`, and to `~/.claude/settings.json`, and blocks Launch Services, so I can't test notifications or clicks myself. Every validation that needs a banner is a command you run.
D10. The idle reminder keeps a banner when no "done" banner came within the hour. It stays because it means Claude is waiting on you.

## Steps

1. Spike: build a minimal Peon.app (post mode, click mode logging to `$TMPDIR/peon-click.log`) with `native/peon-notify/build.sh`, then post one test banner. → check: permission prompt appears, banner shows the peon on the left, and clicking writes a line to the log. If authorization is denied or the icon is generic, stop (D2).
2. Spike: in a Ghostty tab, run `printf '\033]2;peon-test\007'` and then `osascript -e 'tell application "Ghostty" to get name of every terminal of every tab of every window'` (adjust to the sdef's exact element names). → check: `peon-test` appears within 1s. If it doesn't, drop to cwd matching and record that in D5.
3. You clone the fork to `~/Documents/Tools/peon-ping` in your own terminal. I work there from a branch `native-notify`. → check: `git -C ~/Documents/Tools/peon-ping log --oneline -1` shows 8ef3766 or newer.
4. Add `PEON_NATIVE_NOTIFIER=/nonexistent` to `tests/setup.bash`. Then write `scripts/ghostty-focus.sh`, the Ghostty case in `_terminal_focus_click_command`, and the native branch in `scripts/notify.sh`. Add BATS tests in `tests/peon.bats`: with a mock `PEON_NATIVE_NOTIFIER` present, standard style calls it with `-title -message -group -execute` and never calls terminal-notifier. With it absent, terminal-notifier runs as before. With `PEON_BUNDLE_ID=com.mitchellh.ghostty`, the `-execute` value starts with an absolute path ending in `ghostty-focus.sh` and contains the session tty. → check: `bats tests/peon.bats -f native` passes.
5. Add `notification_categories` and the `SubagentStop` banner skip in peon.sh, the config defaults, and the `peon update` backfill. BATS tests:
   - `Stop` notifies.
   - `PermissionRequest` notifies.
   - `SubagentStop` plays a sound without notifying.
   - `PreCompact` plays a sound without notifying.
   - A Bash `PostToolUseFailure` still doesn't notify.

   → check: `bats tests/` passes in full.
6. Finish `main.swift` (single code path, group replacement, `-execute` on click, 10s exit) and hook `build.sh` into `install.sh`. → check: `bash install.sh` rebuilds `~/Applications/Peon.app`, `codesign -dv ~/Applications/Peon.app` shows `Signature=adhoc`, and `bats tests/` still passes with the real app installed. If clicks stop focusing Ghostty after this rebuild, run `tccutil reset AppleEvents com.fleron.peon-notify` and click again to get the prompt back (D2).
7. Back up and clean your settings: `cp ~/.claude/settings.json ~/.claude/settings.json.bak-peon`, then remove the old hook with
   `python3 -c 'import json,pathlib; p=pathlib.Path.home()/".claude/settings.json"; s=json.loads(p.read_text()); s["hooks"]["Notification"]=[m for m in s["hooks"].get("Notification",[]) if not any("needs your attention" in h.get("command","") for h in m.get("hooks",[]))]; p.write_text(json.dumps(s,indent=2)+"\n")'`.
   It is safe to rerun: a second run finds nothing to remove. It leaves any other `Notification` hooks alone. → check: `grep -c 'needs your attention' ~/.claude/settings.json` prints 0. Restore with `cp ~/.claude/settings.json.bak-peon ~/.claude/settings.json`.
8. Run `bash install.sh` from the clone in your own terminal. → check:
   - `grep -c peon.sh ~/.claude/settings.json` is at least 1.
   - `grep -c peon-ping ~/.codex/config.toml` is at least 1.
   - `~/.claude/hooks/peon-ping/scripts/ghostty-focus.sh` exists.
   - `grep -c '"notification_style": "standard"' ~/.claude/hooks/peon-ping/config.json` prints 1. If it prints 0, you're re-running over an older install. Add the key by hand.
9. Commit on `native-notify` and push to your fork. → check: `git status` is clean and the branch is on GitHub.

## Validation

All in your own terminal, in Ghostty.

- `~/Documents/Tools/peon-ping` `bats tests/` → all pass, including the new native and category tests.
- `~/Applications/Peon.app/Contents/MacOS/peon-notify -title Peon -message "Work complete" -group test` → a banner with the peon icon on the left, no sound from the banner itself.
- Real scenario, which proves the whole chain:
  1. Open two Ghostty tabs in the same repo, A and B.
  2. Start `claude` in both.
  3. In tab A, ask for something that takes 20+ seconds, then switch to another app, e.g. the browser.
  4. When A finishes: a peon voice line plays and a peon banner "repo: done" appears. Click it. Ghostty comes forward with tab A selected, not B.
- Approval: in tab B, ask Claude to run a command that needs permission, then switch apps. → a peon banner and a voice line. Clicking it focuses tab B.
- Quiet events:
  - Make a Bash command fail inside a session while Ghostty is in the background. → voice line only, no banner.
  - Ask for work that spawns a subagent. → the subagent's completion plays a voice line with no banner.
  - Wait 60s after a "done" banner without replying. → no second banner.
- Title restore: after clicking a banner, the tab title returns to what it was just before the click. No `peon-` marker is left behind.
- Codex: run `codex` in a Ghostty tab, let a task finish with Ghostty in the background. → peon banner plus voice line.
- Old hook gone: no "Claude Code needs your attention" banner with the Script Editor icon appears during any of the above.

## Skeleton

### File tree (fork `~/Documents/Tools/peon-ping`, branch `native-notify`)

```
peon-ping/
├── native/peon-notify/            NEW
│   ├── main.swift                 NEW   post + click handling, ~200 lines
│   ├── Info.plist                 NEW   bundle id, icon, LSUIElement, AppleEvents text
│   └── build.sh                   NEW   swiftc, icns, codesign, lsregister → ~/Applications/Peon.app
├── scripts/
│   ├── notify.sh                  EDIT  native branch (~:547), Ghostty click case (~:168-195)
│   └── ghostty-focus.sh           NEW   tag-and-find tab focus
├── peon.sh                        EDIT  notification_categories filter + SubagentStop skip (after ~:6094), peon update backfill
├── config.json                    EDIT  + notification_categories, + notification_style: "standard"
├── install.sh                     EDIT  run native/peon-notify/build.sh after Swift helpers (~:822); ghostty-focus.sh copied by scripts/*.sh glob
└── tests/
    ├── setup.bash                 EDIT  export PEON_NATIVE_NOTIFIER=/nonexistent
    └── peon.bats                  EDIT  native-backend tests + category tests

Outside the repo:
~/Applications/Peon.app            BUILT by build.sh
~/.claude/settings.json            EDIT  old osascript hook removed, peon hooks added by installer
~/.codex/config.toml               EDIT  peon hooks added by installer
~/.claude/hooks/peon-ping/         INSTALLED copy of the fork
```

### Runtime flow

```
Claude Code / Codex event
  → peon.sh: event → category, notify flag
      NEW: notify=false if category ∉ notification_categories or event == SubagentStop
      afplay voice line, OSC 0 tab title (unchanged)
      if notify and Ghostty not frontmost → scripts/notify.sh (standard)
          click_cmd: NEW Ghostty case → "/abs/ghostty-focus.sh /dev/ttysNNN /repo/path"
          NEW: $PEON_NATIVE_NOTIFIER executable? → peon-notify -title -message -group -execute click_cmd
               else terminal-notifier / osascript (unchanged)
  → Peon.app posts silent banner (peon icon), exits
Click → Launch Services relaunches Peon.app → didReceive → /bin/bash -c click_cmd
  → ghostty-focus.sh: snapshot names → OSC 2 marker → poll ≤1s → focus id → restore old name
     fallback: cwd match → activate Ghostty
```

### Code stubs

main.swift: `parseArgs(argv) -> PostArgs?`; `Delegate: NSApplicationDelegate, UNUserNotificationCenterDelegate` with `applicationDidFinishLaunching` (authorize, post if args, 10s exit timer), `didReceive` (run userInfo["execute"], exit), `willPresent` (.banner), `send` (sound nil, identifier = group, exit on add callback). Delegate set before `NSApplication.shared.run()`.

notify.sh:
```bash
    com.mitchellh.ghostty) printf '%q %q %q' "$(_find_ghostty_focus)" "$session_tty" "$PWD" ;;
native="${PEON_NATIVE_NOTIFIER:-$HOME/Applications/Peon.app/Contents/MacOS/peon-notify}"
if [ -x "$native" ]; then "$native" "${args_without_appicon_activate[@]}" >/dev/null 2>&1 & return 0; fi
```

peon.sh (Python block):
```python
allowed = cfg.get('notification_categories', ['task.complete', 'input.required'])
if notify and (category not in allowed or event == 'SubagentStop'):
    notify = ''
```

install.sh: on Darwin run `native/peon-notify/build.sh "$SRC"`, warn and continue on failure (old notifier stays as fallback).

New tests: native called instead of terminal-notifier; fallback when missing; Ghostty click cmd has absolute ghostty-focus.sh + tty; Stop/PermissionRequest notify; SubagentStop/PreCompact sound only; Bash failure sound only.
