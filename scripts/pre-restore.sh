#!/usr/bin/env bash
# tmux-resurrect pre-restore-all hook: marks that a restore has started (see
# scripts/restore-safety-net.sh), makes sure `last` is a save with panes, then runs the hook you
# had before tmux-restore, if any.
tmux set-option -g @tmux-restore-restored 1

# A save made after the tmux server went away (at shutdown, say) finds no panes, and resurrect
# still makes it `last`: the restore would bring back nothing. resurrect reads `last` only after
# this hook, so point it back at the newest save that has panes.
# The save folder, worked out as tmux-resurrect does (scripts/helpers.sh, resurrect_dir).
dir=$(tmux show-option -gqv @resurrect-dir)
if [ -z "$dir" ]; then
	if [ -d "$HOME/.tmux/resurrect" ]; then dir=$HOME/.tmux/resurrect; else dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect; fi
fi
dir=$(echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g")
if [ -e "$dir/last" ] && ! grep -q $'^pane\t' "$dir/last"; then
	# Saves are named tmux_resurrect_<YYYYmmddTHHMMSS>.txt, so the glob lists them oldest first.
	saves=("$dir"/tmux_resurrect_*.txt)
	for (( i = ${#saves[@]} - 1; i >= 0; i-- )); do
		if grep -q $'^pane\t' "${saves[i]}" 2> /dev/null; then
			ln -fs "${saves[i]##*/}" "$dir/last"
			break
		fi
	done
fi

next=$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)
[ -n "$next" ] && eval "$next"
exit 0
