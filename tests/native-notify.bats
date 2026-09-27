#!/usr/bin/env bats

load setup.bash

setup() {
  setup_test_env
  export PEON_PLATFORM=mac
  export CMUX_SOCKET_PATH= CMUX_SOCKET= CMUX_WORKSPACE_ID= CMUX_SURFACE_ID= CMUX_BUNDLED_CLI_PATH= CMUX_BUNDLE_ID=
  cat > "$TEST_DIR/config.json" <<'JSON'
{ "default_pack": "peon", "volume": 0.5, "enabled": true, "desktop_notifications": true, "notification_style": "standard", "categories": { "task.complete": true, "input.required": true, "resource.limit": true, "task.error": true } }
JSON
  cat > "$TEST_DIR/peon-notify" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$@" >> "${CLAUDE_PEON_DIR}/native_notifier.log"
SCRIPT
  chmod +x "$TEST_DIR/peon-notify"
}

teardown() {
  teardown_test_env
}

native_log() { cat "$TEST_DIR/native_notifier.log" 2>/dev/null; }
any_banner() { [ -s "$TEST_DIR/native_notifier.log" ] || [ -s "$TEST_DIR/terminal_notifier.log" ]; }

@test "native: standard style posts through Peon.app instead of terminal-notifier" {
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  [[ "$(native_log)" == *"-title"* ]]
  [[ "$(native_log)" == *"myproject"* ]]
  [[ "$(native_log)" == *"peon-ping-s1"* ]]
  ! [[ "$(native_log)" == *"-appIcon"* ]]
  ! [ -f "$TEST_DIR/terminal_notifier.log" ]
}

install_mock_apps() {
  for app in Peon Peasant; do
    mkdir -p "$TEST_DIR/apps/$app.app/Contents/MacOS"
    printf '#!/bin/bash\necho %s >> "%s/which_app.log"\n' "$app" "$TEST_DIR" > "$TEST_DIR/apps/$app.app/Contents/MacOS/peon-notify"
    chmod +x "$TEST_DIR/apps/$app.app/Contents/MacOS/peon-notify"
  done
  unset PEON_NATIVE_NOTIFIER
  export PEON_NATIVE_APPS_DIR="$TEST_DIR/apps"
}

@test "native: Claude sessions post through Peon.app" {
  install_mock_apps
  run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$(cat "$TEST_DIR/which_app.log")" = "Peon" ]
}

@test "native: Codex sessions post through Peasant.app" {
  install_mock_apps
  run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"codex-1","source":"codex","permission_mode":"default"}'
  [ "$(cat "$TEST_DIR/which_app.log")" = "Peasant" ]
}

@test "native: falls back to terminal-notifier when Peon.app is missing" {
  run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  ! [ -f "$TEST_DIR/native_notifier.log" ]
  [ -s "$TEST_DIR/terminal_notifier.log" ]
}

@test "native: Ghostty click runs ghostty-focus.sh by absolute path" {
  cp "$(dirname "$PEON_SH")/scripts/ghostty-focus.sh" "$TEST_DIR/scripts/ghostty-focus.sh"
  chmod +x "$TEST_DIR/scripts/ghostty-focus.sh"
  TERM_PROGRAM=ghostty PEON_SESSION_TTY=/dev/ttys042 PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  local execute
  execute="$(native_log | grep -A1 -x -- '-execute' | tail -1)"
  [[ "$execute" == /*"/scripts/ghostty-focus.sh /dev/ttys042 "* ]]
}

@test "categories: PermissionRequest shows a banner" {
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"PermissionRequest","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default","tool_name":"Bash"}'
  [ "$PEON_EXIT" -eq 0 ]
  afplay_was_called
  [ -s "$TEST_DIR/native_notifier.log" ]
}

@test "categories: SubagentStop plays a sound without a banner" {
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"SubagentStop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  afplay_was_called
  ! any_banner
}

@test "categories: PreCompact plays a sound without a banner" {
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"PreCompact","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  afplay_was_called
  ! any_banner
}

@test "categories: failed Bash command plays a sound without a banner" {
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Exit code 1","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  afplay_was_called
  ! any_banner
}

@test "categories: notification_categories can re-enable resource.limit banners" {
  /usr/bin/python3 -c "
import json
cfg = json.load(open('$TEST_DIR/config.json'))
cfg['notification_categories'] = ['task.complete', 'input.required', 'resource.limit']
json.dump(cfg, open('$TEST_DIR/config.json', 'w'))
"
  PEON_NATIVE_NOTIFIER="$TEST_DIR/peon-notify" run_peon '{"hook_event_name":"PreCompact","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  [ -s "$TEST_DIR/native_notifier.log" ]
}

# Mock Ghostty: terminal T2 "sees" a title once it has been written to the fake tty.
write_ghostty_mock() {
  cat > "$TEST_DIR/osascript" <<SCRIPT
#!/bin/bash
echo "\$*" >> "$TEST_DIR/osascript_calls.log"
case "\$*" in
  *out.push*) printf 'T1\tother: done\nT2\tmyproject: done\n' ;;
  *" name peon-"*) [ "$1" = seen ] && grep -q "\${@: -1}" "$TEST_DIR/fake-tty" && echo T2 ;;
  *" cwd /tmp/myproject") echo T3 ;;
esac
SCRIPT
  chmod +x "$TEST_DIR/osascript"
  : > "$TEST_DIR/fake-tty"
}

@test "ghostty-focus: focuses the tagged terminal and restores its title" {
  write_ghostty_mock seen
  PEON_OSASCRIPT="$TEST_DIR/osascript" run bash "$(dirname "$PEON_SH")/scripts/ghostty-focus.sh" "$TEST_DIR/fake-tty" /tmp/myproject
  [ "$status" -eq 0 ]
  grep -q " name peon-" "$TEST_DIR/osascript_calls.log"
  [ "$(cat "$TEST_DIR/fake-tty")" = "$(printf '\033]2;myproject: done\007')" ]
  ! grep -q " cwd " "$TEST_DIR/osascript_calls.log"
}

@test "ghostty-focus: falls back to working directory when the tag is never seen" {
  write_ghostty_mock unseen
  PEON_OSASCRIPT="$TEST_DIR/osascript" run bash "$(dirname "$PEON_SH")/scripts/ghostty-focus.sh" "$TEST_DIR/fake-tty" /tmp/myproject
  [ "$status" -eq 0 ]
  grep -q " cwd /tmp/myproject" "$TEST_DIR/osascript_calls.log"
  ! grep -q "to activate" "$TEST_DIR/osascript_calls.log"
}

warcraft_setup() {
  local src; src="$(dirname "$PEON_SH")"
  cp -R "$src/custom-packs/orc_custom" "$src/custom-packs/human_custom" "$TEST_DIR/packs/"
  cp "$src/scripts/mac-overlay-warcraft.js" "$TEST_DIR/scripts/"
  cat > "$TEST_DIR/config.json" <<'JSON'
{ "default_pack": "orc_custom", "volume": 0.5, "enabled": true, "desktop_notifications": true,
  "notification_style": "overlay", "overlay_theme": "warcraft",
  "ide_rules": [{"ide": "codex", "pack": "human_custom"}],
  "categories": { "task.complete": true, "input.required": true, "task.error": true } }
JSON
}

# The overlay line must carry a label from <pack>'s <category> list.
assert_label_from() {
  local line labels l
  line="$(cat "$TEST_DIR/overlay.log")"
  labels="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("\n".join(s["label"] for s in m["categories"][sys.argv[2]]["sounds"]))' "$TEST_DIR/packs/$1/openpeon.json" "$2")"
  while IFS= read -r l; do
    [[ "$line" == *"PEON_SOUND_LABEL=$l PEON_PACK_SPEAKER"* ]] && return 0
  done <<< "$labels"
  echo "no $1/$2 label in: $line" >&2
  return 1
}

@test "warcraft: Claude done popup gets orc line, speaker, tint, project and portrait" {
  warcraft_setup
  run_peon '{"hook_event_name":"Stop","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  local line; line="$(cat "$TEST_DIR/overlay.log")"
  [[ "$line" == *"mac-overlay-warcraft.js"* ]]
  [[ "$line" == *"packs/orc_custom/portrait.gif"* ]]
  [[ "$line" == *"PEON_PACK_SPEAKER=Peon PEON_PACK_TINT=orc PEON_NOTIF_TITLE=myproject"* ]]
  assert_label_from orc_custom task.complete
}

@test "warcraft: Codex approval popup gets human line and peasant portrait" {
  warcraft_setup
  run_peon '{"hook_event_name":"PermissionRequest","cwd":"/tmp/myproject","session_id":"codex-1","source":"codex","permission_mode":"default","tool_name":"Bash"}'
  [ "$PEON_EXIT" -eq 0 ]
  local line; line="$(cat "$TEST_DIR/overlay.log")"
  [[ "$line" == *"packs/human_custom/portrait.gif"* ]]
  [[ "$line" == *"PEON_PACK_SPEAKER=Peasant PEON_PACK_TINT=human"* ]]
  assert_label_from human_custom input.required
}

@test "warcraft: failed Bash command plays an error line without a popup" {
  warcraft_setup
  run_peon '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","error":"Exit code 1","cwd":"/tmp/myproject","session_id":"s1","permission_mode":"default"}'
  [ "$PEON_EXIT" -eq 0 ]
  afplay_was_called
  [[ "$(afplay_sound)" == *"packs/orc_custom/sounds/"* ]]
  ! [ -s "$TEST_DIR/overlay.log" ]
}
