#!/usr/bin/env bash
# Saves tmux now, if a tmux server is running. The macOS shutdown watcher runs this; its output
# goes to ~/Library/Logs/tmux-restore.log.
#
# --periodic: run by the timer that saves every few minutes (tmux-restore-save.timer on Linux, a
# LaunchAgent on macOS), because tmux-continuum saves only while a client is attached. It skips:
#   - a server that started less than 5 minutes ago: it may still be restoring, and a save then
#     would replace the good one with half a restore;
#   - a save continuum made in the last 4 minutes, and auto-save turned off
#     (@continuum-save-interval 0).
# It tells continuum it saved, so the two don't save at once, and logs only failures.
# Runs with macOS's /bin/bash 3.2 (the LaunchAgent).
periodic=""
[[ ${1:-} == --periodic ]] && periodic=1
if ! tmux has-session 2> /dev/null; then
	[[ -n $periodic ]] || echo "$(date '+%F %T') no tmux server to save"
	exit 0
fi
# number VALUE: VALUE if it's a whole number, else 0
number() { if [[ $1 =~ ^[0-9]+$ ]]; then echo "$1"; else echo 0; fi; }
if [[ -n $periodic ]]; then
	[[ $(tmux show-option -gqv @continuum-save-interval) == 0 ]] && exit 0
	now=$(date +%s)
	(( now - $(number "$(tmux display-message -p '#{start_time}')") >= 300 )) || exit 0
	(( now - $(number "$(tmux show-option -gqv @continuum-save-last-timestamp)") >= 240 )) || exit 0
	tmux set-option -g @continuum-save-last-timestamp "$now"
fi
save=$(tmux show-option -gqv @resurrect-save-script-path) # set by tmux-resurrect
if "${save:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}" quiet; then
	[[ -n $periodic ]] || echo "$(date '+%F %T') tmux saved"
else
	echo "$(date '+%F %T') tmux save failed ($?)"
fi
