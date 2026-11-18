#!/usr/bin/env bash
# End to end, with the real tmux-resurrect: a save made after the tmux server went away (as at
# shutdown) is empty, and resurrect makes it `last`. The next restore must still bring back the
# last good save (scripts/pre-restore.sh mends `last`). Throwaway tmux server and HOME.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tmux-resurrect.
set -u
here=$(cd "$(dirname "$0")" && pwd)
RESURRECT=${PLUGINS_DIR:-$HOME/.tmux/plugins}/tmux-resurrect/scripts
D=$(mktemp -d)
socket=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/empty-save
trap 'tmux -L empty-save kill-server 2> /dev/null; rm -rf "$D" "$socket"{,.resurrect-restore.lock}' EXIT
mkdir -p "$D/home"
# resurrect's default save folder, as at shutdown (a dead server can't tell it @resurrect-dir)
R=$D/home/.local/share/tmux/resurrect
T() { HOME=$D/home XDG_DATA_HOME="" tmux -L empty-save "$@"; }
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
printf '%s\n' "set -g @resurrect-processes 'false'" \
	"set -g @resurrect-hook-pre-restore-all '$here/../scripts/pre-restore.sh'" \
	"set -g @resurrect-hook-post-restore-all \"echo done >> '$D/log'\"" > "$D/test.conf"

T -f "$D/test.conf" new-session -d -s work -n one; T new-window -d -t work -n two; sleep 1
T run-shell "$RESURRECT/save.sh quiet"
check "a good save" yes "$(grep -q $'^pane\twork' "$R/last" && echo yes)"
T kill-server; sleep 1

# The save at shutdown, after the server went away: resurrect writes an empty `last`.
sleep 1 # a new file name (they're named by the second)
HOME=$D/home XDG_DATA_HOME="" TMUX="$socket,0,0" bash "$RESURRECT/save.sh" quiet > /dev/null 2>&1
check "the save without a server made last empty (the bug this guards against)" 0 "$(wc -c < "$R/last" | tr -d ' ')"

T -f "$D/test.conf" new-session -d -s scratch; sleep 1
T run-shell -b "$RESURRECT/restore.sh"
for _ in $(seq 60); do grep -q "done" "$D/log" 2> /dev/null && break; sleep 0.5; done
check "restored from the last good save" "one two" "$(T list-windows -t work -F '#W' 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"
check "last points at the good save again" yes "$(grep -q $'^pane\twork' "$R/last" && echo yes)"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
