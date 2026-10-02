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
  [ "$(record '[keys[]] | sort | join(",")')" = "agent,agent_pid,cwd,daemon,event,focus,session_id,status,transcript_path,updated_at,v" ]
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
  jq '.agent_pid = 41234 | .focus.tty = "/dev/ttys012" | .focus.tmux_pane = "%14" | .focus.bundle_id = "com.mitchellh.ghostty"' \
    "$TEST_DIR/sessions/$SID.json" > "$tmp" && mv "$tmp" "$TEST_DIR/sessions/$SID.json"

  # The agent process is gone by SessionEnd: nothing on the process tree resolves.
  printf '#!/bin/sh\nexit 1\n' > "$MOCK_BIN/ps"
  chmod +x "$MOCK_BIN/ps"
  claude_event SessionEnd ',"reason":"prompt_input_exit"'
  [ "$(record .status)" = "closed" ]
  [ "$(record .event)" = "SessionEnd" ]
  [ "$(record .focus.tty)" = "/dev/ttys012" ]
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

# Fake process table: "pid ppid tty comm...". Any pid not listed (the hook's
# real parent) is parented to $1, so the hook walks into the fake ancestry.
fake_ancestry() {
  local root="$1"; shift
  printf '%s\n' "$@" > "$TEST_DIR/ps_table"
  cat > "$MOCK_BIN/ps" <<SCRIPT
#!/bin/bash
pid="" fmt=""
while [ \$# -gt 0 ]; do
  case "\$1" in -p) pid="\$2"; shift 2 ;; -o) fmt="\$2"; shift 2 ;; *) shift ;; esac
done
line=\$(awk -v p="\$pid" '\$1 == p' "$TEST_DIR/ps_table")
[ -n "\$line" ] || line="\$pid $root ?? bash"
read -r p_pid p_ppid p_tty p_comm <<<"\$line"
out=""
IFS=, read -ra cols <<<"\$fmt"
for c in "\${cols[@]}"; do
  case "\${c%=}" in ppid) out+="\$p_ppid " ;; tty) out+="\$p_tty " ;; comm) out+="\$p_comm " ;; esac
done
echo "\${out% }"
SCRIPT
  chmod +x "$MOCK_BIN/ps"
}

@test "daemon Claude session records the worker's own pty and blanks inherited focus" {
  mkdir -p "$TEST_DIR/sessions"
  echo "{\"v\":1,\"session_id\":\"$SID\",\"updated_at\":$(date +%s),\"focus\":{\"tty\":\"/dev/ttys021\",\"tmux_pane\":\"%14\",\"bundle_id\":\"com.mitchellh.ghostty\"}}" \
    > "$TEST_DIR/sessions/$SID.json"
  fake_ancestry 9001 \
    "9001 9002 ttys027 claude bg-spare --bg-spare /tmp/cc-daemon/spare/a.claim.sock" \
    "9002 9003 ?? claude bg-pty-host --bg-pty-host /tmp/cc-daemon/spare/a.pty.sock" \
    "9003 9004 ?? /Users/dev/.local/bin/claude" \
    "9004 9005 ttys021 claude agents" \
    "9005 1 ttys021 -zsh"
  export TMUX="/private/tmp/tmux-501/default,123,0" TMUX_PANE="%3" TERM_PROGRAM=ghostty

  claude_event UserPromptSubmit ',"prompt":"go"'
  [ "$(record .daemon)" = "true" ]
  [ "$(record .agent_pid)" = "9001" ]
  [ "$(record .focus.tty)" = "/dev/ttys027" ]
  [ "$(record '[.focus.tmux_socket, .focus.tmux_pane, .focus.tmux_bin, .focus.bundle_id] | join("")')" = "" ]
}

@test "daemon worker launched as plain claude under bg-pty-host is still a daemon session" {
  fake_ancestry 9001 \
    "9001 9002 ttys030 claude --session-id x" \
    "9002 1 ?? claude bg-pty-host --bg-pty-host /tmp/cc-daemon/spare/b.pty.sock"

  claude_event Stop ',"stop_hook_active":false'
  [ "$(record .daemon)" = "true" ]
  [ "$(record .focus.tty)" = "/dev/ttys030" ]
}

@test "plain terminal Claude session keeps its pane focus and daemon false" {
  fake_ancestry 9001 \
    "9001 9005 ttys016 claude" \
    "9005 1 ttys016 -zsh"
  export TERM_PROGRAM=ghostty

  claude_event PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"ls"}'
  [ "$(record .daemon)" = "false" ]
  [ "$(record .agent_pid)" = "9001" ]
  [ "$(record .focus.tty)" = "/dev/ttys016" ]
  [ "$(record .focus.bundle_id)" = "com.mitchellh.ghostty" ]
}

@test "Codex hooks from the tty-less app-server record a null agent_pid" {
  export PEON_TEST=1
  mkdir -p "$TEST_DIR/sessions"
  echo '{"v":1,"session_id":"codex-thread-1","updated_at":'"$(date +%s)"',"agent_pid":53960}' > "$TEST_DIR/sessions/codex-thread-1.json"
  fake_ancestry 9010 \
    "9010 9011 ?? codex app-server" \
    "9011 1 ?? launchd"

  echo '{"hook_event_name":"UserPromptSubmit","session_id":"thread-1","cwd":"/tmp/myproject","prompt":"go"}' | bash "$CODEX_SH"
  [ "$(jq -r .agent_pid "$TEST_DIR/sessions/codex-thread-1.json")" = "null" ]
  [ "$(jq -r .focus.tty "$TEST_DIR/sessions/codex-thread-1.json")" = "" ]
  [ "$(jq -r .daemon "$TEST_DIR/sessions/codex-thread-1.json")" = "false" ]
}

@test "Codex running on a terminal keeps its pid" {
  export PEON_TEST=1
  fake_ancestry 9010 \
    "9010 9011 ttys018 codex" \
    "9011 1 ttys018 -zsh"

  echo '{"hook_event_name":"UserPromptSubmit","session_id":"thread-2","cwd":"/tmp/myproject","prompt":"go"}' | bash "$CODEX_SH"
  [ "$(jq -r .agent_pid "$TEST_DIR/sessions/codex-thread-2.json")" = "9010" ]
  [ "$(jq -r .focus.tty "$TEST_DIR/sessions/codex-thread-2.json")" = "/dev/ttys018" ]
}
