#!/usr/bin/env bash
# End to end, with the real tmux-resurrect, what the security review of fork.11 found.
# Finding 1: resurrect shows a pane's saved contents by running
#   cat '<folder>/pane-<session>:<window>.<pane>'; exec <shell>
# through sh, with the session name inside the quotes as it is, so a quote in the name ran what
# followed it at restore. Names are saved safe (scripts/save-hook.sh), and a save made before that
# is made safe before resurrect reads it (scripts/pre-restore.sh). Throwaway tmux server and HOME.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tmux-resurrect.
set -u
here=$(cd "$(dirname "$0")" && pwd)
RESURRECT=${PLUGINS_DIR:-$HOME/.tmux/plugins}/tmux-resurrect/scripts
D=$(mktemp -d)
socket=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/restore-security
trap 'tmux -L restore-security kill-server 2> /dev/null; rm -rf "$D" "$socket"{,.resurrect-restore.lock}' EXIT
mkdir -p "$D/home"
R=$D/home/.local/share/tmux/resurrect
T() { HOME=$D/home XDG_DATA_HOME="" tmux -L restore-security "$@"; }
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
# stop: kill the server and wait until it's gone, so the next one doesn't meet it on its way out
stop() { T kill-server 2> /dev/null; for _ in $(seq 50); do T list-sessions > /dev/null 2>&1 || return 0; sleep 0.1; done; }
# restore: start a server with tmux-restore loaded and restore into it, as at boot
restore() {
	: > "$D/log"
	T -f "$D/plugin.conf" new-session -d -s scratch
	sleep 1
	T run-shell -b "$RESURRECT/restore.sh"
	for _ in $(seq 60); do grep -q "done" "$D/log" 2> /dev/null && break; sleep 0.5; done
}
# a session with that name and something on its screen, saved
session_saved() {
	T -f "$1" new-session -d -s "$name"
	T send-keys -t "$(T list-panes -a -F '#{pane_id}' | head -1)" 'echo on screen' Enter
	sleep 1
	T run-shell "$RESURRECT/save.sh quiet"
}
sessions() { T list-sessions -F '#S' 2> /dev/null | sort | tr '\n' '|'; }

name="x'; cd; touch MARK; '" # no "/": tmux can't save a name with one
safe="x__ cd_ touch MARK_ _"
printf '%s\n' "set -g @resurrect-processes 'false'" "set -g @resurrect-capture-pane-contents 'on'" > "$D/plain.conf"
printf '%s\n' "set -g @resurrect-processes 'false'" \
	"set -g @resurrect-hook-post-restore-all \"echo done >> '$D/log'\"" "run-shell '$here/../tmux-restore.tmux'" > "$D/plugin.conf"

# 1a. Saved with tmux-restore: the name is saved safe, and nothing runs at restore.
session_saved "$D/plugin.conf"
check "1a. the save has the safe name" "$safe" "$(awk -F'\t' '$1 == "pane" { print $2; exit }' "$R/last")"
stop
restore
check "1a. nothing ran at restore" no "$([[ -e $D/home/MARK ]] && echo yes || echo no)"
check "1a. the session came back with the safe name" "scratch|$safe|" "$(sessions)"
stop

# 1b. Saved without tmux-restore, as before fork.12: made safe before resurrect reads it.
rm -rf "$R" "$D/home/MARK"
session_saved "$D/plain.conf"
check "1b. a save with the name as it was (the bug this guards against)" "$name" "$(awk -F'\t' '$1 == "pane" { print $2; exit }' "$R/last")"
stop
restore
check "1b. nothing ran at restore" no "$([[ -e $D/home/MARK ]] && echo yes || echo no)"
check "1b. the session came back with the safe name" "scratch|$safe|" "$(sessions)"
stop

echo "passed=$pass failed=$fail"; (( fail == 0 ))
