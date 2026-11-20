#!/usr/bin/env bash
# tmux-restore: sets up tmux-resurrect and tmux-continuum so that tmux comes back after a reboot,
# with each coding agent's conversation. Options you set yourself are left alone.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

option() { tmux show-option -gqv "$1"; }
default() { [ -n "$(option "$1")" ] || tmux set-option -g "$1" "$2"; }

main() {
	# Before anything restores (continuum and scripts/restore-safety-net.sh both wait a moment):
	# resurrect won't start a restore when `last` points at nothing, so its pre-restore hook can't
	# mend it then (scripts/mend-last.sh).
	"$CURRENT_DIR/scripts/mend-last.sh"
	# Only you can read the saves, from the first one on (scripts/private-saves.sh)
	"$CURRENT_DIR/scripts/private-saves.sh"

	default @continuum-restore on        # restore when the tmux server starts
	default @continuum-save-interval 1   # save every minute
	default @resurrect-capture-pane-contents on
	# What a pane showed can hold secrets, so keep less of it: the screen, not the whole scrollback,
	# and saves (each with every pane's command line) for 2 days instead of 30. resurrect always
	# keeps the newest 5.
	default @resurrect-pane-contents-area visible
	default @resurrect-delete-backup-after 1
	[ "$(uname -s)" = Linux ] && default @resurrect-save-command-strategy linux_procfs

	# The save hook rewrites each pane's command (scripts/save-hook.sh). A hook you already had
	# runs after it.
	local hook="$CURRENT_DIR/scripts/save-hook.sh" current
	current=$(option @resurrect-hook-post-save-layout)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-hook "$current"
	tmux set-option -g @resurrect-hook-post-save-layout "$hook"

	# Mark each restore, and restore here if tmux-continuum skips it by mistake
	# (scripts/restore-safety-net.sh). Only on a server that just started, like continuum.
	hook="$CURRENT_DIR/scripts/pre-restore.sh"
	current=$(option @resurrect-hook-pre-restore-all)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-pre-restore-hook "$current"
	tmux set-option -g @resurrect-hook-pre-restore-all "$hook"

	# After every save, make sure `last` is a save with panes (scripts/post-save.sh).
	hook="$CURRENT_DIR/scripts/post-save.sh"
	current=$(option @resurrect-hook-post-save-all)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-post-save-hook "$current"
	tmux set-option -g @resurrect-hook-post-save-all "$hook"

	# After a restore, answer Claude Code's home-folder trust prompt if @tmux-restore-trust-home is
	# on (scripts/post-restore.sh).
	hook="$CURRENT_DIR/scripts/post-restore.sh"
	current=$(option @resurrect-hook-post-restore-all)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-post-restore-hook "$current"
	tmux set-option -g @resurrect-hook-post-restore-all "$hook"
	local started
	started=$(tmux display-message -p '#{start_time}')
	[ -n "$started" ] && [ $(($(date +%s) - started)) -le 10 ] && tmux run-shell -b "$CURRENT_DIR/scripts/restore-safety-net.sh"

	# Commands the hook writes start with TMUX_RESTORE=1, and after a restore tmux-restore types
	# them itself, each once its shell is ready (scripts/type-commands.sh). Earlier versions had
	# resurrect type them, through this entry in @resurrect-processes: take it out, or they would
	# be typed twice.
	local procs marker='"~^TMUX_RESTORE=1 "'
	procs=$(option @resurrect-processes)
	case $procs in
	*"$marker"*)
		procs=$(printf '%s' "${procs//"$marker"/}" | sed 's/  */ /g; s/^ //; s/ $//')
		if [ -n "$procs" ]; then tmux set-option -g @resurrect-processes "$procs"; else tmux set-option -gu @resurrect-processes; fi
		;;
	esac
}
main
