#!/usr/bin/env bash
# Saves tmux now, if a tmux server is running. The macOS shutdown watcher runs this; its output
# goes to ~/Library/Logs/tmux-restore.log.
#
# --periodic: run by the timer that saves every few minutes (tmux-restore-save.timer on Linux, a
# LaunchAgent on macOS), because tmux-continuum saves only while a client is attached. It skips a
# server that started less than 5 minutes ago (it may still be restoring, and a save then would
# replace the good one with half a restore), and a save continuum made in the last 4 minutes.
periodic=""
[[ ${1:-} == --periodic ]] && periodic=1
if ! tmux has-session 2> /dev/null; then
	[[ -n $periodic ]] || echo "$(date '+%F %T') no tmux server to save"
	exit 0
fi
if [[ -n $periodic ]]; then
	now=$(date +%s)
	started=$(tmux display-message -p '#{start_time}')
	(( now - ${started:-0} >= 300 )) || exit 0
	continuum=$(tmux show-option -gqv @continuum-save-last-timestamp)
	(( now - ${continuum:-0} >= 240 )) || exit 0
fi
save=$(tmux show-option -gqv @resurrect-save-script-path) # set by tmux-resurrect
if "${save:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}" quiet; then
	echo "$(date '+%F %T') tmux saved"
else
	echo "$(date '+%F %T') tmux save failed ($?)"
fi
