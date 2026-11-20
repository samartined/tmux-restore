#!/usr/bin/env bash
# Makes sure tmux-resurrect's `last` points at a save with panes. Run by tmux-restore.tmux as it
# loads, before anything restores, by the pre-restore-all hook (scripts/pre-restore.sh) and by the
# post-save-all hook (scripts/post-save.sh). `last` goes bad two ways:
#   - a save made after the server went away (at shutdown) finds no panes, and resurrect still
#     makes it `last`: a restore would bring back nothing;
#   - two saves in the same second (the timer and continuum, say, or two at shutdown) write the
#     same file: one makes it `last`, the other finds it unchanged and deletes it, and `last`
#     points at nothing; a restore then doesn't even start, so the pre-restore hook never runs.
# Either way, point `last` at the newest save that has panes.
# shellcheck source=scripts/saves-dir.sh
. "$(dirname "$0")/saves-dir.sh"
dir=$(saves_dir)
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
