# shellcheck shell=bash
# saves_dir: tmux-resurrect's save folder, worked out as resurrect does (its scripts/helpers.sh,
# resurrect_dir). Sourced by scripts/mend-last.sh and scripts/pre-restore.sh.
saves_dir() {
	local dir
	dir=$(tmux show-option -gqv @resurrect-dir)
	if [ -z "$dir" ]; then
		if [ -d "$HOME/.tmux/resurrect" ]; then dir=$HOME/.tmux/resurrect; else dir=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect; fi
	fi
	echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"
}
