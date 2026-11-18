#!/usr/bin/env bash
# Makes sure tmux-resurrect's `last` points at a save with panes. Run by the pre-restore-all hook
# (scripts/pre-restore.sh) and the post-save-all hook (scripts/post-save.sh). `last` goes bad two
# ways:
#   - a save made after the server went away (at shutdown) finds no panes, and resurrect still
#     makes it `last`: a restore would bring back nothing;
#   - two saves in the same second (the timer and continuum, say) write the same file: one makes
#     it `last`, the other finds it unchanged and deletes it, and `last` points at nothing; a
#     restore then doesn't even start.
# Either way, point `last` at the newest save that has panes.
# The save folder, worked out as tmux-resurrect does (scripts/helpers.sh, resurrect_dir).
dir=$(tmux show-option -gqv @resurrect-dir)
if [ -z "$dir" ]; then
	if [ -d "$HOME/.tmux/resurrect" ]; then dir=$HOME/.tmux/resurrect; else dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect; fi
fi
dir=$(echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g")
if [ -L "$dir/last" ] || [ -e "$dir/last" ]; then
	if ! grep -q $'^pane\t' "$dir/last" 2> /dev/null; then
		# Saves are named tmux_resurrect_<YYYYmmddTHHMMSS>.txt, so the glob lists them oldest first.
		saves=("$dir"/tmux_resurrect_*.txt)
		for (( i = ${#saves[@]} - 1; i >= 0; i-- )); do
			if grep -q $'^pane\t' "${saves[i]}" 2> /dev/null; then
				ln -fs "${saves[i]##*/}" "$dir/last"
				break
			fi
		done
	fi
fi
exit 0
