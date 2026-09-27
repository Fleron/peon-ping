# Warcraft dialogue popup with hand-picked voice lines

## Outcome

When Claude finishes a task or needs approval, a popup appears in the screen corner. It has the size and rounded shape of a macOS notification banner, tinted dark orc red, with the peon portrait on the left. Above the line, "Peon" is in gold; the line that just played is in white, set in Friz Quadrata (Warcraft 3's interface font) if it's installed, otherwise Marcellus; and below that, in small text, `myrepo · done · Claude`. Codex gets the same popup tinted navy, with the peasant portrait and "Peasant". Clicking it jumps to the exact Ghostty tab, using the existing `scripts/ghostty-focus.sh`. After the usual 4 seconds it fades on its own.

The text is always the line that played, and lines rotate randomly per trigger with no immediate repeat. That's existing peon-ping behaviour, now using your picked lists:

| Trigger | Orc · Claude | Human · Codex |
|---|---|---|
| Done (popup) | Ready to work? · Work, work. · Something need doing? · Work complete. (WC2) · Done building ship! (WC2) · I can do that. · Be happy to. · Okie dokie. · OK. · Get 'em! · I'll try. | Ready to work. · Right-o. · All right. · Off I go, then! · More work? · Yes, milord. · I guess I can... · If you want... |
| Needs approval (popup) | Yes? · What you want? · Something need doing? · Hmm? · Ready to work? · Why not? · Whaaat? | Yes, milord? · What is it? · More work? · What? · We found a witch! May we burn her? |
| Error (sound only) | Me not that kind of orc! · Me busy, leave me alone! · No time for play. | That's it. I'm dead. · No one else available... · You're the king? Well, I didn't vote for you. · Help! Help! I'm being repressed! · A horse kicked me once. It hurt. |

Other triggers (session start, context full, prompt spam) keep the pack's original lines, so nothing that makes a sound today goes quiet.

Setup, in your own terminal from the worktree: run `bash install.sh`, which copies the two custom packs, the theme and the font into place. Then run the one-line config update in Validation. Your install already exists, so the installer only adds missing config keys and won't change `notification_style`, `default_pack` or `ide_rules` on its own.

## Context

Builds on the `worktree-native-notify` branch of https://github.com/Fleron/peon-ping (PR #1), which already has:
- `scripts/ghostty-focus.sh`, which focuses the exact Ghostty terminal.
- The Ghostty click case in `_terminal_focus_click_command` (`scripts/notify.sh`).
- The `notification_categories` banner filter in `peon.sh`, which applies to overlay popups too, since it clears the same `notify` flag.

Line numbers below are on that branch.

**Overlay popups** (`notification_style: "overlay"`, peon-ping's default).
- `scripts/notify.sh` `_resolve_overlay_theme` (:80-94) reads `overlay_theme`. It only accepts `jarvis|glass|sakura` (:91), and `_find_overlay` (:97-112) runs `scripts/mac-overlay-<theme>.js` with `osascript -l JavaScript`.
- The JXA script gets 14 positional args (notify.sh:489): `msg, color, icon_path, slot, dismiss_secs, bundle_id, ide_pid, session_tty, subtitle, position, notify_type, all_screens, screen_idx, close_button`. The click command comes through the environment as `PEON_CLICK_COMMAND` (:482).
- `scripts/mac-overlay.js` (419 lines) is the only theme that draws the icon and handles clicks fully:
  - it draws a borderless `NSWindow` at `NSStatusWindowLevel` (:264-282), with an `NSImageView` icon (:292-300);
  - on click it activates the bundle, then `runClickCommand` runs `PEON_CLICK_COMMAND` with `/bin/bash -lc` (:86-99, :119+);
  - it has a dismiss timer (:386) and sibling close through `NSDistributedNotificationCenter` (:396-414).
- Themes share no code. Each is a standalone file.
- For Ghostty, notify.sh already exports the ghostty-focus click command into `PEON_CLICK_COMMAND` for overlays, because the passthrough covers every bundle except iTerm2.

**Sound pick** (peon.sh ~:6261-6300).
- `pick = random.choice(candidates)` from `openpeon.json` `categories.<cat>.sounds[]`. It skips the previous file (`last_played`) and filters `disabled_sounds`. Only `pick['file']` is used; `label` is ignored.
- The Python block prints `KEY=value` lines that bash evals (`SOUND_FILE` :6604).
- The notify env block is peon.sh:1036-1080.

**Pack choice** (peon.sh:5655-5760).
- The order is session override, then `path_rules`, then `ide_rules`, then rotation, then `default_pack`.
- `ide_rules` entries are `{"ide": "codex", "pack": "<name>"}`, matched against `session_ide` (hook `source`, else a `codex-` session-id prefix, else `claude`).
- A rule only applies if `$PEON_DIR/packs/<name>/` exists.

**Packs** live in `~/.claude/hooks/peon-ping/packs/<name>/`, with `openpeon.json` and `sounds/`.
- A bare `file` resolves under `sounds/`.
- The per-pack portrait reaches the overlay through peon.sh's icon chain (:6294-6302). That chain reads the manifest's `icon`, or an `icon.png`, into `ICON_PATH`, which is passed as `icon_path` (:7007). Without that key, notify.sh falls back to `_resolve_pack_icon`, which reads `default_pack` instead of the active pack (notify.sh:251). Codex would then get the peon portrait.
- On an existing install (`UPDATING=true`, install.sh:412-415), `config.json` isn't copied (:643-645). The update merge (:699-730) only adds missing keys.
- The overlay mock in `tests/setup.bash:291-298` logs argv, plus `PEON_WARP_FOCUS_URL` as a special case.
- Nothing checks sha256 for local packs.
- `install.sh` has no step that copies packs from the repo.

**Sources.** Sounds come from PeonPing/og-packs (`peon`, `peasant` v1.0.0) and dmurai/zugzug v1.1.0, all CC-BY-NC-4.0. Portraits are already at `native/peon-notify/icons/{peon,peasant}.gif`.

**Fonts.** Friz Quadrata is commercial and ships with Warcraft 3 and WoW. Marcellus is OFL, from google/fonts on GitHub. The repo has no custom-font loading yet; `NSFont.fontWithNameSize` is used by the other themes.

## Approach

1. **Two custom packs, committed in the repo.** They go in `custom-packs/orc_custom/` and `custom-packs/human_custom/`, each with `openpeon.json`, `sounds/` and `portrait.gif`. The manifest's `task.complete`, `input.required` and `task.error` lists are exactly the table above. Labels are fixed where the source labels were wrong:
   - PeonYesAttack2 → "Get 'em!"
   - PeonYesAttack3 → "I'll try."
   - zugzug Done → "Work complete."
   - zugzug Done 2 → "Done building ship!"

   All other categories are copied unchanged from `peon` and `peasant`. Top-level manifest fields:
   - `"icon": "portrait.gif"`, so each pack shows its own portrait.
   - `"speaker": "Peon"` or `"Peasant"`.
   - `"tint": "orc"` or `"human"`.

   peon-ping ignores unknown keys. A throwaway script in the temp dir builds the packs once, and it isn't committed. To change picks later, edit `openpeon.json` by hand.
2. **peon.sh exports the line and theme info.**
   - Next to the pick, set `sound_label = pick.get('label','')`, and read `speaker` and `tint` from the manifest.
   - Print `SOUND_LABEL`, `PACK_SPEAKER` and `PACK_TINT`.
   - Export them as `PEON_SOUND_LABEL`, `PEON_PACK_SPEAKER` and `PEON_PACK_TINT` in the notify env block.
3. **New theme, `scripts/mac-overlay-warcraft.js`,** forked from `mac-overlay.js` so click-to-focus, dismiss and sibling-close stay identical. Only the drawing changes:
   - A rounded 18 px panel, about 360×72, tinted `rgba(84,24,18,.94)` for orc or `rgba(28,52,104,.94)` for human, with a hairline white rim.
   - A 40 px portrait with 9 px corners.
   - Row 1: speaker name in gold `#ffcc00`, Friz Quadrata 13 pt.
   - Row 2: the voice line in white, 15.5 pt. If `PEON_SOUND_LABEL` is empty, it falls back to `msg`.
   - Row 3: `<project> · <status> · <agent>` in 12 pt system font at 82% white. Where each part comes from:
     - project: the notification title (`NOTIFY_TITLE`, e.g. "myrepo"), passed in a new `PEON_NOTIF_TITLE` env var, because it isn't among the 14 args;
     - status: `msg` (argv 0, e.g. "done" or "needs approval: Bash");
     - agent: "Codex" when `PEON_SESSION_IDE` is `codex`, otherwise "Claude".

   The font is resolved in this order:
   1. `fontWithNameSize("FrizQuadrataTT")`, then `"Friz Quadrata TT"`, then `"FrizQuadrataStd"`, if installed.
   2. Otherwise, register the bundled `scripts/fonts/Marcellus-Regular.ttf` for this process with `CTFontManagerRegisterFontsForURL` and use `"Marcellus-Regular"`.
   3. Otherwise, Georgia.
4. **notify.sh** adds `warcraft` to the accepted theme list (:91). It also sets `PEON_NOTIF_TITLE="$title"` on the overlay's `osascript` spawn, next to `PEON_CLICK_COMMAND`, at both spawn sites: the all-screens loop (:482) and the single-screen branch (:494). `PEON_SESSION_IDE`, `PEON_SOUND_LABEL`, `PEON_PACK_SPEAKER` and `PEON_PACK_TINT` are already exported from peon.sh, so the theme inherits them.
5. **Config defaults** (`config.json`):
   - `notification_style: "overlay"` and `overlay_theme: "warcraft"`
   - `default_pack: "orc_custom"`
   - `ide_rules: [{"ide":"codex","pack":"human_custom"}]`
6. **install.sh** copies `custom-packs/*/` into `$INSTALL_DIR/packs/` from a local clone, and copies `scripts/fonts/`. That goes near the existing local-clone script copy (~:618-645), and it echoes `Installed custom pack: <name>` for each pack. It also keeps building Peon.app and Peasant.app, which aren't used while the style is overlay.

## Not doing

- No changes to the native Notification Center path. Peon.app and Peasant.app stay for `notification_style: "standard"` and are simply unused by default.
- No animated portraits. They're possible in an overlay, but out of scope.
- No new triggers such as session start or subagent done with popups. Those are a later idea, and so are the unused lines.
- No upstreaming, no curl-install support for the new theme or packs, and no README translations.
- No other terminals. The click behaviour works as it does today for non-Ghostty terminals.

## Decisions

D1. Use a custom popup instead of Notification Center. You get full colors and fonts, but lose Notification Center history, and macOS Focus no longer hides it. peon-ping's own `focus_detect` stands in for Focus.
D2. Fork `mac-overlay.js` instead of writing a theme from scratch. That's about 400 duplicated lines, the same pattern every other theme follows. The benefit is that click-to-focus and dismiss behave exactly as they already do.
D3. Commit sound files for the custom packs into the fork, about 1.5 MB of CC-BY-NC audio. It's a personal fork, so the non-commercial license is fine. The installer then needs no downloads.
D4. Use Friz Quadrata only if you already have it installed, with Marcellus bundled as the fallback. We can't bundle Friz legally, so your popup looks slightly different on a machine without it.
D5. Keep the pack's original lines for the triggers you didn't pick (session start, context full, spam). The consequence is that "Why not?" and "Whaaat?" can also play for those triggers, as they do today.
D6. Put theme data (speaker, tint) in the pack manifest instead of hard-coding it by agent. Changing a pack changes the popup, and nothing else in peon-ping reads those fields.
D8. On an existing install, a one-time config command in Validation switches you to the popup and packs. The installer isn't changed to overwrite existing keys. It's one extra command you run once, and the installer keeps its rule of never overwriting your settings.
D9. Custom packs live in `custom-packs/`, not `packs/`. peon.sh treats a `packs/` folder next to itself as its data folder (peon.sh:178), so a `packs/` folder in the repo would make the clone act as an install. The cost is a folder name that differs from the installed layout.
D10. The panel is an `NSBox` (corner radius, fill and border set from `NSColor`) instead of a styled layer. Setting CGColor layer properties from JXA crashed osascript. The cost is square portrait corners, which suits the framed WC3 portraits anyway.
D7. You run the final visual check in your terminal. My sandbox blocks drawing windows and Apple Events, so I can only unit-test the data flow, not how the popup looks.

## Steps

1. Use the source audio already downloaded to `/tmp/claude-501/sounds/{peon,peasant,zugzug}/` (flat, no `sounds/` subdir), and the manifests with the file-to-label mapping at `/tmp/claude-501/{peon,peasant,zugzug}-manifest.json`. Those came from `https://raw.githubusercontent.com/PeonPing/og-packs/v1.0.0/{peon,peasant}/` and `https://raw.githubusercontent.com/dmurai/zugzug/v1.1.0/`. Build `custom-packs/orc_custom/` and `custom-packs/human_custom/` with a throwaway script. → check: `python3 -c` over each `openpeon.json` prints the table above exactly, `icon` is `portrait.gif`, and every referenced file exists.
2. Download `Marcellus-Regular.ttf` and its `OFL.txt` from google/fonts into `scripts/fonts/`. → check: `file` reports a TrueType font.
3. peon.sh: export `SOUND_LABEL`, `PACK_SPEAKER` and `PACK_TINT`. Add a BATS test: with a fixture pack whose single `task.complete` sound has label "Work complete.", a `Stop` event reaches the overlay with `PEON_SOUND_LABEL="Work complete."`, `PEON_PACK_SPEAKER` and `PEON_PACK_TINT` set, and with the pack's `portrait.gif` as `icon_path`. Extend the existing overlay mock in `tests/setup.bash:291-298` to log those vars and `PEON_NOTIF_TITLE`, the same way it logs `PEON_WARP_FOCUS_URL`. → check: `bats tests/native-notify.bats` passes.
4. Write `scripts/mac-overlay-warcraft.js` and the notify.sh theme entry. Add a BATS test: `overlay_theme: warcraft` runs `mac-overlay-warcraft.js`, using the mock osascript that already logs overlay invocations. → check: the test passes, and `osascript -l JavaScript` syntax-compiles the file (`osacompile -l JavaScript -o /dev/null`).
5. config.json defaults and the install.sh pack and font copy. Add a BATS install test: a local-clone install produces `packs/orc_custom/openpeon.json`, `packs/human_custom/openpeon.json` and `scripts/fonts/Marcellus-Regular.ttf`. → check: `bats tests/install.bats` passes, with the same pre-existing results as before.
6. Run the full suite per file against the baseline, the same way as last time. → check: no new failures.
7. Commit and push to `worktree-native-notify`, and update PR #1's description. → check: `git status` is clean, and the PR shows the new commits.

## Validation

In your terminal, in Ghostty, from `~/Documents/Tools/peon-ping/.claude/worktrees/native-notify`:

- `bash install.sh` → the output includes `Installed custom pack: orc_custom` and `Installed custom pack: human_custom`.
- One-time config switch, with a backup first:
  ```
  cp ~/.claude/hooks/peon-ping/config.json ~/.claude/hooks/peon-ping/config.json.bak-warcraft
  python3 -c 'import json,pathlib; p=pathlib.Path.home()/".claude/hooks/peon-ping/config.json"; c=json.loads(p.read_text()); c.update(notification_style="overlay", overlay_theme="warcraft", default_pack="orc_custom", ide_rules=[{"ide":"codex","pack":"human_custom"}]); p.write_text(json.dumps(c,indent=2)+"\n")'
  ```
  It's safe to rerun. Check with `python3 -c 'import json,pathlib; c=json.loads((pathlib.Path.home()/".claude/hooks/peon-ping/config.json").read_text()); print(c["notification_style"], c["overlay_theme"], c["default_pack"], c["ide_rules"])'`, which should print `overlay warcraft orc_custom [{'ide': 'codex', 'pack': 'human_custom'}]`.
- Preview without an agent: `PEON_SOUND_LABEL="Work complete." PEON_PACK_SPEAKER=Peon PEON_PACK_TINT=orc PEON_NOTIF_TITLE=myrepo osascript -l JavaScript ~/.claude/hooks/peon-ping/scripts/mac-overlay-warcraft.js "done" blue ~/.claude/hooks/peon-ping/packs/orc_custom/portrait.gif 0 6 com.mitchellh.ghostty 0 "" "" top-right complete true 0 true` → you see the red popup with the peon, gold "Peon", white "Work complete.", and small "myrepo" text. Repeat with `Peasant`/`human`/`peasant` for the navy one.
- Real run: in a Ghostty tab, have Claude do a 20-second task and switch to the browser. A voice line plays, and the popup shows that same line. Clicking it returns you to the tab. Then do the same with `codex`, which should give the navy peasant popup.
- An approval request gives a popup with an approval line, for example "What you want?". A failed Bash command plays an error line with no popup.
