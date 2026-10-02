#!/bin/bash
# peon-ping: focus the exact Ghostty terminal that owns a tty.
# Usage: ghostty-focus.sh <tty> <cwd>
#
# Ghostty's AppleScript exposes terminal id/name/working directory but not the
# tty (ghostty-org/ghostty#11592), so we tag the tty with a unique title, find
# the terminal carrying it, focus it, and restore its previous title.
set -uo pipefail

tty_path="${1:-}"
cwd="${2:-}"
osascript_bin="${PEON_OSASCRIPT:-/usr/bin/osascript}"

_jxa() { "$osascript_bin" -l JavaScript -e "$1" "${@:2}" 2>/dev/null; }

_snapshot() {
  _jxa 'function run(){var ts=Application("Ghostty").terminals();var out=[];
for(var i=0;i<ts.length;i++){try{out.push(ts[i].id()+"\t"+ts[i].name())}catch(e){}}
return out.join("\n")}'
}

# `focus` alone does nothing visible when the terminal sits in a background tab,
# so select its tab and raise its window first.
_focus_where() {
  _jxa 'function reveal(g,id){var ws=g.windows();for(var w=0;w<ws.length;w++){var tabs=ws[w].tabs();
for(var t=0;t<tabs.length;t++){var tt=tabs[t].terminals();for(var k=0;k<tt.length;k++){if(tt[k].id()===id){
try{g.selectTab(tabs[t])}catch(e){}try{g.activateWindow(ws[w])}catch(e){}return}}}}}
function run(argv){var field=argv[0],value=argv[1];var g=Application("Ghostty");var ts=g.terminals();
for(var i=0;i<ts.length;i++){try{var v=field==="name"?ts[i].name():ts[i].workingDirectory();
var hit=field==="name"?v.indexOf(value)!==-1:v===value;
if(hit){var id=ts[i].id();try{reveal(g,id)}catch(e){}g.focus(ts[i]);g.activate();return id}}catch(e){}}return ""}' "$1" "$2"
}

_set_title() { printf '\033]2;%s\007' "$1" > "$tty_path" 2>/dev/null; }

if [ -n "$tty_path" ] && [ -w "$tty_path" ]; then
  snapshot="$(_snapshot)"
  marker="peon-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  _set_title "$marker"
  focused_id=""
  for _ in 1 2 3 4 5; do
    focused_id="$(_focus_where name "$marker")"
    [ -n "$focused_id" ] && break
    sleep 0.1
  done
  if [ -n "$focused_id" ]; then
    _set_title "$(printf '%s\n' "$snapshot" | awk -F'\t' -v id="$focused_id" '$1 == id { sub(/^[^\t]*\t/, ""); print; exit }')"
    exit 0
  fi
  _set_title ""
fi

if [ -n "$cwd" ] && [ -n "$(_focus_where cwd "$cwd")" ]; then
  exit 0
fi
"$osascript_bin" -e 'tell application "Ghostty" to activate' >/dev/null 2>&1
