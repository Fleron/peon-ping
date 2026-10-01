#!/usr/bin/env bats

load setup.bash

SID="2b4712ff-589d-4be9-90f5-9569a1c0bfb5"
TRANSCRIPT="/Users/dev/.claude/projects/-tmp-myproject/$SID.jsonl"

setup() {
  setup_test_env
  unset TMUX TMUX_PANE
  CODEX_SH="${PEON_SH%/peon.sh}/adapters/codex.sh"
  ln -sf "$PEON_SH" "$TEST_DIR/peon.sh"
}

teardown() {
  teardown_test_env
}

claude_event() {
  local event="$1" extra="${2-}"
  run_peon "{\"session_id\":\"$SID\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"/tmp/myproject\",\"permission_mode\":\"default\",\"hook_event_name\":\"$event\"$extra}"
  [ "$PEON_EXIT" -eq 0 ]
}

record() {
  jq -r "$1" "$TEST_DIR/sessions/$SID.json"
}

@test "Claude SessionStart writes a ready record with every key" {
  claude_event SessionStart ',"source":"startup"'
  [ "$(record .status)" = "ready" ]
  [ "$(record .v)" = "1" ]
  [ "$(record .session_id)" = "$SID" ]
  [ "$(record .agent)" = "claude" ]
  [ "$(record .event)" = "SessionStart" ]
  [ "$(record .cwd)" = "/tmp/myproject" ]
  [ "$(record .transcript_path)" = "$TRANSCRIPT" ]
  [ "$(record '.updated_at | type')" = "number" ]
  [ "$(record '[.focus | keys[]] | sort | join(",")')" = "bundle_id,tmux_bin,tmux_pane,tmux_socket,tty" ]
  [ "$(record '[keys[]] | sort | join(",")')" = "agent,agent_pid,cwd,event,focus,session_id,status,transcript_path,updated_at,v" ]
}

@test "Claude UserPromptSubmit records working" {
  claude_event UserPromptSubmit ',"prompt":"fix the build"'
  [ "$(record .status)" = "working" ]
}

@test "Claude PreCompact records compacting" {
  claude_event PreCompact ',"trigger":"auto","custom_instructions":""'
  [ "$(record .status)" = "compacting" ]
}

@test "Claude PermissionRequest records needs approval" {
  claude_event PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"rm -rf build"}'
  [ "$(record .status)" = "needs approval" ]
  [ "$(record .event)" = "PermissionRequest" ]
}

@test "Claude Notification permission_prompt records needs approval" {
  claude_event Notification ',"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"'
  [ "$(record .status)" = "needs approval" ]
}

@test "Claude Notification elicitation_dialog records question" {
  claude_event Notification ',"message":"Claude has a question","notification_type":"elicitation_dialog"'
  [ "$(record .status)" = "question" ]
}

@test "Claude Notification idle_prompt records done" {
  claude_event Notification ',"message":"Claude is waiting for your input","notification_type":"idle_prompt"'
  [ "$(record .status)" = "done" ]
}

@test "Claude Stop records done" {
  claude_event Stop ',"stop_hook_active":false'
  [ "$(record .status)" = "done" ]
}

@test "Claude SessionEnd records closed and keeps earlier focus and pid" {
  claude_event SessionStart ',"source":"startup"'
  tmp="$(mktemp)"
  jq '.agent_pid = 41234 | .focus.tmux_pane = "%14" | .focus.bundle_id = "com.mitchellh.ghostty"' \
    "$TEST_DIR/sessions/$SID.json" > "$tmp" && mv "$tmp" "$TEST_DIR/sessions/$SID.json"

  claude_event SessionEnd ',"reason":"prompt_input_exit"'
  [ "$(record .status)" = "closed" ]
  [ "$(record .event)" = "SessionEnd" ]
  [ "$(record .focus.tmux_pane)" = "%14" ]
  [ "$(record .focus.bundle_id)" = "com.mitchellh.ghostty" ]
  [ "$(record .agent_pid)" = "41234" ]
  [ "$(record .transcript_path)" = "$TRANSCRIPT" ]
}

@test "Codex SessionStart, PermissionRequest and Stop through the adapter" {
  export PEON_TEST=1
  codex_record="$TEST_DIR/sessions/codex-019a-codex-thread.json"
  echo '{"hook_event_name":"SessionStart","session_id":"019a-codex-thread","cwd":"/tmp/myproject","source":"startup"}' | bash "$CODEX_SH"
  [ "$(jq -r .status "$codex_record")" = "ready" ]
  [ "$(jq -r .agent "$codex_record")" = "codex" ]
  [ "$(jq -r .transcript_path "$codex_record")" = "" ]

  echo '{"hook_event_name":"PermissionRequest","session_id":"019a-codex-thread","cwd":"/tmp/myproject","tool_name":"Bash"}' | bash "$CODEX_SH"
  [ "$(jq -r .status "$codex_record")" = "needs approval" ]

  echo '{"hook_event_name":"Stop","session_id":"019a-codex-thread","cwd":"/tmp/myproject"}' | bash "$CODEX_SH"
  [ "$(jq -r .status "$codex_record")" = "done" ]
  [ "$(jq -r .agent "$codex_record")" = "codex" ]
}

@test "subagent events leave the parent record unchanged" {
  claude_event UserPromptSubmit ',"prompt":"go"'
  before="$(cat "$TEST_DIR/sessions/$SID.json")"

  claude_event SubagentStart ',"agent_id":"a1","agent_type":"Explore"'
  claude_event PermissionRequest ',"agent_id":"a1","agent_type":"Explore","tool_name":"Bash","tool_input":{"command":"ls"}'
  claude_event SubagentStop ',"agent_id":"a1","agent_type":"Explore","stop_hook_active":false'
  [ "$(cat "$TEST_DIR/sessions/$SID.json")" = "$before" ]
}

@test "paused PermissionRequest still writes the record" {
  touch "$TEST_DIR/.paused"
  claude_event PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"ls"}'
  [ "$(record .status)" = "needs approval" ]
  ! afplay_was_called
}

@test "non-Claude/Codex IDE events write no record" {
  run_peon '{"hook_event_name":"Stop","session_id":"cursor-abc","cwd":"/tmp/myproject","workspace_roots":["/tmp/myproject"]}'
  run_peon '{"hook_event_name":"SessionStart","session_id":"gemini-abc","cwd":"/tmp/myproject"}'
  [ ! -e "$TEST_DIR/sessions/cursor-abc.json" ]
  [ ! -e "$TEST_DIR/sessions/gemini-abc.json" ]
}

@test "records older than session_ttl_days are deleted on the next hook" {
  mkdir -p "$TEST_DIR/sessions"
  old_ts=$(( $(date +%s) - 8 * 86400 ))
  echo "{\"v\":1,\"session_id\":\"old\",\"updated_at\":$old_ts}" > "$TEST_DIR/sessions/old.json"
  echo "{\"v\":1,\"session_id\":\"fresh\",\"updated_at\":$(date +%s)}" > "$TEST_DIR/sessions/fresh.json"

  claude_event UserPromptSubmit ',"prompt":"go"'
  [ ! -e "$TEST_DIR/sessions/old.json" ]
  [ -e "$TEST_DIR/sessions/fresh.json" ]
  [ -e "$TEST_DIR/sessions/$SID.json" ]
}
